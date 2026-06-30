# 窗口移动性能优化设计

## 背景

WindowMover 在「点击目标显示器 → 所有窗口移动完成」环节存在性能问题。用户反馈主观感受为「窗口移动慢」。

### 瓶颈定位

核心瓶颈在 `WindowController.axWindow(for:)`（`WindowMover/Platform/WindowController.swift:54-64`）：每个窗口的 `isFullscreen` / `currentFrame` / `setFrame` 三次调用，**每次都重新执行完整的 AX 窗口查找**——`AXUIElementCreateApplication(pid)` + 拉取整个 `kAXWindowsAttribute` 列表 + 逐个帧匹配（每个候选还要读 2 个 AX 属性）。

AX API 是跨进程 IPC，单次调用开销显著。`WindowMoverService.moveAllWindows(to:mode:)`（`WindowMover/Services/WindowMoverService.swift:26-56`）是串行 for 循环，N 个窗口导致：

- 3N 次 `axWindow(for:)` 查找（每次内含 `AXUIElementCreateApplication` + `kAXWindowsAttribute` 拉取）
- 帧匹配遍历：每次查找内对每个候选 AX 窗口读 `kAXPosition` + `kAXSize` 两个属性
- 设置阶段：每窗口 2 次 `AXUIElementSetAttributeValue`（position + size 分开）

## 目标

通过消除重复 AX 查找、合并属性调用，显著降低单次「移动所有窗口」的 AX IPC 次数，提升移动速度。

## 非目标

- 不引入并发移动（AXUIElement 跨线程不安全，且并发移动可能触发窗口管理器竞争导致位置错乱或失败率上升）
- 不做按 PID 批量预取（后续按需叠加）
- 不改 `FrameCalculator` 计算逻辑（三种模式行为保持不变）
- 不改 UI / 菜单 / 权限 / 状态管理
- 不补测试（属 code-quality 子项目范围，见 `2026-06-30-code-quality-design.md`）

## 设计

### 1. 协议变更（`WindowControlling`）

**当前协议**（`WindowMover/Platform/PlatformProtocols.swift:5-9`）：

```swift
protocol WindowControlling {
    func isFullscreen(_ window: WindowInfo) -> Bool
    func currentFrame(_ window: WindowInfo) -> CGRect
    func setFrame(_ frame: CGRect, for window: WindowInfo) throws
}
```

**变更后**：用一个合并方法替换三个旧方法。旧三方法仅被 `WindowMoverService` 一处调用，无外部使用方，直接替换不产生破坏。

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

`WindowMoveOutcome` 定义在 `PlatformProtocols.swift` 中，与协议同文件。

### 2. WindowController 实现（`WindowMover/Platform/WindowController.swift`）

`moveWindow` 内部流程——所有步骤基于**一次** `axWindow(for:)` 查找结果：

1. `axWindow(for:)` 查找 AX 窗口；失败返回 `.failed(.axElementNotFound)`
2. 查 `AXFullScreen` → true 则返回 `.skipped`
3. 读 `kAXPosition` + `kAXSize` 得 sourceFrame；失败返回 `.failed`
4. 调 `FrameCalculator.calculateFrame(mode:source:targetFullFrame:targetVisibleFrame:)` 得 targetFrame
5. 用 `kAXPositionAndSizeAttribute` **单次** `SetAttribute` 设置目标 frame；成功 `.moved`，失败 `.failed`

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

`isFullscreen` / `currentFrame` / `setFrame` 改为 `private` 内部方法，参数从 `WindowInfo` 改为已查到的 `AXUIElement`：

- `private func isFullscreen(_ axWindow: AXUIElement) -> Bool`
- `private func currentFrame(_ axWindow: AXUIElement) -> CGRect?`（失败返回 nil 替代原 `.zero`）
- `private func setFrame(_ frame: CGRect, for axWindow: AXUIElement) throws`

`axWindow(for window: WindowInfo) -> AXUIElement?` 保持不变（仍按 PID + 帧匹配查找）。

#### 设置阶段合并

`setFrame` 内用 `kAXPositionAndSizeAttribute` 单次调用替代当前的 position + size 两次 `SetAttribute`：

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

