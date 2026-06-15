#!/usr/bin/env bash
set -euo pipefail

PROJECT="codexBar.xcodeproj"
SCHEME="codexBar"
CONFIGURATION="Debug"
DERIVED_DATA="/tmp/codexbar-derived"
APP_NAME="codexAppBar.app"
PROCESS_NAME="codexAppBar"
BUILD_ONLY=0
RUN_ONLY=0
CLEAN=0
SKIP_KILL=0

usage() {
  cat <<'EOF'
Usage: scripts/restart-local.sh [options]

Options:
  --project PATH       xcodeproj path (default: codexBar.xcodeproj)
  --scheme NAME        scheme name (default: codexBar)
  --config CONFIG      build configuration (default: Debug)
  --derived-data PATH  derivedData path (default: /tmp/codexbar-derived)
  --build-only         only run xcodebuild, do not open app
  --run-only           only kill and open the existing built app
  --clean              pass `clean build` before compile
  --skip-kill          do not kill existing app process
  -h, --help           show this help

Note:
  The build output is expected at:
  <derived-data>/Build/Products/<CONFIG>/<app-name>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --scheme)
      SCHEME="$2"
      shift 2
      ;;
    --config)
      CONFIGURATION="$2"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="$2"
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --run-only)
      RUN_ONLY=1
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --skip-kill)
      SKIP_KILL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$BUILD_ONLY" == "1" && "$RUN_ONLY" == "1" ]]; then
  echo "--build-only and --run-only cannot be used together." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"

run_build() {
  local build_target=(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO)

  if [[ "$CLEAN" == "1" ]]; then
    build_target+=(clean)
  fi

  build_target+=(build)

  echo ">> xcodebuild: ${build_target[*]}"
  (cd "$ROOT_DIR" && "${build_target[@]}")
}

run_app() {
  if [[ -d "$APP_PATH" ]]; then
    if [[ "$SKIP_KILL" == "0" ]]; then
      pkill -x "$PROCESS_NAME" || true
      sleep 0.5
    fi

    echo ">> Open: $APP_PATH"
    open -n "$APP_PATH"
    sleep 1
    pgrep -x "$PROCESS_NAME" || true
    exit 0
  fi

  echo "Built app not found: $APP_PATH" >&2
  echo "Run build first or set --run-only to false when needed." >&2
  exit 1
}

if [[ "$RUN_ONLY" == "1" ]]; then
  run_app
  exit 0
fi

run_build

if [[ "$BUILD_ONLY" == "0" ]]; then
  run_app
fi

