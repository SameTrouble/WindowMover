# 窗口移动性能优化 v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通过按 PID 分组预取窗口列表 + 跨 app 并发，将「移动所有窗口」的 wall-clock 时延从串行 N 窗口降到按 app 分组的并发执行，同时把同 app 的 AX 窗口列表拉取从 N 次降到 1 次。

**Architecture:** `WindowMoverService.moveAllWindows` 改 `async`，按 `ownerPID` 分组后用 `withTaskGroup` 跨 app 并发，每组调用 `WindowControlling.moveWindows`（新批量协议）。`WindowController.moveWindows` 在组内串行处理各窗口，但只做一次 `AXUIElementCreateApplication` + 一次 `kAXWindowsAttribute` 拉取，组内各窗口复用该列表做帧匹配。`AppState.moveAll` 加 `await`。

**Tech Stack:** Swift 5 / ApplicationServices（AXUIElement）/ CoreGraphics / os.Logger / Swift Concurrency（withTaskGroup）/ xcodebuild。

## Global Constraints

- macOS 部署目标 14.6（`MACOSX_DEPLOYMENT_TARGET = 14.6`）。
- `SWIFT_VERSION = 5.0` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`——`WindowMoverService` 默认 MainActor 隔离，但当前 `moveAllWindows` 被 `AppState.moveAll` 用 `Task.detached(.userInitiated)` 调用，实际运行在后台。本计划保持这一模式：`moveAllWindows` 改 `async` 仍由 `Task.detached` 调用，`withTaskGroup` 子 task 继承非 MainActor 上下文，实现跨 app 并发。
- `WindowController` 是 stateless（仅持 `let logger`），`moveWindows` 纯函数式调用，跨 task 安全。`Logger`（os.Logger）线程安全。
- 项目零测试覆盖，本计划不引入测试（延续上一轮约定，属 code-quality 子项目范围）。验证以编译通过 + 手动功能等价 + 主观体感为主。
- 不改 `FrameCalculator` 计算逻辑、不改 UI/菜单/权限/状态管理（`AppState.moveAll` 仅加 `await`）。
- 不引入同 app 内并发（AXUIElement 跨线程不安全，同 app 串行）。
- 不用私有 API。
- Commit messages 遵循仓库风格（简短、小写、祈使语气，如 `perf:` / `refactor:` 前缀）。
- 四个文件改动有顺序依赖：协议先改 → controller 实现 → service 调用方 → appstate 配套。为避免中间提交编译失败，四个文件的改动合并在 Task 2 一次完成。Task 1 做无编译依赖的准备工作（提取复用帧匹配的 private helper）。

---

## File Structure

```
WindowMover/
  Platform/
    PlatformProtocols.swift   # MODIFIED — WindowControlling 从单方法 moveWindow 改为批量 moveWindows
    WindowController.swift    # MODIFIED — 实现 moveWindows（组内单次预取 + 复用列表），
                              #            提取 axWindow(for:in:)，删除旧 axWindow(for:) 与 moveWindow
  Services/
    WindowMoverService.swift  # MODIFIED — moveAllWindows 改 async，按 PID 分组 + withTaskGroup 并发
  Models/
    AppState.swift            # MODIFIED — moveAll 加 await
