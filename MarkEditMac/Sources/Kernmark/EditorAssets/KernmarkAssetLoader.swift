//
//  KernmarkAssetLoader.swift
//  MarkEditMac
//
//  Created by Kernmark on 2026-10-23.
//

import WebKit
import UniformTypeIdentifiers
import os.log

/// 离线资源加载器：处理 kernmark-asset:// 协议
///
/// 用于在 Web 端按需动态加载打包在应用资源中的 KaTeX、Mermaid 等离线渲染库。
/// 示例：kernmark-asset://editor/katex/katex.min.js
@MainActor
public final class KernmarkAssetLoader: NSObject, WKURLSchemeHandler {
  public static let scheme = "kernmark-asset"

  /// 正在进行的任务集合，用于在任务被停止后防止重复调用
  private var activeTasks = Set<ObjectIdentifier>()

  public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let requestURL = task.request.url else {
      task.didFailWithError(URLError(.badURL))
      return
    }

    guard requestURL.host == "editor",
          let root = Bundle.main.resourceURL?.appendingPathComponent("EditorAssets", isDirectory: true) else {
      task.didFailWithError(URLError(.badURL))
      return
    }

    let taskID = ObjectIdentifier(task)
    activeTasks.insert(taskID)

    // 解析相对路径并安全规范化
    let relativePath = (requestURL.path.removingPercentEncoding ?? requestURL.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
    let rootPath = root.standardizedFileURL.path

    // 安全检查：确保目标文件位于 EditorAssets 目录下，防止路径穿越
    guard fileURL.path.hasPrefix(rootPath + "/") || fileURL.path == rootPath else {
      task.didFailWithError(URLError(.noPermissionsToReadFile))
      activeTasks.remove(taskID)
      return
    }

    guard let data = try? Data(contentsOf: fileURL) else {
      // 文件不存在，返回 404 状态码
      if let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 404,
        httpVersion: nil,
        headerFields: [
          "Access-Control-Allow-Origin": "*",
        ]
      ) {
        if activeTasks.contains(taskID) {
          task.didReceive(response)
          task.didFinish()
          activeTasks.remove(taskID)
        }
      } else {
        task.didFailWithError(URLError(.fileDoesNotExist))
        activeTasks.remove(taskID)
      }
      return
    }

    // 确定 MIME 类型
    let ext = fileURL.pathExtension.lowercased()
    let mimeType: String = {
      switch ext {
      case "mjs", "js":
        return "text/javascript"
      case "css":
        return "text/css"
      case "json":
        return "application/json"
      case "woff2":
        return "font/woff2"
      case "woff":
        return "font/woff"
      case "ttf":
        return "font/ttf"
      case "svg":
        return "image/svg+xml"
      default:
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
      }
    }()

    guard let response = HTTPURLResponse(
      url: requestURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": mimeType,
        "Access-Control-Allow-Origin": "*",
      ]
    ) else {
      task.didFailWithError(URLError(.badServerResponse))
      activeTasks.remove(taskID)
      return
    }

    guard activeTasks.contains(taskID) else {
      return
    }

    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
    activeTasks.remove(taskID)
  }

  public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    activeTasks.remove(ObjectIdentifier(task))
  }
}
