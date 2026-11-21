#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/DevLoadBar.app"
mkdir -p "$app/Contents/MacOS"
MACOSX_DEPLOYMENT_TARGET=13.0 xcrun swiftc -swift-version 5 -O Sources/*.swift -o "$app/Contents/MacOS/DevLoadBar"
ditto Resources "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
ditto --norsrc --noextattr "$app" .build/DevLoadBar.app
echo ".build/DevLoadBar.app"
