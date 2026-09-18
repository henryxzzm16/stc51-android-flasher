# 变更记录

本文件格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 文档

- 新增 [docs/SCOPE.md](docs/SCOPE.md)：明确使用边界 ——
  **只在江协科技 51 开发板 + STC89C52RC/LE52RC + 板载 CH340 上验证过**，
  **没有做过 STM32 或任何其他平台的试验**，其他芯片与机型一律未验证。
- README 免责声明重写：明确本项目是**个人自用的新手项目**（目的是上课不用背电脑）、
  **纯 AI 辅助调试**、**不提供技术支持**，遇到问题建议找专业人士或让 AI 协助调试。

### 计划中

- 修正 `MAX_BPS`，让 57600/115200 不再被静默截断为 46875（见
  [docs/DEBUG_LOG.md #14](docs/DEBUG_LOG.md)），并在真机上验证高速传输。
- USB 重新插拔后自动重建 pty（当前桥只重试读写，不重建）。
- 支持多个 CH340 同时插入时的设备选择。

## [1.0.0] - 2026-09-18

首个公开版本。**在真实硬件上完成端到端验证**：

- 设备：OPPO PEPM00 / Android 13 / arm64-v8a / 无 root；
- 目标：STC89C52RC（江协科技 51 开发板）+ CH340（芯片版本 `0x31`）；
- 结果：成功烧录示例固件与第三方固件各一次以上。

### 新增

- `src/ch340_bridge.py`：CH340 用户态驱动 + pty 虚拟串口桥。
  - CH341 厂商控制传输（`0x5F` 读版本、`0xA1` 初始化、`0x9A` 写寄存器、`0xA4` modem 控制）；
  - 波特率分频算法（时钟 48 MHz，公式与移植来源见
    [docs/PROTOCOL.md](docs/PROTOCOL.md)）；
  - 三线程模型：pty→USB 写、USB→pty 读（非阻塞 + pending 缓冲）、termios 监视（3 ms）。
- `src/flash51.sh`：自动识别 CH340、启动桥、调用 stcgal 一键烧录。
- `src/build.sh`：SDCC 编译封装，中间文件隔离到 `build/`。
- `src/led.c`：示例固件（`P2 = 0x00`）。
- `docs/TECH_NOTES.md`：技术笔记。
- `docs/DEBUG_LOG.md`：14 条踩坑记录（现象 / 根因 / 解法）与分频数值自检表。
- `docs/PROTOCOL.md`：CH341 控制传输与 STC-ISP 时序参考。
- `docs/THIRD_PARTY.md`：第三方组件与借鉴来源、许可证清单。
- `tools/verify_divisor.py`：分频算法回归校验（不需要硬件，含期望值断言）。
- `tools/check.ps1`、`tools/push.ps1`：发布前自检与推送辅助脚本。
- `.github/workflows/ci.yml`：语法检查 + 分频算法回归。

### 已知问题

- 传输波特率被限制在 2400。两条并列原因：pty 波特率同步延迟；
  以及 `MAX_BPS = 46875` 会把 57600/115200 静默截断（复核时发现）。
  原始归因无法从日志中区分，已在文档中如实标注。
- 需要人工冷启动（STC89 只在上电时进入 ISP）。
- 需要给 pyserial 打两处容错补丁（Android pty 不支持 DTR/RTS ioctl 与 `tcdrain`）。
- SDCC 需做跨 libc 处理，且必须处理整个目录的 ELF 可执行文件。
