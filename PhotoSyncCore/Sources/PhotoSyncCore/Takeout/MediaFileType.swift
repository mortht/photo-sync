import Foundation

/// The kind of media a file contains.
public enum MediaKind: String, Sendable, Codable, Hashable {
    case photo
    case video
}

/// Classifies files by extension.
enum MediaFileType {
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "avif",
        "dng", "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf",
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "avi", "mkv", "mts", "m2ts", "wmv", "mpg", "mpeg", "webm",
    ]

    /// Photo formats that can be the still image of a Live Photo.
    static let livePhotoStillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]

    static func kind(ofFileNamed name: String) -> MediaKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if photoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    static func isJSON(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "json"
    }
}
