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

    nonisolated func moveWindows(_ windows: [WindowInfo],
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

    /// 在已拉取的 axWindows 列表中按帧匹配查找窗口。
    private func axWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        for axWin in axWindows {
            if matches(window: window, axWindow: axWin) { return axWin }
        }
        return nil
    }

    private func matches(window: WindowInfo, axWindow: AXUIElement) -> Bool {
        // Match by frame proximity; CG window frame and AX frame should be approximately
        // equal (both top-left origin).
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
