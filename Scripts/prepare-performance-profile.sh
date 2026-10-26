#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH="$PWD/work/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PWD/work/PerformanceBaseline"
swift build -c release -debug-info-format none --build-tests --disable-sandbox --scratch-path "$PWD/work/ProfileBuild" -Xswiftc -enable-testing -Xswiftc -DSTAGECUE_PROFILING
python3 - "$PWD" <<'PY'
from pathlib import Path
import sys, plistlib, os
root=Path(sys.argv[1]); runner=root/'work/PerformanceProfile.app'
(runner/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
s=(root/'Scripts/ValidationRunner.swift').read_text()
s=s.replace('work/SwiftBuild/out/Products/Debug/', 'work/ProfileBuild/out/Products/Release/').replace('work/SwiftBuild/arm64-apple-macosx/debug/', 'work/ProfileBuild/arm64-apple-macosx/release/')
s=s.replace('work/native-tests', 'work/PerformanceBaseline/runner').replace('StageCue Audio Validation', 'StageCue Performance Profiling')
s=s.replace('process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")', 'process.executableURL = root.appendingPathComponent("work/PerformanceWorkload.app/Contents/MacOS/ProfileHost")')
s=s.replace('process.arguments = ["--test-bundle-path", bundle.path, "--testing-library", "swift-testing"]', 'process.arguments = [bundle.path]')
s=s.replace('func applicationShouldTerminateAfterLastWindowClosed', 'func applicationWillTerminate(_ notification: Notification) { process?.terminate() }\n    func applicationShouldTerminateAfterLastWindowClosed')
s=s.replace('process.environment = environment', 'environment["STAGECUE_PROFILE_ROOT"] = root.appendingPathComponent("work/PerformanceBaseline").path\n            environment["STAGECUE_PROFILE_MODE"] = Bundle.main.object(forInfoDictionaryKey: "StageCueProfileMode") as? String ?? "full"\n            process.environment = environment')
s=s.replace('Running StageCue automated tests in native macOS context…', 'Measuring StageCue playback, UI, memory and scheduler…').replace('Test runner finished', 'Profiling host finished')
assert 'process.arguments = [bundle.path]' in s
assert 'ProfileHost' in s
(root/'work/ProfileRunner.swift').write_text(s)
host=root/'work/PerformanceWorkload.app'
(host/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
with (host/'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleExecutable='ProfileHost',CFBundleIdentifier='local.StageCue.PerformanceWorkload',CFBundleName='StageCue Workload',CFBundlePackageType='APPL',LSMinimumSystemVersion='14.0'),f)
with (runner/'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleExecutable='StageCueProfile',CFBundleIdentifier='local.StageCue.PerformanceProfile',CFBundleName='StageCue Profile',CFBundlePackageType='APPL',LSMinimumSystemVersion='14.0',StageCueSourceRoot=str(root),StageCueProfileMode=os.environ.get("STAGECUE_PROFILE_MODE","full")),f)
PY
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -parse-as-library -target arm64-apple-macos14.0 -swift-version 5 Scripts/../work/ProfileRunner.swift -o work/PerformanceProfile.app/Contents/MacOS/StageCueProfile
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -parse-as-library -target arm64-apple-macos14.0 -swift-version 5 Scripts/PerformanceHost.swift -o work/PerformanceWorkload.app/Contents/MacOS/ProfileHost
codesign --force --sign - work/PerformanceWorkload.app
codesign --force --sign - work/PerformanceProfile.app
print "Open $PWD/work/PerformanceProfile.app. Results: work/PerformanceBaseline/results.json"
