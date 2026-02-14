#!/usr/bin/env swift

import Foundation

struct UnitTestFailure: Error, CustomStringConvertible {
    let description: String
}

func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
    if lhs != rhs {
        throw UnitTestFailure(description: "\(message). Expected \(rhs), got \(lhs)")
    }
}

func assertTrue(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw UnitTestFailure(description: message)
    }
}

func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
    (lhs ^ rhs).nonzeroBitCount
}

func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
    precondition(lhs.count == rhs.count)
    var dot: Float = 0
    var lhsNorm: Float = 0
    var rhsNorm: Float = 0

    for index in lhs.indices {
        dot += lhs[index] * rhs[index]
        lhsNorm += lhs[index] * lhs[index]
        rhsNorm += rhs[index] * rhs[index]
    }

    if lhsNorm == 0 || rhsNorm == 0 {
        return 1
    }

    let cosineSimilarity = dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    return 1 - cosineSimilarity
}

func similarityScore(distance: Float) -> Double {
    1 / (1 + Double(distance))
}

struct NearAsset {
    let id: String
    let hash: UInt64
}

func clusterNear(_ assets: [NearAsset], threshold: Int) -> [[String]] {
    guard assets.count > 1 else { return [] }

    var parent = Array(0..<assets.count)
    var rank = Array(repeating: 0, count: assets.count)

    func find(_ index: Int, parent: inout [Int]) -> Int {
        if parent[index] == index { return index }
        parent[index] = find(parent[index], parent: &parent)
        return parent[index]
    }

    func union(_ lhs: Int, _ rhs: Int, parent: inout [Int], rank: inout [Int]) {
        let lhsRoot = find(lhs, parent: &parent)
        let rhsRoot = find(rhs, parent: &parent)
        if lhsRoot == rhsRoot { return }

        if rank[lhsRoot] < rank[rhsRoot] {
            parent[lhsRoot] = rhsRoot
        } else if rank[lhsRoot] > rank[rhsRoot] {
            parent[rhsRoot] = lhsRoot
        } else {
            parent[rhsRoot] = lhsRoot
            rank[lhsRoot] += 1
        }
    }

    for lhs in 0..<assets.count {
        for rhs in (lhs + 1)..<assets.count {
            if hammingDistance(assets[lhs].hash, assets[rhs].hash) <= threshold {
                union(lhs, rhs, parent: &parent, rank: &rank)
            }
        }
    }

    var groupsByRoot: [Int: [String]] = [:]
    for index in 0..<assets.count {
        let root = find(index, parent: &parent)
        groupsByRoot[root, default: []].append(assets[index].id)
    }

    return groupsByRoot.values
        .filter { $0.count > 1 }
        .map { $0.sorted() }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.joined(separator: ",") < rhs.joined(separator: ",")
            }
            return lhs.count > rhs.count
        }
}

func runTests() throws {
    try assertEqual(hammingDistance(0b0, 0b0), 0, "Hamming distance for same values failed")
    try assertEqual(hammingDistance(0b1010, 0b1001), 2, "Hamming distance for mixed bits failed")
    try assertEqual(hammingDistance(UInt64.max, 0), 64, "Hamming distance for inverted values failed")

    let identicalDistance = cosineDistance([1, 0, 0], [1, 0, 0])
    try assertTrue(abs(identicalDistance) < 0.0001, "Cosine distance should be zero for identical vectors")

    let orthogonalDistance = cosineDistance([1, 0], [0, 1])
    try assertTrue(abs(orthogonalDistance - 1) < 0.0001, "Cosine distance should be one for orthogonal vectors")

    try assertTrue(similarityScore(distance: 0) > similarityScore(distance: 0.8), "Similarity score should decrease as distance increases")

    let clusters = clusterNear(
        [
            .init(id: "a", hash: 0x0000_0000_0000_0000),
            .init(id: "b", hash: 0x0000_0000_0000_0001),
            .init(id: "c", hash: 0x0000_0000_0000_0003),
            .init(id: "d", hash: 0xFFFF_FFFF_FFFF_FFFF)
        ],
        threshold: 2
    )

    try assertEqual(clusters.count, 1, "Expected one near-duplicate cluster")
    try assertEqual(clusters[0], ["a", "b", "c"], "Near-duplicate cluster membership mismatch")
}

do {
    try runTests()
    print("PASS similarity_unit_tests")
} catch {
    fputs("FAIL similarity_unit_tests: \(error)\n", stderr)
    exit(1)
}
