import Accelerate
import Foundation

/// Groups face embeddings (L2-normalised, so cosine similarity = dot product) for large libraries.
/// DBSCAN within chunks of `chunkSize` faces (similarities computed with BLAS, block by block),
/// then groups from different chunks whose centres match are merged, and faces left over in a
/// chunk join the merged group they match best. Work grows with faces × chunkSize, not faces².
/// A library that fits in one chunk gets plain DBSCAN.
enum FaceClustering {
    static let chunkSize = 4000

    /// Groups of indexes into `vectors` (any size; callers drop small ones).
    static func cluster(_ vectors: [[Float]], threshold: Float, minPoints: Int, chunkSize: Int = chunkSize) -> [[Int]] {
        let n = vectors.count
        guard n > 0, let dim = vectors.first?.count, dim > 0 else { return [] }
        var groups: [(members: [Int], chunk: Int)] = []
        var leftover: [Int] = []
        for (c, start) in stride(from: 0, to: n, by: chunkSize).enumerated() {
            let idx = Array(start..<min(n, start + chunkSize))
            let (found, noise) = dbscan(idx.map { vectors[$0] }, dim: dim, threshold: threshold, minPoints: minPoints)
            groups += found.map { (members: $0.map { idx[$0] }, chunk: c) }
            leftover += noise.map { idx[$0] }
        }
        guard n > chunkSize, !groups.isEmpty else { return groups.map(\.members) }

        // Merge groups of different chunks whose centres match.
        let centres = groups.map { centre(of: $0.members.map { vectors[$0] }, dim: dim) }
        var parent = Array(0..<groups.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        forEachPair(centres, centres, dim: dim, threshold: threshold, upperOnly: true) { i, j in
            if groups[i].chunk != groups[j].chunk { parent[find(i)] = find(j) }
        }
        var merged: [Int: [Int]] = [:]
        for (g, grp) in groups.enumerated() { merged[find(g), default: []] += grp.members }
        var result = Array(merged.values)

        // Leftover faces join the merged group they match best.
        let mergedCentres = result.map { centre(of: $0.map { vectors[$0] }, dim: dim) }
        var best = [Int: (group: Int, score: Float)]()
        forEachPair(leftover.map { vectors[$0] }, mergedCentres, dim: dim, threshold: threshold, upperOnly: false) { i, g in
            let s = dot(vectors[leftover[i]], mergedCentres[g])
            if s > (best[i]?.score ?? -1) { best[i] = (g, s) }
        }
        for (i, b) in best { result[b.group].append(leftover[i]) }
        return result
    }

    /// DBSCAN: groups and noise (indexes into `vs`).
    static func dbscan(_ vs: [[Float]], dim: Int, threshold: Float, minPoints: Int) -> (groups: [[Int]], noise: [Int]) {
        let n = vs.count
        var neighbours = [[Int]](repeating: [], count: n)
        forEachPair(vs, vs, dim: dim, threshold: threshold, upperOnly: true) { i, j in
            neighbours[i].append(j)
            neighbours[j].append(i)
        }
        var label = [Int](repeating: -1, count: n)
        var groups: [[Int]] = []
        for i in 0..<n where label[i] == -1 && neighbours[i].count + 1 >= minPoints {
            let c = groups.count
            var members = [i]
            label[i] = c
            var queue = neighbours[i]
            while let j = queue.popLast() {
                guard label[j] == -1 else { continue }
                label[j] = c
                members.append(j)
                if neighbours[j].count + 1 >= minPoints { queue.append(contentsOf: neighbours[j]) }
            }
            groups.append(members)
        }
        return (groups, (0..<n).filter { label[$0] == -1 })
    }

    /// Calls `body(i, j)` for every a[i]·b[j] ≥ threshold (with `upperOnly`, a == b and only i < j),
    /// computing similarities a block at a time with a matrix product.
    static func forEachPair(_ a: [[Float]], _ b: [[Float]], dim: Int, threshold: Float, upperOnly: Bool,
                            block: Int = 1024, _ body: (Int, Int) -> Void) {
        guard !a.isEmpty, !b.isEmpty else { return }
        let fa = a.flatMap { $0 }, fb = upperOnly ? fa : b.flatMap { $0 }
        var out = [Float](repeating: 0, count: block * block)
        for i0 in stride(from: 0, to: a.count, by: block) {
            let ni = min(block, a.count - i0)
            for j0 in stride(from: upperOnly ? i0 : 0, to: b.count, by: block) {
                let nj = min(block, b.count - j0)
                fa.withUnsafeBufferPointer { pa in
                    fb.withUnsafeBufferPointer { pb in
                        // out[ni × nj] = A[i0..] · B[j0..]ᵀ
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(ni), Int32(nj), Int32(dim), 1,
                                    pa.baseAddress! + i0 * dim, Int32(dim), pb.baseAddress! + j0 * dim, Int32(dim),
                                    0, &out, Int32(nj))
                    }
                }
                for i in 0..<ni {
                    let row = i * nj
                    for j in 0..<nj where out[row + j] >= threshold {
                        let gi = i0 + i, gj = j0 + j
                        if upperOnly && gj <= gi { continue }
                        body(gi, gj)
                    }
                }
            }
        }
    }

    static func centre(of vs: [[Float]], dim: Int) -> [Float] {
        var c = [Float](repeating: 0, count: dim)
        for v in vs { vDSP_vadd(c, 1, v, 1, &c, 1, vDSP_Length(dim)) }
        var norm: Float = 0
        vDSP_svesq(c, 1, &norm, vDSP_Length(dim))
        norm = norm.squareRoot()
        if norm > 0 { var s = 1 / norm; vDSP_vsmul(c, 1, &s, &c, 1, vDSP_Length(dim)) }
        return c
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }
}
