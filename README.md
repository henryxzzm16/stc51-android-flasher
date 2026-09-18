<div align="center">

# STC51 Android Flasher

**用一台没有 root 的 Android 手机，编译并烧录 STC89C52 单片机**

在用户态驱动 CH340（`1a86:7523`），把它伪装成标准串口，交给未修改的 `stcgal` 完成烧录。

[![Platform](https://img.shields.io/badge/platform-Android%2013%20%C2%B7%20Termux-3DDC84?logo=android&logoColor=white)](#软件要求与实测版本--tested-versions)
[![Python](https://img.shields.io/badge/python-3.14-3776AB?logo=python&logoColor=white)](#软件要求与实测版本--tested-versions)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Target](https://img.shields.io/badge/MCU-STC89C52RC-informational)](#软件要求与实测版本--tested-versions)
[![Status](https://img.shields.io/badge/status-working%2C%20hardware--verified-success)](#验证状态--verification-status)

[方案总览](#方案总览--architecture) ·
[快速开始](#快速开始--quick-start) ·
[设计决策](#关键设计决策--design-decisions) ·
[限制](#已知限制--limitations) ·
[排错](#排错--troubleshooting) ·
[借鉴与致谢](#借鉴前人工作--prior-art)

</div>

---

> **这个仓库解决什么问题**
> Android 不给普通应用 `/dev/ttyUSB0`，也不给内核串口驱动；而 CH340 又不是"拿到 fd 就能读写"的设备。
> 本项目用 `termux-usb` 拿到裸 USB fd，在**用户态**完成 CH340 的控制传输与批量收发，
> 再用一个 **pty（伪终端）** 把它包装成 `/dev/pts/N`。
> 结果是 `pyserial` 和 `stcgal` **一行都不用改**就能烧录 51 单片机。

📖 **中文技术笔记**见 [`docs/TECH_NOTES.md`](docs/TECH_NOTES.md) ·
🐛 **14 条踩坑记录**见 [`docs/DEBUG_LOG.md`](docs/DEBUG_LOG.md) ·
🔌 **协议细节**见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)

---

## English abstract

Android gives unprivileged apps no access to USB serial device nodes, and the CH340 is not a
plain file you can `read()`/`write()`. This project obtains a raw USB file descriptor through
`Termux:API` (`termux-usb`), drives the CH340 entirely in userspace with `pyusb`
(vendor control transfers + bulk endpoints, see [`docs/PROTOCOL.md`](docs/PROTOCOL.md)),
and re-exposes it as a **pty** so that **unmodified** `pyserial` / `stcgal` can flash an
STC89C52 (8051) board.

The interesting engineering is not the flashing itself — that is [stcgal](https://github.com/grigorig/stcgal)'s
job — but the glue: baud-rate synchronization between a pty and a CH341 divisor register,
and a documented trail of the 14 failures that shaped the design.

**Scope and honesty:** the CH341 register/divisor logic was ported from existing drivers
(see [prior art](#借鉴前人工作--prior-art)); the baud-rate divisor table in
[`docs/DEBUG_LOG.md`](docs/DEBUG_LOG.md) is independently verified.
Development was AI-assisted with on-hardware debugging; see
[AI-assisted development](#ai-assisted-development--关于-ai-辅助开发) for the exact
division of labour and its limits. Everything in `src/` was tested on real hardware.

---

## 目录

- [特性](#特性--features)
- [方案总览](#方案总览--architecture)
- [硬件要求](#硬件要求--hardware)
- [软件要求与实测版本](#软件要求与实测版本--tested-versions)
- [快速开始](#快速开始--quick-start)
- [使用说明](#使用说明--usage)
- [关键设计决策](#关键设计决策--design-decisions)
- [验证状态](#验证状态--verification-status)
- [已知限制](#已知限制--limitations)
- [排错](#排错--troubleshooting)
- [AI 辅助开发](#ai-assisted-development--关于-ai-辅助开发)
- [借鉴前人工作](#借鉴前人工作--prior-art)
- [项目结构](#项目结构--layout)
- [常见问题 FAQ](#常见问题-faq)
- [参与贡献](#参与贡献--contributing)
- [许可证](#许可证--license)
- [参考资料](#参考资料--references)

---

## 特性 / Features

- **无需 root**，无需 Magisk，不修改系统，不加载内核模块。
- **不 fork、不 patch `stcgal`**：以 pty 形式对外提供标准串口，上位机工具零改动。
- **不 fork `pyserial`**：仅需两处容错补丁（[见下](#3-pyserial-需要两处容错补丁)），改动是相加而非替换。
- **波特率跟随**：3 ms 轮询 pty 的 `termios`，一旦上位机切换波特率就同步写入芯片分频寄存器。
- **自动识别设备**：USB 地址会随重新枚举漂移，脚本扫描并按地址倒序尝试。
- **可离线自检**：`tools/verify_divisor.py` 在电脑上即可校验分频算法，不需要手机或硬件。
- **一键编译**：配套 `build.sh` 封装 SDCC，把中间文件收进 `build/`，不污染仓库根目录。

> **不是什么**：不是 STC-ISP 协议的重新实现（那是 stcgal），不是通用 USB 串口方案
> （当前只适配 CH340），不是生产级工具链（见[已知限制](#已知限制--limitations)）。

---

## 方案总览 / Architecture

```
   ┌──────────────────────────── Android 13, 无 root ─────────────────────────────┐
   │                                                                              │
   │   build.sh ──► sdcc ──► led.ihx                                              │
   │                            │                                                 │
   │                            ▼                                                 │
   │   flash51.sh ──► stcgal ──► /dev/pts/N ◄── 上位机以为这是一根 USB 转串口线      │
   │                              ▲                                               │
   │                              │ pyserial / termios                            │
   │                    ┌─────────┴──────────┐                                    │
   │                    │  ch340_bridge.py   │  ← 本项目                         │
   │                    │  ① pty 桥接        │                                    │
   │                    │  ② 3 ms termios 监视 │                                   │
   │                    │  ③ CH341 控制传输   │                                    │
   │                    └─────────┬──────────┘                                    │
   │                              │ pyusb → libusb 1.0.30                         │
   │                              ▼                                               │
   │                    termux-usb (Termux:API) ──► Android UsbManager 授权        │
   │                              │ 裸 USB fd                                     │
   └──────────────────────────────┼───────────────────────────────────────────────┘
                                  │ USB-C 拓展坞（Hub）
                                  ▼
                          CH340 ──UART──► STC89C52RC (P3.0 / P3.1)
```

| 方向 | 路径 |
|---|---|
| 下行（手机 → 单片机） | pty master → Bulk OUT `0x02` → CH340 → MCU UART |
| 上行（单片机 → 手机） | MCU UART → CH340 → Bulk IN `0x82` → pty master |
| 控制 | `pyusb.ctrl_transfer(0x40/0xC0, 0x5F/0x9A/0xA1/0xA4, …)` 配置芯片 |
| 速率同步 | pty `termios` → `get_divisor()` → 寄存器 `0x12`/`0x13` |

细节见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)（控制传输与寄存器语义）与
[`docs/TECH_NOTES.md`](docs/TECH_NOTES.md)（实现笔记）。

---

## 硬件要求 / Hardware

| 项目 | 要求 | 说明 |
|---|---|---|
| 手机 | Android 7.0+，支持 **USB Host / OTG** | 需能弹出 USB 权限对话框 |
| 转接 | USB-C / Micro-USB **OTG 拓展坞（Hub）** | 也可以直连，但 Hub 更方便 |
| 串口 | **CH340**（板载或独立模块） | `VID:PID = 1a86:7523`；CH341/CH9102 未验证 |
| 开发板 | STC89C52RC / LE52RC | 其他 STC 系列未验证 |
| 供电 | 单片机**独立供电**，且**必须与 USB 共地** | 见[接线](#接线要点) |

### 接线要点

- 串口交叉：`CH340.TXD → MCU.RXD(P3.0)`、`CH340.RXD ← MCU.TXD(P3.1)`（板载成品板已在 PCB 上走好）。
- **GND 必须共地**，否则表现为"能枚举、握手永远失败"。
- 单片机独立供电，避免 USB 掉电导致 ISP 过程被打断。
- **复位键没用**：STC89 只在上电瞬间进 ISP，见[设计决策 4](#4-stc89-只认冷启动无法自动化)。

---

## 软件要求与实测版本 / Tested versions

本项目**只在下面这一组版本上做过端到端实测**。其他组合未验证 —— 这不是免责声明套话，
而是因为其中多个环节（pty 行为、libusb 版本、SDCC 的 libc）都踩过版本相关的坑。

| 组件 | 实测版本 | 安装方式 | 用途 |
|---|---|---|---|
| Termux | 0.118.3 | F-Droid | 终端环境 |
| Termux:API | 0.53.0 | F-Droid | 提供 `termux-usb` |
| Python | 3.14.6 | `pkg install python` | 桥程序 |
| pyusb | 1.3.1 | `pip install pyusb` | USB 抽象 |
| pyserial | 3.5 | `pip install pyserial` | 被 stcgal 调用（需补丁） |
| stcgal | 1.10 | `pip install stcgal` | STC-ISP 烧录 |
| libusb | 1.0.30 | `pkg install libusb` | USB 底座 |
| SDCC | 4.6.2 #16879 | 官方 aarch64-linux-gnu 快照 | 8051 编译器 |
| patchelf | 0.19.1 | `pkg install patchelf` | 改 ELF 解释器 |
| glibc-runner | 2.0 | `pkg install glibc-runner` | 跨 libc 运行 |

实测设备：OPPO PEPM00 / Android 13 (API 33) / arm64-v8a / 内核 `Linux 4.19.191+ aarch64` /
无 root（SELinux 域 `untrusted_app_27`）。

---

## 快速开始 / Quick start

### 1. 安装依赖

```bash
pkg install termux-api python libusb patchelf glibc-runner
pip install pyusb pyserial stcgal
```

> `termux-api` 需要同时安装 **Termux:API 应用**（F-Droid），只有包没有 App 时 `termux-usb` 不工作。

### 2. 准备 SDCC（仓库不含二进制）

```bash
mkdir -p ~/stc51/tools && cd ~/stc51/tools
tar -xjf /path/to/sdcc-snapshot-aarch64-linux-gnu-*.tar.bz2
mv sdcc-snapshot-* sdcc                    # 使 tools/sdcc/bin/sdcc 成立
cd sdcc
# 给整个目录下所有 ELF 可执行文件改解释器（只改顶层不够，原因见 DEBUG_LOG #5）
find . -type f -print0 | while IFS= read -r -d '' f; do
  case "$(file -b "$f" 2>/dev/null)" in
    *ELF*executable*) glibc-runner -c "$f" >/dev/null 2>&1 ;;
  esac
done
```

### 3. 给 pyserial 打两处容错补丁

见 [设计决策 3](#3-pyserial-需要两处容错补丁)，或直接参考
[`docs/TECH_NOTES.md`](docs/TECH_NOTES.md#pyserial-补丁android-pty-的坑)。

### 4. 接线并烧录

```bash
# 验证 USB 设备可见（应列出 /dev/bus/usb/001/00X）
termux-usb -l

# 编译（默认 led.c -> led.ihx）
./build.sh

# 烧录
./flash51.sh
# 看到 "Waiting for MCU, please cycle power:" 时，给单片机【断电再上电】
```

### 5. 预期输出

<details>
<summary>点击展开一次成功烧录的完整日志</summary>

```
$ ./flash51.sh
尝试 /dev/bus/usb/001/005 ...
CH340: /dev/bus/usb/001/005   虚拟串口: /dev/pts/3
接下来请给单片机断电再上电（冷启动）。

Waiting for MCU, please cycle power: done
Target model:
  Name: STC89C52RC/LE52RC
  Magic: F002
  Code flash: 8.0 KB
  EEPROM flash: 6.0 KB
Target frequency: 11.030 MHz
Target BSL version: 6.6C
Loading flash: 178 bytes (Intel HEX)
Switching to 2400 baud: checking setting testing done
Erasing 2 blocks: done
Writing flash: 100%|██████████| 512/512
Setting options: done
Disconnected!
```

</details>

### 验证结果

- `led.c`（`P2 = 0x00`）→ 开发板 P2.0–P2.7 八个 LED 全亮。
- 第三方固件 `Project.hex`（`P2` 依次 `FE FD FB F7 EF DF BF 7F`）→ 流水灯效果。

---

## 使用说明 / Usage

### `build.sh` — 编译

```bash
./build.sh                       # led.c -> led.ihx
./build.sh main.c                # 指定源文件
./build.sh main.c out.ihx        # 指定输出
```

中间文件（`.rel` `.rst` `.asm` …）全部落在 `build/`，仓库根目录保持干净。
SDCC 参数固定为 `-mmcs51 --model-small`。

### `flash51.sh` — 烧录

```bash
./flash51.sh                     # 烧 led.ihx
./flash51.sh Project.hex         # 烧第三方固件
BAUD=2400 ./flash51.sh fw.ihx    # 覆盖波特率（不建议，见设计决策 2）
```

**参数位置**：`flash51.sh [固件]`，脚本内部固定调用
`stcgal -P stc89 -p <pty> -b 2400 -l 2400`。

### `ch340_bridge.py` — 桥（一般不用手动跑）

```bash
python3 ch340_bridge.py --test           # 只做 USB 识别+配置，打印芯片版本
python3 ch340_bridge.py                  # 建 pty，打印 /dev/pts/N 后常驻
python3 ch340_bridge.py 12               # 手动指定 termux-usb 传入的 fd
```

运行时文件写在脚本同目录：`.ch340_pts`（pty 路径）、`.ch340_bridge.pid`（pid）、
`.ch340_bridge.log`（日志）；三者都已在 `.gitignore` 中。

### 命令行参数语义（易错点）

stcgal 的两个波特率参数**不是**字面直觉，官方定义如下
（`stcgal -h` / [USAGE.md](https://github.com/grigorig/stcgal/blob/master/doc/USAGE.md)）：

| 参数 | 官方含义 | 默认 | 本项目 |
|---|---|---|---|
| `-l / --handshake` | **握手**波特率 | 2400 | 2400 |
| `-b / --baud` | **传输**波特率 | 115200 | **2400** |

即本项目**故意把传输速率压到与握手一致**。原因见[设计决策 2](#2-为什么传输波特率锁死-2400)。

---

## 关键设计决策 / Design decisions

每一条都写清"为什么这样、代价是什么、什么情况下该推翻它"。

### 1. 为什么用 pty，而不是管道或 socket

`stcgal` 通过 `pyserial` 打开串口，而 `pyserial` 需要 `termios`（波特率、`tcdrain`、DTR/RTS）。
若用 `pipe` 或 `socketpair` 做出口，就必须改 `stcgal` 或伪造一个设备节点。

pty 的好处是**语义完整**：`os.ttyname()` 给出真实路径 `/dev/pts/N`，
`tcgetattr`/`tcsetattr`/`tcdrain` 全部可用，上位机工具零改动。

**代价**：pty 的 termios 是内核维护的，桥只能"轮询观察"，拿不到"波特率变更事件"——
这直接导致了[设计决策 2](#2-为什么传输波特率锁死-2400) 和[限制 1](#已知限制--limitations)。

> 参考：同类问题在 Termux 下的另一种做法是用 Linux 管道中继
> （[MarkWllms/Termux-serial-tty](https://github.com/MarkWllms/Termux-serial-tty)）。
> 两者取舍不同：管道更简单，pty 兼容性更好。

### 2. 为什么传输波特率锁死 2400
<a id="2-为什么传输波特率锁死-2400"></a>

`stcgal` 默认握手 2400、传输 115200。本项目把**传输也设成 2400**，这是刻意的降级。

原因有两条，**两条都成立，我没有留下区分它们的日志**，所以并列写出：

1. **同步延迟**：桥每 3 ms 轮询一次 pty 的 `termios`。上位机改完波特率是瞬时的，
   但芯片要等下一次轮询才被改写；而 MCU 的回包不会等这 3 ms。速率越高，
   这段窗口里错过的帧越多，表现为 `incorrect frame start`。
2. **速率被截断**（复核源码时才发现，见 [`DEBUG_LOG.md` #14](docs/DEBUG_LOG.md)）：
   `MAX_BPS = 48e6 / 2^10 = 46875`，于是 `115200` 被**静默压成 46875**，
   `get_divisor(115200)` 实际返回 `0x8003` 而非 WCH 驱动的 `0xCC83`。

**代价**：178 字节固件在 2400 下约 2 秒。**收益**：稳定，且实测 2400 档位
（`0xD901`）是全局最优解，误差 0.16%，远小于 UART 容错范围（约 2–3%）。

> **什么时候该推翻它**：先修 `MAX_BPS`，再上板验证 —— 而不是只把 `-b` 调大。

### 3. 运行时状态为什么用文件传，而不是 stdout

`termux-usb -e <command>` 会接管子进程的 stdout，父进程读管道拿不到干净输出。
因此桥把 pty 路径写入 `.ch340_pts`，由 `flash51.sh` 轮询该文件判定启动成功。

这个设计顺带解决了一个问题：`flash51.sh` 需要"尝试多个 USB 地址，选中真正的 CH340"，
而"文件是否出现"正好是一个无需解析日志的判定条件。

### 4. STC89 只认冷启动，无法自动化
<a id="4-stc89-只认冷启动无法自动化"></a>

STC89 系列只在**上电瞬间**进入 ISP，按复位键无效。手机无法替单片机断电，
所以脚本只能打印提示、由人手动断电再上电 —— 这是全流程唯一无法自动化的环节。

> 除非额外做 DTR 控制供电的硬件（`stcgal -a` 思路），本项目没做。

### 3. pyserial 需要两处容错补丁
<a id="3-pyserial-需要两处容错补丁"></a>
<a id="32-pyserial-需要两处容错补丁"></a>

Android 的 pty 不支持 `TIOCMBIS`/`TIOCMGET`（DTR/RTS），`tcdrain` 也会抛错。
不打补丁会在 `open()`/`flush()` 直接异常退出。补丁是**把致命错误降级为忽略**：

```python
# serialposix.py open()：忽略 DTR/RTS ioctl 的权限类错误
if e.errno not in (errno.EINVAL, errno.ENOTTY, errno.EACCES, errno.EPERM):
    raise

# serialposix.py flush()：忽略 tcdrain 的 termios.error
try:
    termios.tcdrain(self.fd)
except termios.error as e:
    if e.args[0] not in (errno.EACCES, errno.EPERM, errno.EINVAL, errno.ENOTTY):
        raise
```

> 这两处是**对依赖的本地修改**，因此仓库不承诺"`pip install pyserial` 即可用"。
> 上游若要修，合理的做法是把"平台不支持 modem 控制线"作为能力探测而非错误。

---

## 验证状态 / Verification status

保持诚实：下面是**已经验证**和**没有验证**的分界。

| 项目 | 状态 | 证据 |
|---|---|---|
| 端到端烧录 STC89C52RC | ✅ 通过（多次） | 见[预期输出](#5-预期输出) |
| `led.c` 点亮 P2.0–P2.7 | ✅ 通过 | 目视确认 |
| 第三方 `Project.hex` 流水灯 | ✅ 通过 | 目视确认 |
| 分频算法 2400/9600/19200/38400 | ✅ 独立复核，均为全局最优 | [`tools/verify_divisor.py`](tools/verify_divisor.py) |
| 分频算法 57600/115200 | ❌ **不通过**（被 `MAX_BPS` 截断） | [DEBUG_LOG #14](docs/DEBUG_LOG.md) |
| `ch340_bridge.py` 语法 | ✅ `python -m py_compile` | CI |
| shell 脚本语法 | ⚠️ 未在电脑上验证 | 开发机无可用 bash，见 CI 说明 |
| 其他手机 / Android 版本 | ⚠️ 未验证 | — |
| CH341、CH9102、CP2102 等其他芯片 | ⚠️ 未验证 | — |
| 传输速率 > 2400 | ⚠️ 未验证 | 见[设计决策 2](#2-为什么传输波特率锁死-2400) |

自动化检查：`.github/workflows/ci.yml` 在每次 push 时执行语法检查与
分频算法回归（`tools/verify_divisor.py` 含期望值断言，回归失败即 CI 失败）。

---

## 已知限制 / Limitations

1. **传输速率被限制在 2400**，根因有两条（[设计决策 2](#2-为什么传输波特率锁死-2400)），
   修复需要同时改 `MAX_BPS` 与同步策略，并重新上板验证。
2. **需要人工冷启动**，无法自动化（[设计决策 4](#4-stc89-只认冷启动无法自动化)）。
3. **必须打 pyserial 补丁**，属于对依赖的本地修改（[设计决策 3.2](#3-pyserial-需要两处容错补丁)）。
4. **SDCC 需要跨 libc 处理**：官方 aarch64 快照是 glibc 的，在 bionic 上跑不了；
   且必须处理**整个目录**的 ELF 可执行文件，只改顶层会在 `posix_spawn` 处失败。
5. **USB 地址会漂移**：重新枚举后 `/dev/bus/usb/001/00X` 变化，靠扫描兜底；
   当前策略是"按地址倒序尝试"，理论上多设备时可能选错（会尝试失败后继续）。
6. **单设备假设**：桥用 `usb.core.find(idVendor, idProduct)` 找**第一个**匹配设备，
   同时插入多个 CH340 时行为未定义。
7. **未做错误恢复**：USB 拔出后桥线程只打日志重试，不会重建 pty。
8. **硬编码 Termux 路径**：脚本 shebang 是 `/data/data/com.termux/files/usr/bin/{python3,bash}`，
   无法在普通 Linux 上直接运行（见 [FAQ](#常见问题-faq)）。

---

## 排错 / Troubleshooting

完整的"现象 / 根因 / 解法"14 条见 **[`docs/DEBUG_LOG.md`](docs/DEBUG_LOG.md)**。高频问题：

| 现象 | 先查什么 |
|---|---|
| `termux-usb -l` 无输出 | 是否装了 **Termux:API 应用**；手机是否开启 OTG；Hub 是否供电 |
| `No such device` | 重新插拔；USB 地址漂移，重跑脚本即可 |
| 一直卡在 `Waiting for MCU` | 是否**冷启动**（断电再上电，不是按复位）；是否共地 |
| `incorrect frame start` | 传输波特率不是 2400（见[设计决策 2](#2-为什么传输波特率锁死-2400)） |
| `PermissionError (13)` / `Unexpected error (13, ...)` | pyserial 补丁没打（[设计决策 3.2](#3-pyserial-需要两处容错补丁)） |
| `cannot execute: required file not found` | SDCC 未做跨 libc 处理（`glibc-runner` + `patchelf`） |
| `posix_spawn: No such file or directory` | SDCC 只 patch 了顶层，子程序没处理（[DEBUG_LOG #5](docs/DEBUG_LOG.md)） |
| 桥进程残留 | `kill "$(cat .ch340_bridge.pid)"` |

自检顺序（由下至上定位）：

```bash
termux-usb -l                          # 1. 设备可见？
python3 src/ch340_bridge.py --test     # 2. 芯片可配置？应打印 chip version
python3 src/ch340_bridge.py            # 3. pty 建起来了？应打印 /dev/pts/N
stcgal -h                              # 4. stcgal 参数与版本
```

---

## AI-assisted development / 关于 AI 辅助开发

**这个方案是 AI 辅助、在真实硬件上反复试错调出来的。** 我把过程如实写下来，
因为本项目最有价值的部分不是那 331 行 Python，而是
[`docs/DEBUG_LOG.md`](docs/DEBUG_LOG.md) 里 14 条失败路径 —— 它们几乎全部来自
"AI 给一个假设 → 上板子试 → 失败 → 把报错贴回去 → 换假设"的循环。

### 分工

| 人负责 | AI 负责 |
|---|---|
| 提出目标：无 root 手机上烧 STC89 | 生成 `ch340_bridge.py` 初版骨架（pty + 三线程模型） |
| 硬件选型、接线、共地 | 对照前人驱动移植 CH341 寄存器与分频算法 |
| **全部真机验证**（插拔、冷启动、看 LED） | 把报错翻译成原因、提出下一轮假设 |
| 判断"是否真的烧进去了" | 编写 `flash51.sh` / `build.sh` / 文档与校验脚本 |
| 否掉不可行的技术路线 | 代码整理、命名、注释 |

### 边界声明（请认真对待）

- **`src/` 下每一行都经过真机验证**；没上过板子的代码不进仓库。
- **AI 给过错误结论**：115200 错帧最初被归因为纯时序问题、SDCC 最初只 patch 了顶层文件。
  两次都是靠实测日志推翻的，不是靠 AI 自我复核。
- **所以本文档的定位是"一份被实测过的记录"，而不是"一份可信的设计规范"。**
  换手机、换芯片、换 SDCC 版本，结论都可能需要重新验证。
- 欢迎按 [CONTRIBUTING.md](CONTRIBUTING.md) 的方式挑战本文档中的任何结论。

---

## 借鉴前人工作 / Prior art

本项目是站在别人肩膀上的。下面这些工作解决了底层问题，本项目只是在其上做了一层
"适配 Android 的胶水"。

| 工作 | 许可证 | 本项目借鉴了什么 |
|---|---|---|
| [grigorig/stcgal](https://github.com/grigorig/stcgal) | MIT | STC-ISP 协议实现与波特率语义。**直接调用，未修改**，是方案成立的前提 |
| [Linux `drivers/usb/serial/ch341.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/serial/ch341.c) | GPL-2.0 | CH341 寄存器语义与 `ch341_calc_divisor()` 算法思路；本项目用 Python 重写，**未复制代码** |
| [WCH CH341SER](https://www.wch.cn/downloads/CH341SER_EXE.html) | 厂商发布 | 控制传输请求码（`0x5F/0x9A/0xA1/0xA4`）与端点布局的权威来源 |
| [MarkWllms/Termux-serial-tty](https://github.com/MarkWllms/Termux-serial-tty) | 见项目 | 同类问题的先例（libusb 中继）。差别：本项目的出口是 pty 而非管道 |
| [termux/termux-api `termux-usb`](https://wiki.termux.com/wiki/Termux-usb) | GPL-3.0 | 无 root 获取 USB fd 的唯一入口与用法 |
| 国内论坛关于"手机 OTG 烧录 STC / 手机编译 51"的讨论 | — | 验证了思路可行，但未找到可直接使用的完整实现，故自行走通 |

完整的第三方清单与许可证见 [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md)。
**如果你的工作应该出现在这里而没有出现，请开 issue 或 PR，我很乐意补上。**

---

## 项目结构 / Layout

```
.
├── README.md                 本文件
├── LICENSE                   MIT（本项目自身代码）
├── CONTRIBUTING.md           贡献指南（含 AI 辅助贡献的披露要求）
├── CHANGELOG.md              变更记录（Keep a Changelog 格式）
├── SECURITY.md               安全策略
├── .gitignore
├── .github/
│   ├── workflows/ci.yml      CI：语法检查 + 分频算法回归
│   └── ISSUE_TEMPLATE/       bug_report.yml / feature_request.yml
├── src/
│   ├── ch340_bridge.py       ★ 核心：CH340 用户态驱动 + pty 桥（331 行）
│   ├── flash51.sh            一键烧录（73 行）
│   ├── build.sh              SDCC 编译封装（30 行）
│   └── led.c                 示例固件（8 行）
├── docs/
│   ├── TECH_NOTES.md         技术笔记（原始手记整理版）
│   ├── DEBUG_LOG.md          14 条踩坑记录 + 分频数值自检表
│   ├── PROTOCOL.md           CH341 控制传输与 STC-ISP 时序参考
│   └── THIRD_PARTY.md        第三方组件与借鉴来源清单
└── tools/
    ├── check.ps1             发布前自检（换行符 / 占位符 / 语法 / 敏感信息）
    ├── verify_divisor.py     分频算法回归校验（不需要硬件）
    └── push.ps1              替换占位符 + 自检 + git init/commit/push
```

源码总量 442 行（331 + 73 + 30 + 8）。

---

## 常见问题 FAQ

<details>
<summary><b>能在普通 Linux / macOS 上跑吗？</b></summary>

不建议。脚本 shebang 硬编码了 Termux 路径
（`/data/data/com.termux/files/usr/bin/{python3,bash}`），且桥的存在意义就是绕过 Android 沙箱。
在桌面 Linux 上直接 `pyserial + stcgal` 即可，不需要本项目。
</details>

<details>
<summary><b>能用 Arduino IDE 或 Keil 工程吗？</b></summary>

可以，只要产出 `.hex`/`.ihx`：

```bash
./flash51.sh Project.hex
```

直接用 Keil 源码编译需要小改（`<reg52.h>` → `<8052.h>`、`interrupt n` → `__interrupt(n)`、
`_nop_()` → `__asm NOP __endasm;`），细节见 [`docs/TECH_NOTES.md`](docs/TECH_NOTES.md)。
</details>

<details>
<summary><b>为什么不用 <code>proot-distro</code> 直接装完整 Linux？</b></summary>

那会绕开本项目的核心问题（如何在没有 root 的情况下访问 USB），
但代价是更重、更慢，且 USB 设备节点在 proot 里同样不直接可用，仍需要 `termux-usb` 转发。
如果你的目标只是"在手机上编译"，proot 是可选项；如果目标是"在手机上烧录"，本项目更直接。
</details>

<details>
<summary><b>速度能更快吗？</b></summary>

可以，但是需要真功夫：先修 `MAX_BPS`（[限制 1](#已知限制--limitations)），
再解决 pty 波特率同步延迟（例如用 `TIOCGETA` 轮询之外的机制，或让桥自己控制切换时机）。
仅把 `-b` 调大会得到 `incorrect frame start`。
</details>

<details>
<summary><b>这个项目安全吗？会不会损坏芯片？</b></summary>

它只做 `stcgal` 让它做的事，写入的是 STC 官方 ISP 流程。
风险主要来自硬件侧：**不共地**、供电不稳、热插拔。请自行评估，见 [SECURITY.md](SECURITY.md) 与免责声明。
</details>

---

## 参与贡献 / Contributing

欢迎 issue 与 PR。有两条硬要求，请在动手前读一下 [CONTRIBUTING.md](CONTRIBUTING.md)：

1. **涉及硬件的改动必须说明验证方式**：什么板子、什么芯片、什么日志/现象。
   "在我机器上可以"不足以合并。
2. **AI 辅助的贡献需要披露**：本仓库不排斥 AI 生成的代码，但要求
   （a）在 PR 描述中说明使用了 AI，（b）提交者对其正确性负责，（c）经过真机或有依据的复核。

其他常规要求：LF 换行、中文注释可接受、改动后跑一遍
`tools/verify_divisor.py` 与 `tools/check.ps1`。

### 发布这个仓库（维护者用）

仓库自带 `tools/push.ps1`，会依次完成：推断作者名/邮箱/GitHub 用户名 →
替换占位符 → 跑自检 → `git init` + 提交 → 建仓库并推送。

**推荐（使用 [GitHub CLI](https://cli.github.com/)，需先 `gh auth login`）：**

```bash
# 公开仓库，仓库名默认取目录名
powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1

# 私有仓库
powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1 -Visibility private

# 只做本地提交，不推送
powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1 -NoPush
```

`gh` 会自动创建仓库并设置 `origin`，因此 `.github/ISSUE_TEMPLATE/config.yml`
里的 `USER/REPO` 占位符也会被一并替换正确。

> **推送报鉴权失败时**（例如 Windows 上的
> `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`、
> 或 `could not read Username for 'https://github.com'`）：
> 先执行一次 `gh auth setup-git`，让 git 使用 gh 的凭据助手，然后重新 `git push`。
> 本仓库的 `.gitattributes` 已强制 LF，因此不必担心检出后换行符被改坏。

**不使用 gh（推送到已存在的空仓库）：**

```bash
git init && git add -A && git commit -m "feat: initial commit"
git remote add origin https://github.com/henryxzzm16/stc51-android-flasher.git
git push -u origin main
```

> 脚本参数：`-RepoName` `-Visibility {public|private|internal}` `-Description`
> `-Name` `-Email` `-Remote` `-Branch` `-NoPush` `-SkipCheck` `-Force`。
> `tools/push.ps1` 与 `tools/check.ps1` 刻意只用 ASCII 编写 —— Windows PowerShell 5.1
> 会把无 BOM 的 `.ps1` 当作 ANSI(GBK) 读取，非 ASCII 内容会变成乱码并破坏路径。

---

## 许可证 / License

本项目自身代码以 **MIT** 发布，见 [LICENSE](LICENSE)。
第三方依赖各自遵循其原许可证（stcgal MIT、SDCC GPL、libusb LGPL、pyserial BSD 等），
完整清单见 [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md)。

**本仓库不包含** SDCC 二进制快照（GPL，且体积大），请自行获取。

---

## 参考资料 / References

- stcgal 使用文档：<https://github.com/grigorig/stcgal/blob/master/doc/USAGE.md>
- Linux 内核 CH341 驱动：<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/serial/ch341.c>
- Termux Wiki · termux-usb：<https://wiki.termux.com/wiki/Termux-usb>
- Termux 跨 libc 问题讨论：<https://github.com/termux/termux-app/discussions/3830>
- SDCC 官网：<https://sdcc.sourceforge.net/>

---

## 免责声明 / Disclaimer

本项目仅供学习与个人开发使用。烧录操作存在风险，请自行确认接线（尤其**共地**）与供电；
因操作不当造成的硬件损坏由使用者自行承担。
