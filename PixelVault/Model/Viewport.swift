import CoreGraphics

/// Pan and zoom state shared by every pane, so original and compressed always show the
/// same region. Scale is in points per image pixel; `center` is the image point at the
/// middle of the pane.
struct Viewport: Equatable {
    static let fitMargin: CGFloat = 0.94
    static let maximumScale: CGFloat = 48

    /// While true the image tracks the pane size; any manual pan or zoom clears it.
    private(set) var isFitted = true
    private var manualScale: CGFloat = 1
    private var manualCenter: CGPoint = .zero
    /// The scale that fits the whole image in the pane; kept current by the pane.
    private(set) var fitScale: CGFloat = 1
    private(set) var imageSize: CGSize = .zero

    var scale: CGFloat { isFitted ? fitScale : manualScale }

    var center: CGPoint {
        isFitted ? CGPoint(x: imageSize.width / 2, y: imageSize.height / 2) : manualCenter
    }

    private var minimumScale: CGFloat { min(fitScale * 0.5, 0.05) }

    /// Called by a pane whenever its size or the image changes.
    mutating func update(imageSize: CGSize, paneSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0, paneSize.width > 0, paneSize.height > 0 else { return }
        if imageSize != self.imageSize {
            // A different image: start over fitted.
            self.imageSize = imageSize
            isFitted = true
        }
        fitScale = min(min(paneSize.width / imageSize.width, paneSize.height / imageSize.height) * Self.fitMargin, 16)
    }

    /// Where the image lands in a pane of `paneSize`.
    func imageFrame(in paneSize: CGSize) -> CGRect {
        let scale = scale, center = center
        return CGRect(x: paneSize.width / 2 - center.x * scale, y: paneSize.height / 2 - center.y * scale,
                      width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// The image point under a pane location.
    func imagePoint(at location: CGPoint, in paneSize: CGSize) -> CGPoint {
        let frame = imageFrame(in: paneSize)
        return CGPoint(x: (location.x - frame.minX) / scale, y: (location.y - frame.minY) / scale)
    }

    private mutating func detach() {
        guard isFitted else { return }
        manualScale = fitScale
        manualCenter = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        isFitted = false
    }

    private mutating func clampCenter() {
        manualCenter.x = min(max(manualCenter.x, 0), imageSize.width)
        manualCenter.y = min(max(manualCenter.y, 0), imageSize.height)
    }

    mutating func fit() {
        isFitted = true
    }

    /// Zooms by `factor`, keeping the image point under `anchor` (an offset from the pane
    /// centre, in points) where it is.
    mutating func zoom(by factor: CGFloat, anchor: CGSize = .zero) {
        setScale(scale * factor, anchor: anchor)
    }

    mutating func setScale(_ newScale: CGFloat, anchor: CGSize = .zero) {
        detach()
        let clamped = min(max(newScale, minimumScale), Self.maximumScale)
        let pinned = CGPoint(x: manualCenter.x + anchor.width / manualScale,
                             y: manualCenter.y + anchor.height / manualScale)
        manualScale = clamped
        manualCenter = CGPoint(x: pinned.x - anchor.width / clamped, y: pinned.y - anchor.height / clamped)
        clampCenter()
    }

    /// Moves the image by `translation` points.
    mutating func pan(by translation: CGSize) {
        detach()
        manualCenter.x -= translation.width / manualScale
        manualCenter.y -= translation.height / manualScale
        clampCenter()
    }

    /// Centres the view on an image point without changing the zoom.
    mutating func center(on point: CGPoint) {
        detach()
        manualCenter = point
        clampCenter()
    }
}
