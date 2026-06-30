# 代码质量优化设计

- 日期：2026-06-30
- 范围：WindowMover 应用代码（不含 Tools/ 脚本与构建配置）
- 目标：在不改变用户可见行为的前提下，修复潜在 bug、消除架构异味、补协议抽象、拆分过载的 `AppState`，并先行为重构建立单元测试安全网
- 非目标：全局热键、偏好设置窗口、本地化、UI 改造、显示器热插拔监听等使用体验改进留待后续子项目

## 背景

WindowMover 是 macOS 菜单栏应用，一键把所有窗口移到选定显示器。当前架构协议驱动、依赖注入清晰，但存在以下代码质量问题：

1. **`AppState` 职责过载**（103 行，5 职责）：持久化设置、显示器状态、辅助功能轮询、开机启动注册、移动任务派发。
2. **`AccessibilityChecker` 无协议抽象**：`final class`，`AppState` 直接持有具体类型，无法 mock，权限轮询逻辑不可测。
3. **`MenuView` 绕过依赖注入**：`MenuView.swift:11` 直接 `AccessibilityChecker().openSystemSettings()`，违反分层。
4. **`WindowInfo` 死字段**：`isFullscreen`/`isMinimized` 永远 `false`（`WindowFilter.swift:33-34` 硬编码），全屏判断实际走 `WindowController.isFullscreen` 查 AX。
5. **`WindowMoverService` 冗余依赖**：持有 `screenObserver` 仅做一次 `contains` 校验，调用方 `AppState` 已持显示器列表。
6. **`WindowController` 崩溃风险**：`AXValueCreate` 返回值强制解包（`WindowController.swift:44-45`）；`AXUIElementCopyAttributeValue` 忽略错误码，失败时静默返回 `.zero`。
7. **`ScreenObserver` 坐标偏差**：`ScreenObserver.swift:22` 用 `NSScreen.screens.first?.frame.height` 做 Y 翻转基准，屏序变化时坐标错位。
8. **`WindowController.axWindow(for:)` 脆弱匹配**：5px 阈值帧近似匹配窗口，多窗口位置相近时可能匹配错。
9. **零测试覆盖**：`FrameCalculator`/`WindowFilter`/`WindowMoverService` 极易测却无测试。

## 方案选择

对 `AppState` 拆分粒度，考虑过三个方案：

- **方案 A（保守）**：仅抽出 `SettingsStore` + `AccessibilityCoordinator`，`AppState` 保留显示器、开机启动、移动派发。改动小但 AppState 仍担 3 职责。
- **方案 B（推荐，采纳）**：抽出 `SettingsStore` + `AccessibilityCoordinator` + `DisplayCoordinator`，`AppState` 降为协调者外观，仅保留移动编排 + `isMoving`。职责清晰，MenuView 仅依赖单一 `AppState`，注入路径不变，回归面可控。
- **方案 C（激进）**：各 Coordinator 直接注入 MenuView，`AppState` 消失。MenuView 注入点变多，改动面大，且移动编排仍需协调者，收益不抵成本。

## 设计

工作分 5 部分，按依赖顺序执行。第 1 部分建立测试安全网，后续 4 部分在测试保护下进行结构改造。

### 第 1 部分：测试基础设施与关键单测

**新文件**：

- `WindowMoverTests/FrameCalculatorTests.swift` — 覆盖三种 `MoveMode`（keepAspect/fill/originalSize）的目标 CGRect 计算。场景含：单屏、多屏、目标屏为非主屏、窗口大于目标屏需缩放、窗口小于目标屏的定位。
- `WindowMoverTests/WindowFilterTests.swift` — 构造 `CGWindowListCopyWindowInfo` 风格 `[NSDictionary]`，验证过滤规则：layer≠0 被过滤、alpha<1 被过滤、`systemOwners` 列表内进程被过滤、正常应用窗口被保留。
- `WindowMoverTests/WindowMoverServiceTests.swift` — 用 mock 依赖验证编排（调用 `moveAllWindows(to:mode:)`）：全屏窗口被跳过、正常窗口被移动、`MoveResult` 的 moved/skipped/failed 计数正确。注意：第 4.3 部分移除 `screenObserver` 依赖后，"目标显示器不存在返回空结果"的校验职责转移到 `AppState.moveAll`，service 测试不再覆盖此场景（由 `displays.contains` 在 `AppState` 层承担）。
- `WindowMoverTests/TestDoubles/MockWindowController.swift` — 实现 `WindowControlling`，记录 `setFrame` 调用参数，可编程返回 `currentFrame`/`isFullscreen`。
- `WindowMoverTests/TestDoubles/MockWindowEnumerator.swift` — 实现 `WindowEnumerating`，可编程返回 `[WindowInfo]`。
- `WindowMoverTests/TestDoubles/MockScreenObserver.swift` — 实现 `ScreenObserving`，可编程返回 `[Display]`。

