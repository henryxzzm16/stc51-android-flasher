# 技术笔记 · 手机 Termux 烧录 STC89C52（江协科技 51 板）

> 这是项目最初的原始笔记（原 `STC51_烧录笔记.md`），保留第一手记录的口吻，
> 只做术语与格式整理，不改结论。
>
> - 目标板：STC89C52RC/LE52RC（江协科技 51 开发板），USB 转串口 CH340（`1a86:7523`）
> - 手机：**无 root** Termux，板子经拓展坞接手机
> - 全部文件都放在 `~/stc51/` 里

## 目录结构（手机上的实际布局）

```
~/stc51/
├── STC51_烧录笔记.md      # 本笔记（= 仓库里的 docs/TECH_NOTES.md）
├── flash51.sh             # 一键烧录
├── build.sh               # 编译 .c -> .ihx
├── ch340_bridge.py        # CH340 用户态驱动 + 虚拟串口桥
├── led.c                  # 示例：P2=0x00 点亮 P2.0–P2.7
├── led.ihx                # 编译产物
└── tools/
    ├── sdcc/              # sdcc 4.6.2（已打补丁）★ 需自行准备，仓库不含
    └── sdcc-snapshot-*.tar.bz2   # 原始快照，备份用
```

## 一句话流程

```bash
# 1. 改 led.c 后编译
~/stc51/build.sh

# 2. 烧录
bash ~/stc51/flash51.sh
# 看到 "Waiting for MCU, please cycle power:" 后，给单片机断电再上电（冷启动）
```

## 硬件连接要点

- 板子 USB 接拓展坞，再连手机。
- 单片机单独供电，和 USB/CH340 **必须共地**。
- 串口交叉：CH340 TXD → 单片机 RXD(P3.0)，CH340 RXD ← 单片机 TXD(P3.1)（板载则忽略）。
- STC89 只在**上电**时进 ISP，所以要在 stcgal 等待时给单片机上电（按复位不行）。

## 为什么这么绕

Android 无 root 时 Termux 拿不到 `/dev/ttyUSB0`，只能用 `termux-usb` 拿 USB fd。
CH340 不是"读写文件"就能通的，必须实现 USB 控制传输（设波特率）+ 批量端点收发，
所以 `ch340_bridge.py` 把 CH340 伪装成 `/dev/pts/N` 虚拟串口给 stcgal 用。

## 关键实现

### ch340_bridge.py

