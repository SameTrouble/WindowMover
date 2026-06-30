import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if !state.accessibilityGranted {
            Button {
                state.refreshAccessibility()
                if !state.accessibilityGranted {
                    AccessibilityChecker().openSystemSettings()
                }
            } label: {
                Label("需要辅助功能权限…", systemImage: "exclamationmark.triangle")
            }
            Divider()
        }

        Section("移动所有窗口到：") {
            if state.hasMultipleDisplays {
                ForEach(state.displays) { display in
                    Button(display.displayName) {
                        state.moveAll(to: display)
                    }
                    .disabled(state.isMoving)
                }
            } else {
                Text("未检测到多显示器").foregroundStyle(.secondary)
            }
        }

        Section("移动方式：") {
            Picker("移动方式", selection: Binding(get: { state.moveMode },
                                              set: { state.moveMode = $0 })) {
                ForEach(MoveMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("选项：") {
            Toggle("开机启动", isOn: Binding(get: { state.launchAtLogin },
                                      set: { state.updateLaunchAtLogin($0) }))
            .disabled(state.isMoving)
        }

        Divider()
        Button("退出 WindowMover") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
