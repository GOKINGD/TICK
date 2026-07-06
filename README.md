# TICK

TICK 是一个 macOS 主动式桌面 Agent。它以可拖动的机器人悬浮球常驻桌面，在合适时机展开小型对话框，把网页、终端和系统行为转化成可点击的下一步行动。它支持 OpenAI-compatible 大模型接口、图片输入、Markdown 输出、trace 日志、Claude Code 风格 skills，以及后台 macOS 行为观察进程。

## 目录结构

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
├── tools/
│   └── skills/
└── docs/
```

运行时会在项目目录下生成 `chat-api-key`、`llm-settings.json`、`trace.jsonl`、`tools/config.json` 等本地状态文件。这些文件可能包含密钥、trace 原始请求或本机路径，默认不会提交到 Git。

## Skills

Skills 位于：

```text
tools/skills/
```

每个 skill 只强制要求一个文件：

```text
skill-name/
└── SKILL.md
```

`SKILL.md` 的 frontmatter 必须包含：

```markdown
---
name: skill-name
description: 这里写触发条件
---
```

`scripts/`、`references/`、`assets/` 都是可选资源。TICK 启动时只把 skill 的 `name + description` 放入模型上下文；只有 description 匹配并调用 `tick_skill action=load` 后，才读取对应的 `SKILL.md` 全文。

## Tools 架构

- Skills 是唯一默认暴露给模型选择的工具，采用 Claude Code 风格的渐进披露。
- MCP 保留为模型工具，但只有配置了可用 MCP server 时才会出现在请求的 tools 列表中；没有配置时不带 MCP。
- Hooks 不是模型工具。Hook 由 TICK 系统代码在 `before_tool`、`after_tool`、`after_response` 等生命周期事件中执行，执行结果写入 trace。

## 构建

```bash
swift build --product TICK
swift build --product TICKObserver
scripts/build_tick_app.sh
```

App 产物：

```text
dist/TICK.app
```

## 官网与 GitHub Pages

宣传官网位于：

```text
docs/
```

GitHub Pages 免费部署方式：

1. 将仓库推送到 GitHub
2. 进入仓库 `Settings -> Pages`
3. Source 选择 `Deploy from a branch`
4. Branch 选择 `main`，Folder 选择 `/docs`

页面入口是：

```text
docs/index.html
```

生成官网产品展示图：

```bash
swift scripts/generate_web_assets.swift
```

## 后台观察进程

`TICKObserver` 会随 TICK 启动，监听：

- 剪贴板内容特征，例如 Error、Exception、代码片段
- 前台 App 和窗口变化
- 停留/空闲上下文：浏览器读取当前页面标题、URL、正文；终端和其他 App 读取 Accessibility 可见文本。默认不截屏，避免触发 macOS 屏幕录制权限弹窗
- Command+Z、Backspace 节奏
- `// todo:`、`# fix:`、`??` 等 ghost trigger

键盘级事件需要 macOS Accessibility/Input Monitoring 权限。没有权限时，TICK 只写 trace 和提示，不会触发模型请求。

频率控制：

- 前台窗口稳定停留 `3s` 后才采样，且会忽略 TICK 自身
- observer 端按事件类型冷却：浏览器约 `20s`、终端约 `12s`、普通 App 约 `30s`
- TICK 端再次按事件类型限流，并按文本/截图内容 key 去重
- 后台主动触发只发送本次上下文，不携带聊天历史
- 主动输出默认要求模型给出行动按钮，例如校验环境、提取命令、生成补丁草案、列确认清单
- 读不到有价值行动时会静默，不会向用户展示截图路径、权限提示、采集失败等内部调试信息
- 普通 App 需要满足内容密度或相关性门槛，避免把所有停顿都发给模型
