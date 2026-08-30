# PowerUp — 用 DualSense 手柄遥控 Claude Code

[English](README.md) | **简体中文** | [日本語](README.ja.md)

PowerUp 把 PS5 的 DualSense 手柄变成 [Claude Code](https://www.anthropic.com/claude-code)
的贴手遥控器。按住扳机键说出指令，Claude 的回复会朗读给你听；手柄上的每个按键
都可以映射成适合你工作流的操作——批准修改、打断当前回合、重播上一条回复、发送
预设提示词等等。想在发送前先检查一下措辞？按住另一个扳机键，把话听写进输入框，
满意后再编辑、发送。手柄的光条和振动会实时反映 Claude 会话的状态，一眼就能看出
它是在空闲、聆听、思考还是朗读。

这是一个用 SwiftUI 构建的原生 macOS 应用。构建不需要 Xcode 工程——只要
Swift Package Manager。

> 注：下方链接的文档目前均为英文。本翻译若与[英文版 README](README.md)
> 有出入，以英文版为准。

## 更大的愿景

今天已有的一切——macOS、DualSense、Claude Code——只是**一个更宏大的开源愿景
的 v1**：让任何人都能解放双手地进行 vibe coding，用**任何设备**（游戏手柄、
耳机按键、脚踏板、宏键盘、纯语音）驱动**任何 AI 编程工具（harness）**
（Claude Code、Codex CLI、Gemini CLI、opencode……），运行在**任何操作系统**上
（macOS、Windows、Linux）——设备还会用灯光、振动、屏幕实时反馈你的智能体
正在做什么。

完整规划见 **[DEVELOPMENT.md](DEVELOPMENT.md)**；参与方式见
**[CONTRIBUTING.md](CONTRIBUTING.md)**。欢迎各类贡献、设备点子或适配新工具
的请求——开一个 issue 或 discussion 即可。

## 快速开始

```sh
./scripts/build.sh        # 发布版构建 → build/PowerUp.app
open build/PowerUp.app    # 务必以 App 包方式启动（macOS 的权限
                          # 与 App 包身份绑定）
```

你需要 macOS 14+、已登录的 `claude` CLI、通过蓝牙配对的 DualSense，以及
Xcode 命令行工具。首次使用时，请在麦克风和语音识别的权限弹窗中点击允许，并
选择一个项目文件夹——详见**[入门指南](docs/getting-started.md)**。

## 三个核心按键

手柄配对之后，三个按键就能覆盖与 Claude 的完整对话循环：

- **L2 —— 听写到输入框。** 按住、说话、松开；你说的内容会落进输入框供你
  检查，此时还不会发送。
- **L1 —— 发送输入框内容。** 不管框里是打字、听写还是两者混合的内容，立刻
  发给 Claude。
- **R2 —— 直接对 Claude 说。** 按住、说话、松开；一松手转录文本就发出去，
  没有检查环节。

其余的一切——批准（✕）、打断（○）、方向键上的快捷提示词、用摇杆和触摸板
切换模型/思考力度/权限模式——都建立在这个循环之上，而且每个按键都可以在
**Settings → Buttons** 里重新映射。完整的默认映射表见
**[按键与控制](docs/controls.md)**。

## 文档

| 指南 | 内容 |
|---|---|
| [入门指南](docs/getting-started.md) | 环境要求、构建、首次运行、权限 |
| [按键与控制](docs/controls.md) | 完整默认映射、听写→检查→发送、切换模型/思考力度/权限、打断 |
| [语音与朗读](docs/voice.md) | 多语言朗读、换一个更好的嗓音、朗读长度上限 |
| [编程工具（harness）](docs/harnesses.md) | 驱动 Claude Code 之外的智能体（opencode 及其他 ACP 智能体）、用手柄按键批准工具调用 |
| [远程控制模式](docs/remote-control.md) | 控制 cmux 或终端里的已有会话、hooks 配置、辅助功能与稳定签名 |
| [配置与会话](docs/configuration.md) | 设置、`config.json`、会话恢复、费用显示 |
| [疑难排解](docs/troubleshooting.md) | 权限重置、手柄问题、`claude` 可执行文件问题 |
| [隐私](docs/privacy.md) | 你的语音和数据去了哪里（剧透：基本哪儿也不去） |
| [PowerUp 协议](docs/protocol.md) | 基于本地 WebSocket API 构建你自己的设备插件或界面 |

贡献者请看：[CONTRIBUTING.md](CONTRIBUTING.md)（构建/测试/PR 规则）、
[DESIGN.md](DESIGN.md)（具有约束力的实现契约）、
[DEVELOPMENT.md](DEVELOPMENT.md)（路线图、架构、各工作方向）。
