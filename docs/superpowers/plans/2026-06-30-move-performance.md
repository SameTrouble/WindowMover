# 窗口移动性能优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通过消除 `WindowController` 中重复的 AX 窗口查找、合并 position/size 属性设置，将单次「移动所有窗口」的 AX IPC 次数从 ~8+ 次/窗口降到 ~5 次/窗口，提升移动速度。

**Architecture:** 把 `WindowControlling` 协议从三方法（`isFullscreen` / `currentFrame` / `setFrame`）合并为单方法 `moveWindow`，在一次 AX 窗口查找内完成全屏判断 → 读源 frame → 计算 → 设置。旧三方法降为 `WindowController` 的 `private` 方法，参数由 `WindowInfo` 改为已查到的 `AXUIElement`。设置阶段用 `kAXPositionAndSizeAttribute` 单次调用替代 position + size 两次调用。`WindowMoverService` 循环体简化为单步 `moveWindow` 调用，`FrameCalculator` 依赖从 service 转移到 controller。

**Tech Stack:** Swift 5 / ApplicationServices（AXUIElement）/ CoreGraphics / os.Logger / xcodebuild。

## Global Constraints

- macOS 部署目标 14.6（`MACOSX_DEPLOYMENT_TARGET = 14.6`），`kAXPositionAndSizeAttribute` 与 `AXValueType.cgRect` 在该版本可用。
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`——新增类型默认主线程隔离；但 `WindowMoverService.moveAllWindows` 实际由 `AppState.moveAll` 在 `Task.detached(.userInitiated)` 中调用，运行在后台。新增的 `WindowMoveOutcome` 枚举无需 actor 隔离标注（纯值类型，`Error` 关联值）。
- 项目零测试覆盖，本计划不引入测试（属 code-quality 子项目范围，见 `docs/superpowers/specs/2026-06-30-code-quality-design.md`）。验证以编译通过 + 手动功能等价为主。
- 不改 `FrameCalculator` 计算逻辑、不改 UI/菜单/权限/状态管理。
- Commit messages 遵循仓库风格（简短、小写、祈使语气，如 `docs:` / `fix:` 前缀）。
- 三个文件改动有顺序依赖：协议先改 → controller 实现 → service 调用方。但为避免中间提交编译失败，三个文件的改动合并在 Task 2 一次完成，Task 1 仅做不动编译的准备工作。实际上更稳妥的做法是：单一任务完成全部三文件改动，保证每个提交都能编译。因此本计划拆为 2 个任务：Task 1 做无编译依赖的辅助重构（提取 private helper），Task 2 一次性完成协议合并 + controller 重写 + service 简化。

---

## File Structure

```
WindowMover/
  Platform/
    PlatformProtocols.swift   # MODIFIED — 新增 WindowMoveOutcome，WindowControlling 合并为单方法
    WindowController.swift    # MODIFIED — 实现 moveWindow，旧三方法降为 private 接收 AXUIElement，
                              #            setFrame 改用 kAXPositionAndSizeAttribute，消除强制解包
  Services/
    WindowMoverService.swift  # MODIFIED — 循环体改为单步 moveWindow 调用，移除对 FrameCalculator 的直接调用
