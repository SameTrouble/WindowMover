# AppIcon 设计规格说明书

- 日期：2026-06-30
- 主题：为 WindowMover（macOS 菜单栏应用）设计并生成 App 图标
- 状态：已批准（设计阶段）

## 1. 背景

WindowMover 是一个 macOS 菜单栏应用，一键把所有窗口移动到选定显示器。当前 `Assets.xcassets/AppIcon.appiconset/` 仅有 `Contents.json`，没有任何 PNG 图像，应用在 Finder/Dock 中使用系统默认图标。

应用主功能图标在菜单栏使用 SF Symbol `display.2`（多显示器）。AppIcon 应与之语义呼应，但作为独立图标可以更丰富。

## 2. 目标

- 为 `AppIcon.appiconset` 提供 macOS 应用所需的全部 10 个 PNG 尺寸
- 图标语义清晰传达"多显示器 + 窗口移动"的核心功能
- 风格融入 macOS 系统（Big Sur 之后），不显突兀
- 生成过程可重现，便于后续调整

## 3. 非目标

- 不为 iOS/iPadOS 提供图标（仅 mac idiom）
- 不设计营销素材、不设计菜单栏图标（已用 SF Symbol）
- 不引入外部图像素材或第三方依赖

## 4. 视觉设计

### 4.1 概念

两台显示器左右并排，一个窗口从左显示器跃迁到右显示器，下方带半透明拖尾表达运动方向。呼应核心功能"把窗口移到另一台显示器"。

### 4.2 画布与底板

- 设计画布：1024×1024 px
- 底板：macOS squircle（圆角矩形），圆角半径 ≈ 224 px（约 22% 边长），占满画布边缘
- 底板填充：蓝色径向渐变
  - 圆心偏左上（约 30%, 25%）
  - 起始色：`#0A84FF`（系统 blue）
  - 结束色：`#0040DD`（系统 blue 深色变体）
- 底板投影：黑色 20% 透明、向下偏移 8 px、模糊 24 px（图标内阴影感）

### 4.3 显示器

两台显示器左右对称，大小一致。

- 单台显示器尺寸：宽 ≈ 320 px、高 ≈ 240 px（屏幕区域）
- 两台水平间距：≈ 60 px，整体水平居中
- 垂直位置：屏幕区域中线位于画布约 45% 处，下方留空间给底座
- 外壳：`#1C1C1E` 圆角矩形（圆角 16 px），边框厚 ≈ 16 px 包裹屏幕
- 屏幕区域：`#E5E5EA` 填充
- 底座：`#1C1C1E`，短颈（宽 40 px、高 28 px）+ 椭圆底盘（宽 120 px、高 16 px），居中于各自显示器下方
- 投影：每台显示器投下黑色 15% 透明、向下偏移 6 px、模糊 12 px 的阴影

### 4.4 跃迁窗口

- 尺寸：宽 ≈ 160 px、高 ≈ 110 px
- 位置：整体位于左显示器屏幕右上方，并向右上方偏移 ≈ 30 px（朝右显示器方向），轻微倾斜（旋转 +8°）
- 填充：`#FFFFFF`，描边 `#0A84FF` 宽 3 px
- 顶部三色按钮：红 `#FF5F57`、黄 `#FEBC2E`、绿 `#28C840`，直径 8 px，位于窗口顶栏左侧
- 投影：黑色 25% 透明、向下偏移 4 px、模糊 8 px

### 4.5 拖尾

窗口下方留 3 段半透明白色矩形拖尾，表达运动轨迹：

- 3 段，从窗口到左显示器屏幕方向依次排列
- 每段尺寸 ≈ 80×20 px，圆角 6 px
- 透明度依次：60%、40%、20%
- 旋转角度与窗口一致（+8°）

### 4.6 配色总表

