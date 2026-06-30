# README 设计规格说明书

日期：2026-06-30
主题：为 WindowMover 仓库编写 README（中英双语）与 LICENSE

## 背景

WindowMover 是一个 macOS 菜单栏应用，把所有可见窗口一键移动到选定的显示器，支持三种移动模式（保持原比例 / 填满 / 原始尺寸）、开机启动，需要辅助功能权限。仓库目前没有 README 和 LICENSE，通过 GitHub Actions 打 tag 时构建 DMG 发布到 Release。

## 目标

- 为仓库提供面向用户的中英双语 README，内容等价、结构对称。
- 提供 MIT LICENSE 文件。
- 让新用户能快速理解用途、完成安装与授权、正确使用三种模式。

## 范围

仅编写以下三个文件：

- `README.md`（中文）
- `README.en.md`（英文）
- `LICENSE`（MIT）

不改动其他文件，不新增构建/发布流程。

## 受众与语言

- 受众：终端用户（需要在多显示器 Mac 上批量搬运窗口的人）。
- 语言：中英双语，两个独立文件，顶部互相链接切换。
- 语气：简洁实用，面向用户，避免架构术语（不写 App/Models/Platform 分层）。
- 英文版用自然的技术英语，非逐字翻译。

## 文件结构

### README.md（中文）

顶部：语言切换链接 `English`（指向 `README.en.md`）。

章节顺序：

1. **标题 + 一句话介绍**
   - `# WindowMover`
   - 一句话：macOS 菜单栏工具，一键把所有窗口移到指定显示器。

2. **功能特性**
   - 三条要点：
     - 一键移动所有可见窗口到目标显示器
     - 三种移动模式：保持原比例 / 填满 / 原始尺寸
     - 支持开机启动

3. **下载与安装**
   - 路径一（推荐）：从 GitHub Release 下载 DMG
     1. 前往仓库的 Release 页面
     2. 下载最新版 `WindowMover-<version>.dmg`
     3. 打开 DMG，把 WindowMover 拖到 Applications
     4. 首次启动若被 Gatekeeper 拦截，到"系统设置 → 隐私与安全性"点击"仍要打开"
   - 路径二：源码编译
     1. 克隆仓库
     2. 用 Xcode 打开 `WindowMover.xcodeproj`
     3. 选择 Release configuration，构建并运行

4. **使用方法**
   - 启动后菜单栏出现显示器图标。
   - 点击图标 → 在"移动所有窗口到"下选择目标显示器 → 所有可见窗口自动移过去。
   - "移动方式"切换三种模式；"开机启动"开关。
   - 首次使用需授予辅助功能权限；未授予时菜单顶部会显示"需要辅助功能权限…"按钮，点击即跳转系统设置。

5. **三种移动模式**
   - **保持原比例（keepAspect）**：按窗口原宽高比等比缩放到目标显示器内，居中放置。
   - **填满（fill）**：把窗口拉伸到目标显示器的可用区域（扣除 Dock/菜单栏）。
   - **原始尺寸（originalSize）**：保持窗口原尺寸，居中放置；若原尺寸超出目标显示器，则回退为保持原比例。

6. **已知限制**
   - 因 macOS 底层 API 限制，不支持操作全屏窗口：全屏窗口会被跳过，不参与移动。
   - 仅在多显示器场景下有意义；单显示器时菜单会提示"未检测到多显示器"。

7. **License**
   - MIT，详见 `LICENSE`。

### README.en.md（英文）

顶部：语言切换链接 `中文`（指向 `README.md`）。

章节与中文版对称，内容等价。章节标题用英文：

1. Title + one-line intro
2. Features
3. Download & Installation
4. Usage
5. Move Modes
6. Known Limitations
7. License

### LICENSE

MIT License，版权行：`Copyright (c) 2026 gcy <gcy8599@outlook.com>`。

## 写作约定

- 不写具体 release 版本号或直链下载 URL（随版本失效），用"前往 Release 页面"指引。
- 不放截图/演示 GIF 占位（用户明确不需要）。
- 不写项目结构/架构（面向用户，非开发者）。
- 两个 README 文件内容必须等价，维护时需同步。

## 验收标准

- 仓库根目录存在 `README.md`、`README.en.md`、`LICENSE` 三个文件。
- `README.md` 与 `README.en.md` 章节结构对称，内容等价，顶部互相链接。
- `LICENSE` 为标准 MIT 文本，版权行正确。
- 中文 README 中的"三种移动模式"描述与代码 `FrameCalculator.swift` 实现一致。
- "已知限制"中全屏窗口限制与代码 `WindowMoverService.swift` 的 skip 行为一致。
