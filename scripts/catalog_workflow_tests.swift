#!/usr/bin/env swift

import Foundation

struct CatalogWorkflowFailure: Error, CustomStringConvertible {
    let description: String
}

func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
    if lhs != rhs {
        throw CatalogWorkflowFailure(description: "\(message). Expected \(rhs), got \(lhs)")
    }
}

func assertTrue(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw CatalogWorkflowFailure(description: message)
    }
}

enum Source: String {
    case applePhotos
    case amazonPhotos
}

enum Action: String {
    case uploadToAmazon
    case importToApplePhotos
}

enum Status: String {
    case proposed
    case approved
    case running
    case completed
    case failed
    case skipped
}

struct AssetRecord {
    let source: Source
    let id: String
    let filename: String
    let contentHash: String?
    let width: Int
    let height: Int
    let captureDate: Date?

    var exactKey: String? {
        contentHash.map { "content:\($0)" }
    }

    var dimensionBucket: String {
        "\(width)x\(height)"
    }
}

struct PlannedSyncItem {
    let action: Action
    let source: Source
    let id: String

    var identifier: String {
        "sync:\(action.rawValue):\(source.rawValue):\(id)"
    }
}

struct ExistingSyncItem {
    let identifier: String
    var status: Status
    var reason: String
    var errorMessage: String?
}

func makeCrossLibraryMatches(local: [AssetRecord], amazon: [AssetRecord]) -> [(String, String)] {
    var amazonByExactKey: [String: [AssetRecord]] = [:]
    for record in amazon {
        guard let key = record.exactKey else { continue }
        amazonByExactKey[key, default: []].append(record)
    }

    var matches: [(String, String)] = []
    for localRecord in local {
        guard let key = localRecord.exactKey,
              var candidates = amazonByExactKey[key],
              let amazonRecord = candidates.popLast() else {
            continue
        }
        amazonByExactKey[key] = candidates
        matches.append((localRecord.id, amazonRecord.id))
    }
    return matches
}

func makeSyncPlan(local: [AssetRecord], amazon: [AssetRecord]) -> [PlannedSyncItem] {
    let matches = makeCrossLibraryMatches(local: local, amazon: amazon)
    let matchedLocal = Set(matches.map(\.0))
    let matchedAmazon = Set(matches.map(\.1))

    let uploads = local
        .filter { !matchedLocal.contains($0.id) }
        .map { PlannedSyncItem(action: .uploadToAmazon, source: .applePhotos, id: $0.id) }
    let imports = amazon
        .filter { !matchedAmazon.contains($0.id) }
        .map { PlannedSyncItem(action: .importToApplePhotos, source: .amazonPhotos, id: $0.id) }
    return uploads + imports
}

func reconcile(existing: [ExistingSyncItem], planned: [PlannedSyncItem]) -> [ExistingSyncItem] {
    let plannedIdentifiers = Set(planned.map(\.identifier))
    return existing.map { item in
        var item = item
        if item.status == .running {
            item.status = .failed
            item.errorMessage = "Interrupted before completion. Review and retry if this action is still needed."
        }

        if !plannedIdentifiers.contains(item.identifier) {
            switch item.status {
            case .proposed, .approved, .failed:
                item.status = .completed
                item.reason = "No longer needed after comparison reconciliation."
                item.errorMessage = nil
            case .running, .completed, .skipped:
                break
            }
        }
        return item
    }
}

func searchMatches(
    filename: String,
    sourceIdentifier: String,
    labels: String?,
    ocrText: String?,
    ownerId: String?,
    parents: String?,
    query: String
) -> Bool {
    let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    var freeText: [String] = []

    for token in tokens {
        if token == "has:text" {
            guard let ocrText, !ocrText.isEmpty else { return false }
        } else if token == "has:labels" {
            guard let labels, !labels.isEmpty else { return false }
        } else if token.hasPrefix("label:") {
            let value = String(token.dropFirst("label:".count))
            guard labels?.localizedCaseInsensitiveContains(value) == true else { return false }
        } else if token.hasPrefix("text:") {
            let value = String(token.dropFirst("text:".count))
            guard ocrText?.localizedCaseInsensitiveContains(value) == true else { return false }
        } else if token.hasPrefix("owner:") {
            let value = String(token.dropFirst("owner:".count))
            guard ownerId?.localizedCaseInsensitiveContains(value) == true else { return false }
        } else if token.hasPrefix("parent:") {
            let value = String(token.dropFirst("parent:".count))
            guard parents?.localizedCaseInsensitiveContains(value) == true else { return false }
        } else {
            freeText.append(token)
        }
    }

    let haystack = [filename, sourceIdentifier, labels, ocrText, ownerId, parents]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    return freeText.isEmpty || haystack.contains(freeText.joined(separator: " "))
}

