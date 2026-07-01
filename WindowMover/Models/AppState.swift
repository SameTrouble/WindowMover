import AppKit
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
    @ObservationIgnored private var screenToken: NSObjectProtocol?

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
        // Keep displays fresh when the display configuration changes (connect/disconnect).
        // MenuBarExtra.onAppear refresh is unreliable, so observe the system notification and
        // re-read NSScreen.screens on the main actor.
        self.screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplays()
            }
        }
    }

    deinit {
        if let token = screenToken {
            NotificationCenter.default.removeObserver(token)
        }
        pollTimer?.invalidate()
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
        // Resolve the freshest frame by id rather than trusting the menu snapshot:
        // the display layout may have changed (connect/disconnect) since the menu was built.
        guard let current = screenObserver.displays.first(where: { $0.id == display.id }) else {
            logger.warning("moveAll: display \(display.id) no longer present; no-op")
            return
        }
        isMoving = true
        let mode = moveMode
        let svc = service
        Task.detached(priority: .userInitiated) {
            _ = await svc.moveAllWindows(to: current, mode: mode)
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