**约定**：mock 放测试 target 内，不污染 app target。测试 target 部署目标保持 `14.6`。

**验证标准**：`xcodebuild test -scheme WindowMover -destination 'platform=macOS'` 全绿。

### 第 2 部分：修潜在 bug

**2.1 `WindowController` 强制解包与错误码忽略**

位置：`WindowController.swift:44-45`（`AXValueCreate` 强制解包）、`WindowController.swift:29-30`（`AXUIElementCopyAttributeValue` 忽略返回码）、`WindowController.swift:71-72`（`matches` 内同类问题）。

修复：

- `AXValueCreate` 返回值改为 `guard let value = AXValueCreate(...) else { throw WindowControlError.axValueCreationFailed }`。新增 `axValueCreationFailed` case 到 `WindowControlError`。
- `takeUnretainedValue()` 改为 `takeRetainedValue()`，配合 `Create` 语义避免泄漏。
- `AXUIElementCopyAttributeValue` 调用检查返回码为 `.success`，非成功则抛 `WindowControlError.attributeReadFailed(String)`，不再静默返回 `.zero`。`matches` 函数同理。

**2.2 `ScreenObserver` 多屏坐标基准偏差**

位置：`ScreenObserver.swift:22`，`NSScreen.screens.first?.frame.height ?? nsRect.height`。

修复：改用全局主屏高度作 Y 翻转基准，不依赖 `NSScreen` 排序：

```swift
let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
let flippedY = mainDisplayHeight - nsRect.origin.y - nsRect.height
```

`CGMainDisplayID()` 返回主屏 ID，`CGDisplayBounds` 取其点坐标高度（与 `NSScreen.frame` 单位一致），稳定不受屏序影响，且无像素/点混淆。

**2.3 `WindowController.axWindow(for:)` 脆弱匹配**

位置：`WindowController.swift:77-80`，5px 阈值帧近似匹配。

修复：优先用 PID + windowID 精确查找。`WindowInfo` 已有 `id`（`CGWindowID`）与 `ownerPID`。流程：

1. `AXUIElementCreateApplication(pid)` 取 app 元素。
2. `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` 取其窗口数组。
3. 遍历数组，用 `AXUIElementCopyAttributeValue(window, kAXParentAttribute)` 或帧精确比对定位；若可取到窗口标识则按 `windowID` 精确匹配。
4. 精确匹配失败时，退回当前 5px 帧匹配作回退。

保留帧匹配回退是为了兼容部分不暴露 windowID 的应用，避免引入新回归。

**验证标准**：`xcodebuild build` 通过；第 1 部分单测全绿；手动跑 app 移动窗口行为不变（含多屏、非主屏目标、窗口密集场景）。

### 第 3 部分：补 AccessibilityChecker 协议

**新协议**：放 `PlatformProtocols.swift`，与现有三协议并列。方法名对齐现有 `AccessibilityChecker` 实现。

```swift
protocol AccessibilityChecking {
    func isGranted() -> Bool
    @discardableResult func requestPrompt() -> Bool
    func openSystemSettings()
}
```

**类型改造**：`AccessibilityChecker` 由 `final class` 改为 `final class AccessibilityChecker: AccessibilityChecking`（保留 `logger` 属性，维持 class）。三方法签名不变，仅增加协议遵从。

**依赖改造**：`AppState` 的 `@ObservationIgnored let accessibility: AccessibilityChecking`（类型标注换协议；原属性名 `accessibility` 保留，仅类型从具体类换为协议）。`WindowMoverApp.init()` 注入点不变，`AccessibilityChecker()` 作为协议实例传入。

