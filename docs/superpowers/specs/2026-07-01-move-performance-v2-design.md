# 窗口移动性能优化设计（第二轮：分组预取 + 跨 app 并发）

## 背景

上一轮优化（`feat/move-performance`，见 `2026-06-30-move-performance-design.md`）已将每窗口的 AX 查找从 3 次合并为 1 次，并消除强制解包。当前每窗口开销约：1 次 `axWindow(for:)` 查找（含 `AXUIElementCreateApplication` + 拉 `kAXWindowsAttribute` 列表 + 逐候选读 2 属性做帧匹配）+ 3 次属性读（AXFullScreen + position + size）+ 2 次属性设置。

用户反馈：整体仍偏慢，需进一步压缩。可接受跨 app 并发。成功标准为「明显更快即可」。

### 剩余瓶颈

当前 `WindowController.axWindow(for:)` 对**每个窗口**都执行完整流程：`AXUIElementCreateApplication(pid)` + 拉 `kAXWindowsAttribute` 列表 + 逐候选读 position/size 做帧匹配。

**关键浪费**：同一 app 的多个窗口会重复拉取窗口列表。例如 Chrome 有 5 个窗口，当前会对 Chrome 的 PID 调 5 次 `AXUIElementCreateApplication` + 5 次 `kAXWindowsAttribute` 拉取，每次还遍历全部候选做帧匹配。N 个同 app 窗口 = N 次列表拉取，而这本可降到 1 次。

设 K 个 app、每 app 平均 M 个窗口（N = K×M）：
- 当前：N 次 app 创建 + N 次窗口列表拉取，全串行
- 优化空间：降到 K 次创建 + K 次拉取，且跨 app 并发

## 目标

通过按 PID 分组预取窗口列表 + 跨 app 并发，进一步降低「移动所有窗口」的 wall-clock 时延。

## 非目标

- 不改 `FrameCalculator` 计算逻辑（三种模式行为保持不变）
- 不改 UI / 菜单 / 权限 / 状态管理（`AppState.moveAll` 仅加 `await`）
- 不改 `WindowFilter` / `WindowEnumerator`
- 不补测试（延续上一轮约定，属 code-quality 子项目范围）
- 不引入并发移动同 app 内窗口（AXUIElement 跨线程不安全，同 app 串行）
- 不用私有 API（如 `_AXUIElementGetWindow` 精确匹配，有审核与兼容风险）

## 设计

### 架构与数据流

**当前数据流**（串行）：

```
moveAllWindows → for window in windows（串行）→ windowController.moveWindow(window)
                                                    └─ axWindow(for: window)  ← 每个 window 都重建 app + 重拉窗口列表
```

**新数据流**（按 PID 分组 + 跨 app 并发）：

```
moveAllWindows(async)
  ├─ visibleWindows()
  ├─ Dictionary(grouping: by ownerPID)          // 按 app 分组
  └─ withTaskGroup:
       ├─ addTask(PID 组 A) → windowController.moveWindows(groupA) → [(window, outcome)]
       ├─ addTask(PID 组 B) → windowController.moveWindows(groupB) → [(window, outcome)]
       └─ ...                                     // 跨 app 并发，组内串行
       └─ 汇总各组结果到 MoveResult
```

**关键不变量**：

- 同一 PID 的窗口组**串行**处理（同 app 的 AXUIElement 非线程安全）
- 不同 PID 组**并发**处理（不同 app 走独立 IPC 连接）
- 每 PID 组内：**一次** `AXUIElementCreateApplication` + **一次** `kAXWindowsAttribute` 拉取，组内各窗口复用该列表做帧匹配

### 1. 协议变更（`WindowControlling`）

**当前协议**（`WindowMover/Platform/PlatformProtocols.swift`）：

```swift
protocol WindowControlling {
    func moveWindow(_ window: WindowInfo,
                    mode: MoveMode,
                    targetFullFrame: CGRect,
                    targetVisibleFrame: CGRect) -> WindowMoveOutcome
}
```

