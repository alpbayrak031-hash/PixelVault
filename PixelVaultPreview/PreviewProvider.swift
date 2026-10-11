import CoreGraphics
import Foundation
import PixelVaultKit
import QuickLookUI

/// Renders a `.pixv` file for Quick Look (space bar in Finder) and Finder's preview pane.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Enough for a full-screen preview on a 5K display; larger files stop a pyramid level early.
    private static let longSide = 2880

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
        let image = try PixelVault.decodePreview(data, minimumLongSide: Self.longSide).makeCGImage()
        let size = CGSize(width: image.width, height: image.height)
        return QLPreviewReply(contextSize: size, isBitmap: true) { context, _ in
            let bounds = context.convertToUserSpace(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.draw(image, in: bounds)
        }
    }
}
