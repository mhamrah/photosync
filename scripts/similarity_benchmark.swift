#!/usr/bin/env swift

import Foundation

func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
    (lhs ^ rhs).nonzeroBitCount
}

func randomHashes(count: Int) -> [UInt64] {
    var rng = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt64.random(in: UInt64.min...UInt64.max, using: &rng) }
}

func benchmarkPairwiseHamming(count: Int) -> (comparisons: Int, milliseconds: Double) {
    let hashes = randomHashes(count: count)
    var comparisons = 0
    var accumulator = 0
    let start = DispatchTime.now()

    for lhs in 0..<hashes.count {
        for rhs in (lhs + 1)..<hashes.count {
            accumulator += hammingDistance(hashes[lhs], hashes[rhs])
            comparisons += 1
        }
    }

    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    if accumulator == -1 {
        print("impossible")
    }
    return (comparisons, elapsed)
}

func benchmarkSort(count: Int) -> Double {
    var rng = SystemRandomNumberGenerator()
    let values = (0..<count).map { _ in Double.random(in: 0...1, using: &rng) }
    let start = DispatchTime.now()
    _ = values.sorted(by: >)
    return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

let sampleSizes = [500, 1000, 2000]

print("Similarity benchmark (synthetic)")
for size in sampleSizes {
    let hamming = benchmarkPairwiseHamming(count: size)
    let sortMillis = benchmarkSort(count: size * 5)
    print("size=\(size) pairwise=\(hamming.comparisons) comparisons hamming_ms=\(String(format: "%.2f", hamming.milliseconds)) sort_ms=\(String(format: "%.2f", sortMillis))")
}