- `termux-usb -e ch340_bridge.py <设备>`：`termux-usb` 以**参数**形式把设备 fd 交给子进程
  （见 [Termux Wiki: termux-usb](https://wiki.termux.com/wiki/Termux-usb)）；
  本脚本的 `run()` 接受这个 fd，同时也接受 `TERMUX_USB_FD` 环境变量。
- pyusb 找 `1a86:7523`，发 CH341 厂商控制传输：
  - 读版本 `0x5F`，初始化 `0xA1`
  - 设波特率 `0x9A`（wValue = `(reg 0x13 << 8) | reg 0x12`，wIndex = 分频值）
  - DTR/RTS/流控 `0xA4`
  - 端点：OUT `0x02`，IN `0x82`
- 建 pty，master ↔ USB 批量端点双向搬数据；监控 pty termios，stcgal 一改波特率就同步写 CH340。
- 运行时文件（`._ch340_pts` 等）写在本文件夹。

### sdcc 补丁（glibc 快照在 bionic 上跑不了）
<a id="sdcc-补丁glibc-快照在-bionic-上跑不了"></a>

仓库**不包含** SDCC 二进制，需要自己准备。完整步骤：

```bash
# 1. 解包官方 aarch64-linux-gnu 快照（仓库同级的 tar.bz2）
mkdir -p ~/stc51/tools && cd ~/stc51/tools
tar -xjf ~/sdcc-snapshot-aarch64-linux-gnu-*.tar.bz2
mv sdcc-snapshot-* sdcc          # 让 tools/sdcc/bin/sdcc 成立

# 2. 依赖
pkg install glibc-runner patchelf

# 3. 给整个目录下所有 ELF 可执行文件改解释器
cd ~/stc51/tools/sdcc
find . -type f -print0 | while IFS= read -r -d '' f; do
  t=$(file -b "$f" 2>/dev/null)
  case "$t" in *ELF*executable*) glibc-runner -c "$f" >/dev/null 2>&1;; esac
done
```

> 只 patch 顶层 `bin/sdcc` 是不够的：它会去 spawn `sdcpp` / `cc1` / `sdas8051` 等子程序，
> 这些也都是 glibc 二进制，未处理就会报 `posix_spawn: No such file or directory`。

### pyserial 补丁（Android pty 的坑）
<a id="pyserial-补丁android-pty-的坑"></a>

文件：`$PREFIX/lib/python3.14/site-packages/serial/serialposix.py`

1. `open()`：忽略 DTR/RTS ioctl 的 EACCES/EPERM（Android pty 不支持 `TIOCMBIS`）
```python
if e.errno not in (errno.EINVAL, errno.ENOTTY, errno.EACCES, errno.EPERM):
    raise
```
2. `flush()`：忽略 `tcdrain` 的 `termios.error`
```python
try:
    termios.tcdrain(self.fd)
except termios.error as e:
    if e.args[0] not in (errno.EACCES, errno.EPERM, errno.EINVAL, errno.ENOTTY):
        raise
```

## 注意事项 / 已知问题

- **传输波特率必须用 2400**（和握手一致）。115200 会在 "Switching to … baud" 报
  `incorrect frame start`——虚拟串口同步切波特率有延迟，MCU 已回复导致错帧。
- 固件很小（178 字节），2400 下约 2 秒，够用。
- 设备地址每次插拔/上电会变（如 001/004→001/005），脚本自动重新识别。
- 报 `No such device`：重新插一下再跑。
- 残留进程：`cat ~/stc51/.ch340_bridge.pid` 后 `kill` 掉。

### 术语订正（易混）

stcgal 的两个波特率参数含义**不是**字面直觉，官方帮助里写得很清楚
（`stcgal -h` 或 [doc/USAGE.md](https://github.com/grigorig/stcgal/blob/master/doc/USAGE.md)）：

| 参数 | 官方含义 | 默认 | 本项目取值 |
|---|---|---|---|
| `-b / --baud` | **transfer** baud rate（切过去之后的传输速率） | 115200 | **2400** |
| `-l / --handshake` | **handshake** baud rate（同步握手速率） | 2400 | 2400 |

所以 `-b 2400 -l 2400` 的含义是"握手 2400、传输也用 2400"，即**把传输速率压到和握手一致**，
并不是"两个都调成握手值"这种模糊说法。

### 关于分频值的订正

早期版本的本笔记写过"115200 对应分频字节 `0xCC83`"，**这个说法与本仓库代码不符**：
`get_divisor(115200)` 实际返回 `0x8003`（= 46875 baud），被 `MAX_BPS` 截断了。
`0xCC83`（ps=3, fact=0, div=52 → 115384 baud）是 WCH 驱动的真实取值，算法本身能表达，
是那个上限把它挡住了。详见 [DEBUG_LOG.md #14](DEBUG_LOG.md)。
实测固定使用的 **2400 档位（`0xD901`）是全局最优解，误差 0.16%**，
远小于 UART 容错范围（约 2–3%），这也解释了它为什么一直很稳。

## 换成 Keil 的例程

- 有 `.hex`：直接 `bash ~/stc51/flash51.sh 固件.hex` 烧。
- 只有 Keil 源码：用 `build.sh` 编译，需小改 Keil 特有写法
  （`#include <reg52.h>` → `<8052.h>`，`interrupt n` → `__interrupt(n)`，`_nop_()` → `__asm NOP __endasm;` 等）。

## 参考输出（成功）

```
Waiting for MCU, please cycle power: done
Target model: STC89C52RC/LE52RC
Switching to 2400 baud: checking setting testing done
Erasing 2 blocks: done
Writing flash: 100%|██████████| 512/512
Setting options: done
Disconnected!
```
