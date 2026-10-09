#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH="$PWD/work/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift test --disable-sandbox --scratch-path "$PWD/work/SwiftBuild"
