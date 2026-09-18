# 踩坑记录 · DEBUG_LOG

本项目最值钱的部分。几乎每一条都是"AI 给一个假设 → 上真机试 → 失败 → 把报错贴回去 → 换假设"
循环里撞出来的，**没有一条是靠通读文档提前规避的**。

| # | 现象 | 根因 | 解法 |
|---|---|---|---|
| 1 | `/dev/ttyUSB*`、`/dev`、`/sys` 均 Permission denied | Android 非 root 下应用沙箱无权限 | 改用 `termux-usb` 向系统申请权限，取得裸 USB fd |
| 2 | 对 USB fd 直接 `os.write` 报 `Errno 22 EINVAL` | usbfs 设备节点不支持裸 read/write 做批量传输 | 改为控制传输 + `USBDEVFS_BULK`（pyusb 端点读写） |
| 3 | `libusb_init()` 失败 / 枚举不到设备 | Termux 定制 libusb 需要拿到那个 fd 才能看到设备 | 由 `termux-usb` 把 fd 交给子进程（参数 / `TERMUX_USB_FD`），再初始化 libusb |
| 4 | sdcc 报 `cannot execute: required file not found` | glibc 快照缺 `/lib/ld-linux-aarch64.so.1` | `glibc-runner -c` + `patchelf` 改所有 ELF 解释器 |
| 5 | sdcc 子进程报 `posix_spawn: No such file or directory` | `libexec/.../cc1` 等子程序也是 glibc 二进制 | 对 SDCC 全目录所有 ELF 可执行文件统一打补丁（只改顶层不够） |
| 6 | pyserial 打开 pty 抛 `PermissionError (13)` | Android pty 不支持 `TIOCMBIS/TIOCMGET`（DTR/RTS） | 补丁 `serialposix.open()` 忽略 EACCES/EPERM |
| 7 | stcgal 抛 `Unexpected error (13, Permission denied)` | pty 上 `tcdrain()` 返回 `termios.error` | 补丁 `serialposix.flush()` 捕获该异常 |
| 8 | 设备路径频繁变化（004→005→012） | 重新上电导致 USB 重新枚举，地址漂移 | 脚本每次扫描 `termux-usb -l` 自动识别 CH340 |
| 9 | 切 115200 时 `incorrect frame start` | **pty 波特率同步滞后**，MCU 已按新速率回包而芯片还没切完，导致错帧 | 固定传输波特率 2400（`-b 2400 -l 2400`） |
| 10 | 桥进程拿不到 pty 路径 | `termux-usb -e` 会接管子进程 stdout，管道理不可靠 | 将路径写入文件 `.ch340_pts` 再由脚本读取 |
| 11 | 数据丢失/阻塞 | pty 缓冲满时直接写会阻塞 | master 非阻塞 + `pending` 缓冲；`tty.setraw` |
| 12 | 烧录总是同步失败 | STC89 仅在上电时进 ISP，复位无效 | 在 stcgal 等待时给单片机冷启动上电 |
| 13 | 脚本执行报 `bad interpreter /usr/bin/env` | Termux 无 `/usr/bin` | shebang 写 Termux 绝对路径 |
| 14 | 文档里写"115200 对应分频字节 `0xCC83`"，但代码算出来不是 | `MAX_BPS = 48e6/(2^9*2) = 46875` 这条上限沿用了内核驱动写法，**57600/115200 会被静默截断到 46875**，实测 `get_divisor(115200)` 返回 `0x8003`；`0xCC83` 是 WCH 驱动的真实 115200 取值（ps=3, fact=0, div=52） | 暂不改算法（本项目固定 2400，改上限需要重新上板验证）；已在源码里加注释、并把文档改对，见下 |

补充现象：pty 初始默认波特率为 `B38400`，桥启动瞬间会把 CH340 设为 38400，
随后由 stcgal 改写为 2400，属正常过程。

---

## 值得单独说清楚的四条

### #2 为什么不能直接读写 USB fd

`termux-usb` 给的是设备 fd，但 usbfs **不支持用 `read()`/`write()` 直接做批量传输**，
必须走 `USBDEVFS_BULK` ioctl（libusb 帮你包好了）。
这条是 AI 的第一版方案（"拿到 fd 就直接 os.write"）**直接失败**的根因。

### #5 跨 libc 必须"整目录"处理