```

不动文件：`FrameCalculator.swift` / `WindowFilter.swift` / `WindowEnumerator.swift` / `AppState.swift` / `MenuView.swift` / `WindowMoverApp.swift` / `Models/*` / 其余 Platform 文件。

---

### Task 1: 在 WindowController 提取接收 AXUIElement 的 private helper

此任务做**不改变公开协议**的内部重构：把 `isFullscreen` / `currentFrame` 的核心逻辑提取为接收 `AXUIElement` 的 `private` 方法，原公开方法改为调用这些 helper。这一步让 Task 2 的合并更平滑，且单独提交后仍可编译、行为不变。

**Files:**
- Modify: `WindowMover/Platform/WindowController.swift`

**Interfaces:**
- Consumes: `WindowControlling`（当前协议，本任务不改）、`WindowInfo`、`AXUIElement`、`WindowControlError`
- Produces: `WindowController` 内新增三个 private helper，签名见下方步骤。公开方法行为不变。

**当前 `WindowController.swift` 完整内容（实现前对照基准）：**

```swift
import ApplicationServices
import CoreGraphics
import os

enum WindowControlError: Error {
    case axElementNotFound
    case axCallFailed(String)
}

final class WindowController: WindowControlling {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func isFullscreen(_ window: WindowInfo) -> Bool {
        guard let axWindow = axWindow(for: window) else { return false }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &value)
        guard err == .success, let flag = value as? Bool else { return false }
        return flag
    }

    func currentFrame(_ window: WindowInfo) -> CGRect {
        guard let axWindow = axWindow(for: window) else { return window.frame }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        let origin = CGPoint(from: positionRef) ?? .zero
        let size = CGSize(from: sizeRef) ?? .zero
        return CGRect(origin: origin, size: size)
    }

    func setFrame(_ frame: CGRect, for window: WindowInfo) throws {
        guard let axWindow = axWindow(for: window) else {
            throw WindowControlError.axElementNotFound
        }
        var origin = frame.origin
        var size = frame.size
        let pos = AXValueCreate(.cgPoint, &origin)
        let sizeValue = AXValueCreate(.cgSize, &size)
        let posErr = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pos!)
        let sizeErr = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue!)
        guard posErr == .success, sizeErr == .success else {
            throw WindowControlError.axCallFailed("pos=\(posErr.rawValue) size=\(sizeErr.rawValue)")
        }
    }

    // MARK: - AX window lookup

    private func axWindow(for window: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.ownerPID)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard let axWindows = windowsRef as? [AXUIElement] else { return nil }

        for axWin in axWindows {
            if matches(window: window, axWindow: axWin) { return axWin }
        }
        return nil
    }

    private func matches(window: WindowInfo, axWindow: AXUIElement) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        let axFrame = CGRect(
            origin: CGPoint(from: posRef) ?? .zero,
            size: CGSize(from: sizeRef) ?? .zero)

        return abs(axFrame.origin.x - window.frame.origin.x) < 5
            && abs(axFrame.origin.y - window.frame.origin.y) < 5
            && abs(axFrame.width - window.frame.width) < 5
            && abs(axFrame.height - window.frame.height) < 5
    }
}

private extension CGPoint {
    init?(from ref: CFTypeRef?) {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        self = point
    }
}

private extension CGSize {
    init?(from ref: CFTypeRef?) {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        self = size
    }
}
```

- [ ] **Step 1: 提取 `isFullscreen` 的 private helper**

在 `WindowController` 中，把 `isFullscreen(_ window: WindowInfo)` 的核心逻辑提取为接收 `AXUIElement` 的 private 方法，原公开方法改为先查 `axWindow(for:)` 再委托。

修改后的 `isFullscreen` 区域（替换原 `func isFullscreen(_ window: WindowInfo) -> Bool { ... }` 整段）：

```swift
    func isFullscreen(_ window: WindowInfo) -> Bool {
        guard let axWindow = axWindow(for: window) else { return false }
        return isFullscreen(axWindow)
    }

    private func isFullscreen(_ axWindow: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &value)
        guard err == .success, let flag = value as? Bool else { return false }
        return flag
    }
```

- [ ] **Step 2: 提取 `currentFrame` 的 private helper**

把 `currentFrame(_ window: WindowInfo)` 的核心逻辑提取为接收 `AXUIElement` 的 private 方法，返回 `CGRect?`（失败返回 nil，替代原公开版本的 `.zero` 回退——公开版本保持原行为不变）。

修改后的 `currentFrame` 区域（替换原 `func currentFrame(_ window: WindowInfo) -> CGRect { ... }` 整段）：

```swift
    func currentFrame(_ window: WindowInfo) -> CGRect {
        guard let axWindow = axWindow(for: window) else { return window.frame }
        return currentFrame(axWindow) ?? window.frame
    }

    private func currentFrame(_ axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        guard let origin = CGPoint(from: positionRef),
              let size = CGSize(from: sizeRef) else { return nil }
        return CGRect(origin: origin, size: size)
    }
```

注意：`CGPoint(from:)` / `CGSize(from:)` 返回 `Optional`，用 `guard let` 解包；原公开版本用 `?? .zero` 回退，这里 helper 返回 nil 让调用方决定回退值。公开 `currentFrame(_ window:)` 保持原行为（`?? window.frame`）。

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -scheme WindowMover -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add WindowMover/Platform/WindowController.swift
git commit -m "refactor: extract axuielper-based helpers in windowcontroller"
```

---

### Task 2: 合并协议为单方法 moveWindow，重写 controller 与 service

此任务完成核心优化：协议合并、controller 用 `kAXPositionAndSizeAttribute`、service 简化、消除强制解包。三文件改动在一次提交内完成，保证提交可编译。

**Files:**
- Modify: `WindowMover/Platform/PlatformProtocols.swift`
- Modify: `WindowMover/Platform/WindowController.swift`
- Modify: `WindowMover/Services/WindowMoverService.swift`

**Interfaces:**
- Consumes: Task 1 产出的 `WindowController` private helpers（`isFullscreen(_ axWindow:)` / `currentFrame(_ axWindow:)` / `axWindow(for:)`）、`FrameCalculator.calculateFrame(mode:source:targetFullFrame:targetVisibleFrame:)`、`WindowInfo`、`MoveMode`、`Display`、`Logger`
- Produces: 新增 `WindowMoveOutcome` 枚举（`case moved / skipped / failed(Error)`）；`WindowControlling` 协议单方法 `moveWindow(_:mode:targetFullFrame:targetVisibleFrame:) -> WindowMoveOutcome`；`WindowMoverService.moveAllWindows(to:mode:)` 内部调用改为单步

**当前 `PlatformProtocols.swift` 完整内容（实现前基准）：**

```swift
import Foundation
import CoreGraphics
import ApplicationServices

protocol WindowControlling {
    func isFullscreen(_ window: WindowInfo) -> Bool
    func currentFrame(_ window: WindowInfo) -> CGRect
    func setFrame(_ frame: CGRect, for window: WindowInfo) throws
}

protocol WindowEnumerating {
    func visibleWindows() -> [WindowInfo]
}

protocol ScreenObserving {
    var displays: [Display] { get }
}
```

**当前 `WindowMoverService.swift` 完整内容（实现前基准）：**

```swift
import Foundation
import os

struct MoveResult: Equatable {
    var moved: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
}

final class WindowMoverService {
    private let windowController: WindowControlling
    private let windowEnumerator: WindowEnumerating
    private let screenObserver: ScreenObserving
    private let logger: Logger

    init(windowController: WindowControlling,
         windowEnumerator: WindowEnumerating,
         screenObserver: ScreenObserving,
         logger: Logger) {
        self.windowController = windowController
        self.windowEnumerator = windowEnumerator
        self.screenObserver = screenObserver
        self.logger = logger
    }

    func moveAllWindows(to display: Display, mode: MoveMode) -> MoveResult {
        guard screenObserver.displays.contains(where: { $0.id == display.id }) else {
            logger.warning("target display \(display.id) not present; no-op")
            return MoveResult()
        }

        var result = MoveResult()
        let windows = windowEnumerator.visibleWindows()

        for window in windows {
            if windowController.isFullscreen(window) {
                result.skipped += 1
                logger.info("skip fullscreen window \(window.id) (\(window.ownerName))")
                continue
            }
            do {
                let sourceFrame = windowController.currentFrame(window)
                let targetFrame = FrameCalculator.calculateFrame(
                    mode: mode,
                    source: sourceFrame,
                    targetFullFrame: display.frame,
                    targetVisibleFrame: display.visibleFrame)
                try windowController.setFrame(targetFrame, for: window)
                result.moved += 1
            } catch {
                result.failed += 1
                logger.error("failed to move window \(window.id) (\(window.ownerName)): \(String(describing: error))")
            }
        }
        return result
    }
}
```

- [ ] **Step 1: 改 `PlatformProtocols.swift`——新增 `WindowMoveOutcome`，合并协议**

替换 `PlatformProtocols.swift` 中 `WindowControlling` 协议定义为下方内容，并新增 `WindowMoveOutcome` 枚举。`WindowEnumerating` / `ScreenObserving` 不动。

把原：

```swift
protocol WindowControlling {
    func isFullscreen(_ window: WindowInfo) -> Bool
    func currentFrame(_ window: WindowInfo) -> CGRect
    func setFrame(_ frame: CGRect, for window: WindowInfo) throws
}
```

替换为：

```swift
/// 单窗口移动结果。
enum WindowMoveOutcome {
    case moved
    case skipped  // 全屏窗口
    case failed(Error)
}

protocol WindowControlling {
    /// 在一次 AX 窗口查找内完成：全屏判断 → 读源 frame → 计算目标 frame → 设置。
    func moveWindow(_ window: WindowInfo,
                    mode: MoveMode,
                    targetFullFrame: CGRect,
                    targetVisibleFrame: CGRect) -> WindowMoveOutcome
}
```

- [ ] **Step 2: 改 `WindowController.swift`——实现 `moveWindow`，删除旧公开方法，`setFrame` 改用 `kAXPositionAndSizeAttribute`**

在 Task 1 后的 `WindowController.swift` 基础上：

1. 删除三个公开方法 `isFullscreen(_ window:)` / `currentFrame(_ window:)` / `setFrame(_:for window:)`（它们的 private helper 版本保留）
2. 新增公开方法 `moveWindow(_:mode:targetFullFrame:targetVisibleFrame:) -> WindowMoveOutcome`
3. private `setFrame(_:for axWindow:)` 改用 `kAXPositionAndSizeAttribute` 单次调用，消除强制解包
4. 顶部新增 `import ApplicationServices` 已有；确认 `kAXPositionAndSizeAttribute` 可用（属 `ApplicationServices`）

新增的 `moveWindow` 方法（插入到 `init` 之后、`isFullscreen(_ axWindow:)` private helper 之前）：

```swift
    func moveWindow(_ window: WindowInfo,
                    mode: MoveMode,
                    targetFullFrame: CGRect,
                    targetVisibleFrame: CGRect) -> WindowMoveOutcome {
        guard let axWindow = axWindow(for: window) else {
            return .failed(WindowControlError.axElementNotFound)
        }

        if isFullscreen(axWindow) { return .skipped }

        guard let sourceFrame = currentFrame(axWindow) else {
            return .failed(WindowControlError.axCallFailed("read source frame"))
        }

        let target = FrameCalculator.calculateFrame(
            mode: mode,
            source: sourceFrame,
            targetFullFrame: targetFullFrame,
            targetVisibleFrame: targetVisibleFrame)

        do {
            try setFrame(target, for: axWindow)
            return .moved
        } catch {
            return .failed(error)
        }
    }
```

把 Task 1 中的 private `setFrame`（本任务里它原本是公开的 `setFrame(_ frame:, for window: WindowInfo)`，Task 1 未动它；现在它仍是公开版本需先降为 private 并改签名）。注意：Task 1 未对 `setFrame` 做 helper 提取，所以此步要**重写** `setFrame`。

删除原公开 `setFrame` 整段：

```swift
    func setFrame(_ frame: CGRect, for window: WindowInfo) throws {
        guard let axWindow = axWindow(for: window) else {
            throw WindowControlError.axElementNotFound
        }
        var origin = frame.origin
        var size = frame.size
        let pos = AXValueCreate(.cgPoint, &origin)
        let sizeValue = AXValueCreate(.cgSize, &size)
        let posErr = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pos!)
        let sizeErr = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue!)
        guard posErr == .success, sizeErr == .success else {
            throw WindowControlError.axCallFailed("pos=\(posErr.rawValue) size=\(sizeErr.rawValue)")
        }
    }
```

替换为 private 版本（接收 `AXUIElement`，用 `kAXPositionAndSizeAttribute`，`guard let` 消除强制解包）：

```swift
    private func setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws {
        var rect = frame
        guard let value = AXValueCreate(.cgRect, &rect) else {
            throw WindowControlError.axCallFailed("AXValueCreate cgRect failed")
        }
        let err = AXUIElementSetAttributeValue(
            axWindow,
            kAXPositionAndSizeAttribute as CFString,
            value)
        guard err == .success else {
            throw WindowControlError.axCallFailed("set positionAndSize=\(err.rawValue)")
        }
    }
```

同时删除 Task 1 中公开的 `isFullscreen(_ window: WindowInfo)` 和 `currentFrame(_ window: WindowInfo)` 两个委托方法（它们调 private helper，现在协议不再需要公开版本）。

Task 2 完成后，`WindowController` 的方法清单应为：
- `init(logger:)`
- `func moveWindow(...) -> WindowMoveOutcome`（公开，协议要求）
- `private func isFullscreen(_ axWindow: AXUIElement) -> Bool`（Task 1 产出）
- `private func currentFrame(_ axWindow: AXUIElement) -> CGRect?`（Task 1 产出）
- `private func setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws`（本步重写）
- `private func axWindow(for window: WindowInfo) -> AXUIElement?`（不动）
- `private func matches(window: WindowInfo, axWindow: AXUIElement) -> Bool`（不动）
- 底部两个 `private extension CGPoint/CGSize`（不动）

- [ ] **Step 3: 改 `WindowMoverService.swift`——循环体改为单步 `moveWindow` 调用**

把 `moveAllWindows(to:mode:)` 中的 for 循环整段：

```swift
        for window in windows {
            if windowController.isFullscreen(window) {
                result.skipped += 1
                logger.info("skip fullscreen window \(window.id) (\(window.ownerName))")
                continue
            }
            do {
                let sourceFrame = windowController.currentFrame(window)
                let targetFrame = FrameCalculator.calculateFrame(
                    mode: mode,
                    source: sourceFrame,
                    targetFullFrame: display.frame,
                    targetVisibleFrame: display.visibleFrame)
                try windowController.setFrame(targetFrame, for: window)
                result.moved += 1
            } catch {
                result.failed += 1
                logger.error("failed to move window \(window.id) (\(window.ownerName)): \(String(describing: error))")
            }
        }
```

替换为：

```swift
        for window in windows {
            let outcome = windowController.moveWindow(
                window,
                mode: mode,
                targetFullFrame: display.frame,
                targetVisibleFrame: display.visibleFrame)
            switch outcome {
            case .moved:
                result.moved += 1
            case .skipped:
                result.skipped += 1
                logger.info("skip fullscreen window \(window.id) (\(window.ownerName))")
            case .failed(let error):
                result.failed += 1
                logger.error("failed to move window \(window.id) (\(window.ownerName)): \(String(describing: error))")
            }
        }
```

`WindowMoverService` 顶部 `import Foundation` / `import os` 不变；不再直接引用 `FrameCalculator`，但无需删除任何 import（`FrameCalculator` 是同 module 内 enum，无需 import）。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -scheme WindowMover -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

若出现 `'kAXPositionAndSizeAttribute' is unavailable` 之类的错误（预期不会出现，该属性自 macOS 10.4 可用），回退方案：保留两次 `SetAttribute`（position + size），但用 `guard let` 解包 `AXValueCreate` 返回值，其余逻辑不变。

- [ ] **Step 5: Release 配置编译验证**

Run: `xcodebuild -scheme WindowMover -configuration Release -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 提交**

```bash
git add WindowMover/Platform/PlatformProtocols.swift WindowMover/Platform/WindowController.swift WindowMover/Services/WindowMoverService.swift
git commit -m "perf: collapse windowcontroller ax lookup into single movewindow call"
```

---

### Task 3: 手动功能验证

此任务无代码改动，仅按设计文档「验证方式」逐项确认功能等价。在多显示器环境下运行 app 手动验证。

**Files:** 无

**Interfaces:** 无

- [ ] **Step 1: 启动 app**

Run: `open WindowMover/build/Debug/WindowMover.app`（路径以 Step 4 实际产物为准；或直接 `xcodebuild ... build` 后从 DerivedData 打开）

若首次运行被 Gatekeeper 拦截，到「系统设置 → 隐私与安全性」点击「仍要打开」；首次使用需授予辅助功能权限。

Expected: 菜单栏出现 `display.2` 图标。

- [ ] **Step 2: 验证三种移动模式功能等价**

在多显示器环境下：
1. 打开若干普通窗口（如 Finder、TextEdit、Terminal，5-10 个）
2. 切换「移动方式」到「保持原比例」，点目标显示器 → 窗口等比缩放居中到目标屏
3. 切换到「填满」→ 窗口填满目标屏可见区域（扣除 Dock/菜单栏）
4. 切换到「原始尺寸」→ 窗口保持原尺寸居中；超大的回退为等比缩放

Expected: 三种模式结果与优化前一致。

- [ ] **Step 3: 验证全屏窗口被跳过**

将一个窗口全屏（如 Safari 全屏），再执行移动。

Expected: 全屏窗口不参与移动，其余窗口正常移动。日志中应有 `skip fullscreen window ...`（用 Console.app 过滤 subsystem `com.sametrouble.WindowMover` 查看）。

- [ ] **Step 4: 验证菜单栏图标状态切换**

点击目标显示器移动。

Expected: 移动中菜单栏图标切换为 `arrow.triangle.2.circlepath`（macOS 15+ 旋转动画），完成后恢复 `display.2`。

- [ ] **Step 5: 主观体感对比**

窗口较多（10+）时移动完成明显更快。无需量化，主观确认即可。

Expected: 移动完成等待时间较优化前缩短。

---

## 自审

**1. 规格覆盖：**
- 协议变更（设计 §1）→ Task 2 Step 1 ✓
- WindowController 实现 moveWindow（设计 §2）→ Task 2 Step 2 ✓
- kAXPositionAndSizeAttribute 合并设置（设计 §2 设置阶段合并）→ Task 2 Step 2 ✓
- 消除强制解包（设计 §2 顺带修复）→ Task 2 Step 2（`guard let value = AXValueCreate(...)`）✓
- WindowMoverService 简化（设计 §3）→ Task 2 Step 3 ✓
- AX 调用次数对比（设计 §4）→ 验证方式为编译+手动，无量化断言（设计 §验证方式）✓
- 影响范围三文件（设计 §影响范围）→ Task 2 ✓
- 验证方式 5 项（设计 §验证方式）→ Task 3 Step 1-5 ✓
- 非目标（不引入并发/不做批量预取/不改 FrameCalculator/不改 UI/不补测试）→ 计划中均未涉及 ✓

**2. 占位符扫描：** 无 TBD/TODO/"添加合适的错误处理"等。每个代码步骤含完整代码块。Task 3 为手动验证步骤，无代码占位符。

**3. 类型一致性：**
- `WindowMoveOutcome` 三 case：`moved` / `skipped` / `failed(Error)`——Task 2 Step 1 定义，Task 2 Step 2 返回值使用，Task 2 Step 3 switch 匹配，一致 ✓
- `moveWindow(_:mode:targetFullFrame:targetVisibleFrame:) -> WindowMoveOutcome`——协议定义（Step 1）、controller 实现（Step 2）、service 调用（Step 3）签名一致 ✓
- private helper 签名：`isFullscreen(_ axWindow: AXUIElement) -> Bool` / `currentFrame(_ axWindow: AXUIElement) -> CGRect?` / `setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws`——Task 1 产出，Task 2 `moveWindow` 内调用一致 ✓
- `FrameCalculator.calculateFrame(mode:source:targetFullFrame:targetVisibleFrame:)`——原 `WindowMoverService` 调用签名，Task 2 `moveWindow` 内调用签名一致（见 `FrameCalculator.swift` 原定义）✓
