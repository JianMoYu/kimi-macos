#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/Kimi.app"
DMG_NAME="Kimi-Installer-$(uname -m).dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
STAGING_DIR="${DIST_DIR}/dmg_staging"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "==> 未找到构建产物，正在先执行 build.sh..."
    "${SCRIPT_DIR}/build.sh"
fi

echo "==> 准备 DMG 打包工作区..."
rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"

echo "==> 拷贝应用程序与 Applications 快捷方式..."
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> 正在生成压缩 DMG 镜像..."
hdiutil create \
    -volname "Kimi Code" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

echo ""
echo "🎉 DMG 安装包生成成功！"
echo "DMG 路径: ${DMG_PATH}"
echo "体积: $(du -sh "${DMG_PATH}" | cut -f1)"