```

不动文件：`FrameCalculator.swift` / `WindowFilter.swift` / `WindowEnumerator.swift` / `MenuView.swift` / `WindowMoverApp.swift` / `Models/Display.swift` / `Models/MoveMode.swift` / `Models/WindowInfo.swift` / 其余 Platform 文件。

---

### Task 1: 在 WindowController 提取接收 axWindows 列表的 private helper

此任务做**不改变公开协议**的内部重构：把帧匹配查找从「重建 app + 拉列表」剥离，提取为接收已拉取 `axWindows` 数组的 `private` 方法。原 `axWindow(for window: WindowInfo)` 暂时改为调用新 helper（仍自己重建 app + 拉列表），保持行为不变。这一步让 Task 2 的 `moveWindows` 实现更平滑，且单独提交后仍可编译、行为不变。

**Files:**
- Modify: `WindowMover/Platform/WindowController.swift`

**Interfaces:**
- Consumes: `WindowControlling`（当前协议，本任务不改）、`WindowInfo`、`AXUIElement`、`WindowControlError`
- Produces: `WindowController` 内新增 private `axWindow(for:in:)`，原 `axWindow(for:)` 改为委托新 helper。公开方法行为不变。

**当前 `WindowController.swift` 完整内容（实现前对照基准，已含上一轮优化的 `moveWindow`）：**

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

    private func isFullscreen(_ axWindow: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &value)
        guard err == .success, let flag = value as? Bool else { return false }
        return flag
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

    private func setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws {
        var origin = frame.origin
        var size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &origin) else {
            throw WindowControlError.axCallFailed("AXValueCreate cgPoint failed")
        }
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw WindowControlError.axCallFailed("AXValueCreate cgSize failed")
        }
        let posErr = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        guard posErr == .success else {
            throw WindowControlError.axCallFailed("set position=\(posErr.rawValue)")
        }
        let sizeErr = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        guard sizeErr == .success else {
            throw WindowControlError.axCallFailed("set size=\(sizeErr.rawValue)")
        }
    }

    // MARK: - AX window lookup

    /// Find the AXUIElement for a window by matching its CGWindowID against the owning app's windows.
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

- [ ] **Step 1: 提取 `axWindow(for:in:)` private helper**

把 `axWindow(for window: WindowInfo)` 中的帧匹配查找部分剥离为接收已拉取 `axWindows` 数组的 private 方法。原 `axWindow(for window: WindowInfo)` 改为：自己重建 app + 拉列表，然后委托新 helper。

把原 `axWindow(for window: WindowInfo)` 整段：

```swift
    /// Find the AXUIElement for a window by matching its CGWindowID against the owning app's windows.
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
```

替换为：

```swift
    /// Find the AXUIElement for a window by matching its CGWindowID against the owning app's windows.
    private func axWindow(for window: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.ownerPID)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard let axWindows = windowsRef as? [AXUIElement] else { return nil }
        return axWindow(for: window, in: axWindows)
    }

    /// 在已拉取的 axWindows 列表中按帧匹配查找窗口。
    private func axWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        for axWin in axWindows {
            if matches(window: window, axWindow: axWin) { return axWin }
        }
        return nil
    }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -scheme WindowMover -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add WindowMover/Platform/WindowController.swift
git commit -m "refactor: extract axwindow lookup helper to accept pre-fetched list"
```

---

### Task 2: 协议改批量 moveWindows，重写 controller 与 service，appstate 加 await

此任务完成核心优化：协议从单窗口 `moveWindow` 改为批量 `moveWindows`；`WindowController.moveWindows` 在组内单次预取 app + 窗口列表，组内各窗口复用；`WindowMoverService.moveAllWindows` 改 `async` + 按 PID 分组 + `withTaskGroup` 跨 app 并发；`AppState.moveAll` 加 `await`。四文件改动在一次提交内完成，保证提交可编译。

**Files:**
- Modify: `WindowMover/Platform/PlatformProtocols.swift`
- Modify: `WindowMover/Platform/WindowController.swift`
- Modify: `WindowMover/Services/WindowMoverService.swift`
- Modify: `WindowMover/Models/AppState.swift`

**Interfaces:**
- Consumes: Task 1 产出的 `WindowController` private helper `axWindow(for:in:)`、`isFullscreen(_ axWindow:)` / `currentFrame(_ axWindow:)` / `setFrame(_:for axWindow:)`、`FrameCalculator.calculateFrame(mode:source:targetFullFrame:targetVisibleFrame:)`、`WindowInfo`、`MoveMode`、`Display`、`Logger`
- Produces: `WindowControlling` 协议改为单方法 `moveWindows(_:mode:targetFullFrame:targetVisibleFrame:) -> [(window: WindowInfo, outcome: WindowMoveOutcome)]`；`WindowMoverService.moveAllWindows(to:mode:)` 改 `async`；`AppState.moveAll` 加 `await`

**当前 `PlatformProtocols.swift` 完整内容（实现前基准）：**

```swift
import Foundation
import CoreGraphics
import ApplicationServices

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
        return result
    }
}
```

**当前 `AppState.moveAll`（`AppState.swift` 实现前基准）：**

```swift
    func moveAll(to display: Display) {
        guard !isMoving else { return }
        isMoving = true
        let mode = moveMode
        let svc = service
        Task.detached(priority: .userInitiated) {
            _ = svc.moveAllWindows(to: display, mode: mode)
            await MainActor.run { self.isMoving = false }
        }
    }