**变更后**：改为「批量」接口，接收**同 PID 的窗口组**：

```swift
protocol WindowControlling {
    /// 移动一组同 PID 的窗口。组内串行；调用方负责保证跨组并发。
    func moveWindows(_ windows: [WindowInfo],
                     mode: MoveMode,
                     targetFullFrame: CGRect,
                     targetVisibleFrame: CGRect) -> [(window: WindowInfo, outcome: WindowMoveOutcome)]
}
```

返回元组数组而非 `WindowMoveOutcome`，让调用方（service）按窗口汇总 `moved/skipped/failed` 计数，并保留「哪个窗口失败」的信息用于日志。

### 2. WindowController 实现（`WindowMover/Platform/WindowController.swift`）

新增 `moveWindows(_:mode:targetFullFrame:targetVisibleFrame:)`，组内逻辑：

1. 取组内任一窗口的 `ownerPID`（同组一致）
2. **一次** `AXUIElementCreateApplication(pid)` + **一次** 拉 `kAXWindowsAttribute`
3. 对组内每个 window：在已拉取的 `axWindows` 列表里做帧匹配 → 找到 `axWin` 后走原 `isFullscreen`/`currentFrame`/`setFrame` 流程
4. 收集 `[(window, outcome)]` 返回

**提取 `axWindow(for window:in axWindows:)`**：把帧匹配从「重建 app + 拉列表」剥离，直接接收已拉取的 `axWindows` 数组复用。

旧 `axWindow(for window: WindowInfo)`（含 app 创建 + 列表拉取）删除——它只被旧 `moveWindow` 用，而 `moveWindow` 被 `moveWindows` 取代。

`isFullscreen` / `currentFrame` / `setFrame` 保持 `private` 接收 `AXUIElement`，不变。

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

