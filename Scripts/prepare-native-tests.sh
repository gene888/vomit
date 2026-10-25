#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH="$PWD/work/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build --build-tests --disable-sandbox --scratch-path "$PWD/work/SwiftBuild"
runner="$PWD/work/NativeValidation.app"
mkdir -p "$runner/Contents/MacOS"
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -parse-as-library -target arm64-apple-macos14.0 -swift-version 5 Scripts/ValidationRunner.swift -o "$runner/Contents/MacOS/StageCueValidation"
python3 - "$runner" "$PWD" <<'PY'
import plistlib, sys
from pathlib import Path
plist = dict(CFBundleExecutable='StageCueValidation', CFBundleIdentifier='local.StageCue.NativeValidation', CFBundleName='StageCue Validation', CFBundlePackageType='APPL', LSMinimumSystemVersion='14.0', StageCueSourceRoot=sys.argv[2])
with (Path(sys.argv[1])/'Contents/Info.plist').open('wb') as f: plistlib.dump(plist, f)
PY
codesign --force --sign - "$runner"
print "Open $runner to run tests. Results are in work/native-tests.log and work/native-tests.exit."
