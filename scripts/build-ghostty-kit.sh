#!/usr/bin/env bash
# Build GhosttyKit.xcframework from the latest ghostty release tag into the repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GHOSTTY_DIR="${GHOSTTY_DIR:-${HOME}/repos/ghostty}"
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

if [[ ! -d "${GHOSTTY_DIR}/.git" ]]; then
  echo "ghostty repo not found at ${GHOSTTY_DIR}" >&2
  echo "Clone it or set GHOSTTY_DIR." >&2
  exit 1
fi

resolve_latest_release_tag() {
  git -C "${GHOSTTY_DIR}" fetch --tags --quiet 2>/dev/null || true

  # Prefer GitHub's latest release when gh is available; fall back to highest v* tag.
  if command -v gh >/dev/null 2>&1; then
    local gh_tag
    gh_tag="$(GHOSTTY_DIR="${GHOSTTY_DIR}" gh release view --repo ghostty-org/ghostty --json tagName --jq .tagName 2>/dev/null || true)"
    if [[ -n "${gh_tag}" ]]; then
      echo "${gh_tag}"
      return
    fi
  fi

  local latest_tag
  latest_tag="$(git -C "${GHOSTTY_DIR}" tag -l 'v*' --sort=-v:refname | head -n 1)"
  if [[ -z "${latest_tag}" ]]; then
    echo "No ghostty release tags (v*) found in ${GHOSTTY_DIR}" >&2
    echo "Fetch tags with: git -C \"${GHOSTTY_DIR}\" fetch --tags" >&2
    exit 1
  fi
  echo "${latest_tag}"
}

GHOSTTY_TAG="${GHOSTTY_TAG:-$(resolve_latest_release_tag)}"

prune_macos_only_xcframework() {
  local xcframework="$1"

  rm -rf \
    "${xcframework}/ios-arm64" \
    "${xcframework}/ios-arm64-simulator"

  # ghostty's zig build always bundles iOS slices with -Dxcframework-target=universal.
  # Frostty is macOS-only; rewrite Info.plist to match the remaining slice.
  cat > "${xcframework}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libghostty.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>libghostty.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

  if [[ ! -d "${xcframework}/macos-arm64_x86_64" ]]; then
    echo "Expected macOS slice missing: ${xcframework}/macos-arm64_x86_64" >&2
    exit 1
  fi
}

echo "Building GhosttyKit ${GHOSTTY_TAG} (${OPTIMIZE}) from ${GHOSTTY_DIR}..."
(
  cd "${GHOSTTY_DIR}"
  git fetch --tags --quiet 2>/dev/null || true
  git checkout "${GHOSTTY_TAG}"
  zig build \
    -Doptimize="${OPTIMIZE}" \
    -Demit-xcframework=true \
    -Demit-macos-app=false
)

rm -rf "${REPO_ROOT}/GhosttyKit.xcframework"
cp -R "${GHOSTTY_DIR}/macos/GhosttyKit.xcframework" "${REPO_ROOT}/GhosttyKit.xcframework"
prune_macos_only_xcframework "${REPO_ROOT}/GhosttyKit.xcframework"

commit="$(git -C "${GHOSTTY_DIR}" rev-parse HEAD)"
mkdir -p "${REPO_ROOT}/GhosttyKit"
cat > "${REPO_ROOT}/GhosttyKit/VERSION" <<EOF
ghostty_tag=${GHOSTTY_TAG}
ghostty_commit=${commit}
optimize=${OPTIMIZE}
built_at=$(date -u +"%Y-%m-%dT%H:%MZ")
output=${REPO_ROOT}/GhosttyKit.xcframework
macos_slice=macos-arm64_x86_64/libghostty.a
build_command=scripts/build-ghostty-kit.sh
pin_command=GHOSTTY_TAG=vX.Y.Z scripts/build-ghostty-kit.sh
check_build_mode=ghostty_info().build_mode (0=Debug, 2=ReleaseFast) or disassemble _ghostty_info
notes=Defaults to latest ghostty release tag. iOS slices are stripped post-build (macOS universal only).
EOF

echo "Installed ${REPO_ROOT}/GhosttyKit.xcframework"
echo "Pinned ${REPO_ROOT}/GhosttyKit/VERSION"
