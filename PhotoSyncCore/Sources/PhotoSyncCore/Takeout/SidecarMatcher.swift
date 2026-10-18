import Foundation

/// Matches media files to their Takeout sidecar JSON files using file names
/// only (plus the sidecar's `title` as a last resort).
///
/// Takeout naming rules handled here:
/// - `IMG.jpg` → `IMG.jpg.json`
/// - newer exports: `IMG.jpg.supplemental-metadata.json`, with the suffix
///   truncated to fit the name limit (`IMG.jpg.supplemental-met.json`, `IMG.jpg.supp.json`)
/// - long names truncated as a whole (`a_very_long_file_na.json`)
/// - duplicates: `IMG(1).jpg` → `IMG.jpg(1).json` / `IMG.jpg.supplemental-metadata(1).json`
/// - edited copies without their own sidecar: `IMG-edited.jpg` (localized) uses `IMG.jpg`'s
/// - sidecars without the media extension: `IMG.json`
struct SidecarMatcher {
    struct Sidecar: Sendable, Hashable {
        var name: String
        /// The `title` field of the sidecar (the original upload file name).
        var title: String?
    }

    struct Result: Sendable, Equatable {
        /// Media file name → sidecar file name. Edited copies share their original's sidecar.
        var sidecarByMedia: [String: String]
        var unmatchedSidecars: [String]
    }

    static let supplementalSuffix = ".supplemental-metadata"

    /// Suffixes Google Photos appends to edited copies, by export language.
    static let editedSuffixes = [
        "-edited", "-bearbeitet", "-modifié", "-modificato", "-editado", "-editada", "-bewerkt", "-redigerad",
    ]

    /// Sidecar stems at least this long may be a truncated media file name.
    static let minimumTruncatedLength = 30

    static func match(mediaNames: [String], sidecars: [Sidecar]) -> Result {
        let index = MediaIndex(mediaNames: mediaNames)

        var sidecarByKey: [Key: String] = [:]
        var unresolved: [Sidecar] = []
        for sidecar in sidecars.sorted(by: { $0.name < $1.name }) {
            if let key = index.resolve(sidecarName: sidecar.name), sidecarByKey[key] == nil {
                sidecarByKey[key] = sidecar.name
            } else {
                unresolved.append(sidecar)
            }
        }

        var sidecarByMedia: [String: String] = [:]
        for media in mediaNames {
            let keys = index.ownKeys[media, default: []] + index.editedTargetKeys[media, default: []]
            if let sidecar = keys.lazy.compactMap({ sidecarByKey[$0] }).first {
                sidecarByMedia[media] = sidecar
            }
        }

        // Last resort: the sidecar's `title` is the original file name.
        var byTitle: [String: [Sidecar]] = [:]
        for sidecar in unresolved {
            if let title = sidecar.title?.lowercased() { byTitle[title, default: []].append(sidecar) }
        }
        var titleMatched: Set<String> = []
        for media in mediaNames where sidecarByMedia[media] == nil {
            let candidateNames = [media] + index.alternativeNames(for: media)
            for name in candidateNames {
                guard let candidates = byTitle[name.lowercased()] else { continue }
                let free = candidates.filter { !titleMatched.contains($0.name) }
                if free.count == 1 {
                    sidecarByMedia[media] = free[0].name
                    titleMatched.insert(free[0].name)
                    break
                }
            }
        }

        let unmatched = unresolved.map(\.name).filter { !titleMatched.contains($0) }
        return Result(sidecarByMedia: sidecarByMedia, unmatchedSidecars: unmatched)
    }

    /// For an edited copy like `IMG-edited.jpg`, returns `IMG.jpg`.
    static func originalName(forEdited name: String) -> String? {
        let (stem, ext) = splitExtension(name)
        let lowerStem = stem.lowercased()
        for suffix in editedSuffixes where lowerStem.hasSuffix(suffix) && lowerStem.count > suffix.count {
            return String(stem.dropLast(suffix.count)) + ext
        }
        return nil
    }

    // MARK: - Name helpers

