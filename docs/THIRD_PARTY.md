# 第三方组件与许可证

本项目**自身源码**（`src/ch340_bridge.py`、`src/flash51.sh`、`src/build.sh`、`src/led.c`）
为原创，以 MIT 发布。下列组件均为**运行/编译依赖**，未随仓库分发，
各自遵循其原许可证。

| 组件 | 本项目实测版本 | 许可证 | 用途 |
|---|---|---|---|
| [Python](https://www.python.org/) | 3.14.6 | PSF License | 主程序运行环境 |
| [Termux](https://termux.dev/) | 0.118.3 | GPL-3.0 | Android 上的终端环境 |
| [Termux:API](https://github.com/termux/termux-api) | 0.53.0 | GPL-3.0 | 提供 `termux-usb` |
| [libusb](https://libusb.info/) | 1.0.30（Termux 版） | LGPL-2.1 | 用户态 USB |
| [pyusb](https://github.com/pyusb/pyusb) | 1.3.1 | BSD-3-Clause | USB 抽象层 |
| [pyserial](https://github.com/pyserial/pyserial) | 3.5 | BSD-3-Clause | 串口抽象（被 stcgal 调用；本机打了补丁） |
| [stcgal](https://github.com/grigorig/stcgal) | 1.10 | MIT | STC-ISP 烧录（**直接调用，未修改**） |
| [SDCC](https://sdcc.sourceforge.net/) | 4.6.2 #16879 | GPL-2.0/GPL-3.0（含运行时库例外） | 8051 编译器（**仓库不分发**） |
| [patchelf](https://repo.or.cz/patchelf.git) | 0.19.1 | GPL-3.0 | 修改 ELF 解释器，适配 glibc |
| [glibc-runner](https://github.com/termux/glibc-packages) | 2.0 | 以项目声明为准（**使用前请自行核对**） | 在 bionic 上运行 glibc 二进制（两个包都用 `pkg install` 装，包名以 Termux 仓库实际为准） |
| GNU glibc | 随 Termux glibc 包 | LGPL-2.1 | SDCC 的运行库依赖 |

## 借鉴实现的来源

代码逻辑上的借鉴（不只是"用了库"）单独列出，因为这部分是方案能成立的关键：

| 来源 | 许可证 | 借鉴内容 |
|---|---|---|
| [Linux 内核 `drivers/usb/serial/ch341.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/serial/ch341.c) | GPL-2.0 | CH341 寄存器语义与 `ch341_calc_divisor()` 分频算法思路；本项目用 Python 重写，未复制代码 |
| [WCH CH341SER](https://www.wch.cn/downloads/CH341SER_EXE.html) 厂商驱动/公开驱动 | 厂商发布 | 控制传输请求码 `0x5F/0x9A/0xA1/0xA4`、端点布局 |
| [MarkWllms/Termux-serial-tty](https://github.com/MarkWllms/Termux-serial-tty) | 见项目 | 同类问题的先例（libusb 中继）；本项目出口改为 pty |
| [stcgal USAGE.md](https://github.com/grigorig/stcgal/blob/master/doc/USAGE.md) | MIT | `-b` 传输速率 / `-l` 握手速率的准确语义 |
| [Termux Wiki: termux-usb](https://wiki.termux.com/wiki/Termux-usb) | CC BY 4.0 | `termux-usb -e` 传 fd 的用法 |
| [全国大学生智能汽车竞赛 / 论坛上关于手机 OTG 烧录 STC 的讨论](https://www.mydigit.cn/forum.php?mod=viewthread&tid=424341) | — | 可行性验证，非代码 |

## 注意

- 仓库**不包含** SDCC 二进制快照（GPL，体积大），请自行从 SDCC 官方快照获取，
  准备步骤见 [TECH_NOTES.md](TECH_NOTES.md#sdcc-补丁glibc-快照在-bionic-上跑不了)。
- `pyserial` 的两个本地补丁属于**对依赖的修改**，未随仓库分发原文件，
  仅以补丁片段形式记录在 [DEBUG_LOG.md](DEBUG_LOG.md)。以 BSD-3-Clause 分发时请遵守其署名要求。
