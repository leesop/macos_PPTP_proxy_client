#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
mkdir -p "$root/build/clang-cache" "$root/build/swift-cache"
cmake -S "$root/proxy-engine" -B "$root/build/engine" -DCMAKE_BUILD_TYPE=Release
cmake --build "$root/build/engine" -j 6
tar -xzf "$root/pptp-1.10.0.tar.gz" -C "$root/build"
make -C "$root/build/pptp-1.10.0" CC=clang -j 6
app="$root/build/PPTPProxy.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/lwip/COPYING" "$app/Contents/Resources/lwIP-COPYING"
cp "$root/build/pptp-1.10.0/COPYING" "$app/Contents/Resources/PPTP-COPYING"
cp "$root/build/engine/pptp-proxy" "$app/Contents/MacOS/pptp-proxy"
cp "$root/build/pptp-1.10.0/pptp" "$app/Contents/MacOS/pptp"
CLANG_MODULE_CACHE_PATH="$root/build/clang-cache" SWIFT_MODULE_CACHE_PATH="$root/build/swift-cache" \
  swiftc -sdk "$sdk" -target arm64-apple-macosx14.0 -parse-as-library -O \
  "$root/PPTPProxyClient.swift" -o "$app/Contents/MacOS/PPTPProxyClient" \
  -framework SwiftUI -framework AppKit -framework Security
chmod 755 "$app/Contents/MacOS/"*
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
print "빌드 완료: $app"