```

- [ ] **Step 1: 改 `PlatformProtocols.swift`——协议从单方法改为批量 `moveWindows`**

把 `WindowControlling` 协议定义整段：

```swift
protocol WindowControlling {
    /// 在一次 AX 窗口查找内完成：全屏判断 → 读源 frame → 计算目标 frame → 设置。
    func moveWindow(_ window: WindowInfo,
                    mode: MoveMode,
                    targetFullFrame: CGRect,
                    targetVisibleFrame: CGRect) -> WindowMoveOutcome
}
```

替换为：

```swift
protocol WindowControlling {
    /// 移动一组同 PID 的窗口。组内串行；调用方负责保证跨组并发。
    /// 组内只做一次 AXUIElementCreateApplication + kAXWindowsAttribute 拉取，组内各窗口复用该列表。
    func moveWindows(_ windows: [WindowInfo],
                     mode: MoveMode,
                     targetFullFrame: CGRect,
                     targetVisibleFrame: CGRect) -> [(window: WindowInfo, outcome: WindowMoveOutcome)]
}
```

`WindowMoveOutcome` / `WindowEnumerating` / `ScreenObserving` 不动。

- [ ] **Step 2: 改 `WindowController.swift`——实现 `moveWindows`，删除旧 `moveWindow` 与 `axWindow(for window:)`**

在 Task 1 后的 `WindowController.swift` 基础上：

1. 删除公开方法 `moveWindow(_:mode:targetFullFrame:targetVisibleFrame:)`（协议不再要求）
2. 新增公开方法 `moveWindows(_:mode:targetFullFrame:targetVisibleFrame:)`，组内：一次 `AXUIElementCreateApplication` + 一次 `kAXWindowsAttribute` 拉取，组内各窗口用 Task 1 产出的 `axWindow(for:in:)` 复用列表做帧匹配
3. 删除旧 private `axWindow(for window: WindowInfo) -> AXUIElement?`（含 app 创建 + 列表拉取），其逻辑已内联到 `moveWindows` 开头
4. 保留 Task 1 产出的 `axWindow(for:in:)`、`isFullscreen(_ axWindow:)` / `currentFrame(_ axWindow:)` / `setFrame(_:for axWindow:)` / `matches(window:axWindow:)` 与底部两个 `private extension`

把原 `moveWindow` 整段：

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

替换为：

```swift
    func moveWindows(_ windows: [WindowInfo],
                     mode: MoveMode,
                     targetFullFrame: CGRect,
                     targetVisibleFrame: CGRect) -> [(window: WindowInfo, outcome: WindowMoveOutcome)] {
        guard let pid = windows.first?.ownerPID else { return [] }

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard let axWindows = windowsRef as? [AXUIElement] else {
            return windows.map { ($0, .failed(WindowControlError.axElementNotFound)) }
        }

        var results: [(window: WindowInfo, outcome: WindowMoveOutcome)] = []
        results.reserveCapacity(windows.count)

        for window in windows {
            guard let axWin = axWindow(for: window, in: axWindows) else {
                results.append((window, .failed(WindowControlError.axElementNotFound)))
                continue
            }

            if isFullscreen(axWin) {
                results.append((window, .skipped))
                continue
            }

            guard let sourceFrame = currentFrame(axWin) else {
                results.append((window, .failed(WindowControlError.axCallFailed("read source frame"))))
                continue
            }

            let target = FrameCalculator.calculateFrame(
                mode: mode,
                source: sourceFrame,
                targetFullFrame: targetFullFrame,
                targetVisibleFrame: targetVisibleFrame)

            do {
                try setFrame(target, for: axWin)
                results.append((window, .moved))
            } catch {
                results.append((window, .failed(error)))
            }
        }
        return results
    }
