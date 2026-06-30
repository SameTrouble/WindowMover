import Foundation
import CoreGraphics

enum WindowFilter {
    private static let systemOwners: Set<String> = [
        "Dock", "Window Server", "Control Center", "Spotlight", "SystemUIServer",
    ]

    static func filter(from infos: [[String: Any]]) -> [WindowInfo] {
        infos.compactMap { info -> WindowInfo? in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  alpha >= 1.0,
                  let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  isOnscreen,
                  !systemOwners.contains(ownerName),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat,
                  w > 0, h > 0
            else { return nil }
            return WindowInfo(
                id: id,
                ownerPID: ownerPid,
                ownerName: ownerName,
                frame: CGRect(x: x, y: y, width: w, height: h),
                isFullscreen: false,
                isMinimized: false
            )
        }
    }
}
