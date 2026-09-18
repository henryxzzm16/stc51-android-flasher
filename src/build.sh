#!/data/data/com.termux/files/usr/bin/bash
# 用自带的 sdcc 编译 8051 源码
# 用法: ./build.sh [源文件.c] [输出.ihx]
# 默认: led.c -> led.ihx
# 中间文件都放在 build/ 里，不污染项目根目录

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$SCRIPT_DIR/led.c}"
OUT="${2:-${SRC%.c}.ihx}"
SDCC_BIN="$SCRIPT_DIR/tools/sdcc/bin"
BUILD="$SCRIPT_DIR/build"

if [ ! -x "$SDCC_BIN/sdcc" ]; then
    echo "找不到 sdcc: $SDCC_BIN/sdcc"
    exit 1
fi
if [ ! -f "$SRC" ]; then
    echo "找不到源文件: $SRC"
    exit 1
fi

mkdir -p "$BUILD"
BASE="$(basename "$SRC")"
cp -f "$SRC" "$BUILD/$BASE"

export PATH="$SDCC_BIN:$PATH"
( cd "$BUILD" && sdcc -mmcs51 --model-small -o "${BASE%.c}.ihx" "$BASE" )
cp -f "$BUILD/${BASE%.c}.ihx" "$OUT"
echo "生成: $OUT"
