#!/usr/bin/env bash
set -euo pipefail

PROJECT="codexBar.xcodeproj"
SCHEME="codexBar"
CONFIGURATION="Release"
ARCHIVE_PATH="build/codexBar.xcarchive"
APP_RELATIVE_PATH="Products/Applications/codexAppBar.app"
DEFAULT_REPO="iamzjt-front-end/codexbar"

REPO="$DEFAULT_REPO"
TAG=""
NOTES_FILE=""
ASSUME_YES=0
DRY_RUN=0
ALLOW_DIRTY=0
TASK_STARTED=0
CANCELED=0
TEMP_FILES=()
LOG_DIR=""
LOG_INDEX=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[38;5;203m'
  GREEN=$'\033[38;5;149m'
  BLUE=$'\033[38;5;81m'
  YELLOW=$'\033[38;5;221m'
  MUTED=$'\033[38;5;245m'
  BG_BLUE=$'\033[48;5;81m\033[38;5;236m'
  BG_GREEN=$'\033[48;5;149m\033[38;5;236m'
else
  RESET=""
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  BLUE=""
  YELLOW=""
  MUTED=""
  BG_BLUE=""
  BG_GREEN=""
fi

task_start() {
  TASK_STARTED=1
  printf '\n%s%s Release task start %s\n\n' "$BG_BLUE" "$BOLD" "$RESET"
}

task_end() {
  printf '\n%s%s Release task end %s\n' "$BG_GREEN" "$BOLD" "$RESET"
}

step() {
  printf '%s│%s\n' "$DIM" "$RESET"
  printf '%s◇%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$1" "$RESET"
}

prompt_step() {
  printf '%s│%s\n' "$DIM" "$RESET"
  printf '%s■%s %s%s%s\n' "$RED" "$RESET" "$BOLD" "$1" "$RESET"
}

print_box() {
  local title="$1"
  local body="$2"
  step "$title"
  printf '%s┌────────────────────────────────────────%s\n' "$DIM" "$RESET"
  while IFS= read -r line; do
    printf '%s│%s  %s%s%s\n' "$DIM" "$RESET" "$BLUE" "${line:- }" "$RESET"
  done <<< "$body"
  printf '%s└────────────────────────────────────────%s\n' "$DIM" "$RESET"
}

ensure_log_dir() {
  if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="$(mktemp -d -t codexbar-release-logs.XXXXXX)"
  fi
}

slugify_label() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//'
}

print_log_tail() {
  local log_file="$1"
  printf '%s│%s  %s日志：%s%s\n' "$DIM" "$RESET" "$MUTED" "$log_file" "$RESET" >&2
  if [[ -s "$log_file" ]]; then
    printf '%s│%s  %s最近 80 行输出：%s\n' "$DIM" "$RESET" "$MUTED" "$RESET" >&2
    tail -n 80 "$log_file" >&2
  fi
}

