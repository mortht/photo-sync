# photo-sync

A native macOS app (Swift + SwiftUI) that transfers and syncs whole photo
albums between **iCloud Photos** and **Google Photos**: connect both
accounts, browse albums on each side, and copy an album across.

> Status: early development. The album browser lists Apple Photos albums
> (including Shared Albums) and scanned Google Takeout exports. Transfers are
> not implemented yet. See the [roadmap](#roadmap).

## Platform constraints

The design follows from what the two platforms actually allow:

- **iCloud Photos has no public web API.** The only official access is
  PhotoKit on macOS/iOS. With full library access, PhotoKit lists all albums,
  including iCloud Shared Albums (`PHAssetCollection` subtype
  `.albumCloudShared`). Unofficial iCloud web APIs are out of scope.
- **Google Photos Library API (since March 31, 2025)** only lets apps read
  media and albums *they created* (`photoslibrary.appendonly`,
  `photoslibrary.readonly.appcreateddata`, `photoslibrary.edit.appcreateddata`).
  Listing the user's albums or shared albums is no longer possible. Uploading
  and creating albums still works.
- **Google Photos Picker API**: the user picks items in a Google-hosted UI.
  The app creates a session, opens `pickerUri`, polls `sessions.get` until
  `mediaItemsSet`, lists the picked `mediaItems`, and downloads them via
  `baseUrl` + `=d` (photos) / `=dv` (videos) with the bearer token. It returns
  no album information. Limits still to be verified: ~2000 items per
  session, `baseUrl` valid ~60 minutes, unclear support for shared albums.
- **Google Takeout** exports albums as folders, `Takeout/Google Photos/<Album>/`,
  with an album `metadata.json` and a sidecar JSON per item. The sidecar holds
  the capture time, location and description, which are **not** embedded in
  the exported files.

## Architecture

| Direction | Path | How |
|---|---|---|
| Apple → Google | automatic | PhotoKit reads the album and exports originals (`PHAssetResourceManager`), then the Library API creates the album, uploads the bytes (`uploads` → upload token) and adds them with `mediaItems:batchCreate` (≤ 50 per call). |
| Google → Apple | **primary: Takeout import** | Scan the extracted export, show albums with counts, match sidecars, restore date/location/description, import with `PHAssetCreationRequest`, recreate the album under the same name. |
| Google → Apple | secondary: Picker | Quick small transfers; the user names the target album. |
| Both | incremental sync | A local mapping in Application Support (source ID/content hash ↔ destination ID, per album pair) so re-runs only transfer new items. |

### Repository layout

```
PhotoSyncCore/            Swift package, platform-independent, unit-tested
  Sources/PhotoSyncCore/
    Takeout/              Takeout scanner, sidecar matcher, metadata parsing
  Tests/PhotoSyncCoreTests/
PhotoSync/                macOS app (SwiftUI); file-system-synchronized group
  Apple/                  PhotoKit adapter and Apple album pane
  Takeout/                Takeout folder pane
  Shared/                 Shared views
PhotoSync.xcodeproj       App project, depends on the local PhotoSyncCore package
Config/                   Entitlements (and later the local OAuth client config)
```

To come in `PhotoSyncCore`: Google OAuth (PKCE with a loopback redirect,
tokens in the Keychain behind a protocol), Google Library and Picker REST
clients, the sync state store, and a transfer engine with retry/backoff and
progress reporting.

### Takeout sidecar matching

`TakeoutScanner` accepts any folder that contains an extracted export: a
single album, `Google Photos`, `Takeout`, or a parent folder with several
archive parts. Folders with the same name are merged, because split exports
can put an album's media and its sidecars in different parts.
`SidecarMatcher` handles:

- `IMG.jpg.json` and the newer `IMG.jpg.supplemental-metadata.json`, including
  truncated suffixes (`IMG.jpg.supplemental-met.json`, `IMG.jpg.supp.json`)
- long file names truncated as a whole
- duplicate numbering: `IMG(1).jpg` ↔ `IMG.jpg(1).json`
- edited copies (`IMG-edited.jpg`, localized, e.g. `-bearbeitet`), which share
  the original's sidecar and are grouped with it
- sidecars without the media extension (`IMG.json`)
- the sidecar's `title` (original file name) as a last resort

The scanner also pairs Live Photos (`IMG_1234.HEIC` + `IMG_1234.MOV`), reads
the album title from `metadata.json` (or a localized name such as
`Metadaten.json`), and tags year folders (`Photos from 2019`,
`Fotos von 2019`, …), Archive and Trash so they can be kept apart from real
albums.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6)

## Building

```bash
swift test --package-path PhotoSyncCore
```

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Debug -derivedDataPath build/DerivedData build
```

Or open `PhotoSync.xcodeproj` in Xcode and run the `PhotoSync` scheme.
The project signs ad hoc ("Sign to Run Locally"). Set your own development
team under *Signing & Capabilities* so macOS remembers the Photos permission
between builds.

The app is sandboxed with these entitlements: Photos library, read-only
access to user-selected files (the Takeout folder), and outgoing network
connections.

## Google Cloud setup

Needed for the Google features (roadmap step 4 onward):

1. Create a project in the [Google Cloud console](https://console.cloud.google.com/).
2. Enable the **Photos Library API** and the **Photos Picker API**.
3. Configure the **OAuth consent screen** (External, testing mode) and add
   your Google account as a test user.
4. Create an **OAuth client ID** of type **Desktop app**.
5. Put the client ID in a local, git-ignored config file (details follow with
   the OAuth implementation).

## Roadmap

- [x] Scaffold the package, app and README
- [x] Takeout scanner and sidecar matcher, with unit tests
- [x] PhotoKit album listing in the UI (albums, folders, Shared Albums)
- [ ] Google OAuth and Apple → Google album transfer
- [ ] Takeout → Apple import
- [ ] Picker API import
- [ ] Incremental sync and polish

## License

Apache 2.0, see [LICENSE](LICENSE).
