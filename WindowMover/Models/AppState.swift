import Foundation
import os
import ServiceManagement

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let screenObserver: ScreenObserving
    @ObservationIgnored private let service: WindowMoverService
    @ObservationIgnored private let accessibility: AccessibilityChecker
    @ObservationIgnored private let logger = Logger(subsystem: "com.sametrouble.WindowMover", category: "appstate")
    @ObservationIgnored private var pollTimer: Timer?

    // Persisted settings (stored so @Observable tracks changes; didSet syncs UserDefaults).
    var moveMode: MoveMode {
        didSet { defaults.set(moveMode.rawValue, forKey: Keys.moveMode) }
    }
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    // Runtime state
    var displays: [Display] = []
    var accessibilityGranted: Bool = false
    var isMoving: Bool = false

    var hasMultipleDisplays: Bool { displays.count > 1 }

    private enum Keys {
        static let moveMode = "moveMode"
        static let launchAtLogin = "launchAtLogin"
    }

    init(screenObserver: ScreenObserving,
         service: WindowMoverService,
         accessibility: AccessibilityChecker) {
        self.screenObserver = screenObserver
        self.service = service
        self.accessibility = accessibility
        // Seed persisted settings from UserDefaults; subsequent mutations sync back via didSet.
        self.moveMode = MoveMode(rawValue: defaults.string(forKey: Keys.moveMode) ?? "") ?? .keepAspect
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        // Seed runtime immediately so the first menu render is correct.
        self.displays = screenObserver.displays
        self.accessibilityGranted = accessibility.isGranted()
        if !self.accessibilityGranted {
            startPollingAccessibility()
        }
    }

    func startPollingAccessibility() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.accessibilityGranted = self.accessibility.isGranted()
                if self.accessibilityGranted {
                    timer.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }

    func refreshDisplays() {
        displays = screenObserver.displays
    }

    func refreshAccessibility() {
        accessibilityGranted = accessibility.isGranted()
        if !accessibilityGranted {
            accessibility.requestPrompt()
        }
    }

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

    func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLogin = enabled
            logger.info("launchAtLogin set to \(enabled)")
        } catch {
            logger.error("SMAppService \(enabled ? "register" : "unregister") failed: \(String(describing: error))")
            launchAtLogin = (service.status == .enabled)
        }
    }
}