run_progress() {
  local running_label="$1"
  local done_label="$2"
  shift 2

  if [[ "$DRY_RUN" == 1 ]]; then
    step "$running_label"
    run "$@"
    return
  fi

  ensure_log_dir

  local slug log_file pid status frame_index frame
  slug="$(slugify_label "$running_label")"
  [[ -z "$slug" ]] && slug="command"
  LOG_INDEX=$((LOG_INDEX + 1))
  log_file="${LOG_DIR}/$(printf '%02d' "$LOG_INDEX")-${slug}.log"

  printf '%s│%s\n' "$DIM" "$RESET"

  set +e
  "$@" >"$log_file" 2>&1 &
  pid=$!

  if [[ -t 1 ]]; then
    local frames=("-" "\\" "|" "/")
    frame_index=0
    while kill -0 "$pid" >/dev/null 2>&1; do
      frame="${frames[$frame_index]}"
      printf '\r\033[K%s◇%s %s%s%s %s%s%s' "$GREEN" "$RESET" "$BLUE" "$frame" "$RESET" "$BOLD" "$running_label" "$RESET"
      frame_index=$(((frame_index + 1) % ${#frames[@]}))
      sleep 0.12
    done
  else
    printf '%s◇%s %s...%s %s%s%s\n' "$GREEN" "$RESET" "$BLUE" "$RESET" "$BOLD" "$running_label" "$RESET"
  fi

  wait "$pid"
  status=$?
  set -e

  if [[ "$status" == 0 ]]; then
    if [[ -t 1 ]]; then
      printf '\r\033[K%s◇%s %s✓%s %s%s%s\n' "$GREEN" "$RESET" "$GREEN" "$RESET" "$BOLD" "$done_label" "$RESET"
    else
      printf '%s│%s  %s✓%s %s%s%s\n' "$DIM" "$RESET" "$GREEN" "$RESET" "$BOLD" "$done_label" "$RESET"
    fi
    return 0
  fi

  if [[ -t 1 ]]; then
    printf '\r\033[K%s◇%s %s✕%s %s%s%s\n' "$RED" "$RESET" "$RED" "$RESET" "$BOLD" "$running_label" "$RESET" >&2
  else
    printf '%s│%s  %s✕%s %s%s%s\n' "$DIM" "$RESET" "$RED" "$RESET" "$BOLD" "$running_label" "$RESET" >&2
  fi
  print_log_tail "$log_file"
  return "$status"
}

cancel_release() {
  CANCELED=1
  exit 0
}

cleanup_and_finish() {
  local status=$?
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f "$file"
  done

  if [[ -n "$LOG_DIR" ]]; then
    if [[ "$status" == 0 || "$CANCELED" == 1 ]]; then
      rm -rf "$LOG_DIR"
    else
      printf '%sRelease logs: %s%s\n' "$MUTED" "$LOG_DIR" "$RESET" >&2
    fi
  fi

  if [[ "$TASK_STARTED" == 1 ]]; then
    if [[ "$CANCELED" == 1 ]]; then
      printf '\n%sOperation canceled%s\n' "$RED" "$RESET"
    elif [[ "$status" != 0 ]]; then
      printf '\n%sRelease task failed%s\n' "$RED" "$RESET"
    fi
    task_end
  fi
}

trap cleanup_and_finish EXIT

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [options]

Options:
  --tag TAG          指定发布 tag；默认使用当天日期，如 v2026.06.12，冲突时自动递增为 .1/.2
  --repo OWNER/REPO  GitHub 仓库；默认 iamzjt-front-end/codexbar
  --notes-file FILE  使用自定义中文 release notes 文件
  --yes             跳过交互确认
  --dry-run         只打印将执行的发布信息，不创建 tag、不推送、不发 release
  --allow-dirty     允许 tracked 文件有未提交改动
  -h, --help        显示帮助

脚本会执行：
  1. 交互式查询并选择发布 tag
  2. 读取上一个 GitHub Release tag，并用 git log 生成中文 release notes
  3. xcodebuild clean archive
  4. 对 .app 做 ad-hoc 签名并验证
  5. 生成干净 zip（无 ._* / .DS_Store）
  6. 创建 annotated tag、推送 main/tag、创建 GitHub Release
  7. 校验上传 asset，并更新 dist/.last_tag 与 dist/.last_asset

正常发布时会隐藏底层命令日志，只显示当前步骤和加载动画；失败时会打印对应日志尾部。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "非交互环境请加 --yes。" >&2
    exit 1
  fi
  prompt_step "$prompt"
  read -r -p "  Continue? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

choose_release_tag() {
  local suggested="$1"
  local choice custom

  if [[ -n "$TAG" ]]; then
    print_box "Selected release tag" "$TAG"
    return
  fi

  if [[ "$ASSUME_YES" == 1 || ! -t 0 ]]; then
    TAG="$suggested"
    print_box "Selected release tag" "$TAG"
    return
  fi

  prompt_step "Select the version to release"
  printf '  %s1)%s %s%s%s  %srecommended%s\n' "$YELLOW" "$RESET" "$BOLD" "$suggested" "$RESET" "$MUTED" "$RESET"
  printf '  %s2)%s Custom tag\n' "$YELLOW" "$RESET"
  printf '  %sq)%s Cancel\n' "$YELLOW" "$RESET"
  read -r -p "  Choose [1]: " choice

  case "${choice:-1}" in
    1)
      TAG="$suggested"
      ;;
    2)
      read -r -p "  Enter custom tag: " custom
      if [[ -z "$custom" ]]; then
        cancel_release
      fi
      if tag_exists "$custom"; then
        echo "tag 或 release 已存在：$custom" >&2
        exit 1
      fi
      TAG="$custom"
      ;;
    q|Q)
      cancel_release
      ;;
    *)
      echo "无效选择：$choice" >&2
      exit 1
      ;;
  esac

  print_box "Selected release tag" "$TAG"
}

