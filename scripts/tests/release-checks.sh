#!/usr/bin/env bash
set -euo pipefail

# 轻量离线自检脚本：验证 release.sh 的 CI 状态校验与 build.sh 的代码签名决议分支。
# 纯本地临时隔离运行，禁止真实网络调用、真实钥匙串写入与完整构建。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"

# 1. 隔离 stub: git（离线隔离，拦截 fetch，模拟 branch、status 与指定 HEAD SHA）
cat <<'EOF' > "$STUB_BIN/git"
#!/usr/bin/env bash
case "$1" in
  rev-parse)
    if [ "${2:-}" = "--abbrev-ref" ] && [ "${3:-}" = "HEAD" ]; then
      echo "main"
    elif [ "${2:-}" = "HEAD" ] || [ "${2:-}" = "origin/main" ]; then
      echo "${MOCK_HEAD_SHA:-1111111111111111111111111111111111111111}"
    else
      echo "unknown"
    fi
    ;;
  status)
    exit 0
    ;;
  fetch)
    # 严格离线，不访问远程
    exit 0
    ;;
  add|commit|tag)
    echo "$1" >> "$MOCK_RELEASE_STEPS"
    ;;
  *)
    echo "测试禁止未声明的 git 操作" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN/git"

# 2. 隔离 stub: gh（根据环境变量输出预设 CI 数据或模拟 API 错误）
cat <<'EOF' > "$STUB_BIN/gh"
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "gh: API rate limit exceeded or network down" >&2
  exit 1
fi

if [ -n "${MOCK_GH_OUTPUT+x}" ]; then
  echo -n "$MOCK_GH_OUTPUT"
  exit 0
fi

exit 0
EOF
chmod +x "$STUB_BIN/gh"

# 3. 隔离 stub: security（根据环境变量模拟是否存在指定自签名证书）
cat <<'EOF' > "$STUB_BIN/security"
#!/usr/bin/env bash
case "$1" in
  find-identity)
    if [ "${MOCK_HAS_CERT:-0}" = "1" ]; then
      echo '  1) 1234567890ABCDEF1234567890ABCDEF12345678 "Inkpot Self-Signed"'
      echo '     1 valid identities found'
    else
      echo '     0 valid identities found'
    fi
    exit 0
    ;;
  *)
    echo "测试禁止未声明的 security 操作" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN/security"

TARGET_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"

pass_count=0
run_test() {
  local desc="$1"
  shift
  echo -n "运行测试: $desc ... "
  if "$@"; then
    echo "通过"
    pass_count=$((pass_count + 1))
  else
    echo "失败！" >&2
    exit 1
  fi
}

# --- 场景 1: CI 匹配待发布 main HEAD、push 事件、已完成 success ---
test_ci_success() {
  local out
  out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$TARGET_SHA completed success push"
    source scripts/release.sh
    check_ci_state 2>&1
  )"
  [[ "$out" == *"CI 状态：main HEAD"*"运行成功"* ]]
}

# --- 场景 2: 最新 CI 提交是旧 SHA，必须阻止发版 ---
test_ci_old_sha() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$OLD_SHA completed success push"
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"不一致"* ]]
}

# --- 场景 3: 最新 CI 事件为非 push，必须阻止发版 ---
test_ci_non_push() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$TARGET_SHA completed success workflow_dispatch"
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"必须为 push 事件"* ]]
}

# --- 场景 4: 最新 CI 运行失败，必须阻止发版 ---
test_ci_failure() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$TARGET_SHA completed failure push"
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"运行未成功"* ]]
}

# --- 场景 5: 最新 CI 运行中/排队中，必须阻止发版 ---
test_ci_running() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$TARGET_SHA in_progress null push"
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"尚未完成"* ]]
}

# --- 场景 6: 查不到 CI 运行记录，必须阻止发版 ---
test_ci_no_records() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT=""
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"未找到 main 分支上 build-and-test.yml 的 CI 运行记录"* ]]
}

# --- 场景 7: API 错误或网络异常，必须阻止发版 ---
test_ci_api_error() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_FAIL=1
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"获取 CI 运行状态失败"* ]]
}

# --- 场景 8: 未安装 gh 工具，必须阻止发版 ---
test_ci_missing_gh() {
  local no_gh_bin="$TMP_DIR/no_gh_bin"
  mkdir -p "$no_gh_bin"
  ln -s "$STUB_BIN/git" "$no_gh_bin/git"

  local out
  if out="$(
    # PATH 只包含 git，不包含 gh
    export PATH="$no_gh_bin:/bin:/usr/bin"
    source scripts/release.sh
    check_ci_state 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"未安装 gh"* ]]
}

