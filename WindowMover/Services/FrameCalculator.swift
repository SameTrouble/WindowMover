import CoreGraphics

enum FrameCalculator {
    static func calculateFrame(
        mode: MoveMode,
        source: CGRect,
        targetFullFrame: CGRect,
        targetVisibleFrame: CGRect
    ) -> CGRect {
        switch mode {
        case .keepAspect:
            return keepAspect(source: source, target: targetFullFrame)
        case .fill:
            return targetVisibleFrame
        case .originalSize:
            if source.width > targetFullFrame.width || source.height > targetFullFrame.height {
                return keepAspect(source: source, target: targetFullFrame)
            }
            let newX = targetFullFrame.origin.x + (targetFullFrame.width - source.width) / 2
            let newY = targetFullFrame.origin.y + (targetFullFrame.height - source.height) / 2
            return CGRect(x: newX, y: newY, width: source.width, height: source.height)
        }
    }

    private static func keepAspect(source: CGRect, target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return target }
        let scale = min(target.width / source.width, target.height / source.height)
        let newW = source.width * scale
        let newH = source.height * scale
        let newX = target.origin.x + (target.width - newW) / 2
        let newY = target.origin.y + (target.height - newH) / 2
        return CGRect(x: newX, y: newY, width: newW, height: newH)
    }
}
