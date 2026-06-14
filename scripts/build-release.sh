#!/usr/bin/env bash
# Build Frostty Release into build/Release/Frostty.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_OUT="${BUILD_DIR}/Release/Frostty.app"

if [[ ! -d "${REPO_ROOT}/GhosttyKit.xcframework" ]]; then
  echo "GhosttyKit not found at repo root; building..."
  "${SCRIPT_DIR}/build-ghostty-kit.sh"
fi

cd "${REPO_ROOT}"
xcodegen generate

mkdir -p "${BUILD_DIR}/Release"

echo "Building Frostty (Release)..."
xcodebuild \
  -project Frostty.xcodeproj \
  -scheme Frostty \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

built_app="${DERIVED_DATA}/Build/Products/Release/Frostty.app"
if [[ ! -d "${built_app}" ]]; then
  echo "Expected app not found at ${built_app}" >&2
  exit 1
fi

rm -rf "${APP_OUT}"
cp -R "${built_app}" "${APP_OUT}"

echo ""
echo "Release build ready"
echo "Run: open \"${APP_OUT}\""
