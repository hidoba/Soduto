import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// The clipboard wire format used by KDE Connect's clipboard.file extension.
/// Decode within explicit limits, normalize color/alpha, and compare pixels rather
/// than PNG/TIFF encodings so a relay cannot echo the same picture indefinitely.
struct ClipboardImage {
    static let maximumBytes = 50 * 1024 * 1024
    static let maximumPixels = 16_777_216
    let png: Data
    let fingerprint: Data

    static func decode(_ data: Data) -> ClipboardImage? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= maximumPixels / height,
              // Apply EXIF/TIFF orientation before discarding source metadata.
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width * image.height <= maximumPixels,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Include dimensions: identical byte sequences can describe different shapes.
        var hash = SHA256()
        hash.update(data: Data("\(image.width)x\(image.height):".utf8))
        hash.update(data: Data(bytesNoCopy: pixels, count: image.width * image.height * 4, deallocator: .none))
        guard let normalized = context.makeImage() else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, normalized, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= maximumBytes else { return nil }
        return ClipboardImage(png: encoded as Data, fingerprint: Data(hash.finalize()))
    }
}