**测试影响**：新增 `WindowMoverTests/TestDoubles/MockAccessibilityChecker.swift` 实现 `AccessibilityChecking`，供未来 `AccessibilityCoordinator` 测试。本轮不强制写 coordinator 测试，但协议就位后可测。

**验证标准**：`xcodebuild build` 通过；现有单测不受影响。

### 第 4 部分：修架构异味（3 项小改）

**4.1 `MenuView` 绕过依赖注入**

位置：`MenuView.swift:11`，`AccessibilityChecker().openSystemSettings()`。

修复：`AppState` 增加转发方法 `func openSystemSettings() { accessibility.openSystemSettings() }`。`MenuView` 改调 `state.openSystemSettings()`。依赖链回归 `MenuView → AppState → 协议`。与第 3 部分协同——`AppState` 转发给协议而非具体类。

注：第 5 部分拆分后此方法转发给 `AccessibilityCoordinator.openSystemSettings()`，但对外接口不变。

**4.2 移除 `WindowInfo` 死字段**

位置：`WindowInfo.swift` 的 `isFullscreen`/`isMinimized`，`WindowFilter.swift:33-34` 硬编码赋 `false`。

修复：从 `WindowInfo` 删除两字段及 `WindowFilter` 中对应赋值。grep 全代码库确认无其他引用。`WindowMoverService` 已用 `WindowController.isFullscreen` 查 AX，不受影响。第 1 部分的 `WindowMoverServiceTests` 与 `MockWindowController` 不依赖此字段。

**4.3 去除 `WindowMoverService` 冗余依赖**

位置：`WindowMoverService.swift:27`，`screenObserver.displays.contains`。

修复：`WindowMoverService` 移除 `screenObserver` 依赖（构造参数与存储属性均删）。`moveAllWindows(to:)` 信任调用方传入的显示器，不再内部校验。安全检查由 `AppState.moveAll` 在调用前 `displays.contains(display)` 承担，不丢失。`WindowMoverApp.init()` 注入少一个参数。第 1 部分的 `WindowMoverServiceTests` 相应移除 mock 注入。

**验证标准**：`xcodebuild build` + 全部单测通过。

### 第 5 部分：拆分 AppState（方案 B）

**目标**：`AppState` 从 5 职责降为协调者外观，下沉 3 职责到独立 coordinator。

**新文件**：

`Models/SettingsStore.swift`：
- `@MainActor @Observable final class`
- 持有 `UserDefaults.standard`（`@ObservationIgnored`）
- 属性 `moveMode: MoveMode`，`didSet` 回写 `defaults`
- 属性 `launchAtLogin: Bool`，`didSet` 内调 `SMAppService.mainApp` 注册/注销，失败回滚属性值并记日志
- `init()` 从 defaults 种子
- `syncLaunchAtLoginStatus()` 读 `SMAppService.mainApp.status` 回填 `launchAtLogin`，供启动时同步系统真实状态

`Models/AccessibilityCoordinator.swift`：
- `@MainActor @Observable final class`
- 依赖 `AccessibilityChecking`（`@ObservationIgnored`）
- 属性 `granted: Bool`
- `@ObservationIgnored private var pollTimer: Timer?`
- `init(checker:)` 初始化 `granted = checker.isGranted()`
- `refresh()`：更新 `granted`；若未授权且无 timer，启动 2 秒间隔轮询；若已授权则停止轮询
- `requestPrompt() -> Bool` 转发 `checker.requestPrompt()`
- `openSystemSettings()` 转发 `checker.openSystemSettings()`
- `startPolling()`/`stopPolling()` 内部方法管理 timer

`Models/DisplayCoordinator.swift`：
- `@MainActor @Observable final class`
- 依赖 `ScreenObserving`（`@ObservationIgnored`）
- 属性 `displays: [Display]`
- `init(observer:)` 初始化时 `displays = observer.displays`
- `refresh()`：`displays = observer.displays`
- 计算属性 `hasMultiple: Bool`（`displays.count > 1`）、`primary: Display?`
- `func contains(_ display: Display) -> Bool`

**`AppState` 重塑为协调者外观**：

