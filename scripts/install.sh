#!/usr/bin/env bash
#
# install.sh — build Frostty in Release configuration and install the
# resulting bundle to /Applications, replacing any existing copy.
#
# Usage: ./scripts/install.sh

set -euo pipefail

SCHEME="Frostty"
CONFIGURATION="Release"
APP_NAME="Frostty.app"
DEST="/Applications/${APP_NAME}"

# Resolve repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Use a script-local DerivedData path so the built product is easy to find
# and so we don't disturb Xcode's main DerivedData cache.
DERIVED_DATA="${REPO_ROOT}/build/DerivedData"
mkdir -p "${DERIVED_DATA}"

echo "==> Building ${SCHEME} (${CONFIGURATION})…"
xcodebuild \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    build

BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}"
if [[ ! -d "${BUILT_APP}" ]]; then
    echo "error: build succeeded but ${BUILT_APP} is missing" >&2
    exit 1
fi

if [[ -e "${DEST}" ]]; then
    echo "==> Removing existing ${DEST}"
    # Avoid surprises if the previous install is running.
    if pgrep -x "${SCHEME}" >/dev/null; then
        echo "warning: ${SCHEME} appears to be running; quit it before reinstalling" >&2
        exit 1
    fi
    rm -rf "${DEST}"
fi

echo "==> Installing to ${DEST}"
# -R preserves bundle metadata; cp into /Applications usually doesn't need
# sudo on a single-user Mac, but fall back to sudo if it does.
if ! cp -R "${BUILT_APP}" "${DEST}" 2>/dev/null; then
    echo "    (needs elevated permissions, retrying with sudo)"
    sudo cp -R "${BUILT_APP}" "${DEST}"
fi

echo "==> Done: ${DEST}"
