import CoreGraphics
import os

final class WindowEnumerator: WindowEnumerating {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func visibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoArray = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            logger.error("CGWindowListCopyWindowInfo returned nil")
            return []
        }
        return WindowFilter.filter(from: infoArray)
    }
}
