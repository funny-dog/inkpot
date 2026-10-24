#!/usr/bin/env swift
// Inkpot 应用层性能测量：冷启动时间与内存占用，留作 UI 改版前后的对比基线。
//
// 用法（在仓库根目录）：
//   swift scripts/measure-perf.swift              # 全部：冷启动（含预热）+ 内存
//   swift scripts/measure-perf.swift cold         # 只测冷启动
//   swift scripts/measure-perf.swift memory       # 只测内存（含每文档增量）
//   swift scripts/measure-perf.swift snapshot     # 只打印当前会话的一次内存快照
//   可选参数：--runs 5（冷启动轮数）--docs 8（内存增量的最大临时文档数）--out 路径（结果另存）
//
// 测量口径：
// - 冷启动：`open -a Inkpot` 发出到屏幕上出现该应用第一个窗口（CGWindowList，layer 0 且尺寸非零），
//   包含窗口/标签会话恢复的成本，是用户真实体感；首轮预热不计入统计。应用保持在用户当前会话上测量。
// - 内存：主进程 + 归属于它的 WebKit 子进程（WebContent/Networking/GPU，用 `launchctl print pid/<pid>`
//   归属，免 root）的 physical footprint 之和（`footprint` 命令）。每文档增量在受控会话里测：
//   依次打开 1/4/8 个内容相同的临时文档，取相邻两档的差值除以文档数，含新窗口与 WebView 固定开销。
// - 会话安全（AGENTS.md）：退出应用走正常 AppleScript quit（保留系统未保存提示），20 秒没退出
//   （多半是有未保存文档弹了保存框）立即中止，绝不强制终止；内存测量会临时清空会话恢复记录
//   （先整体备份 com.erhu.inkpot 域，测完原样写回），用户原有的窗口与标签不受影响。
// - 临时文档放在 /tmp/inkpot-perf-docs/，测完删除。

import AppKit
import CoreGraphics
import Foundation

let bundleID = "com.erhu.inkpot"
let appName = "Inkpot"
let defaultsDomain = "com.erhu.inkpot"
let sessionKey = "session.state"

// MARK: - 参数

struct Options {
    var mode = "all"
    var coldRuns = 5
    var docs = 8
    var out: String? = nil

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            switch args[i] {
            case "all", "cold", "memory", "snapshot": mode = args[i]
            case "--runs": i += 1; if i < args.count { coldRuns = Int(args[i]) ?? coldRuns }
            case "--docs": i += 1; if i < args.count { docs = Int(args[i]) ?? docs }
            case "--out": i += 1; if i < args.count { out = args[i] }
            default: break
            }
            i += 1
        }
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
var report: [String] = []

func emit(_ line: String) {
    print(line)
    report.append(line)
}

// MARK: - 基础工具

func sh(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

func runningApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
}

func appPID() -> pid_t? { runningApp()?.processIdentifier }

func isRunning() -> Bool { runningApp() != nil }

func waitUntilRunning(timeout: TimeInterval = 15) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if isRunning() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