    /// Splits `IMG.jpg` into (`IMG`, `.jpg`). Names without a dot have an empty extension.
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Splits `IMG(2)` into (`IMG`, 2).
    static func splitDuplicate(_ string: String) -> (base: String, number: Int)? {
        guard string.hasSuffix(")"), let open = string.lastIndex(of: "("), open != string.startIndex else {
            return nil
        }
        let digits = string[string.index(after: open)..<string.index(before: string.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let number = Int(digits) else { return nil }
        return (String(string[..<open]), number)
    }

    // MARK: - Index

    struct Key: Hashable {
        /// Lowercased media file name with any duplicate number removed.
        var name: String
        /// The `(n)` duplicate number, or 0.
        var duplicate: Int
    }

    private struct MediaIndex {
        /// Keys under which each media file's own sidecar may be filed.
        var ownKeys: [String: [Key]] = [:]
        /// For edited copies: keys of the original's sidecar.
        var editedTargetKeys: [String: [Key]] = [:]
        /// All keys a sidecar may resolve to.
        var acceptable: Set<Key> = []
        /// Name without extension → full keys, for `IMG.json`-style sidecars.
        var byStem: [Key: Set<Key>] = [:]
        /// Own keys of edited copies, which never carry their own sidecar.
        var editedOwnKeys: Set<Key> = []

        init(mediaNames: [String]) {
            for media in mediaNames {
                let keys = Self.keys(for: media)
                ownKeys[media] = keys
                acceptable.formUnion(keys)
                for key in keys {
                    let stemKey = Key(name: splitExtension(key.name).stem, duplicate: key.duplicate)
                    byStem[stemKey, default: []].insert(key)
                }
                if let original = originalName(forEdited: media) {
                    let targets = Self.keys(for: original)
                    editedTargetKeys[media] = targets
                    editedOwnKeys.formUnion(keys)
                    acceptable.formUnion(targets)
                }
            }
        }

        static func keys(for media: String) -> [Key] {
            let lower = media.lowercased()
            var keys = [Key(name: lower, duplicate: 0)]
            let (stem, ext) = splitExtension(lower)
            if let (base, number) = splitDuplicate(stem) {
                keys.append(Key(name: base + ext, duplicate: number))
            }
            return keys
        }

        /// Other names the same item may carry in a sidecar `title`.
        func alternativeNames(for media: String) -> [String] {
            var names: [String] = []
            let (stem, ext) = splitExtension(media)
            if let (base, _) = splitDuplicate(stem) { names.append(base + ext) }
            if let original = originalName(forEdited: media) { names.append(original) }
            return names
        }

        func resolve(sidecarName: String) -> Key? {
            guard MediaFileType.isJSON(sidecarName) else { return nil }
            let stem = splitExtension(sidecarName).stem.lowercased()
            var candidates = [Key(name: stem, duplicate: 0)]
            if let (base, number) = splitDuplicate(stem) {
                candidates.append(Key(name: base, duplicate: number))
            }

            for candidate in candidates {
                if let key = resolve(candidate) { return key }
            }
            return nil
        }

        private func resolve(_ candidate: Key) -> Key? {
            let name = candidate.name
            if acceptable.contains(candidate) { return candidate }

            // `IMG.jpg.supplemental-metadata`, possibly truncated: strip the
            // longest tail that is a prefix of the suffix.
            let suffix = supplementalSuffix
            let maxTail = min(suffix.count, name.count - 1)
            if maxTail >= 1 {
                for length in stride(from: maxTail, through: 1, by: -1) {
                    let tail = name.suffix(length)
                    guard suffix.hasPrefix(tail) else { continue }
                    let key = Key(name: String(name.dropLast(length)), duplicate: candidate.duplicate)
                    if acceptable.contains(key) { return key }
                }
            }

            // `IMG.json` for `IMG.jpg`.
            if let keys = byStem[candidate], keys.count == 1 { return keys.first }

            // The whole name was truncated: the sidecar stem is a prefix of the media name.
            if name.count >= minimumTruncatedLength {
                let matches = acceptable.filter {
                    $0.duplicate == candidate.duplicate && $0.name.hasPrefix(name)
                }
                if matches.count == 1 { return matches.first }
                let unedited = matches.subtracting(editedOwnKeys)
                if unedited.count == 1 { return unedited.first }
            }
            return nil
        }
    }
}
