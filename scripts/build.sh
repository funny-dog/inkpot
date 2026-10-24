#!/usr/bin/env bash
set -euo pipefail

# Inkpot 发布构建：CoreEditor 前端构建 → xcodebuild Release → 自签名（hardened runtime）→ DMG/ZIP。
#
#   bash scripts/build.sh               # 本地验证构建，产物只写 build/
#   RELEASE=1 bash scripts/build.sh     # 额外把发布件复制到仓库根目录（release.sh 用）
#
# 环境变量：
#   INKPOT_SIGN_IDENTITY     证书名称，默认「Inkpot Self-Signed」（须与 setup-signing.sh 一致）
#   INKPOT_KEYCHAIN          非默认钥匙串的路径
#   INKPOT_SKIP_WEB_BUILD=1  跳过 CoreEditor 前端构建（仅本地迭代用，前提是 editor/dist 已是最新）

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 遵守仓库约定：只影响本次构建，不改系统的 xcode-select
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_BUILD_DIR="$PROJECT_DIR/build/Release/Build/Products/Release/Inkpot.app"
STAGE_DIR="$PROJECT_DIR/build/dmg-stage"

fail() {
  echo "错误：$*" >&2
  exit 1
}

resolve_signing_identity() {
  # 优先使用 scripts/setup-signing.sh 生成的自签名证书：签名规则「标识 + 证书指纹」跨版本不变，
  # 用户升级后无需重新放行，后续自动更新也以它验签。发布构建（RELEASE=1）缺指定证书必须失败；
  # 本地验证构建（RELEASE 未设置或为 0）仍允许退回 ad-hoc 签名（升级后需重新放行）。
  SIGN_IDENTITY_NAME="${INKPOT_SIGN_IDENTITY:-Inkpot Self-Signed}"
  # 不用 grep -q：它命中即退出，security 若仍在输出会收到 SIGPIPE，pipefail 下误判失败（同 setup-signing.sh）
  local identities
  identities="$(security find-identity -p codesigning ${INKPOT_KEYCHAIN:+"$INKPOT_KEYCHAIN"} 2>/dev/null || true)"
  if [[ "$identities" == *"\"$SIGN_IDENTITY_NAME\""* ]]; then
    SIGN_IDENTITY="$SIGN_IDENTITY_NAME"
    echo "使用证书签名：$SIGN_IDENTITY"
  elif [ "${RELEASE:-0}" = "1" ]; then
    fail "发布构建（RELEASE=1）要求签名证书「${SIGN_IDENTITY_NAME}」，钥匙串中未找到。发布前请先运行 scripts/setup-signing.sh 配置证书"
  else
    SIGN_IDENTITY="-"
    echo "警告：未找到签名证书「${SIGN_IDENTITY_NAME}」，退回 ad-hoc 签名（升级后需重新放行）。发布前请先运行 scripts/setup-signing.sh" >&2
  fi
}

