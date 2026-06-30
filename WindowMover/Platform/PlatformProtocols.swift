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
