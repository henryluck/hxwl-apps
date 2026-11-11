#!/bin/bash
# 归档后 / 上传前：补齐第三方 SDK 的 dSYM，并做 UUID 全覆盖自检。
#
# 背景：Bugly 官方 SDK 是「静态 ar archive 型 framework」，经 SPM binaryTarget 接入后，
# swift-build 会额外生成一个 0 字节 __text、0 导出符号的转发空壳 dylib 塞进 App 的
# Frameworks/（真实 Bugly 代码全部静态链入主程序，主程序也不依赖这个空壳）。这个空壳
# 有自己的 LC_UUID，且每次重新归档都会变；dsymutil 因「no debug symbols」不会为它产
# dSYM → App Store Connect 上传后报
#   "The archive did not include a dSYM for the Bugly.framework with the UUIDs [...]"
#
# 解法：对归档内的空壳 dylib 直接跑 dsymutil，生成同 UUID 的 dSYM 容器（校验只机械比对
# UUID），放进归档的 dSYMs/。真实崩溃解析不依赖它（Bugly 代码在主程序 dSYM 里）。
#
# 用法：
#   Scripts/fixup-dsyms.sh                 # 不传参数 = 自动处理 ~/Library/.../Archives 里最新的归档
#   Scripts/fixup-dsyms.sh <xcarchive>    # 指定归档
# 退出码 0 = 所有 UUID 均已覆盖（可上传）；1 = 仍有缺失或校验失败。
set -euo pipefail

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE=$(find "$HOME/Library/Developer/Xcode/Archives" -type d -name "*.xcarchive" \
        -exec ls -dt {} + 2>/dev/null | head -1) || true
    echo "▸ 未指定归档，自动选取最新: $ARCHIVE"
fi
[[ -n "$ARCHIVE" && -d "$ARCHIVE" ]] || { echo "✗ 归档不存在: ${ARCHIVE:-<未指定>}" >&2; exit 1; }

APP_DIR=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -type d -name "*.app" | head -1) || true
[[ -n "${APP_DIR:-}" ]] || { echo "✗ 归档里没找到 .app: $ARCHIVE" >&2; exit 1; }

DSYMS_DIR="$ARCHIVE/dSYMs"
mkdir -p "$DSYMS_DIR"

# 只认「当前归档」里的 dSYM。旧实现用 mdfind 全局搜 Spotlight，会把别的归档里碰巧
# 同 UUID 的 dSYM 误判为已存在，从而跳过补齐（已移除）。
collect_dsym_uuids() {
    find "$DSYMS_DIR" -name "*.dSYM" -exec dwarfdump --uuid {} \; 2>/dev/null \
        | awk '{print $2}' | sort -u
}
HAVE=$(collect_dsym_uuids)

shopt -s nullglob
for FW in "$APP_DIR/Frameworks/"*.framework; do
    [[ -d "$FW" ]] || continue
    NAME=$(basename "$FW" .framework)
    BIN="$FW/$NAME"
    [[ -f "$BIN" ]] || continue
    U=$(dwarfdump --uuid "$BIN" 2>/dev/null | awk 'NR==1 {print $2}') || true
    [[ -n "$U" ]] || continue

    if echo "$HAVE" | grep -q "$U"; then
        echo "✓ $NAME.framework 已覆盖 ($U)"
        continue
    fi

    OUT="$DSYMS_DIR/$NAME.framework.dSYM"
    rm -rf "$OUT"
    echo "… 为 $NAME 生成 dSYM ($U)"
    if dsymutil "$BIN" -o "$OUT" >/tmp/dsymutil_err 2>&1; then
        # 无调试段时 dsymutil 只产 UUID 匹配的空容器，正好够 App Store 校验。
        grep -q "no debug symbols" /tmp/dsymutil_err 2>/dev/null && \
            echo "  （无调试段，仅生成 UUID 匹配的容器）"
        echo "✓ 已生成 $OUT"
    else
        echo "✗ $NAME 生成失败" >&2
        cat /tmp/dsymutil_err >&2
        exit 1
    fi
done

# ── 最终自检：归档内所有二进制（嵌入 framework + 主程序）的 UUID 都必须有对应 dSYM ──
HAVE=$(collect_dsym_uuids)
FAILED=0
check_uuid() {
    local label="$1" bin="$2" u
    u=$(dwarfdump --uuid "$bin" 2>/dev/null | awk 'NR==1 {print $2}') || true
    [[ -n "$u" ]] || return 0
    if echo "$HAVE" | grep -q "$u"; then
        echo "  PASS  $label  $u"
    else
        echo "  FAIL  $label  $u  ← 缺 dSYM" >&2
        FAILED=1
    fi
}

EXE=$(plutil -extract CFBundleExecutable raw "$APP_DIR/Info.plist" 2>/dev/null || true)
[[ -n "$EXE" && -f "$APP_DIR/$EXE" ]] && check_uuid "主程序" "$APP_DIR/$EXE"
for FW in "$APP_DIR/Frameworks/"*.framework; do
    [[ -d "$FW" ]] || continue
    NAME=$(basename "$FW" .framework)
    [[ -f "$FW/$NAME" ]] && check_uuid "$NAME.framework" "$FW/$NAME"
done

echo "────────────────────────────────────────"
echo "归档: $ARCHIVE"
echo "版本: $(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Info.plist" 2>/dev/null) ($(plutil -extract CFBundleVersion raw "$APP_DIR/Info.plist" 2>/dev/null))"
echo "dSYMs:"
for d in "$DSYMS_DIR"/*.dSYM; do
    [[ -d "$d" ]] && dwarfdump --uuid "$d" 2>/dev/null | sed 's/^/  /'
done
if (( FAILED )); then
    echo "✗ 校验未通过，请勿上传" >&2
    exit 1
fi
echo "✓ 校验通过：所有 UUID 均有 dSYM，可以上传"
