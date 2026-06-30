import Foundation
import CoreGraphics

struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let isPrimary: Bool

    var displayName: String {
        isPrimary ? "\(name) (主)" : name
    }

    static func == (lhs: Display, rhs: Display) -> Bool {
        lhs.id == rhs.id
    }
}
