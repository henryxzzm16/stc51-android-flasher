#!/data/data/com.termux/files/usr/bin/bash
# 一键烧录 STC89C52（江协科技 51 开发板，CH340 串口）
# 用法: ./flash51.sh [固件.ihx] [传输波特率]
# 默认固件: 本目录/led.ihx   默认波特率: 2400（必须，115200 会错帧）

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEX="${1:-$SCRIPT_DIR/led.ihx}"
BAUD="${2:-${BAUD:-2400}}"
PTS_FILE="$SCRIPT_DIR/.ch340_pts"
PID_FILE="$SCRIPT_DIR/.ch340_bridge.pid"
LOG="$SCRIPT_DIR/.ch340_bridge.log"
BRIDGE="$SCRIPT_DIR/ch340_bridge.py"

if [ ! -f "$HEX" ]; then
    echo "找不到固件: $HEX"
    exit 1
fi

cleanup_bridge() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
    fi
    rm -f "$PTS_FILE" "$PID_FILE"
}

cleanup_bridge
sleep 0.3

# 设备列表按地址从大到小（新插入的通常地址更大）
DEVICES="$(termux-usb -l 2>/dev/null | grep -o '/dev/bus/usb/[0-9]*/[0-9]*' | sort -t/ -k6 -nr)"
if [ -z "$DEVICES" ]; then
    echo "没有检测到 USB 设备。"
    exit 1
fi

PTS=""
FOUND_DEV=""
for DEV in $DEVICES; do
    echo "尝试 $DEV ..."
    rm -f "$PTS_FILE" "$PID_FILE"
    : > "$LOG"
    setsid bash -c "exec termux-usb -r -E -e '$BRIDGE' '$DEV'" >"$LOG" 2>&1 </dev/null &

    for _ in $(seq 1 20); do
        [ -f "$PTS_FILE" ] && break
        sleep 0.25
    done

    if [ -f "$PTS_FILE" ]; then
        PTS="$(cat "$PTS_FILE")"
        FOUND_DEV="$DEV"
        break
    fi
    cleanup_bridge
    sleep 0.3
done

if [ -z "$PTS" ]; then
    echo "没找到 CH340，最后日志:"
    cat "$LOG"
    exit 1
fi

echo "CH340: $FOUND_DEV   虚拟串口: $PTS"
echo "接下来请给单片机断电再上电（冷启动）。"
echo

stcgal -P stc89 -p "$PTS" -b "$BAUD" -l 2400 "$HEX"
RC=$?

cleanup_bridge
exit $RC
