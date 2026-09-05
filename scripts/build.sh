#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Kimi Code"
BUNDLE_NAME="Kimi.app"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${BUILD_DIR}/${BUNDLE_NAME}"

echo "==> [1/4] 清理历史构建产物..."
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${DIST_DIR}"

echo "==> [2/4] 编译 Swift 原生二进制..."
TARGET_ARCH="$(uname -m)"
TARGET_TRIPLE="${TARGET_ARCH}-apple-macos13.0"

swiftc -O \
    -parse-as-library \
    -target "${TARGET_TRIPLE}" \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    "${ROOT_DIR}/Sources/KimiServiceManager.swift" \
    "${ROOT_DIR}/Sources/WebView.swift" \
    "${ROOT_DIR}/Sources/ContentView.swift" \
    "${ROOT_DIR}/Sources/App.swift" \
    -o "${APP_BUNDLE}/Contents/MacOS/Kimi"

echo "==> [3/4] 组装 App Bundle 资源与图标..."
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "==> [4/4] 执行本地代码签名..."
codesign --force --deep --sign - "${APP_BUNDLE}"
xattr -rc "${APP_BUNDLE}" 2>/dev/null || true

cp -R "${APP_BUNDLE}" "${DIST_DIR}/${BUNDLE_NAME}"

echo ""
echo "🎉 构建成功！"
echo "产物路径: ${DIST_DIR}/${BUNDLE_NAME}"
echo "可直接在访达中运行，或复制到系统应用程序目录: cp -R '${DIST_DIR}/${BUNDLE_NAME}' /Applications/"
