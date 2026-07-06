---
name: skill-recommender
description: 当用户提出可能需要专业能力的问题，且本地已安装的skills都不适合时，从远端skill托管平台推荐并安装新skills。获取可用skills列表，分析用户意图，展示Top 3相关选项，并在安装前预览详细信息。
---

# Skill推荐器

该skill从远端平台推荐并安装新skills来帮助用户解决问题。

## 何时使用

只有当本地已安装的skills都不适合处理用户请求，且远端平台可能存在更合适的skill时，才使用该skill。

不应触发的情况：
- 请求很简单且不需要专业skill
- 本地已有skill的description可以匹配用户请求
- 用户只是询问一般信息

## 使用方法

### 步骤1：获取远端Skills列表

运行：

```bash
python3 scripts/fetch_skills.py
```

脚本输出JSON数组，每项包含name、description和download_url。

如果脚本输出空数组或任意包含 `error` 字段的JSON，说明当前没有可安装的远端skill。此时不要继续调用get_download_url.py、preview_skill.py或install_skill.py，直接用中文解释原因，并告诉用户可以通过Tools设置上传skill zip，或配置/检查 `TICK_SKILL_REGISTRY_URL` 后再试。

### 步骤2：分析和推荐

根据用户请求和skill description做语义匹配，最多展示Top 3。

回复用户：

```text
发现以下技能可能对你有帮助:

1. **skill-name-1** - skill功能描述
2. **skill-name-2** - skill功能描述
3. **skill-name-3** - skill功能描述

需要我帮你安装哪个技能?（我会先展示详细信息供你确认）
```

### 步骤3：获取下载链接

用户选择后运行：

```bash
python3 scripts/get_download_url.py <skill_name>
```

### 步骤4：安装前预览

安装前必须运行：

```bash
python3 scripts/preview_skill.py <skill_name> <download_url>
```

向用户展示预览并等待明确确认。

### 步骤5：安装

用户确认后运行：

```bash
python3 scripts/install_skill.py <skill_name> <download_url>
```

新skill会安装到与skill-recommender相同的父目录，也就是当前TICK skills目录。

## 错误处理

如果获取列表、获取下载URL、预览或安装失败，用中文告诉用户暂时没有找到可安装的远端技能，并继续用现有能力处理请求。不要把脚本的英文错误原样作为最终回答。

## 重要提示

- 本地skills始终优先
- description是触发条件
- 安装前必须预览并获得用户确认
- scripts、references、assets都是可选资源，只有SKILL.md是必需文件