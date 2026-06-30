import ApplicationServices
import AppKit
import os

final class AccessibilityChecker {
    private let logger = Logger(subsystem: "com.sametrouble.WindowMover", category: "accessibility")

    /// Check whether the app is already granted Accessibility permission.
    func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Trigger the one-time system prompt (and return whether granted after the prompt).
    @discardableResult
    func requestPrompt() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let granted = AXIsProcessTrustedWithOptions(options)
        logger.info("requestPrompt granted=\(granted)")
        return granted
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
