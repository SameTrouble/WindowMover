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
