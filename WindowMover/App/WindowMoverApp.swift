import os
import SwiftUI

@main
struct WindowMoverApp: App {
    @State private var state: AppState

    init() {
        let logger = Logger(subsystem: "com.sametrouble.WindowMover", category: "app")
        let screenObserver = ScreenObserver()
        let windowController = WindowController(logger: logger)
        let windowEnumerator = WindowEnumerator(logger: logger)
        let service = WindowMoverService(
            windowController: windowController,
            windowEnumerator: windowEnumerator,
            screenObserver: screenObserver,
            logger: logger)
        let accessibility = AccessibilityChecker()
        _state = State(initialValue: AppState(
            screenObserver: screenObserver,
            service: service,
            accessibility: accessibility))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(state)
                .onAppear { state.refreshDisplays() }
        } label: {
            if #available(macOS 15.0, *) {
                Image(systemName: state.isMoving ? "arrow.triangle.2.circlepath" : "display.2")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state.isMoving)
            } else {
                Image(systemName: state.isMoving ? "arrow.triangle.2.circlepath" : "display.2")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
