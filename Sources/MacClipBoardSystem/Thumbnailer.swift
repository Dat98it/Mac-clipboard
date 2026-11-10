import Foundation
import ImageIO

/// Builds small previews with ImageIO, which downsamples while decoding instead of loading the full bitmap.
/// Thumbnails live in memory only; they are never written to disk and the stored image bytes are untouched.
public enum Thumbnailer {
    /// Refuse images that would need an unreasonable amount of memory to decode (a tiny file can declare huge dimensions).
    public static let maxSourcePixels = 100_000_000

    public static func makeThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxSourcePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true, // decode here, off the main thread
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
