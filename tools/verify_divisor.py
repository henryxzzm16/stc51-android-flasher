#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 ch340_bridge.py 里的 CH341 波特率分频算法。

为什么单独写一个脚本：Windows 上没有 `termios`，直接 import 桥脚本会
`ModuleNotFoundError`，而这个算法恰恰是最该被验证的部分。
所以这里**把算法逐行抄一遍**（下方 get_divisor），再按官方公式暴力枚举
全部 `(ps, fact, div)` 组合做交叉验证，最后给出误差表。

用法：
    python tools/verify_divisor.py

输出中「是否全局最优」为「否」的行，说明该档位被 MAX_BPS 截断了，
详见 docs/DEBUG_LOG.md #14。
"""

CLKRATE = 48000000
MIN_BPS = (CLKRATE + (1 << 12) * 256 - 1) // ((1 << 12) * 256)
MAX_BPS = CLKRATE // ((1 << 9) * 2)

# 期望值表（回归用）：档位 -> 桥应输出的编码。
# 2400 是本项目实际使用的档位，必须在表里且为全局最优。
EXPECT = {
    2400: 0xD901,
    9600: 0xB202,
    19200: 0xD902,
    38400: 0x6403,
}


def clk_div(ps, fact):
    return 1 << (12 - 3 * ps - fact)


def min_rate(ps):
    return CLKRATE / (clk_div(ps, 1) * 512)


def get_divisor(speed):
    """与 src/ch340_bridge.py 中的实现保持一致。"""
    speed = int(max(MIN_BPS, min(MAX_BPS, speed)))
    ps = -1
    for p in range(3, -1, -1):
        if speed > min_rate(p):
            ps = p
            break
    if ps < 0:
        raise ValueError("baud out of range")
    fact = 1
    cdiv = clk_div(ps, fact)
    div = CLKRATE // (cdiv * speed)
    if div < 9 or div > 255:
        div //= 2
        cdiv *= 2
        fact = 0
    if div < 2:
        raise ValueError("baud out of range")
    a = 16 * CLKRATE // (cdiv * div)
    b = 16 * CLKRATE // (cdiv * (div + 1))
    if a - 16 * speed >= 16 * speed - b:
        div += 1
    if fact == 1 and div % 2 == 0:
        div //= 2
        fact = 0
    return (0x100 - div) << 8 | fact << 2 | ps


def decode(v):
    ps = v & 3
    fact = (v >> 2) & 1
    div = 0x100 - ((v >> 8) & 0xFF)
    return ps, fact, div


def best_possible(speed):
    """按 baud = CLKRATE / (2^(12-3ps-fact) * div) 暴力枚举，找误差最小的组合。"""
    best = None
    for ps in range(4):
        for fact in (0, 1):
            for div in range(2, 257):
                actual = CLKRATE / (clk_div(ps, fact) * div)
                key = (abs(actual - speed) / speed, div)
                if best is None or key < best[0]:
                    best = (key, ps, fact, div, actual)
    return best


def main():
    print("CH341 时钟 = %d Hz   MIN_BPS = %d   MAX_BPS = %d" % (CLKRATE, MIN_BPS, MAX_BPS))
    print()
    print("%-8s %-8s %-18s %-11s %-9s %s" % ("目标", "输出", "ps/fact/div", "实际", "误差", "全局最优?"))
    print("-" * 76)

    failures = []
    for baud in sorted(set(list(EXPECT) + [1200, 57600, 115200])):
        v = get_divisor(baud)
        ps, fact, div = decode(v)
        actual = CLKRATE / (clk_div(ps, fact) * div)
        _, _, _, _, best_actual = best_possible(baud)
        err = abs(actual - baud) / baud
        is_best = abs(err - abs(best_actual - baud) / baud) < 1e-12
        print("%-8d 0x%04X   ps=%d fact=%d div=%-4d   %-11.1f %.4f%%    %s"
              % (baud, v, ps, fact, div, actual, err * 100, "是" if is_best else "否（被截断）"))
        if baud in EXPECT and v != EXPECT[baud]:
            failures.append("档位 %d 期望 0x%04X，实际 0x%04X" % (baud, EXPECT[baud], v))

    print()
    print("实际使用的 2400 编码 = 0x%04X（文档/软著素材里应为 0xD901）" % get_divisor(2400))
    print("115200 编码 = 0x%04X，WCH 驱动为 0xCC83 -> %s"
          % (get_divisor(115200), "一致" if get_divisor(115200) == 0xCC83 else "不一致（已知问题 #14）"))

    if failures:
        print()
        for f in failures:
            print("FAIL: %s" % f)
        return 1
    print()
    print("回归通过：期望值全部匹配。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
