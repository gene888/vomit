#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
configuration=${1:-Release}
xcodebuild -project StageCue.xcodeproj -scheme StageCue -configuration "$configuration" -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/work/DerivedData" CODE_SIGNING_ALLOWED=NO build
codesign --force --sign - "$PWD/work/DerivedData/Build/Products/$configuration/StageCue.app"
codesign --verify --strict "$PWD/work/DerivedData/Build/Products/$configuration/StageCue.app"
