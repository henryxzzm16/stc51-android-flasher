# 参与贡献 / Contributing

感谢你有兴趣改进这个项目。它很小，但涉及**真实硬件**，所以有两条硬要求。

> **关于维护者**：作者是**新手**，本项目是**个人自用 + 纯 AI 辅助调试**的产物，
> 目标是"上实验课时不用背电脑"。作者**不提供技术支持**，也没有能力审阅所有方向。
> 如果你的问题比较棘手，**建议同时找专业人士，或把完整报错贴给 AI 帮你调试**；
> 在这里开 issue 也欢迎，但不承诺处理时间或结果。使用边界见
> [docs/SCOPE.md](docs/SCOPE.md)。

---

## 硬要求

### 1. 涉及硬件的改动，必须说明验证方式

请在 PR 描述里写清：

- 手机型号 / Android 版本 / 内核；
- 开发板与主控型号（例如 STC89C52RC）、USB 转串口芯片（例如 CH340，`1a86:7523`）；
- **你实际观察到的现象**：日志片段、LED 行为、`termux-usb -l` 输出等；
- 如果改动是"理论上更好"，请明确标记为**未验证的推测**，不要描述成已验证结论。

> "在我机器上可以" 不足以合并。反过来，写清"我只验证了 A 情况，B 情况未测"是非常受欢迎的表述。

### 2. AI 辅助的贡献需要披露

本仓库**不排斥** AI 生成的代码 —— 项目本身就是 AI 辅助开发的（见
[README · AI 辅助开发](README.md#ai-assisted-development--关于-ai-辅助开发)）。
但要求：

1. 在 PR 描述中说明是否使用了 AI、用在哪些部分；
2. **提交者对其正确性负责**，不能以"AI 写的"为理由免责；
3. 经过真机验证，或有可复核的依据（例如官方驱动源码、数据手册页、独立脚本验证）。

审阅者会对 AI 生成的代码**按同样标准审查**，不因为来源而放宽或加重。

---

## 开发环境

```bash
git clone https://github.com/<you>/stc51-android-flasher.git
cd stc51-android-flasher
```

电脑上不需要手机或硬件即可做基础检查：

```bash
python tools/verify_divisor.py      # 分频算法回归（含期望值断言，失败即退出码 1）
python -m py_compile src/ch340_bridge.py
```

Windows 上还可以跑发布前自检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check.ps1
```

CI（`.github/workflows/ci.yml`）会对每次 push/PR 跑上面两项。

---

## 代码风格

- **换行符必须是 LF**。`tools/check.ps1` 会检查；用 Windows 提交前请确认
  `git config core.autocrlf` 没有把它们改成 CRLF。
- Python：遵循 PEP 8，保持现有的"无第三方依赖、只用标准库 + pyusb"的取向。
- Shell：`set -u`，变量加引号，shebang 用 Termux 绝对路径。
- 中文注释可以接受；但**关键算法与"为什么这么做"的注释请用中文或英文写清楚依据**。
- 不要引入新的运行时依赖，除非在 PR 里说明为什么必需。

---

## 提交信息

推荐 [Conventional Commits](https://www.conventionalcommits.org/)：

```
fix(bridge): 修正 MAX_BPS 使 115200 不再被截断为 46875

- 现状：get_divisor(115200) 返回 0x8003，实际 46875 baud
- 改动：按 WCH 驱动改写上限判断
- 验证：STC89C52RC + CH340(0x31) 上完成一次 115200 烧录，日志见下
```

---

## 适合上手的任务

见 [README · 已知限制](README.md#已知限制--limitations) 与仓库 Issues 中带
`good first issue` 标签的条目。典型方向：

- 修 `MAX_BPS` 并验证高速传输；
- 让桥在 USB 重新插拔后自动重建（当前不会）；
- 支持 CH341 / CH9102 等其他 WCH 芯片；
- 把 pyserial 补丁做成可复用的安装脚本或 `sitecustomize`；
- 补充其他手机 / Android 版本的兼容性记录。

> **超出当前范围的方向也欢迎**（例如支持 STM32、其他 USB 转串口芯片、其他 STC 系列），
> 但前提是：**你能提供真机验证记录或可复核的依据**。
> 目前项目没有任何 STM32 相关代码，也从未做过 STM32 试验，
> 因此这类 PR 必须自带完整的验证说明（见上方硬要求 1），否则无法合并。

---

## 行为准则

请保持技术性、就事论事。项目接受直接的批评与反驳 —— **挑战结论是受欢迎的**，
人身攻击不是。详见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

---

## 许可证

提交即表示你同意以本项目的 MIT 许可证发布你的贡献。