build_main() {
  echo "=== 1. 构建 CoreEditor 前端 ==="
  if [ "${INKPOT_SKIP_WEB_BUILD:-0}" != "1" ]; then
    if [ ! -d CoreEditor/node_modules ]; then
      echo "node_modules 缺失，先按 yarn.lock 安装依赖（与 CI 一致）……"
      (cd CoreEditor && node .yarn/releases/yarn-4.18.0.cjs install --immutable)
    fi
    # build = lint + typecheck + vite 单文件打包 + render-assets（公式/Mermaid/代码语言资源）
    (cd CoreEditor && node .yarn/releases/yarn-4.18.0.cjs build)
  else
    echo "INKPOT_SKIP_WEB_BUILD=1，跳过前端构建（沿用 CoreEditor/editor/dist 现有产物）"
  fi
  [ -f CoreEditor/editor/dist/index.html ] || fail "CoreEditor/editor/dist/index.html 不存在：前端构建未执行或失败"

  echo "=== 2. xcodebuild Release ==="
  xcodebuild build \
    -project App/Inkpot.xcodeproj \
    -scheme Inkpot \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath build/Release \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

  [ -d "$APP_BUILD_DIR" ] || fail "构建产物缺失：$APP_BUILD_DIR"

  # 硬校验：编辑器页面与公式/Mermaid/代码语言资源必须真的进了 app，缺了立即失败，不静默发布残缺包。
  # （pbxproj 通过 index.html 文件引用 + math folder 引用把 CoreEditor/editor/dist 拷进 Resources。）
  for rel in \
    "Contents/MacOS/Inkpot" \
    "Contents/Resources/index.html" \
    "Contents/Resources/ThirdPartyNotices.md" \
    "Contents/Resources/AppIcon.icns" \
    "Contents/Resources/math/katex.mjs" \
    "Contents/Resources/math/mermaid.mjs" \
    "Contents/Resources/math/katex.min.css" \
    "Contents/Resources/math/lang-javascript.mjs"; do
    [ -s "$APP_BUILD_DIR/$rel" ] || fail "构建产物缺少 ${rel}（检查 CoreEditor 构建与 pbxproj 资源引用）"
  done
  [ -d "$APP_BUILD_DIR/Contents/Resources/math/fonts" ] || fail "构建产物缺少 math/fonts（KaTeX 字体未打包）"

  # 版本号唯一来源是 App/Info.plist，从构建产物读取，用于给 DMG/ZIP 命名
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUILD_DIR/Contents/Info.plist")
  [ -n "$VERSION" ] || fail "读不到构建产物的 CFBundleShortVersionString"

  echo "=== 3. 代码签名 ==="
  resolve_signing_identity

  # 单个 bundle、无扩展，不需要 --deep；-o runtime 开启 Hardened Runtime
  if [ -n "${INKPOT_KEYCHAIN:-}" ]; then
    codesign -s "$SIGN_IDENTITY" --keychain "$INKPOT_KEYCHAIN" --force -o runtime "$APP_BUILD_DIR"
  else
    codesign -s "$SIGN_IDENTITY" --force -o runtime "$APP_BUILD_DIR"
  fi

  # 硬校验：签名有效且带 runtime 标志，否则立即构建失败。
  # 先取完整输出再匹配：pipefail 下 `codesign -dv | grep -q` 会因 grep 提前退出、codesign 收到 SIGPIPE 而误判失败
  codesign --verify --strict "$APP_BUILD_DIR"
  sig_info="$(codesign -dv "$APP_BUILD_DIR" 2>&1)"
  if [[ "$sig_info" != *"flags="*"runtime"* ]]; then
    echo "错误：$APP_BUILD_DIR 未启用 Hardened Runtime" >&2
    exit 1
  fi
  echo "签名规则：$(codesign -d -r- "$APP_BUILD_DIR" 2>&1 | sed -n 's/.*designated => //p')"

  echo "=== 4. 打包 DMG 与 ZIP ==="
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  ditto "$APP_BUILD_DIR" "$STAGE_DIR/Inkpot.app"
  ln -shf /Applications "$STAGE_DIR/Applications"

  # 默认只写 build/：本地验证不应该改动仓库根目录的已发布产物。
  # 需要生成可直接上传的发布件时用 RELEASE=1（scripts/release.sh 会带上）。
  mkdir -p "$PROJECT_DIR/build"
  DMG_PATH="$PROJECT_DIR/build/Inkpot-$VERSION.dmg"
  ZIP_PATH="$PROJECT_DIR/build/Inkpot-v$VERSION.zip"
  DMG_SHA_PATH="$PROJECT_DIR/build/Inkpot.dmg.sha256"
  ZIP_SHA_PATH="$PROJECT_DIR/build/Inkpot-v$VERSION.zip.sha256"
  rm -f "$DMG_PATH" "$ZIP_PATH" "$ZIP_SHA_PATH" "$DMG_SHA_PATH"

  hdiutil create -volname "Inkpot" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"

  (cd "$STAGE_DIR" && zip -ry "$ZIP_PATH" Inkpot.app)
  (cd "$PROJECT_DIR/build" && shasum -a 256 "Inkpot-v$VERSION.zip" > "Inkpot-v$VERSION.zip.sha256")
  # 与 zip 对等：DMG 也要有自己的 .sha256，供下载页与用户校验
  (cd "$PROJECT_DIR/build" && shasum -a 256 "Inkpot-$VERSION.dmg" > "Inkpot.dmg.sha256")

  if [ "${RELEASE:-0}" = "1" ]; then
    echo "=== 5. 复制发布件到仓库根目录（RELEASE=1）==="
    cp "$DMG_PATH" "$PROJECT_DIR/Inkpot.dmg"
    cp "$ZIP_PATH" "$PROJECT_DIR/Inkpot-v$VERSION.zip"
    cp "$ZIP_SHA_PATH" "$PROJECT_DIR/Inkpot-v$VERSION.zip.sha256"
    (cd "$PROJECT_DIR" && shasum -a 256 "Inkpot.dmg" > "Inkpot.dmg.sha256")
    echo "发布件：Inkpot.dmg / Inkpot.dmg.sha256 / Inkpot-v$VERSION.zip（含 .sha256）"
  else
    echo "提示：本次为本地验证构建，仓库根目录的发布件未被改动；需要发布件请用 RELEASE=1 bash scripts/build.sh"
  fi

  echo "=== 构建完成！==="
  echo "DMG 产物: $DMG_PATH"
  echo "ZIP 产物: $ZIP_PATH"
  echo "SHA256:  $ZIP_SHA_PATH"
  echo "SHA256:  $DMG_SHA_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  build_main "$@"
fi