# --- 场景 9: 正式构建（RELEASE=1）缺签名证书必须失败 ---
test_build_release_missing_cert() {
  local out
  if out="$(
    export PATH="$STUB_BIN:$PATH"
    export RELEASE=1
    export MOCK_HAS_CERT=0
    source scripts/build.sh
    resolve_signing_identity 2>&1
  )"; then
    return 1
  fi
  [[ "$out" == *"发布构建（RELEASE=1）要求签名证书"* ]]
}

# --- 场景 10: 本地构建缺证书允许退回 ad-hoc ---
test_build_local_adhoc_fallback() {
  local out
  out="$(
    export PATH="$STUB_BIN:$PATH"
    unset RELEASE
    export MOCK_HAS_CERT=0
    source scripts/build.sh
    resolve_signing_identity 2>&1
    echo "FINAL_SIGN_IDENTITY=$SIGN_IDENTITY"
  )"
  [[ "$out" == *"退回 ad-hoc 签名"* ]] && [[ "$out" == *"FINAL_SIGN_IDENTITY=-"* ]]
}

# --- 场景 11: 证书存在时正常使用指定自签名证书 ---
test_build_cert_found() {
  local out
  out="$(
    export PATH="$STUB_BIN:$PATH"
    export RELEASE=1
    export MOCK_HAS_CERT=1
    source scripts/build.sh
    resolve_signing_identity 2>&1
    echo "FINAL_SIGN_IDENTITY=$SIGN_IDENTITY"
  )"
  [[ "$out" == *"使用证书签名：Inkpot Self-Signed"* ]] && [[ "$out" == *"FINAL_SIGN_IDENTITY=Inkpot Self-Signed"* ]]
}

# --- 场景 12: 端到端 scripts/release.sh --check 只读校验通过 ---
test_release_check_e2e_pass() {
  local out
  out="$(
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$TARGET_SHA completed success push"
    bash scripts/release.sh --check
  )"
  [[ "$out" == *"校验完成（未改动任何文件）"* ]]
}

# --- 场景 13: 端到端 scripts/release.sh --check CI 不匹配时被拒绝 ---
test_release_check_e2e_fail() {
  if (
    export PATH="$STUB_BIN:$PATH"
    export MOCK_HEAD_SHA="$TARGET_SHA"
    export MOCK_GH_OUTPUT="$OLD_SHA completed success push"
    bash scripts/release.sh --check >/dev/null 2>&1
  ); then
    return 1
  fi
  return 0
}

test_build_before_tag() {
  local steps="$TMP_DIR/release-steps" status expected
  for status in 0 1; do
    : > "$steps"
    if (
      export PATH="$STUB_BIN:$PATH"
      export MOCK_HEAD_SHA="$TARGET_SHA"
      export MOCK_GH_OUTPUT="$TARGET_SHA completed success push"
      export MOCK_RELEASE_STEPS="$steps" MOCK_BUILD_STATUS="$status"
      # 独立进程保留 set -e，避免 if 条件中的子 shell 忽略构建失败。
      /bin/bash -c '
        source scripts/release.sh
        bump_version() { :; }
        verify_assets() { echo verify >> "$MOCK_RELEASE_STEPS"; }
        bash() {
          [ "$1" = "scripts/build.sh" ] || return 1
          echo build >> "$MOCK_RELEASE_STEPS"
          return "$MOCK_BUILD_STATUS"
        }
        main 999.0.0
      ' >/dev/null 2>&1
    ); then
      [ "$status" = 0 ] || return 1
      expected=$'build\nverify\nadd\ncommit\ntag'
    else
      [ "$status" = 1 ] || return 1
      expected=build
    fi
    [ "$(cat "$steps")" = "$expected" ] || return 1
  done
}

run_test "CI 成功通过（HEAD SHA / push / completed success）" test_ci_success
run_test "CI 拦截旧 SHA（即使最新 run 成功）" test_ci_old_sha
run_test "CI 拦截非 push 事件（如 workflow_dispatch）" test_ci_non_push
run_test "CI 拦截运行失败（conclusion 非 success）" test_ci_failure
run_test "CI 拦截未完成（status 运行中或排队中）" test_ci_running
run_test "CI 拦截查不到运行记录" test_ci_no_records
run_test "CI 拦截 API 错误与网络异常" test_ci_api_error
run_test "CI 拦截未安装 gh" test_ci_missing_gh
run_test "正式构建（RELEASE=1）缺证书被拒绝" test_build_release_missing_cert
run_test "本地构建缺证书退回 ad-hoc 签名" test_build_local_adhoc_fallback
run_test "存在证书时成功选择指定证书" test_build_cert_found
run_test "端到端 scripts/release.sh --check 成功只读通过" test_release_check_e2e_pass
run_test "端到端 scripts/release.sh --check 在 CI 异常时拒绝发版" test_release_check_e2e_fail
run_test "构建与校验成功后才提交打标签，构建失败不创建标签" test_build_before_tag

echo "=========================================="
echo "自检全部通过！共运行 $pass_count 个测试用例。"