tag_exists() {
  local candidate="$1"
  git rev-parse -q --verify "refs/tags/$candidate" >/dev/null 2>&1 && return 0
  git ls-remote --exit-code --tags origin "refs/tags/$candidate" >/dev/null 2>&1 && return 0
  gh release view "$candidate" --repo "$REPO" >/dev/null 2>&1 && return 0
  return 1
}

next_date_tag() {
  local base candidate suffix
  base="v$(date '+%Y.%m.%d')"
  candidate="$base"
  suffix=1
  while tag_exists "$candidate"; do
    candidate="${base}.${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate"
}

release_notes_from_git() {
  local last_tag="$1"
  local range="$2"
  local asset_name="$3"
  local marketing_version="$4"
  local bundle_version="$5"
  local sha256="$6"
  local changelog

  if [[ -n "$range" ]]; then
    changelog="$(git log "$range" --pretty=format:'- %s（%h）' --no-merges || true)"
  else
    changelog="$(git log --pretty=format:'- %s（%h）' --no-merges || true)"
  fi

  {
    echo "## 更新内容"
    echo
    if [[ -n "$last_tag" ]]; then
      echo "自 ${last_tag} 以来的变更："
      echo
    fi
    if [[ -n "$changelog" ]]; then
      echo "$changelog"
    else
      echo "- 本次发布包含重新打包和发布产物更新。"
    fi
    echo
    echo "## 构建信息"
    echo
    echo "- App 版本：${marketing_version}"
    echo "- 构建号：${bundle_version}"
    echo "- 发布产物：${asset_name}"
    echo "- SHA-256：${sha256}"
  }
}

require_cmd git
require_cmd gh
require_cmd xcodebuild
require_cmd codesign
require_cmd ditto
require_cmd unzip
require_cmd shasum

task_start

if [[ ! -d .git ]]; then
  echo "请在仓库根目录运行 scripts/release.sh。" >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
if [[ -z "$current_branch" ]]; then
  echo "当前处于 detached HEAD，不能发布。" >&2
  exit 1
fi

