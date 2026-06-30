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
    /// 移动一组同 PID 的窗口。组内串行；调用方负责保证跨组并发。
    /// 组内只做一次 AXUIElementCreateApplication + kAXWindowsAttribute 拉取，组内各窗口复用该列表。
    nonisolated func moveWindows(_ windows: [WindowInfo],
                     mode: MoveMode,
                     targetFullFrame: CGRect,
                     targetVisibleFrame: CGRect) -> [(window: WindowInfo, outcome: WindowMoveOutcome)]
}

protocol WindowEnumerating {
    func visibleWindows() -> [WindowInfo]
}

protocol ScreenObserving {
    var displays: [Display] { get }
}
