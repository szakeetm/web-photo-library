import Testing
import Foundation
@testable import PhotoCore

@Suite struct SidecarLocatorTests {
    func find(_ image: String, _ entries: [String]) -> String? {
        SidecarLocator.sidecar(for: image, in: Set(entries + [image]))
    }

    @Test func plain() { #expect(find("IMG_1.jpg", ["IMG_1.jpg.json"]) == "IMG_1.jpg.json") }
    @Test func supplemental() {
        #expect(find("IMG_1.jpg", ["IMG_1.jpg.supplemental-metadata.json"]) == "IMG_1.jpg.supplemental-metadata.json")
    }
    @Test func truncatedSupplemental() {
        #expect(find("IMG_1.jpg", ["IMG_1.jpg.supplemental-metad.json"]) == "IMG_1.jpg.supplemental-metad.json")
    }
    @Test func duplicateCounter() {
        #expect(find("IMG_1(1).jpg", ["IMG_1.jpg(1).json", "IMG_1.jpg.json"]) == "IMG_1.jpg(1).json")
    }
    @Test func duplicateCounterSupplemental() {
        #expect(find("IMG_1(2).jpg", ["IMG_1.jpg.supplemental-metadata(2).json"]) == "IMG_1.jpg.supplemental-metadata(2).json")
    }
    @Test func editedUsesOriginal() {
        #expect(find("IMG_1-edited.jpg", ["IMG_1.jpg.json"]) == "IMG_1.jpg.json")
        #expect(find("IMG_1-bearbeitet.jpg", ["IMG_1.jpg.json"]) == "IMG_1.jpg.json")
    }
    @Test func longNameTruncated() {
        let image = "PXL_20210704_153000123.PORTRAIT.ORIGINAL_EXTRA_LONG.jpg"  // 55 chars
        let json = String(image.prefix(46)) + ".json"
        #expect(find(image, [json]) == json)
    }
    @Test func nfdImageNfcJson() {
        let nfc = "Ároktő.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(find(nfd, [nfc + ".json"]) == nfc + ".json")
    }
    @Test func noMatch() { #expect(find("IMG_1.jpg", ["IMG_2.jpg.json", "metadata.json"]) == nil) }
    @Test func ambiguousTruncationIsNil() {
        let image = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij_one.jpg"
        let a = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij_o.json"
        let b = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij_.json"
        #expect(find(image, [a, b]) == nil)
    }
}

@Suite struct SidecarParserTests {
    func parse(_ s: String) -> SidecarData? { SidecarParser.parse(Data(s.utf8)) }

    @Test func takenTime() {
        let d = parse(#"{"photoTakenTime":{"timestamp":"1625405400","formatted":"x"}}"#)
        #expect(d?.takenAt == ISO8601DateFormatter().date(from: "2021-07-04T13:30:00Z"))
    }
    @Test func geoFallsBackToExifGeo() {
        let d = parse(#"{"geoData":{"latitude":0.0,"longitude":0.0},"geoDataExif":{"latitude":47.5,"longitude":19.04}}"#)
        #expect(d?.lat == 47.5 && d?.lon == 19.04)
    }
    @Test func zeroGeoIsNil() {
        let d = parse(#"{"geoData":{"latitude":0.0,"longitude":0.0},"geoDataExif":{"latitude":0.0,"longitude":0.0}}"#)
        #expect(d != nil && d?.lat == nil && d?.lon == nil)
    }
    @Test func favoritedAndDescription() {
        let d = parse(#"{"favorited":true,"description":"Lake"}"#)
        #expect(d?.favorited == true && d?.description == "Lake")
    }
    @Test func emptyDescriptionIsNil() { #expect(parse(#"{"description":""}"#)?.description == nil) }
    @Test func invalidJSONIsNil() { #expect(parse("nope") == nil) }
}
