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