- `@MainActor @Observable final class`
- 持有四个 `@ObservationIgnored` 依赖：`settings`、`accessibility`、`displays`、`moverService`
- 运行时状态 `var isMoving = false`
- 对 MenuView 暴露外观方法（转发到对应 coordinator）：
  - `moveMode: MoveMode` / `setMoveMode(_:)`
  - `launchAtLogin: Bool` / `updateLaunchAtLogin(_:)`
  - `accessibilityGranted: Bool` / `refreshAccessibility()` / `openSystemSettings()` / `requestAccessibilityPrompt() -> Bool`
  - `displayList: [Display]` / `hasMultipleDisplays: Bool` / `refreshDisplays()`
- 保留 `moveAll(to:)` 编排：`guard !isMoving, displays.contains(display) else { return }` → `isMoving = true` → 局部捕获 `let mode = moveMode; let svc = moverService` → `Task.detached(priority: .userInitiated)` 调 `svc.moveAllWindows(to: display, mode: mode)` → 主线程 `isMoving = false`。`displays.contains(display)` 检查承接第 4.3 部分从 `WindowMoverService` 移出的校验，不丢失。

**`WindowMoverApp.init()` 组装顺序**：

```swift
let logger = Logger(subsystem: "com.sametrouble.WindowMover", category: "app")
let observer = ScreenObserver()
let controller = WindowController(logger: logger)
let enumerator = WindowEnumerator(logger: logger)
let service = WindowMoverService(windowController: controller, windowEnumerator: enumerator, logger: logger)
let accessibilityChecker = AccessibilityChecker()
let state = AppState(
    settings: SettingsStore(),
    accessibility: AccessibilityCoordinator(checker: accessibilityChecker),
    displays: DisplayCoordinator(observer: observer),
    moverService: service
)
```

**MenuView 影响**：`@Environment(AppState.self)` 不变，仍通过 `state.xxx` 访问外观方法。`MenuView.swift:11` 的直接 new 已在第 4 部分改为 `state.openSystemSettings()`，此处无额外改动。

**拆分后职责对照**：

| 原 AppState 职责 | 归属 |
|---|---|
| 持久化 moveMode/launchAtLogin | `SettingsStore` |
| 辅助功能轮询/请求 | `AccessibilityCoordinator` |
| 显示器刷新/查询 | `DisplayCoordinator` |
| 开机启动注册 | `SettingsStore`（`launchAtLogin.didSet`） |
| 移动编排 + isMoving | `AppState`（保留） |

**验证标准**：`xcodebuild build` + 全部单测通过；手动跑 app 验证四条路径不变：
1. 选显示器移动窗口（三种 MoveMode）
2. 切换移动模式并重启 app 验证持久化
3. 开机启动开关开/关
4. 辅助功能权限：未授权→点按钮触发弹窗→去系统设置授权→轮询自动检测

## 实现顺序

1. 第 1 部分（测试基础设施）— 必须最先完成，建立安全网
2. 第 2 部分（修 bug）— 在测试保护下修复
3. 第 3 部分（协议抽象）— 为第 5 部分铺路
4. 第 4 部分（架构异味）— 含与第 3 部分协同的 MenuView 改动
5. 第 5 部分（拆分 AppState）— 最后执行，依赖前 4 部分就位

每部分完成后跑 `xcodebuild build` + `xcodebuild test`，绿后再进入下一部分。

## 风险与缓解

- **拆分后行为回归**：先补单测再重构；`SettingsStore` 的 `launchAtLogin.didSet` 内 `SMAppService` 调用失败回滚逻辑需对照原 `AppState.updateLaunchAtLogin` 行为。
- **`axWindow(for:)` 精确匹配改动影响面**：保留帧匹配回退，兼容不暴露 windowID 的应用；手动测多应用场景。
- **`ScreenObserver` 坐标修复**：`CGDisplayBounds` 返回点坐标，与原 `NSScreen.frame.height`（点）单位一致，无像素/点混淆风险。

## 验收标准

- `xcodebuild build -scheme WindowMover` 成功
- `xcodebuild test -scheme WindowMover -destination 'platform=macOS'` 全绿，覆盖 `FrameCalculator`/`WindowFilter`/`WindowMoverService`
- 无强制解包（app target 内）、无死字段、`WindowMoverService` 无冗余依赖
- `AccessibilityChecker` 遵从 `AccessibilityChecking` 协议，可注入 mock
- `AppState` 仅保留移动编排 + `isMoving`，其余职责由三个 coordinator 承担
- 手动验证四条用户路径行为不变