```

把原 Task 1 中 private `axWindow(for window: WindowInfo) -> AXUIElement?`（含 app 创建 + 列表拉取 + 委托 `axWindow(for:in:)`）整段：

```swift
    /// Find the AXUIElement for a window by matching its CGWindowID against the owning app's windows.
    private func axWindow(for window: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.ownerPID)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard let axWindows = windowsRef as? [AXUIElement] else { return nil }
        return axWindow(for: window, in: axWindows)
    }
```

删除（其逻辑已内联到 `moveWindows` 开头）。保留 `axWindow(for:in:)`：

```swift
    /// 在已拉取的 axWindows 列表中按帧匹配查找窗口。
    private func axWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        for axWin in axWindows {
            if matches(window: window, axWindow: axWin) { return axWin }
        }
        return nil
    }
```

Task 2 完成后，`WindowController` 的方法清单应为：
- `init(logger:)`
- `func moveWindows(...) -> [(window: WindowInfo, outcome: WindowMoveOutcome)]`（公开，协议要求）
- `private func isFullscreen(_ axWindow: AXUIElement) -> Bool`（不动）
- `private func currentFrame(_ axWindow: AXUIElement) -> CGRect?`（不动）
- `private func setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws`（不动）
- `private func axWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement?`（Task 1 产出，保留）
- `private func matches(window: WindowInfo, axWindow: AXUIElement) -> Bool`（不动）
- 底部两个 `private extension CGPoint/CGSize`（不动）

- [ ] **Step 3: 改 `WindowMoverService.swift`——`moveAllWindows` 改 `async` + 按 PID 分组 + `withTaskGroup` 并发**

把 `moveAllWindows(to:mode:)` 整段：

```swift
    func moveAllWindows(to display: Display, mode: MoveMode) -> MoveResult {
        guard screenObserver.displays.contains(where: { $0.id == display.id }) else {
            logger.warning("target display \(display.id) not present; no-op")
            return MoveResult()
        }

        var result = MoveResult()
        let windows = windowEnumerator.visibleWindows()

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
        return result
    }