func runTests() throws {
    let now = Date()
    let local = [
        AssetRecord(source: .applePhotos, id: "local-1", filename: "IMG_0001.JPG", contentHash: "hash-a", width: 4032, height: 3024, captureDate: now),
        AssetRecord(source: .applePhotos, id: "local-2", filename: "IMG_0002.JPG", contentHash: "hash-b", width: 4032, height: 3024, captureDate: now)
    ]
    let amazon = [
        AssetRecord(source: .amazonPhotos, id: "amazon-1", filename: "IMG_0001.JPG", contentHash: "hash-a", width: 4032, height: 3024, captureDate: now),
        AssetRecord(source: .amazonPhotos, id: "amazon-2", filename: "IMG_0003.JPG", contentHash: "hash-c", width: 4032, height: 3024, captureDate: now)
    ]

    let planned = makeSyncPlan(local: local, amazon: amazon)
    try assertEqual(Set(planned.map(\.identifier)), Set([
        "sync:uploadToAmazon:applePhotos:local-2",
        "sync:importToApplePhotos:amazonPhotos:amazon-2"
    ]), "Sync plan should only include assets missing from the opposite library")

    let existing = [
        ExistingSyncItem(identifier: "sync:uploadToAmazon:applePhotos:local-2", status: .approved, reason: "Still missing", errorMessage: nil),
        ExistingSyncItem(identifier: "sync:importToApplePhotos:amazonPhotos:amazon-2", status: .skipped, reason: "User skipped", errorMessage: nil),
        ExistingSyncItem(identifier: "sync:uploadToAmazon:applePhotos:old-local", status: .proposed, reason: "Old proposal", errorMessage: nil),
        ExistingSyncItem(identifier: "sync:importToApplePhotos:amazonPhotos:stalled", status: .running, reason: "Interrupted", errorMessage: nil)
    ]
    let reconciled = reconcile(existing: existing, planned: planned)
    let byID = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.identifier, $0) })

    try assertEqual(byID["sync:uploadToAmazon:applePhotos:local-2"]?.status, .approved, "Approved planned work should stay approved")
    try assertEqual(byID["sync:importToApplePhotos:amazonPhotos:amazon-2"]?.status, .skipped, "Skipped planned work should stay skipped")
    try assertEqual(byID["sync:uploadToAmazon:applePhotos:old-local"]?.status, .completed, "Stale proposed work should be reconciled closed")
    try assertEqual(byID["sync:importToApplePhotos:amazonPhotos:stalled"]?.status, .completed, "Stale interrupted work should close when no longer planned")

    try assertTrue(
        searchMatches(
            filename: "receipt.jpg",
            sourceIdentifier: "node-1",
            labels: "dog|0.91\nsofa|0.88",
            ocrText: "Total due 42.00",
            ownerId: "owner-abc",
            parents: "vacation/shared",
            query: "has:text label:dog owner:abc parent:shared"
        ),
        "Search tokens should match AI and Amazon metadata"
    )
    try assertTrue(
        !searchMatches(
            filename: "receipt.jpg",
            sourceIdentifier: "node-1",
            labels: "dog|0.91",
            ocrText: nil,
            ownerId: "owner-abc",
            parents: "vacation/shared",
            query: "has:text label:dog"
        ),
        "Required search tokens should reject missing fields"
    )
}

do {
    try runTests()
    print("PASS catalog_workflow_tests")
} catch {
    fputs("FAIL catalog_workflow_tests: \(error)\n", stderr)
    exit(1)
}
