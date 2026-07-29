import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads dimensions and builds thumbnails straight from encoded image bytes,
/// without ever materialising the full-size bitmap.
public enum ImageInspector {
    public struct Info: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var format: String
    }

    public static func inspect(_ data: Data) -> Info? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }

        var format = "image"
        if let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier) {
            format = type.preferredFilenameExtension ?? type.localizedDescription ?? identifier
        }
        return Info(width: width, height: height, format: format)
    }

    /// A downscaled PNG suitable for caching inline in the database.
    public static func thumbnailPNG(from data: Data, maxPixelSize: Int = 384) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