private func axWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
    for axWin in axWindows {
        if matches(window: window, axWindow: axWin) { return axWin }
    }
    return nil
}
```

### 3. WindowMoverService 简化（`WindowMover/Services/WindowMoverService.swift`）

`moveAllWindows` 改为 `async`，按 PID 分组后用 `withTaskGroup` 跨 app 并发：

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
                self.windowController.moveWindows(groupWindows, mode: mode,
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

### 4. AppState.moveAll（`WindowMover/Models/AppState.swift`）

当前已用 `Task.detached`，仅加 `await`：

```swift
func moveAll(to display: Display) {
    guard !isMoving else { return }
    isMoving = true
    let mode = moveMode
    let svc = service
    Task.detached(priority: .userInitiated) {
        _ = await svc.moveAllWindows(to: display, mode: mode)
        await MainActor.run { self.isMoving = false }
    }
}
```

仅加 `await`，结构不变。

### AX 调用次数对比

| 阶段 | 上一轮优化后（每窗口） | 本轮优化后（每 PID 组） |
|---|---|---|
| `AXUIElementCreateApplication` | N 次 | K 次（每 app 1 次） |
| `kAXWindowsAttribute` 拉取 | N 次 | K 次（每 app 1 次） |
| 帧匹配读属性 | N×2×M 次 | N×2×M 次（不变，但复用一次列表） |
| 全屏+源 frame 读 | 3N 次 | 3N 次（不变） |
| 设置 | 2N 次 | 2N 次（不变） |
| **wall-clock** | 串行总和 | ≈ 最慢组耗时（受核数限制） |

主要收益：
1. app 创建与列表拉取 N→K（同 app 多窗口场景显著）
2. 跨 app 并发的 wall-clock 提速（多 app 场景显著）

## 错误处理

| 场景 | 处理 |
|---|---|
| 组内 `AXUIElementCreateApplication` / `kAXWindowsAttribute` 拉取失败 | 整组窗口标记 `.failed(.axElementNotFound)`，不影响其他并发组 |
| 组内某窗口帧匹配未命中 | 该窗口 `.failed(.axElementNotFound)`，继续组内下一窗口（不中断组） |
| 组内某窗口 `setFrame` 失败 | 该窗口 `.failed(error)`，继续下一窗口（同当前行为） |
| `kAXWindowsAttribute` 为空（app 无可见 AX 窗口） | 组内所有窗口 `.failed(.axElementNotFound)` |

关键原则：**组内局部失败不传播**。一个 app 的 AX 问题不拖累其他 app 的并发组——这正是跨 app 并发的容错优势。

## 边界

- **空窗口列表**：`groups` 为空，`withTaskGroup` 无 task，直接返回空 `MoveResult`，无需特判
- **单 app 多窗口**（K=1，M=N）：无并发收益，但拿到预取收益（app 创建 + 列表拉取 N→1）
- **单 app 单窗口**（K=N=1）：无并发无预取收益，退化为当前行为，无回退
- **空组**：`Dictionary(grouping:)` 不会产生空组，无需处理
- **`withTaskGroup` task 数**：等于 app 数 K，通常 ≤10，无调度压力

## 并发安全性

- `withTaskGroup` 子 task 间无共享可变状态——每组独立调用 `windowController.moveWindows`
- `WindowController` 是 stateless（仅持 `logger`），跨 task 调用安全
- `WindowMoverService` 内 `result` 在 `for await` 循环中单线程累加，无数据竞争
- `logger` 是 `OSLogger`，线程安全

## 影响范围

| 文件 | 改动类型 |
|---|---|
| `WindowMover/Platform/PlatformProtocols.swift` | 协议从单窗口 `moveWindow` 改为批量 `moveWindows` |
| `WindowMover/Platform/WindowController.swift` | 实现 `moveWindows`（组内单次预取 + 复用列表），提取 `axWindow(for:in:)`，删除旧 `axWindow(for:)` |
| `WindowMover/Services/WindowMoverService.swift` | `moveAllWindows` 改 `async`，按 PID 分组 + `withTaskGroup` 并发 |
| `WindowMover/Models/AppState.swift` | `moveAll` 加 `await` |

不动文件：`FrameCalculator.swift` / `WindowFilter.swift` / `WindowEnumerator.swift` / `MenuView.swift` / `WindowMoverApp.swift` / `Models/Display.swift` / `Models/MoveMode.swift` / `Models/WindowInfo.swift` / 其余 Platform 文件。

## 验证方式

项目零测试覆盖且无 benchmark。验证以**功能正确性 + 主观体感**为主：

1. **编译通过**：`xcodebuild` Release configuration 无错误、无新 warning
2. **功能等价**：多显示器环境下手动移动窗口，确认三种模式（keepAspect / fill / originalSize）结果与优化前一致
3. **全屏跳过**：确认全屏窗口仍被 `.skipped` 跳过，不参与移动
4. **容错**：某个 app 无响应/被杀时，其他 app 窗口仍正常移动
5. **状态正常**：菜单栏图标在移动中切换为旋转箭头，完成后恢复 `display.2`
6. **主观体感**：窗口数较多（10+，跨多 app）时移动完成明显更快

## 风险

- **AXUIElement 跨 PID 并发**：无官方文档明确保证，但实践中 Rectangle / Amethyst 等窗口管理器均按 PID 分组并发操作 AXUIElement，长期可行。本设计遵循同 app 串行、跨 app 并发的保守边界。
- **并发移动个别窗口失败**：与串行版本相比，失败率不应上升——同 app 内仍串行，跨 app 并发不互相影响 AX 状态。若个别 app 的 AX 连接在并发下偶发失败，该窗口标记 `.failed` 不影响其他窗口，容错性优于串行整体回滚。
- **行为等价性**：组内串行语义与当前串行循环一致，仅时序从全局串行变为分 app 并发，单窗口的移动逻辑（全屏判断 → 读 frame → 计算 → 设置）完全不变。
