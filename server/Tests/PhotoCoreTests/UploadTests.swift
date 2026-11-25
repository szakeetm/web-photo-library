import Testing
import Foundation
@testable import PhotoCore

@Suite struct UploadTests {
    func incomingFiles(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".incoming").path)) ?? []
    }

    @Test func receiveHashesWhileWriting() throws {
        let root = Fixtures.tempDir()
        let s = try UploadSession(uploadsRoot: root)
        try s.write(Data("ab".utf8))
        try s.write(Data("c".utf8))
        let r = try s.finish()
        #expect(r.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" && r.size == 3)
        #expect(try Data(contentsOf: r.tempURL) == Data("abc".utf8))
    }

    @Test func abortLeavesNothingBehind() throws {
        let root = Fixtures.tempDir()
        let s = try UploadSession(uploadsRoot: root)
        try s.write(Data(repeating: 1, count: 1000))
        s.abort()
        #expect(incomingFiles(root).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [".incoming"])
    }

    @Test func sizeLimitEnforced() throws {
        let s = try UploadSession(uploadsRoot: Fixtures.tempDir(), maxBytes: 10)
        #expect(throws: UploadError.tooLarge) { try s.write(Data(repeating: 0, count: 11)) }
    }

    @Test func placementByCaptureMonthWithUniqueNames() throws {
        let root = Fixtures.tempDir()
        func place(_ name: String, _ bytes: String) throws -> String {
            let s = try UploadSession(uploadsRoot: root)
            try s.write(Data(bytes.utf8))
            let r = try s.finish()
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let when = cal.date(from: DateComponents(year: 2024, month: 7, day: 31, hour: 23))!
            return try UploadPlacer.place(temp: r.tempURL, uploadsRoot: root, source: .phone, name: name,
                                          takenAt: when, tzOffset: 7200)
        }
        #expect(try place("IMG_1.HEIC", "one") == "phone-uploads/2024-08/IMG_1.HEIC")
        #expect(try place("IMG_1.HEIC", "two") == "phone-uploads/2024-08/IMG_1 (2).HEIC")
        #expect(try place("../../evil/x.jpg", "three") == "phone-uploads/2024-08/x.jpg")
        #expect(try place(".hidden", "four") == "phone-uploads/2024-08/hidden")
        #expect(incomingFiles(root).isEmpty)
    }
}
