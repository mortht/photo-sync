import Testing
@testable import PhotoSyncCore

@Suite struct SidecarMatcherTests {
    private func match(_ media: [String], _ sidecars: [String], titles: [String: String] = [:]) -> SidecarMatcher.Result {
        SidecarMatcher.match(
            mediaNames: media,
            sidecars: sidecars.map { .init(name: $0, title: titles[$0]) }
        )
    }

    @Test func exactName() {
        let result = match(["IMG_0001.jpg"], ["IMG_0001.jpg.json"])
        #expect(result.sidecarByMedia == ["IMG_0001.jpg": "IMG_0001.jpg.json"])
        #expect(result.unmatchedSidecars.isEmpty)
    }

    @Test func caseInsensitive() {
        let result = match(["IMG_0001.JPG"], ["IMG_0001.jpg.json"])
        #expect(result.sidecarByMedia["IMG_0001.JPG"] == "IMG_0001.jpg.json")
    }

    @Test(arguments: [
        "IMG_0001.jpg.supplemental-metadata.json",
        "IMG_0001.jpg.supplemental-metad.json",
        "IMG_0001.jpg.supp.json",
        "IMG_0001.jpg.s.json",
        "IMG_0001.jpg..json",
    ])
    func supplementalMetadata(sidecar: String) {
        let result = match(["IMG_0001.jpg"], [sidecar])
        #expect(result.sidecarByMedia["IMG_0001.jpg"] == sidecar)
    }

    @Test func truncatedLongName() {
        let media = "Screenshot_20200101-123456_Some Very Long App Name.png"
        let sidecar = "Screenshot_20200101-123456_Some Very Long Ap.json"
        let result = match([media], [sidecar])
        #expect(result.sidecarByMedia[media] == sidecar)
    }

    @Test func duplicateNumberMovesAfterExtension() {
        let result = match(
            ["IMG.jpg", "IMG(1).jpg", "IMG(2).jpg"],
            ["IMG.jpg.json", "IMG.jpg(1).json", "IMG.jpg.supplemental-metadata(2).json"]
        )
        #expect(result.sidecarByMedia == [
            "IMG.jpg": "IMG.jpg.json",
            "IMG(1).jpg": "IMG.jpg(1).json",
            "IMG(2).jpg": "IMG.jpg.supplemental-metadata(2).json",
        ])
    }

    @Test func literalParenthesesInName() {
        let result = match(["Party (1).jpg"], ["Party (1).jpg.json"])
        #expect(result.sidecarByMedia["Party (1).jpg"] == "Party (1).jpg.json")
    }

    @Test(arguments: ["IMG-edited.jpg", "IMG-bearbeitet.jpg", "IMG-modifié.jpg"])
    func editedCopySharesOriginalSidecar(edited: String) {
        let result = match(["IMG.jpg", edited], ["IMG.jpg.json"])
        #expect(result.sidecarByMedia["IMG.jpg"] == "IMG.jpg.json")
        #expect(result.sidecarByMedia[edited] == "IMG.jpg.json")
    }

    @Test func editedCopyWithoutOriginal() {
        let result = match(["IMG-edited.jpg"], ["IMG.jpg.supplemental-metadata.json"])
        #expect(result.sidecarByMedia["IMG-edited.jpg"] == "IMG.jpg.supplemental-metadata.json")
    }

    @Test func truncatedNameWithEditedCopy() {
        let original = "Screenshot_20200101-123456_Some Very Long App Name.png"
        let edited = "Screenshot_20200101-123456_Some Very Long App Name-edited.png"
        let sidecar = "Screenshot_20200101-123456_Some Very Long Ap.json"
        let result = match([original, edited], [sidecar])
        #expect(result.sidecarByMedia[original] == sidecar)
        #expect(result.sidecarByMedia[edited] == sidecar)
    }

    @Test func sidecarWithoutMediaExtension() {
        let result = match(["IMG_0001.jpg"], ["IMG_0001.json"])
        #expect(result.sidecarByMedia["IMG_0001.jpg"] == "IMG_0001.json")
    }

    @Test func titleFallback() {
        let result = match(["holiday photo.jpg"], ["weird name.json"], titles: ["weird name.json": "Holiday Photo.jpg"])
        #expect(result.sidecarByMedia["holiday photo.jpg"] == "weird name.json")
        #expect(result.unmatchedSidecars.isEmpty)
    }

    @Test func unmatchedSidecarsAreReported() {
        let result = match(["A.jpg"], ["A.jpg.json", "B.jpg.json"])
        #expect(result.sidecarByMedia == ["A.jpg": "A.jpg.json"])
        #expect(result.unmatchedSidecars == ["B.jpg.json"])
    }

    @Test func secondSidecarForSameMediaIsUnmatched() {
        let result = match(["A.jpg"], ["A.jpg.json", "A.jpg.supplemental-metadata.json"])
        #expect(result.sidecarByMedia["A.jpg"] == "A.jpg.json")
        #expect(result.unmatchedSidecars == ["A.jpg.supplemental-metadata.json"])
    }

    @Test func nameHelpers() {
        #expect(SidecarMatcher.splitExtension("IMG.jpg") == ("IMG", ".jpg"))
        #expect(SidecarMatcher.splitExtension("noext") == ("noext", ""))
        #expect(SidecarMatcher.splitExtension(".hidden") == (".hidden", ""))
        #expect(SidecarMatcher.splitDuplicate("IMG(12)")! == ("IMG", 12))
        #expect(SidecarMatcher.splitDuplicate("IMG()") == nil)
        #expect(SidecarMatcher.splitDuplicate("(1)") == nil)
        #expect(SidecarMatcher.originalName(forEdited: "IMG-EDITED.JPG") == "IMG.JPG")
        #expect(SidecarMatcher.originalName(forEdited: "-edited.jpg") == nil)
    }
}
