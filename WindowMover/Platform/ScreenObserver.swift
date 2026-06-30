import AppKit
import CoreGraphics

final class ScreenObserver: ScreenObserving {
    var displays: [Display] {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            let isPrimary = id == CGMainDisplayID()
            return Display(
                id: id,
                name: name,
                frame: cgRect(from: screen.frame),
                visibleFrame: cgRect(from: screen.visibleFrame),
                isPrimary: isPrimary
            )
        }
    }

    /// NSScreen uses bottom-left origin; convert to top-left (CG) global coordinate space.
    private func cgRect(from nsRect: NSRect) -> CGRect {
        let screenHeight = NSScreen.screens.first?.frame.height ?? nsRect.height
        let cgY = screenHeight - nsRect.origin.y - nsRect.height
        return CGRect(x: nsRect.origin.x, y: cgY, width: nsRect.width, height: nsRect.height)
    }
}
