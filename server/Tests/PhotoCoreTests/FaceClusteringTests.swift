import Foundation
import Testing
@testable import PhotoCore

@Suite struct FaceClusteringTests {
    /// Unit vectors near `centre` (spread so neighbours pass the threshold).
    func faces(around centre: [Float], count: Int, noise: Float, rng: inout SystemRandomNumberGenerator) -> [[Float]] {
        (0..<count).map { _ in
            FaceService.normalized(centre.map { $0 + Float.random(in: -noise...noise, using: &rng) })
        }
    }

    @Test func chunksAreMergedIntoTheSamePeople() {
        var rng = SystemRandomNumberGenerator()
        let dim = 128
        let people = (0..<3).map { _ in FaceService.normalized((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }) }
        var vectors: [[Float]] = []
        var truth: [Int] = []
        for (p, c) in people.enumerated() {
            let f = faces(around: c, count: 300, noise: 0.05, rng: &rng)
            vectors += f
            truth += Array(repeating: p, count: f.count)
        }
        // shuffle so every chunk sees every person
        let order = Array(vectors.indices).shuffled(using: &rng)
        let shuffled = order.map { vectors[$0] }, labels = order.map { truth[$0] }

        let one = FaceClustering.cluster(shuffled, threshold: FaceService.clusterThreshold, minPoints: 3, chunkSize: 10_000)
        let chunked = FaceClustering.cluster(shuffled, threshold: FaceService.clusterThreshold, minPoints: 3, chunkSize: 100)
        for groups in [one, chunked] {
            let big = groups.filter { $0.count >= 3 }
            #expect(big.count == 3)
            for g in big { #expect(Set(g.map { labels[$0] }).count == 1) }  // never mixes people
            #expect(big.map(\.count).reduce(0, +) == shuffled.count)        // nobody left out
        }
    }

    @Test func blockedProductMatchesPlainDots() {
        var rng = SystemRandomNumberGenerator()
        let vs = (0..<50).map { _ in FaceService.normalized((0..<16).map { _ in Float.random(in: -1...1, using: &rng) }) }
        var viaBlas = Set<[Int]>()
        FaceClustering.forEachPair(vs, vs, dim: 16, threshold: 0.3, upperOnly: true, block: 7) { viaBlas.insert([$0, $1]) }
        var plain = Set<[Int]>()
        for i in 0..<vs.count { for j in (i + 1)..<vs.count where FaceService.dot(vs[i], vs[j]) >= 0.3 { plain.insert([i, j]) } }
        #expect(viaBlas == plain)
    }
}
