import Foundation

enum MoveMode: String, Codable, CaseIterable {
    case keepAspect
    case fill
    case originalSize

    var displayName: String {
        switch self {
        case .keepAspect: return "保持原比例"
        case .fill: return "填满"
        case .originalSize: return "原始尺寸"
        }
    }
}
