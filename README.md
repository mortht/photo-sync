# photo-sync

A native macOS app (Swift + SwiftUI) that transfers and syncs whole photo
albums between **iCloud Photos** and **Google Photos**: connect both
accounts, browse albums on each side, and copy an album across.

> Status: early development, all roadmap steps working. It copies Apple
> Photos albums (including Shared Albums) to Google Photos, and imports
> Google albums into Apple Photos from a Takeout export or the Google Photos
> Picker. Copying an album again adds only its new items. See the
> [roadmap](#roadmap).

## Using the app

The window has two panes:

- **Apple Photos** (left): your albums, grouped into albums (with their
  folder path) and Shared Albums. Select one and choose *Copy to Google
  Photos…*, or use the context menu.
- **Google Takeout** (right): choose an extracted Takeout folder to list its
  albums, years, Archive and Trash. An orange ⚠️ marks albums where photos
  and metadata files couldn't all be matched (hover for counts). Select an
  album and choose *Copy to Apple Photos…*.

The toolbar connects or disconnects your Google account and opens *Pick
from Google Photos…*. Album rows that were synced before show a badge:
a green ✓ with the count when every item was copied, otherwise
`copied/total` (hover for the destination album and last sync time). Each
copy runs in a sheet with progress, a Stop button, and a list of failed
items at the end; failed and not-yet-reached items are retried on the next
run.

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
  no album information. A session allows up to 2000 items, `baseUrl`s are
  valid for 60 minutes, and `=d` downloads have their location removed.
  Whether shared albums can be picked from is not verified yet.
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
    Google/               OAuth (PKCE + loopback redirect), Keychain token store,
                          Photos Library and Picker API clients with retry/backoff
    Transfer/             Album uploader (export → upload → batchCreate),
                          Takeout and Picker importers, image metadata writer
    Sync/                 SQLite sync history, content hashing, per-direction coordinators
  Tests/PhotoSyncCoreTests/
PhotoSync/                macOS app (SwiftUI); file-system-synchronized group
  Apple/                  PhotoKit adapter, exporter, import destination, album pane
  Google/                 Google account model and toolbar control
  Takeout/                Takeout folder pane
  Transfer/               Transfer and import sheets and their models
  Shared/                 Shared views, sync badges, progress and sync-store helpers
PhotoSync.xcodeproj       App project, depends on the local PhotoSyncCore package
Config/                   Build settings, Info.plist keys, entitlements, OAuth secrets
```

### Apple → Google transfer

Sign-in uses the authorization-code flow with PKCE. A listener on
`127.0.0.1` with a random port receives the redirect, and the tokens are
stored in the login keychain. All scopes (including the Picker) are
requested up front so later features don't need new consent. Sign-in fails
if you untick the Photos permissions on the consent screen.

The first transfer of an album creates a Google album; later ones add to
it (see [Incremental sync](#incremental-sync)). For each new item the app
exports the current version from PhotoKit (edited if edited; Live Photos as
stills, iCloud-only originals are downloaded), uploads the bytes, and adds
uploaded items with `mediaItems:batchCreate` in batches of 50. Transient
errors (429, 5xx, network) are retried with exponential backoff, honoring
`Retry-After`, and a 401 triggers one token refresh. Failed items are listed
at the end rather than aborting the transfer. Uploads run one at a time.

### Takeout → Apple import

Select a scanned Takeout album and choose *Copy to Apple Photos…*. The
first import creates an Apple Photos album with the same name (you can
rename it in the sheet); later imports add to it. Items are added with
`PHAssetCreationRequest` in capture-date order. The importer restores:

- **capture date** (`photoTakenTime`), **location** and **favorite** from the sidecar
- **Live Photos** as photo + paired video. If Photos rejects the pair (the
  files' content identifiers don't match), both halves are imported
  separately and the item is listed under "Imported with notes".
- **edited copies**: the edited version (default), the original, or both
- **descriptions** as captions. PhotoKit can't set captions directly, so the
  description is written into a copy of the file as XMP `dc:description` /
  IPTC caption (lossless, JPEG/PNG/TIFF). ImageIO can't write HEIC metadata
  in place, so HEIC items with a description import without it, with a note.

### Google Photos Picker → Apple import

*Pick from Google Photos…* in the toolbar creates a Picker session and
opens the picker in your browser. After you confirm your selection, the
app lists the picked items and you name the Apple Photos album to import
them into. Items are downloaded (`=d` for photos, `=dv` for videos, which
Google delivers transcoded) and imported with their capture date. If a large
import runs close to the 60-minute `baseUrl` lifetime, items are listed
again to get fresh URLs. Videos that Google is still processing fail with a
note and can be picked again later.

Google strips location from Picker downloads and returns no descriptions,
so use Takeout when those matter. Sync history is kept per target album
name: picking the same items into an album with the same name again skips
them.

### Incremental sync

Every transfer is recorded in `sync.sqlite` in the app's Application Support
folder (inside the sandbox container,
`~/Library/Containers/com.mortht.PhotoSync/Data/Library/Application Support/PhotoSync/`):
each source album is linked to the album it was copied into, and each item
is recorded as soon as it reaches the destination, so a stopped or crashed
run resumes where it ended. The album rows show this history as badges.
When you copy the same album again, the sheet shows how many items were
copied before and:

- adds only the new items to the **same** destination album
- retries items that failed or weren't reached because the run was stopped
- recognizes a photo in a newer Takeout export by its SHA-256 even when
  Takeout named it differently (e.g. `IMG(1).jpg`)
- starts a fresh album if you deleted the earlier one, or if you choose
  *Copy into a new album instead*

Sync is one-way and additive: items you delete at the destination are not
copied again, and deletions at the source are not mirrored. If the sheet
can't check the history (for example while offline), it says so; items
copied before are still skipped once the run can reach the earlier album.

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
- sidecars without the media extension (`IMG.json`), including items uploaded
  without one (`3806.jpg` ↔ `3806.supplemental-metadata.json`)
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
The project signs ad hoc ("Sign to Run Locally"), so after a rebuild macOS
may ask again for Photos access and whether Photo Sync may use its keychain
item (choose *Always Allow*). Set your own development team under
*Signing & Capabilities* to keep these permissions between builds.

The core tests (`swift test`) cover the Takeout scanner and sidecar
matching, OAuth (including a real loopback redirect), the Library and
Picker clients, the uploader and importers, and the sync store. They use
fake HTTP clients and a fake photo library, so they need no network,
Google account or Photos access.

The app is sandboxed with these entitlements: Photos library, read-only
access to user-selected files (the Takeout folder), outgoing network
connections, and incoming connections for the OAuth loopback redirect.

## Google Cloud setup

Needed for everything that talks to Google (all features except listing
Apple albums and scanning Takeout):

1. Create a project in the [Google Cloud console](https://console.cloud.google.com/).
2. Enable the **Photos Library API** and the **Photos Picker API**.
3. Configure the **OAuth consent screen** (External, testing mode) and add
   your Google account as a test user.
4. Create an **OAuth client ID** of type **Desktop app**.
5. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`
   (git-ignored), fill in the client ID and client secret, and rebuild.
   Without it, the toolbar shows "Google Not Configured".

While the consent screen is in testing mode, Google expires refresh tokens
after 7 days, so you'll need to reconnect about once a week.

## Roadmap

- [x] Scaffold the package, app and README
- [x] Takeout scanner and sidecar matcher, with unit tests
- [x] PhotoKit album listing in the UI (albums, folders, Shared Albums)
- [x] Google OAuth and Apple → Google album transfer
- [x] Takeout → Apple import
- [x] Picker API import
- [x] Incremental sync

Possible next steps: upload several items in parallel, verify picking from
shared albums in the Picker, and recreate Live Photos from Picker motion
photos.

## License

Apache 2.0, see [LICENSE](LICENSE).
