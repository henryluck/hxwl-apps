#!/bin/bash
# 一键归档：xcodebuild archive → 自动补第三方 SDK dSYM → 产物就绪可上传。
#
# 用法：
#   Scripts/archive.sh              # 用 project.yml（真机，含 CrashBugly）
#   Scripts/archive.sh sim          # 用 project-simulator.yml（模拟器验证用）
#
# 产物：<工程根>/build/<Scheme>-<日期>.xcarchive
set -euo pipefail

cd "$(dirname "$0")/.."

XCODEGEN="${XCODEGEN:-$HOME/.local/opt/xcodegen/bin/xcodegen}"
MODE="${1:-device}"

if [[ "$MODE" == "sim" ]]; then
    SPEC="project-simulator.yml"; PROJ="FactoryCoreSim.xcodeproj"; SCHEME="FactoryCoreSim"
    SDK="iphonesimulator"
else
    SPEC="project.yml"; PROJ="FactoryCore.xcodeproj"; SCHEME="FactoryCore"
    SDK="iphoneos"
fi

# 1) 重新生成工程（保证版本号/依赖与 yml 同步）
"$XCODEGEN" generate --spec "$SPEC" >/dev/null
echo "▸ 工程已生成 ($SPEC)"

# 2) 归档
OUT="build/${SCHEME}-$(date +%Y-%m-%d_%H%M).xcarchive"
mkdir -p build
if [[ "$SDK" == "iphoneos" ]]; then
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
        -sdk iphoneos -archivePath "$OUT" archive \
        -allowProvisioningUpdates DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-363GQLCMXG}" \
        CODE_SIGN_STYLE=Automatic | tail -3
else
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
        -sdk iphonesimulator -archivePath "$OUT" archive | tail -3
fi
echo "▸ 归档完成: $OUT"

# 3) 补齐第三方 SDK dSYM（Bugly 空壳 dylib 等）
Scripts/fixup-dsyms.sh "$OUT"

# 4) 导出校验清单
APP=$(find "$OUT/Products/Applications" -maxdepth 1 -type d -name "*.app" | head -1)
echo "────────────────────────────────────────"
echo "归档自检："
echo "  版本: $(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist") ($(plutil -extract CFBundleVersion raw "$APP/Info.plist"))"
echo "  dSYMs:"
for d in "$OUT"/dSYMs/*.dSYM; do
    dwarfdump --uuid "$d" 2>/dev/null | sed 's/^/    /'
done
echo "────────────────────────────────────────"
echo "✓ 可用 Xcode Organizer 或 altool/xcrun notarytool 上传: $OUT"
