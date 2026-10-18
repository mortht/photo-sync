import Foundation
import ImageIO

/// Writes metadata into a copy of an image without re-encoding its pixels.
enum ImageMetadataWriter {
    struct WriteError: Error, LocalizedError {
        var errorDescription: String?
    }

    /// Copies `source` to `destination` with `description` set as XMP
    /// `dc:description`, which ImageIO mirrors into the IPTC caption that
    /// Photos shows. Works for JPEG, PNG and TIFF. For HEIC, ImageIO reports
    /// success without writing anything, so the result is read back and an
    /// error thrown if the description is missing.
    static func copy(_ source: URL, to destination: URL, settingDescription description: String) throws {
        // The destination only finishes writing the file once it is released,
        // so write in a separate scope before reading the result back.
        try write(source, to: destination, description: description)
        guard readDescription(of: destination) == description else {
            try? FileManager.default.removeItem(at: destination)
            throw WriteError(errorDescription: "This image format does not support adding a description")
        }
    }

    private static func write(_ source: URL, to destination: URL, description: String) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource) else {
            throw WriteError(errorDescription: "Unreadable image")
        }
        guard let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw WriteError(errorDescription: "Unsupported image type \(type)")
        }

        // ImageIO stores a plain string at this path as the x-default language alternative.
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString, description as CFString) else {
            throw WriteError(errorDescription: "Could not build metadata")
        }

        let options = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(imageDestination, imageSource, options, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "Could not write metadata"
            try? FileManager.default.removeItem(at: destination)
            throw WriteError(errorDescription: message)
        }
    }

    static func readDescription(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String?
    }
}
