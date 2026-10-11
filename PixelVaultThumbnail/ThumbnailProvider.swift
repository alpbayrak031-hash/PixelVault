import CoreGraphics
import Foundation
import PixelVaultKit
import QuickLookThumbnailing

/// Gives Finder, the Desktop and file dialogs the picture inside a `.pixv` file to use as
/// its icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
            // Decode no more of the pyramid than the icon needs: icons are requested in
            // bulk, and this process has a small memory budget.
            let pixels = max(request.maximumSize.width, request.maximumSize.height) * request.scale
            let image = try PixelVault.decodePreview(data, minimumLongSide: Int(pixels.rounded(.up))).makeCGImage()

            let fit = min(request.maximumSize.width / CGFloat(image.width),
                          request.maximumSize.height / CGFloat(image.height))
            let size = CGSize(width: max(1, (CGFloat(image.width) * fit).rounded()),
                              height: max(1, (CGFloat(image.height) * fit).rounded()))
            let reply = QLThumbnailReply(contextSize: size) { context in
                // The bitmap is `size × scale` pixels but arrives without a matching transform,
                // so fill its device bounds rather than `size`.
                let bounds = context.convertToUserSpace(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.interpolationQuality = .high
                context.draw(image, in: bounds)
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
