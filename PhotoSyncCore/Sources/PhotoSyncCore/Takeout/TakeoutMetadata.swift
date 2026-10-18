import Foundation

/// A geographic coordinate taken from a Takeout sidecar.
public struct GeoLocation: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    public init(latitude: Double, longitude: Double, altitude: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// Per-item metadata from a Takeout sidecar JSON (`IMG.jpg.json`,
/// `IMG.jpg.supplemental-metadata.json`, ...). Google does not embed these
/// values in the exported files, so they have to be restored on import.
public struct TakeoutMetadata: Sendable, Hashable {
    /// The original file name as uploaded to Google Photos.
    public var title: String?
    public var description: String?
    public var photoTakenTime: Date?
    /// When the item was uploaded to Google Photos.
    public var creationTime: Date?
    public var location: GeoLocation?
    public var people: [String]
    public var isFavorite: Bool
    public var isArchived: Bool
    public var isTrashed: Bool

    public init(
        title: String? = nil,
        description: String? = nil,
        photoTakenTime: Date? = nil,
        creationTime: Date? = nil,
        location: GeoLocation? = nil,
        people: [String] = [],
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false
    ) {
        self.title = title
        self.description = description
        self.photoTakenTime = photoTakenTime
        self.creationTime = creationTime
        self.location = location
        self.people = people
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isTrashed = isTrashed
    }

    /// The best available capture date.
    public var captureDate: Date? { photoTakenTime ?? creationTime }
}

/// Album-level metadata from an album folder's `metadata.json`
/// (localized, e.g. `Metadaten.json` in German exports).
public struct TakeoutAlbumMetadata: Sendable, Hashable {
    public var title: String
    public var description: String?
}

/// A parsed Takeout JSON file, classified by its content rather than its
/// name because both sidecar and album file names vary by locale and get
/// truncated.
enum TakeoutJSONDocument: Sendable, Equatable {
    case sidecar(TakeoutMetadata)
    case album(TakeoutAlbumMetadata)
    case other

    static func parse(_ data: Data) -> TakeoutJSONDocument {
        guard let raw = try? JSONDecoder().decode(RawDocument.self, from: data) else { return .other }
        if raw.photoTakenTime != nil || raw.creationTime != nil {
            return .sidecar(TakeoutMetadata(raw))
        }
        if let title = raw.title {
            return .album(TakeoutAlbumMetadata(title: title, description: raw.description.nonEmpty))
        }
        return .other
    }
}

// MARK: - Raw JSON

private struct RawDocument: Decodable {
    var title: String?
    var description: String?
    var photoTakenTime: RawTimestamp?
    var creationTime: RawTimestamp?
    var geoData: RawGeoData?
    var geoDataExif: RawGeoData?
    var people: [RawPerson]?
    var favorited: Bool?
    var archived: Bool?
    var trashed: Bool?
}

private struct RawTimestamp: Decodable {
    var date: Date?

    enum CodingKeys: String, CodingKey { case timestamp }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Takeout writes epoch seconds as a string; accept numbers too.
        let seconds: Double?
        if let string = try? container.decode(String.self, forKey: .timestamp) {
            seconds = Double(string)
        } else {
            seconds = try? container.decode(Double.self, forKey: .timestamp)
        }
        date = seconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }
}

private struct RawGeoData: Decodable {
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?

    /// Takeout uses 0/0 to mean "no location".
    var location: GeoLocation? {
        guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
        return GeoLocation(latitude: latitude, longitude: longitude, altitude: altitude ?? 0)
    }
}

private struct RawPerson: Decodable {
    var name: String?
}

private extension TakeoutMetadata {
    init(_ raw: RawDocument) {
        self.init(
            title: raw.title,
            description: raw.description.nonEmpty,
            photoTakenTime: raw.photoTakenTime?.date,
            creationTime: raw.creationTime?.date,
            location: raw.geoData?.location ?? raw.geoDataExif?.location,
            people: raw.people?.compactMap(\.name) ?? [],
            isFavorite: raw.favorited ?? false,
            isArchived: raw.archived ?? false,
            isTrashed: raw.trashed ?? false
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
