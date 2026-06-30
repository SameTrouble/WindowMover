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
