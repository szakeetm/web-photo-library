import CoreGraphics
import Foundation
import GRDB
import Vision

/// Text in photos (signs, documents, screenshots), recognised on the Mac with Vision (built into
/// macOS: nothing is downloaded) and added to search. A fast pass looks at every photo; only photos
/// where it found text get the slower, accurate pass.
public final class TextService: Sendable {
    /// Bumped when recognition changes: older results are redone.
    public static let version = 1
    /// Longest text kept per photo.
    static let maxLength = 4000

    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// The recognised text, one line per line found ("" when there is none).
    public static func recognize(_ image: CGImage) throws -> String {
        let fast = try lines(image, level: .fast)
        // A couple of stray characters is usually texture, not text.
        guard fast.joined().filter({ $0.isLetter || $0.isNumber }).count >= 3 else { return "" }
        let accurate = try lines(image, level: .accurate)
        return String(accurate.joined(separator: "\n").prefix(maxLength))
    }

    static func lines(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        if level == .accurate { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let t = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    public func store(assetId: String, text: String) throws {
        try db.writer.write { d in
            if text.isEmpty {
                try d.execute(sql: "DELETE FROM asset_text WHERE assetId = ?", arguments: [assetId])
            } else {
                try d.execute(sql: "INSERT OR REPLACE INTO asset_text (assetId, text) VALUES (?, ?)", arguments: [assetId, text])
            }
            try d.execute(sql: "UPDATE asset SET textVersion = ? WHERE id = ?", arguments: [Self.version, assetId])
        }
    }

    static func text(_ d: Database, assetId: String) throws -> String? {
        try String.fetchOne(d, sql: "SELECT text FROM asset_text WHERE assetId = ?", arguments: [assetId])
    }
}