/// 正常退出应用；返回 false 表示超时（可能弹了未保存提示），调用方必须中止而不是强杀。
func quitApp(timeout: TimeInterval = 20) -> Bool {
    guard runningApp() != nil else { return true }
    guard let script = NSAppleScript(source: "tell application id \"\(bundleID)\" to quit") else { return false }
    var error: NSDictionary?
    _ = script.executeAndReturnError(&error)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if runningApp() == nil { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return runningApp() == nil
}

func runApple(_ source: String) -> Bool {
    guard let script = NSAppleScript(source: source) else { return false }
    var error: NSDictionary?
    _ = script.executeAndReturnError(&error)
    return error == nil
}

/// 等窗口数量连续几次采样不再变化，返回稳定后的数量（超时返回最后一样本）。
func waitWindowsStable(timeout: TimeInterval = 15) -> Int {
    var last = -1
    var unchanged = 0
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let count = windowCount()
        if count == last {
            unchanged += 1
            if unchanged >= 3 { return count }
        } else {
            unchanged = 0
            last = count
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    return max(last, 0)
}

// MARK: - 窗口检测（CGWindowList，不需要辅助功能/录屏权限）

/// 该应用 layer 0、尺寸非零的窗口数（用全量窗口列表兜底跨 Space 的情况）。
func windowCount() -> Int {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return 0 }
    guard let pid = appPID() else { return 0 }
    var count = 0
    for window in list {
        guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, width > 50,
              let height = bounds["Height"] as? Double, height > 50 else { continue }
        count += 1
    }
    return count
}

/// 等待该应用出现第一个合格窗口，返回自 t0 起的毫秒数（超时返回 nil）。
func waitFirstWindow(since t0: DispatchTime, timeout: TimeInterval = 30) -> Double? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if windowCount() > 0 {
            return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
}

// MARK: - 内存

struct MemorySnapshot {
    var mainMB: Double = 0
    var webkitMB: [String: Double] = [:]
    var windows = 0

    var totalMB: Double { mainMB + webkitMB.values.reduce(0, +) }
}

/// 解析 `footprint <pid>` 输出里的 physical footprint 总量，统一成 MB。
func footprintMB(pid: pid_t) -> Double? {
    guard let output = sh("footprint \(pid)") else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"Footprint:\s*([\d.]+)\s*(KB|MB|GB)"#) else { return nil }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          let numberRange = Range(match.range(at: 1), in: output),
          let unitRange = Range(match.range(at: 2), in: output),
          let value = Double(output[numberRange]) else { return nil }
    switch output[unitRange] {
    case "GB": return value * 1024
    case "KB": return value / 1024
    default: return value
    }
}

/// 归属该应用的 WebKit 子进程：`launchctl print pid/<pid>` 会列出注册在应用 pid 域里的
/// WebContent / Networking / GPU 服务，第一列是存活进程的 pid（0 表示未运行）。免 root。
func webkitChildren(of app: pid_t) -> [(pid: pid_t, kind: String)] {
    guard let output = sh("launchctl print pid/\(app)") else { return [] }
    var result: [(pid_t, String)] = []
    for line in output.split(separator: "\n") {
        guard let match = line.range(of: #"^\s*(\d+)\s+\S+\s+com\.apple\.WebKit\.[\w-]+"#, options: .regularExpression) else { continue }
        let parts = line[match].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let pid = parts.first.flatMap({ Int($0) }), pid > 0 else { continue }
        let label = parts.last.map(String.init) ?? ""
        let kind = label.hasPrefix("com.apple.WebKit.")
            ? String(label.dropFirst("com.apple.WebKit.".count)).split(separator: ".").first.map(String.init) ?? label
            : label
        result.append((pid_t(pid), kind))
    }
    return result
}

func snapshot() -> MemorySnapshot {
    var snap = MemorySnapshot()
    guard let pid = appPID() else { return snap }
    snap.mainMB = footprintMB(pid: pid) ?? 0
    for child in webkitChildren(of: pid) {
        if let mb = footprintMB(pid: child.pid) {
            snap.webkitMB[child.kind, default: 0] += mb
        }
    }
    snap.windows = windowCount()
    return snap
}

func formatted(_ snap: MemorySnapshot) -> String {
    let webkit = snap.webkitMB.sorted { $0.key < $1.key }
        .map { "\($0.key)=\(String(format: "%.0f", $0.value))MB" }
        .joined(separator: " + ")
    return "合计 \(String(format: "%.0f", snap.totalMB))MB（主进程 \(String(format: "%.0f", snap.mainMB))MB\(webkit.isEmpty ? "" : " + " + webkit)），\(snap.windows) 个窗口"
}

// MARK: - 会话备份与还原（内存测量用）

let stashURL = URL(fileURLWithPath: "/tmp/inkpot-perf-session.plist")

func stashDefaults() -> Bool {
    guard sh("defaults export \(defaultsDomain) '\(stashURL.path)'") != nil else { return false }
    return FileManager.default.fileExists(atPath: stashURL.path)
}

func restoreDefaults() {
    _ = sh("defaults import \(defaultsDomain) '\(stashURL.path)'")
    try? FileManager.default.removeItem(at: stashURL)
}

func clearSessionKey() {
    _ = sh("defaults delete \(defaultsDomain) \(sessionKey)")
}

// MARK: - 临时文档

func makeTempDocs(_ count: Int) -> [URL] {
    let dir = URL(fileURLWithPath: "/tmp/inkpot-perf-docs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sample = """
    # inkpot-perf-PLACEHOLDER

    这是 Inkpot 性能测量的临时文档：一段普通正文、一行行内公式 $a^2 + b^2 = c^2$、
    一个小代码块和一个两列表格，用来近似真实文档的编辑器状态。

    ```swift
    func add(_ a: Int, _ b: Int) -> Int { a + b }
    ```

    | 项目 | 数值 |
    | --- | --- |
    | 内存 | 观测 |
    | 冷启动 | 观测 |

    ```markdown
    ## 占位小节

    重复正文让文档体量接近日常笔记：编辑器、预览与大纲都要为此付一份稳定开销，
    测量脚本用它衡量每多开一个标签页要付出的内存成本，改版前后保持同一份内容可比。
    ```
    """
    return (1...count).map { index in
        let url = dir.appendingPathComponent(String(format: "inkpot-perf-%02d.md", index))
        try? sample.replacingOccurrences(of: "PLACEHOLDER", with: String(format: "%02d", index))
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - 冷启动

func measureColdStart(runs: Int) -> Bool {
    var samples: [Double] = []
    for index in 0..<(runs + 1) {
        guard quitApp() else {
            emit("- **冷启动：第 \(max(index, 1)) 轮退出超时（20 秒），多半是有未保存文档弹了保存框。已中止测量，未做任何其他改动。**")
            return false
        }
        let isWarmup = index == 0
        let t0 = DispatchTime.now()
        _ = sh("open -a \(appName)")
        guard waitUntilRunning() else {
            emit("- **冷启动：应用没有起来，中止。**")
            return false
        }
        guard let elapsed = waitFirstWindow(since: t0) else {
            emit("- **冷启动：30 秒内没有等到第一个窗口，中止。**")
            return false
        }
        Thread.sleep(forTimeInterval: 2.0) // 让会话恢复与渲染稳定下来
        let windows = waitWindowsStable(timeout: 5)
        if isWarmup {
            emit("- 预热轮（不计入）：\(String(format: "%.0f", elapsed))ms，\(windows) 个窗口")
        } else {
            samples.append(elapsed)
            emit("- 冷启动 \(index)/\(runs)：\(String(format: "%.0f", elapsed))ms（\(windows) 个窗口）")
        }
    }
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    emit("- **冷启动中位数：\(String(format: "%.0f", median))ms**（\(runs) 轮，最快 \(String(format: "%.0f", sorted.first!))ms，最慢 \(String(format: "%.0f", sorted.last!))ms）")
    return true
}

// MARK: - 内存（受控会话，含每文档增量）

func measureMemory(docCount: Int) -> Bool {
    // 先正常退出：退出成功才动会话备份；退出被拦（未保存文档）就到此为止
    guard quitApp() else {
        emit("- **内存：退出超时（20 秒），多半是有未保存文档弹了保存框。已中止，会话未做任何改动。**")
        return false
    }
    guard stashDefaults() else {
        emit("- **内存：备份应用偏好（defaults export）失败，已中止。**")
        return false
    }
    defer {
        restoreDefaults()
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/inkpot-perf-docs"))
        // 恢复用户原会话后把应用带回来
        if !isRunning() { _ = sh("open -a \(appName)") }
    }
    clearSessionKey()
    _ = sh("open -a \(appName)")
    guard waitUntilRunning() else {
        emit("- **内存：应用没有起来，已中止（会话已还原）。**")
        return false
    }
    Thread.sleep(forTimeInterval: 3.0)
    _ = waitWindowsStable(timeout: 5)

    let stages: [Int] = [0] + stride(from: 1, through: docCount, by: max(docCount / 3, 1)).map { $0 }
    var totals: [Double] = []
    var opened = 0
    var files: [URL] = []
    for (stageIndex, stage) in stages.enumerated() {
        if stage > opened {
            let batch = makeTempDocs(stage).suffix(stage - opened)
            files.append(contentsOf: batch)
            _ = sh("open -a \(appName) " + batch.map { "'\($0.path)'" }.joined(separator: " "))
            opened = stage
            Thread.sleep(forTimeInterval: 3.0) // 等渲染与内存趋于稳定
            _ = waitWindowsStable(timeout: 10)
        }
        let snap = snapshot()
        totals.append(snap.totalMB)
        emit("- \(stage) 个文档：\(formatted(snap))")
        if stageIndex == 0 { files.removeAll() } // 0 档没有文件
    }

    let increments: [(from: Int, to: Int, perDoc: Double)] = (1..<stages.count).map { i in
        let span = stages[i] - stages[i - 1]
        return (stages[i - 1], stages[i], (totals[i] - totals[i - 1]) / Double(span))
    }
    for inc in increments {
        emit("- 增量 \(inc.from)→\(inc.to) 文档：每文档约 \(String(format: "%.1f", inc.perDoc))MB")
    }
    return true
}

// MARK: - 环境

func environmentLines() {
    let machine = sh("sysctl -n machdep.cpu.brand_string")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    let memory = sh("sysctl -n hw.memsize").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map { "\($0 / 1_073_741_824) GB" } ?? "?"
    let macOS = ProcessInfo.processInfo.operatingSystemVersionString
    var version = "?"
    var sign = "?"
    if let infoPlist = sh("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/\(appName).app/Contents/Info.plist") {
        version = infoPlist.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let codesign = sh("codesign -dv /Applications/\(appName).app 2>&1") {
        let hasRuntime = codesign.contains("runtime")
        let authority = codesign.range(of: #"Authority=(.*)"#, options: .regularExpression).map { String(codesign[$0]) } ?? "ad-hoc"
        sign = "\(hasRuntime ? "hardened runtime" : "无 hardened runtime") / \(authority)"
    }
    emit("## 环境")
    emit("- 机器：\(machine)，\(memory)，\(macOS)")
    emit("- 应用：/Applications/\(appName).app v\(version)；签名：\(sign)")
}

// MARK: - 主流程

environmentLines()
switch options.mode {
case "snapshot":
    if isRunning() {
        emit("## 当前快照")
        emit("- \(formatted(snapshot()))")
    } else {
        emit("Inkpot 没有在运行。")
    }
case "cold":
    emit("## 冷启动（含会话恢复）")
    _ = measureColdStart(runs: options.coldRuns)
case "memory":
    emit("## 内存（受控会话）")
    _ = measureMemory(docCount: options.docs)
default:
    emit("## 冷启动（含会话恢复）")
    let coldOK = measureColdStart(runs: options.coldRuns)
    emit("")
    emit("## 内存（受控会话）")
    if coldOK {
        _ = measureMemory(docCount: options.docs)
    } else {
        emit("- 冷启动测量被拦下（未保存文档），内存测量需要退出应用，同样跳过。")
    }
}

if let out = options.out {
    try? report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("\n（结果已另存：\(out)）")
}