SDCC 是 GCC 风格的多进程编译链：`sdcc` 会 `posix_spawn` 出 `sdcpp`、`cc1`、`sdas8051`。
只把 `bin/sdcc` 的解释器改好，第一次编译能过，一进预处理/汇编就 `No such file or directory`。
结论：**把 `tools/sdcc` 下所有 ELF 可执行文件统一处理**。

### #9 这是时序问题，不是代码 bug

AI 起初把它当成"分频算错了"或"写寄存器顺序不对"，试了几轮都不对。

最可能的原因是**两条链路的速度差异**：stcgal 改 pty 波特率是瞬时的，
但桥要 3 ms 才轮询到并写进芯片，而 MCU 的回包不会等你这 3 ms。
所以这不是能"调参调好"的 bug，只能**回避**——把传输速率压到握手速率（2400），
让"切换波特率"这一步实际上不发生。

> **诚实补充**：后来做数值复核时发现还有**第二条更硬的原因**（见 #14）——
> 这个桥在 115200 上根本切不到 115200，`MAX_BPS` 会把请求截断成 46875。
> 所以当时的 `incorrect frame start` 到底是"同步延迟"造成的、还是"速率被截断"造成的，
> **我没有留下那次的完整日志，无法断定**，两个解释都成立。
> 唯一确定的是 2400 能稳定工作。

### #14 115200 的第二个坑：静默截断

写软著素材时顺手复核了一遍分频算法（脚本见本节末），发现文档里的一个说法对不上代码：

```
文档声称：115200 对应分频字节 0xCC83
实测代码：get_divisor(115200) -> 0x8003  ->  实际 46875 baud
```

原因在 `MAX_BPS`：

```python
MAX_BPS = CH341_CLKRATE // ((1 << 9) * 2)   # 48000000/1024 = 46875
speed = int(max(MIN_BPS, min(MAX_BPS, speed)))   # ← 115200 在这里被压成 46875
```

这条上限是从内核驱动照搬过来的写法，对 2400–9600 这类常用档位毫无影响；
WCH 驱动配置 115200 用的是 `ps=3, fact=0, div=52`，解回 115384 baud（误差 0.16%）——
也就是说**算法本身支持 115200，是这个上限把它挡住了**。

对现有方案没有实际影响（固定 2400），但两个后果必须写下来：
一是"115200 会错帧"这个结论的归因存疑（见 #9）；
二是以后想做高速传输，得先把 `MAX_BPS` 改对并重新上板验证，不能直接调参数。

## 数值自检（不依赖 termios）

Windows 上没有 `termios`，所以没法直接 import 桥脚本做测试。
复核方式是：按文档公式
`baud = 48e6 / (2^(12-3*ps-fact) * div)`（`0<=ps<=3`、`0<=fact<=1`、`2<=div<=256`）
**暴力枚举全部组合**找误差最小的解，再和桥里 `get_divisor()` 的输出对照。

| 目标 | 输出 | ps/fact/div | 实际 | 误差 | 是否全局最优 |
|---|---|---|---|---|---|
| 1200 | `0xB201` | 1/0/78 | 1201.9 | 0.1603% | 是 |
| **2400** | **`0xD901`** | **1/0/39** | **2403.8** | **0.1603%** | **是** |
| 9600 | `0xB202` | 2/0/78 | 9615.4 | 0.1603% | 是 |
| 19200 | `0xD902` | 2/0/39 | 19230.8 | 0.1603% | 是 |
| 38400 | `0x6403` | 3/0/156 | 38461.5 | 0.1603% | 是 |
| 57600 | `0x8003` | 3/0/128 | 46875.0 | 18.62% | **否**（被 MAX_BPS 截断） |
| 115200 | `0x8003` | 3/0/128 | 46875.0 | 59.31% | **否**（被 MAX_BPS 截断） |

结论：
- **实际使用的 2400 档位是全局最优解**，误差 0.16%，远小于 UART 的容错范围（约 2–3%），
  这解释了"为什么 2400 一直很稳"；
- 57600 及以上的截断问题就是 #14。

---

## 复现/自检清单

```bash
# 1. 设备能被枚举到
termux-usb -l

# 2. 桥能认到芯片（应打印 chip version 0x31 之类）
python3 src/ch340_bridge.py --test

# 3. 虚拟串口建起来了（应打印 /dev/pts/N）
python3 src/ch340_bridge.py

# 4. stcgal 认不认这两个参数（不同版本帮助措辞可能不同）
stcgal -h | grep -E '\-b|\-l'
```
