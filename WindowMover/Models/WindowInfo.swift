import Foundation
import CoreGraphics

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let frame: CGRect
    let isFullscreen: Bool
    let isMinimized: Bool

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}
