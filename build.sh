#!/bin/bash
# Universal(Intel + Apple Silicon) Clampless.app 빌드
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Clampless.app"
MIN_OS="11.0"

rm -rf build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in x86_64 arm64; do
    echo "==> $arch 빌드"
    swiftc -O \
        -target "$arch-apple-macos$MIN_OS" \
        -o "build/Clampless-$arch" \
        Sources/*.swift
done

echo "==> Universal 바이너리 생성"
lipo -create build/Clampless-x86_64 build/Clampless-arm64 -output "$APP/Contents/MacOS/Clampless"
rm build/Clampless-x86_64 build/Clampless-arm64
cp Resources/Info.plist "$APP/Contents/Info.plist"
# VERSION=1.2.3 ./build.sh 처럼 주면 번들 버전에 반영 (CI에서 태그 값 사용)
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
[ -f Resources/AppIcon.icns ] || Scripts/make_icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc 서명"
codesign --force --sign - "$APP"

lipo -info "$APP/Contents/MacOS/Clampless"
echo "완료: $APP"
