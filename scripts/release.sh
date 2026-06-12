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
  1. 读取上一个 GitHub Release tag，并用 git log 生成中文 release notes
  2. xcodebuild clean archive
  3. 对 .app 做 ad-hoc 签名并验证
  4. 生成干净 zip（无 ._* / .DS_Store）
  5. 创建 annotated tag、推送 main/tag、创建 GitHub Release
  6. 校验上传 asset，并更新 dist/.last_tag 与 dist/.last_asset
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
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
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
  local sha256="$5"
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

run git fetch origin --tags --prune --prune-tags

if [[ -z "$TAG" ]]; then
  TAG="$(next_date_tag)"
elif tag_exists "$TAG"; then
  echo "tag 或 release 已存在：$TAG" >&2
  exit 1
fi

last_release_tag="$(gh release list --repo "$REPO" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
if [[ -z "$last_release_tag" || "$last_release_tag" == "null" ]]; then
  last_release_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi

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

date_suffix="$(date '+%Y%m%d')"
if [[ "$TAG" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.([0-9]+)$ ]]; then
  date_suffix="${date_suffix}.${BASH_REMATCH[1]}"
fi
asset_name="codexAppBar-${marketing_version}-${date_suffix}-release.zip"
asset_path="dist/${asset_name}"
app_path="${ARCHIVE_PATH}/${APP_RELATIVE_PATH}"

echo "发布目标："
echo "  Repo:       $REPO"
echo "  Branch:     $current_branch"
echo "  Tag:        $TAG"
echo "  Last tag:   ${last_release_tag:-<none>}"
echo "  Range:      ${release_range:-<all commits>}"
echo "  Asset:      $asset_path"
echo

confirm "确认开始构建并发布 ${TAG}？" || {
  echo "已取消发布。"
  exit 0
}

run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  clean archive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= \
  CODE_SIGNING_REQUIRED=NO

if [[ "$DRY_RUN" != 1 && ! -d "$app_path" ]]; then
  echo "archive 中未找到 app：$app_path" >&2
  exit 1
fi

run codesign --force --deep --sign - "$app_path"
run codesign --verify --deep --strict --verbose=2 "$app_path"

run mkdir -p dist
run rm -f "$asset_path"
run ditto --norsrc -c -k --keepParent "$app_path" "$asset_path"

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
trap 'rm -f "$notes_tmp"' EXIT
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$notes_tmp"
else
  release_notes_from_git "$last_release_tag" "$release_range" "$asset_name" "$marketing_version" "$sha256" > "$notes_tmp"
fi

echo
echo "Release notes:"
echo "--------------"
cat "$notes_tmp"
echo "--------------"
echo

confirm "确认创建 tag、推送并发布 GitHub Release？" || {
  echo "已取消发布。"
  exit 0
}

run git tag -a "$TAG" -m "CodexAppBar $TAG"
run git push origin "$current_branch"
run git push origin "$TAG"

run gh release create "$TAG" "$asset_path" \
  --repo "$REPO" \
  --title "CodexAppBar $TAG" \
  --notes-file "$notes_tmp" \
  --latest

if [[ "$DRY_RUN" != 1 ]]; then
  remote_digest="$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"${asset_name}\") | .digest" 2>/dev/null || true)"
  if [[ -n "$remote_digest" && "$remote_digest" != "sha256:${sha256}" ]]; then
    echo "远端 asset SHA 不一致：${remote_digest} != sha256:${sha256}" >&2
    exit 1
  fi
  gh release view "$TAG" --repo "$REPO"
fi

run git fetch --tags --prune --prune-tags
if [[ "$DRY_RUN" != 1 ]]; then
  printf '%s\n' "$TAG" > dist/.last_tag
  printf '%s\n' "$asset_name" > dist/.last_asset
fi

echo
echo "发布完成：${TAG}"
echo "产物：${asset_path}"
echo "SHA-256：${sha256}"