if [[ "$ALLOW_DIRTY" != 1 && -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "存在未提交的 tracked 改动，先提交后再发布；如确实需要可加 --allow-dirty。" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "notes 文件不存在：$NOTES_FILE" >&2
  exit 1
fi

run_progress "同步标签中" "标签已同步" git fetch origin --tags --prune --prune-tags

if [[ -n "$TAG" ]] && tag_exists "$TAG"; then
  echo "tag 或 release 已存在：$TAG" >&2
  exit 1
fi

last_release_tag="$(gh release list --repo "$REPO" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
if [[ -z "$last_release_tag" || "$last_release_tag" == "null" ]]; then
  last_release_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi
print_box "Last release tag" "${last_release_tag:-undefined}"

suggested_tag="$(next_date_tag)"
choose_release_tag "$suggested_tag"

release_range=""
if [[ -n "$last_release_tag" ]] && git rev-parse -q --verify "${last_release_tag}^{commit}" >/dev/null 2>&1; then
  release_range="${last_release_tag}..HEAD"
fi

marketing_version="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/{print $2; exit}' \
    | tr -d '[:space:]'
)"
if [[ -z "$marketing_version" ]]; then
  echo "无法读取 MARKETING_VERSION。" >&2
  exit 1
fi

if [[ "$TAG" =~ ^v([0-9]{4})\.([0-9]{2})\.([0-9]{2})(\.([0-9]+))?$ ]]; then
  date_suffix="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  if [[ -n "${BASH_REMATCH[5]:-}" ]]; then
    date_suffix="${date_suffix}.${BASH_REMATCH[5]}"
  fi
else
  date_suffix="$(date '+%Y%m%d')"
fi
bundle_version="$date_suffix"
asset_name="codexAppBar-${marketing_version}-${date_suffix}-release.zip"
asset_path="dist/${asset_name}"
app_path="${ARCHIVE_PATH}/${APP_RELATIVE_PATH}"

print_box "Release target" "Repo:   $REPO
Branch: $current_branch
Tag:    $TAG
Range:  ${release_range:-<all commits>}
Build:  $bundle_version
Asset:  $asset_path"

confirm "确认开始构建并发布 ${TAG}？" || {
  cancel_release
}

run_progress "编译中" "编译完成" xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  clean archive \
  CURRENT_PROJECT_VERSION="$bundle_version" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= \
  CODE_SIGNING_REQUIRED=NO

if [[ "$DRY_RUN" != 1 && ! -d "$app_path" ]]; then
  echo "archive 中未找到 app：$app_path" >&2
  exit 1
fi

run_progress "签名中" "签名完成" codesign --force --deep --sign - "$app_path"
run_progress "签名校验中" "签名校验完成" codesign --verify --deep --strict --verbose=2 "$app_path"

run mkdir -p dist
run rm -f "$asset_path"
run_progress "打包中" "打包完成" ditto --norsrc -c -k --keepParent "$app_path" "$asset_path"

if [[ "$DRY_RUN" != 1 ]]; then
  if unzip -l "$asset_path" | grep -qE '(^|/)\._|\.DS_Store'; then
    echo "zip 中包含 ._* 或 .DS_Store，请检查打包命令。" >&2
    exit 1
  fi
fi

sha256="dry-run"
if [[ "$DRY_RUN" != 1 ]]; then
  sha256="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
fi

notes_tmp="$(mktemp -t codexbar-release-notes.XXXXXX.md)"
TEMP_FILES+=("$notes_tmp")
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$notes_tmp"
else
  release_notes_from_git "$last_release_tag" "$release_range" "$asset_name" "$marketing_version" "$bundle_version" "$sha256" > "$notes_tmp"
fi

echo
step "Release notes preview"
cat "$notes_tmp"
echo

confirm "确认创建 tag、推送并发布 GitHub Release？" || {
  cancel_release
}

run_progress "创建 tag 中" "tag 已创建" git tag -a "$TAG" -m "CodexAppBar $TAG"
run_progress "推送 main 中" "main 已推送" git push origin "$current_branch"
run_progress "推送 tag 中" "tag 已推送" git push origin "$TAG"

run_progress "发布 GitHub Release 中" "GitHub Release 已发布" gh release create "$TAG" "$asset_path" \
  --repo "$REPO" \
  --title "CodexAppBar $TAG" \
  --notes-file "$notes_tmp" \
  --latest

release_url=""
asset_url=""
if [[ "$DRY_RUN" != 1 ]]; then
  remote_digest="$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"${asset_name}\") | .digest" 2>/dev/null || true)"
  if [[ -n "$remote_digest" && "$remote_digest" != "sha256:${sha256}" ]]; then
    echo "远端 asset SHA 不一致：${remote_digest} != sha256:${sha256}" >&2
    exit 1
  fi
  release_url="$(gh release view "$TAG" --repo "$REPO" --json url --jq '.url' 2>/dev/null || true)"
  asset_url="$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"${asset_name}\") | .url" 2>/dev/null || true)"
fi

run_progress "同步本地标签中" "本地标签已同步" git fetch --tags --prune --prune-tags
if [[ "$DRY_RUN" != 1 ]]; then
  printf '%s\n' "$TAG" > dist/.last_tag
  printf '%s\n' "$asset_name" > dist/.last_asset
fi

echo
echo "发布完成：${TAG}"
if [[ -n "${release_url:-}" ]]; then
  echo "Release：${release_url}"
fi
if [[ -n "${asset_url:-}" ]]; then
  echo "GitHub 包：${asset_url}"
fi
echo "产物：${asset_path}"
echo "SHA-256：${sha256}"