| 元素 | 颜色 |
|------|------|
| 底板渐变起始 | `#0A84FF` |
| 底板渐变结束 | `#0040DD` |
| 显示器外壳/底座 | `#1C1C1E` |
| 显示器屏幕 | `#E5E5EA` |
| 跃迁窗口填充 | `#FFFFFF` |
| 跃迁窗口描边 | `#0A84FF` |
| 窗口三色按钮 | `#FF5F57` / `#FEBC2E` / `#28C840` |
| 拖尾 | `#FFFFFF` 60%/40%/20% |
| 各处阴影 | 黑色 15%–25% 透明 |

## 5. 技术实现

### 5.1 文件结构

```
Tools/
  icon-source.svg          # 矢量源文件（1024×1024）
  render-icon.swift        # 渲染脚本
WindowMover/
  Assets.xcassets/
    AppIcon.appiconset/
      Contents.json        # 更新指向 PNG 文件
      icon_16.png
      icon_16@2x.png
      icon_32.png
      icon_32@2x.png
      icon_128.png
      icon_128@2x.png
      icon_256.png
      icon_256@2x.png
      icon_512.png
      icon_512@2x.png
```

### 5.2 SVG 源文件

`Tools/icon-source.svg`：手写的纯文本 SVG，1024×1024 viewBox，按第 4 节规格绘制所有元素。所有形状用整数坐标，渐变/滤镜用 `<defs>` 定义。

### 5.3 渲染脚本

`Tools/render-icon.swift`：

1. 读取 `icon-source.svg` 为 `Data`
2. 用 `NSImage(data:)` 加载（macOS 原生支持 SVG 解析），取得 `NSVGImageRep`
3. 对第 5.1 节列出的每个目标尺寸，独立从 SVG 重新栅格化为该尺寸的 `NSBitmapImageRep`（而不是从 1024 缩放，以保证每个尺寸质量）
4. 用 `NSBitmapImageRep.representation(using: .png)` 写出对应文件名的 PNG 到 `AppIcon.appiconset/`
5. 输出共 10 个 PNG

脚本可重复执行：先清空 `AppIcon.appiconset/*.png`，再重新生成。

### 5.4 Contents.json

更新 `AppIcon.appiconset/Contents.json`，为每个尺寸条目增加 `"filename"` 字段，指向 5.1 约定的文件名。

## 6. 测试与验证

- 视觉验证（不读取图片二进制，靠命令行元信息）：
  - `sips -g pixelWidth -g pixelHeight` 校验每个 PNG 尺寸正确
  - `file` 命令确认 PNG 格式
- 构建验证：
  - `xcodebuild -scheme WindowMover -configuration Debug build` 成功，无 asset catalog 警告
- 文件结构验证：
  - `AppIcon.appiconset` 下存在 10 个 PNG + `Contents.json`
  - `Contents.json` 每个 entry 都有 `filename`

## 7. 风险与回退

- **风险**：`NSImage` 对 SVG 的栅格化质量在小尺寸（16×16）下可能模糊
  - 缓解：脚本对每个目标尺寸独立栅格化，而不是从 1024 缩放；SVG 矢量信息在每个尺寸重新采样
- **风险**：`NSImage(data:)` 对某些 SVG 特性（滤镜、mask）支持有限
  - 缓解：SVG 中尽量用 `<linearGradient>`/`<radialGradient>` 和基本形状，避免复杂滤镜；如必要改用 rsvg-convert（需 brew 安装）作为回退
- **风险**：squircle 圆角与系统模板不完全一致
  - 缓解：使用标准圆角矩形，macOS 会在显示时套用 mask；不追求 100% squircle 数学曲线

## 8. 验收标准

1. `AppIcon.appiconset/` 下存在 10 个 PNG 文件，尺寸分别对应 16/32/128/256/512 @1x/@2x
2. `Contents.json` 已更新，每个 entry 指向对应 PNG
3. `xcodebuild` 构建成功且无 asset catalog 警告
4. `Tools/icon-source.svg` 与 `Tools/render-icon.swift` 存在且可重复执行