```

替换为：

```swift
    func moveAllWindows(to display: Display, mode: MoveMode) async -> MoveResult {
        guard screenObserver.displays.contains(where: { $0.id == display.id }) else {
            logger.warning("target display \(display.id) not present; no-op")
            return MoveResult()
        }

        let windows = windowEnumerator.visibleWindows()
        let groups = Dictionary(grouping: windows, by: { $0.ownerPID })

        return await withTaskGroup(of: [(window: WindowInfo, outcome: WindowMoveOutcome)].self) { group in
            for (_, groupWindows) in groups {
                group.addTask {
                    self.windowController.moveWindows(
                        groupWindows,
                        mode: mode,
                        targetFullFrame: display.frame,
                        targetVisibleFrame: display.visibleFrame)
                }
            }
            var result = MoveResult()
            for await groupOutcomes in group {
                for (window, outcome) in groupOutcomes {
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
            }
            return result
        }
    }
```

`WindowMoverService` 顶部 `import Foundation` / `import os` 不变。`FrameCalculator` 不再被 service 直接引用（移入 controller），但无需删除任何 import（`FrameCalculator` 是同 module 内 enum，无 import）。

**关于 actor 隔离：** `WindowMoverService` 因 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 默认 MainActor 隔离，但当前 `moveAllWindows` 被 `AppState.moveAll` 用 `Task.detached(.userInitiated)` 调用，实际运行在后台（`Task.detached` 脱离 MainActor）。改为 `async` 后这一模式不变。`withTaskGroup` 子 task 继承当前 actor 上下文（非 MainActor），实现跨 app 并发。`windowController`（`WindowControlling` 协议实现 `WindowController`，stateless）跨 task 调用安全。`logger`（`os.Logger`）线程安全。`result` 在 `for await` 循环中单线程累加，无数据竞争。

- [ ] **Step 4: 改 `AppState.swift`——`moveAll` 加 `await`**

把 `moveAll(to:)` 中的 `Task.detached` 块：

```swift
        Task.detached(priority: .userInitiated) {
            _ = svc.moveAllWindows(to: display, mode: mode)
            await MainActor.run { self.isMoving = false }
        }
```

替换为（仅加 `await`）：

```swift
        Task.detached(priority: .userInitiated) {
            _ = await svc.moveAllWindows(to: display, mode: mode)
            await MainActor.run { self.isMoving = false }
        }
```

其余 `AppState.swift` 不动。

- [ ] **Step 5: Debug 编译验证**

Run: `xcodebuild -scheme WindowMover -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

若出现 actor 隔离相关警告/错误（如 `withTaskGroup` 子 task 被 MainActor 串行化），检查 `WindowMoverService` 是否被显式标注 `@MainActor`——当前未标注，依赖 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 默认值。若编译器报子 task 不能逃逸 MainActor，在 `moveAllWindows` 上加 `nonisolated` 标注：

```swift
    nonisolated func moveAllWindows(to display: Display, mode: MoveMode) async -> MoveResult {
```

因为 `WindowMoverService` 的所有成员都是 `let`（不可变），`nonisolated` 安全。重新编译确认。

- [ ] **Step 6: Release 配置编译验证**

Run: `xcodebuild -scheme WindowMover -configuration Release -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 提交**

```bash
git add WindowMover/Platform/PlatformProtocols.swift WindowMover/Platform/WindowController.swift WindowMover/Services/WindowMoverService.swift WindowMover/Models/AppState.swift
git commit -m "perf: group windows by pid and move across apps concurrently"
```

---

### Task 3: 手动功能验证

此任务无代码改动，仅按设计文档「验证方式」逐项确认功能等价与提速体感。在多显示器环境下运行 app 手动验证。

**Files:** 无

**Interfaces:** 无

- [ ] **Step 1: 启动 app**

Run: `open WindowMover/build/Debug/WindowMover.app`（路径以 Step 5 实际产物为准；或直接从 DerivedData 打开）

若首次运行被 Gatekeeper 拦截，到「系统设置 → 隐私与安全性」点击「仍要打开」；首次使用需授予辅助功能权限。

Expected: 菜单栏出现 `display.2` 图标。

- [ ] **Step 2: 验证三种移动模式功能等价**

在多显示器环境下：
1. 打开若干普通窗口（如 Finder、TextEdit、Terminal，5-10 个，跨多 app）
2. 切换「移动方式」到「保持原比例」，点目标显示器 → 窗口等比缩放居中到目标屏
3. 切换到「填满」→ 窗口填满目标屏可见区域（扣除 Dock/菜单栏）
4. 切换到「原始尺寸」→ 窗口保持原尺寸居中；超大的回退为等比缩放

Expected: 三种模式结果与优化前一致。

- [ ] **Step 3: 验证全屏窗口被跳过**

将一个窗口全屏（如 Safari 全屏），再执行移动。

Expected: 全屏窗口不参与移动，其余窗口正常移动。日志中应有 `skip fullscreen window ...`（用 Console.app 过滤 subsystem `com.sametrouble.WindowMover` 查看）。

- [ ] **Step 4: 验证容错（某个 app 无响应时不拖累其他 app）**

打开多个 app 的窗口。执行移动时，理论上某个 app 的 AX 连接异常不应影响其他 app。

简化验证：正常移动多次，确认无窗口丢失、无错误激增。若条件允许，可用 Activity Monitor 挂起一个 app 的进程后立即移动，观察其他 app 窗口是否仍正常移动。

Expected: 其他 app 窗口正常移动；被挂起 app 的窗口可能 `.failed` 但不阻塞整体。

- [ ] **Step 5: 验证菜单栏图标状态切换**

点击目标显示器移动。

Expected: 移动中菜单栏图标切换为 `arrow.triangle.2.circlepath`（macOS 15+ 旋转动画），完成后恢复 `display.2`。

- [ ] **Step 6: 主观体感对比**

窗口较多（10+，跨多 app）时移动完成明显更快。无需量化，主观确认即可。

Expected: 移动完成等待时间较优化前缩短，跨 app 窗口几乎同时开始移动而非逐个跳转。

---

## 自审

**1. 规格覆盖：**
- 协议变更（设计 §1 协议变更）→ Task 2 Step 1 ✓
- WindowController 实现 moveWindows + 组内单次预取 + 复用列表（设计 §2）→ Task 2 Step 2 ✓
- 提取 `axWindow(for:in:)`（设计 §2）→ Task 1 Step 1（先做 helper 提取）+ Task 2 Step 2（删除旧 `axWindow(for:)`）✓
- WindowMoverService 改 async + 按 PID 分组 + withTaskGroup 并发（设计 §3）→ Task 2 Step 3 ✓
- AppState.moveAll 加 await（设计 §4）→ Task 2 Step 4 ✓
- AX 调用次数对比（设计 §AX 调用次数对比）→ 验证方式为编译+手动，无量化断言（设计 §验证方式）✓
- 错误处理 4 场景（设计 §错误处理）→ Task 2 Step 2 `moveWindows` 实现：拉取失败整组 failed ✓、帧匹配未命中单窗口 failed continue ✓、setFrame 失败单窗口 failed continue ✓、列表空整组 failed ✓
- 边界 5 项（设计 §边界）→ Task 2 Step 3 `moveAllWindows`：空列表 groups 空 withTaskGroup 无 task 返回空 ✓、单 app 多窗口预取收益 ✓、单 app 单窗口退化 ✓、空组 Dictionary 不产生 ✓、task 数=app 数 ✓
- 并发安全性 4 点（设计 §并发安全性）→ Task 2 Step 3 actor 隔离说明 + WindowController stateless + result 单线程累加 + logger 线程安全 ✓
- 影响范围四文件（设计 §影响范围）→ Task 2 ✓
- 验证方式 6 项（设计 §验证方式）→ Task 3 Step 1-6 ✓
- 非目标（不引入同 app 并发/不用私有 API/不改 FrameCalculator/不改 UI/不补测试）→ 计划中均未涉及 ✓

**2. 占位符扫描：** 无 TBD/TODO/"添加合适的错误处理"等。每个代码步骤含完整代码块。Task 3 为手动验证步骤，无代码占位符。actor 隔离的 `nonisolated` 回退方案给出了具体代码与触发条件，非占位符。

**3. 类型一致性：**
- `WindowMoveOutcome` 三 case：`moved` / `skipped` / `failed(Error)`——已在 `PlatformProtocols.swift` 定义（不动），Task 2 Step 2 `moveWindows` 返回值使用，Task 2 Step 3 switch 匹配，一致 ✓
- `moveWindows(_:mode:targetFullFrame:targetVisibleFrame:) -> [(window: WindowInfo, outcome: WindowMoveOutcome)]`——协议定义（Step 1）、controller 实现（Step 2）、service 调用（Step 3）签名一致 ✓
- `axWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement?`——Task 1 Step 1 产出，Task 2 Step 2 `moveWindows` 内调用一致 ✓
- `isFullscreen(_ axWindow: AXUIElement) -> Bool` / `currentFrame(_ axWindow: AXUIElement) -> CGRect?` / `setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws`——上一轮已产出，Task 2 Step 2 `moveWindows` 内调用一致 ✓
- `FrameCalculator.calculateFrame(mode:source:targetFullFrame:targetVisibleFrame:)`——`FrameCalculator.swift` 原定义，Task 2 Step 2 `moveWindows` 内调用签名一致 ✓
- `moveAllWindows(to display: Display, mode: MoveMode) async -> MoveResult`——Task 2 Step 3 定义，Task 2 Step 4 `AppState.moveAll` 用 `await svc.moveAllWindows(to:mode:)` 调用一致 ✓
