#!/usr/bin/env swift

import Foundation

struct IntegrationFailure: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) throws -> Never {
    throw IntegrationFailure(description: message)
}

struct FixtureAsset: Decodable {
    let id: String
    let contentHash: String
    let perceptualHashHex: String
    let embedding: [Float]
}

struct Fixture: Decodable {
    let assets: [FixtureAsset]
}

func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
    (lhs ^ rhs).nonzeroBitCount
}

func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
    var dot: Float = 0
    var lhsNorm: Float = 0
    var rhsNorm: Float = 0
    for index in lhs.indices {
        dot += lhs[index] * rhs[index]
        lhsNorm += lhs[index] * lhs[index]
        rhsNorm += rhs[index] * rhs[index]
    }
    let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
    if denominator == 0 {
        return 1
    }
    return 1 - (dot / denominator)
}

func exactGroups(_ assets: [FixtureAsset]) -> [[String]] {
    var map: [String: [String]] = [:]
    for asset in assets {
        map[asset.contentHash, default: []].append(asset.id)
    }
    return map.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0.count > $1.count }
}

func nearGroups(_ assets: [FixtureAsset], threshold: Int) -> [[String]] {
    let parsed: [(id: String, hash: UInt64)] = assets.compactMap { asset in
        guard let hash = UInt64(asset.perceptualHashHex, radix: 16) else { return nil }
        return (asset.id, hash)
    }

    var results: [[String]] = []
    var visited = Set<String>()

    for lhs in parsed {
        if visited.contains(lhs.id) { continue }
        var cluster: [String] = [lhs.id]
        for rhs in parsed where rhs.id != lhs.id {
            if hammingDistance(lhs.hash, rhs.hash) <= threshold {
                cluster.append(rhs.id)
            }
        }
        if cluster.count > 1 {
            let unique = Array(Set(cluster)).sorted()
            unique.forEach { visited.insert($0) }
            results.append(unique)
        }
    }

    return results.sorted { $0.count > $1.count }
}

func similar(to seedID: String, assets: [FixtureAsset], topK: Int) -> [String] {
    guard let seed = assets.first(where: { $0.id == seedID }) else { return [] }
    let candidates = assets.filter { $0.id != seedID }
    let ranked = candidates
        .map { asset in
            (id: asset.id, distance: cosineDistance(seed.embedding, asset.embedding))
        }
        .sorted { $0.distance < $1.distance }
    return Array(ranked.prefix(topK).map(\.id))
}

let fixtureJSON = """
{
  "assets": [
    { "id": "img-1", "contentHash": "hash-a", "perceptualHashHex": "0000000000000000", "embedding": [1.0, 0.0, 0.0] },
    { "id": "img-2", "contentHash": "hash-a", "perceptualHashHex": "0000000000000001", "embedding": [0.9, 0.1, 0.0] },
    { "id": "img-3", "contentHash": "hash-b", "perceptualHashHex": "0000000000000003", "embedding": [0.8, 0.2, 0.0] },
    { "id": "img-4", "contentHash": "hash-c", "perceptualHashHex": "ffffffffffffffff", "embedding": [0.0, 1.0, 0.0] },
    { "id": "img-5", "contentHash": "hash-d", "perceptualHashHex": "fffffffffffffffe", "embedding": [0.0, 0.9, 0.1] }
  ]
}
"""

do {
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(fixtureJSON.utf8))

    let exact = exactGroups(fixture.assets)
    if exact != [["img-1", "img-2"]] {
        try fail("Exact grouping mismatch: \(exact)")
    }

    let near = nearGroups(fixture.assets, threshold: 2)
    let nearSet = Set(near.map { $0.joined(separator: ",") })
    let expectedNearSet: Set<String> = [
        "img-1,img-2,img-3",
        "img-4,img-5"
    ]
    if nearSet != expectedNearSet {
        try fail("Near grouping mismatch: \(near)")
    }

    let similarMatches = similar(to: "img-1", assets: fixture.assets, topK: 2)
    if similarMatches != ["img-2", "img-3"] {
        try fail("Similarity ranking mismatch: \(similarMatches)")
    }

    print("PASS similarity_integration_tests")
} catch {
    fputs("FAIL similarity_integration_tests: \(error)\n", stderr)
    exit(1)
}
