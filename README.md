# TICK

TICK 是一个 macOS Proactive Agent。它以可拖动的机器人悬浮球常驻桌面，在合适时机展开小型对话框，把网页、终端和系统行为转化成可点击的下一步行动。

TICK 不把主动式 Agent 做成“自动总结器”。它更关注用户下一步可能要做什么：诊断报错、提取命令、校验环境、生成补丁草案、预警危险操作，或者把当前上下文交给工具继续执行。

## Features

- 可拖动的 macOS 悬浮机器人 UI
- OpenAI-compatible 模型接口，可配置 Base URL、model 和 API key
- Markdown 输出、图片输入、流式对话
- 主动式观察进程 `TICKObserver`
- Trace 日志平台，展示 raw HTTP、SSE、工具过程和 token/word count
- 支持 Skills、MCP、Hooks
- Agent loop：模型请求工具，TICK 执行后把结果回传，直到模型输出最终结果

## Project Structure

```text
TICK/
├── Package.swift
├── Sources/
│   ├── TICK/
│   └── TICKObserver/
├── AppBundle/
│   └── TICKInfo.plist
├── scripts/
│   ├── build_tick_app.sh
│   ├── generate_icon.swift
│   └── generate_web_assets.swift
├── tools/
│   └── skills/
└── docs/
```

运行时会在项目目录下生成 `chat-api-key`、`llm-settings.json`、`trace.jsonl`、`tools/config.json` 等本地状态文件。这些文件可能包含密钥、trace 原始请求或本机路径，默认不会提交到 Git。

## Build

```bash
swift build --product TICK
swift build --product TICKObserver
scripts/build_tick_app.sh
```

App 产物：

```text
dist/TICK.app
```

## Download

官网中的二进制下载文件位于：

```text
docs/downloads/TICK-macOS.zip
```

重新生成：

```bash
scripts/build_tick_app.sh
mkdir -p docs/downloads
ditto -c -k --keepParent dist/TICK.app docs/downloads/TICK-macOS.zip
```

## Observer

`TICKObserver` 会随 TICK 启动，监听：

- 剪贴板内容特征，例如 Error、Exception、代码片段
- 前台 App 和窗口变化
- 浏览器标题、URL、正文
- 终端和其他 App 的 Accessibility 可见文本
- Command+Z、Backspace 节奏
- `// todo:`、`# fix:`、`??` 等 ghost trigger

默认不截屏，避免触发 macOS 屏幕录制权限弹窗。键盘级事件需要 macOS Accessibility/Input Monitoring 权限。