注意：`AXValueCreate(.cgRect, &rect)` 需要 `import CoreGraphics`（已有）且 `CGRect` 可作为 `AXValue` 类型 `.cgRect`。此属性为 AX 标准属性，macOS 原生窗口普遍支持；若个别窗口不支持，`SetAttribute` 返回非 `.success`，被计入 `.failed`，行为与当前一致（当前两次设置任一失败也抛错）。

#### 顺带修复：强制解包崩溃风险

当前 `WindowController.swift:44-45` 的 `pos!` / `sizeValue!` 强制解包在合并实现中一并消除（合并后的 `setFrame` 用 `guard let` 创建 AXValue）。这同时解决了 `2026-06-30-code-quality-design.md` 第 2.1 节标记的崩溃风险，属同一文件同一逻辑的自然改进，不额外扩大范围。

### 3. WindowMoverService 简化（`WindowMover/Services/WindowMoverService.swift`）

循环体从三步调用变为单步：

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

`WindowMoverService` 不再直接调用 `FrameCalculator`（frame 计算移入 `WindowController.moveWindow` 内部，因为需要先读 sourceFrame）。`FrameCalculator` 依赖从 `WindowMoverService` 转移到 `WindowController`。

### 4. AX 调用次数对比

| 阶段 | 优化前（每窗口） | 优化后（每窗口） |
|---|---|---|
| 查找 AX 窗口（`axWindow(for:)`） | 3 次（isFullscreen / currentFrame / setFrame 各一次） | **1 次** |
| 读 AX 属性 | 3+ 次（每次查找内含帧匹配读 2 属性 + 全屏读 1） | ~3 次（全屏 1 + 源 frame 2） |
| 设置 AX 属性 | 2 次（position + size 分开） | **1 次**（positionAndSize 合并） |
| **合计 AX IPC** | ~8+ 次/窗口 | ~5 次/窗口 |

查找重复的消除还减少了帧匹配遍历：优化前每次 `axWindow(for:)` 内对每个候选 AX 窗口读 2 个属性，N 个窗口、每 app M 个候选时是 `3 × N × 2 × M` 次读；优化后降到 `N × 2 × M` 次。

预计实际提速 2-3 倍，窗口数越多收益越明显。

## 影响范围

| 文件 | 改动类型 |
|---|---|
| `WindowMover/Platform/PlatformProtocols.swift` | 改协议 + 新增 `WindowMoveOutcome` 枚举 |
| `WindowMover/Platform/WindowController.swift` | 重写为实现 `moveWindow`，旧三方法降为 private 接收 `AXUIElement`，`setFrame` 用 `kAXPositionAndSizeAttribute`，消除强制解包 |
| `WindowMover/Services/WindowMoverService.swift` | 循环体改为单步 `moveWindow` 调用，移除 `FrameCalculator` 直接依赖 |

不动文件：`FrameCalculator.swift` / `WindowFilter.swift` / `WindowEnumerator.swift` / `AppState.swift` / `MenuView.swift` / `WindowMoverApp.swift` / `Models/*` / 其余 Platform 文件。

## 验证方式

项目零测试覆盖且无 benchmark。验证以**功能正确性 + 主观体感**为主：

1. **编译通过**：`xcodebuild` Release configuration 无错误、无新 warning
2. **功能等价**：多显示器环境下手动移动窗口，确认三种模式（keepAspect / fill / originalSize）结果与优化前一致
3. **全屏跳过**：确认全屏窗口仍被 `.skipped` 跳过，不参与移动
4. **状态正常**：菜单栏图标在移动中切换为旋转箭头，完成后恢复 `display.2`
5. **主观体感**：窗口数量较多（10+）时移动完成明显更快

## 风险

- **`kAXPositionAndSizeAttribute` 兼容性**：此为 AX 标准属性，macOS 原生窗口普遍支持。若个别窗口不支持，`SetAttribute` 返回非 `.success` 被计入 `.failed`，行为与当前两次设置任一失败一致，不会更差。
- **行为等价性**：`moveWindow` 合并三步后，若中途某步失败（如读 sourceFrame 失败），该窗口直接 `.failed` 跳过，与当前行为一致（当前 `currentFrame` 失败返回 `.zero` 后 `calculateFrame` 会算出错误 frame 再 `setFrame`，实际更差）。优化后失败处理更早、更干净。
