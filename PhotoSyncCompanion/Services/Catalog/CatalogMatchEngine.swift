import CoreData
import Foundation

struct CatalogMatchRunSummary: Equatable, Sendable {
    let totalLocal: Int
    let totalAmazon: Int
    let exactMatches: Int
    let likelyMatches: Int
    let localOnly: Int
    let amazonOnly: Int
    let duplicateClusterCount: Int
    let proposedSyncItemCount: Int
    let computedAt: Date
}

final class CatalogMatchEngine {
    private let persistenceController: PersistenceController
    private let metadataDateTolerance: TimeInterval = 120
    private let metadataDurationTolerance: TimeInterval = 2
    private let nearDuplicateHammingThreshold = 6

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    func refreshMatches() async throws -> CatalogMatchRunSummary {
        let context = persistenceController.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let metadataDateTolerance = self.metadataDateTolerance
        let metadataDurationTolerance = self.metadataDurationTolerance
        let nearDuplicateHammingThreshold = self.nearDuplicateHammingThreshold

        return try await context.perform {
            try Self.deleteGeneratedRecords(in: context)

            let records = try Self.fetchAssetRecords(in: context)
            let localRecords = records.filter { $0.source == .applePhotos }
            let amazonRecords = records.filter { $0.source == .amazonPhotos }

            let matches = Self.makeCrossLibraryMatches(
                localRecords: localRecords,
                amazonRecords: amazonRecords,
                metadataDateTolerance: metadataDateTolerance,
                metadataDurationTolerance: metadataDurationTolerance
            )

            for match in matches {
                try Self.upsert(match: match, in: context)
            }

            let clusters = Self.makeDuplicateClusters(
                records: records,
                nearDuplicateHammingThreshold: nearDuplicateHammingThreshold
            )
            for cluster in clusters {
                try Self.upsert(cluster: cluster, in: context)
            }

            let matchedLocal = Set(matches.map(\.localIdentifier))
            let matchedAmazon = Set(matches.map(\.amazonNodeId))
            let syncItems = Self.makeSyncPlanItems(
                localOnly: localRecords.filter { !matchedLocal.contains($0.sourceIdentifier) },
                amazonOnly: amazonRecords.filter { !matchedAmazon.contains($0.sourceIdentifier) }
            )
            let plannedSyncItemIdentifiers = Set(syncItems.map(Self.syncPlanIdentifier(for:)))
            try Self.reconcileSyncPlanItems(
                plannedIdentifiers: plannedSyncItemIdentifiers,
                in: context
            )

            for syncItem in syncItems {
                try Self.upsert(syncItem: syncItem, in: context)
            }

            if context.hasChanges {
                try context.save()
            }

            let exactMatches = matches.filter { $0.kind == .exact }.count
            let likelyMatches = matches.filter { $0.kind == .nearDuplicate || $0.kind == .semanticSimilar }.count
            return CatalogMatchRunSummary(
                totalLocal: localRecords.count,
                totalAmazon: amazonRecords.count,
                exactMatches: exactMatches,
                likelyMatches: likelyMatches,
                localOnly: syncItems.filter { $0.actionKind == .uploadToAmazon }.count,
                amazonOnly: syncItems.filter { $0.actionKind == .importToApplePhotos }.count,
                duplicateClusterCount: clusters.count,
                proposedSyncItemCount: syncItems.count,
                computedAt: Date()
            )
        }
    }

    private static func fetchAssetRecords(in context: NSManagedObjectContext) throws -> [AssetRecord] {
        let request: NSFetchRequest<AssetAnalysis> = AssetAnalysis.fetchRequest()
        request.fetchBatchSize = 1_000
        request.sortDescriptors = [
            NSSortDescriptor(key: "sourceRaw", ascending: true),
            NSSortDescriptor(key: "sourceIdentifier", ascending: true)
        ]

        return try context.fetch(request).map(AssetRecord.init(asset:))
    }

    private static func deleteGeneratedRecords(in context: NSManagedObjectContext) throws {
        for match in try context.fetch(CrossLibraryMatch.fetchRequest()) {
            context.delete(match)
        }

        for cluster in try context.fetch(DuplicateCluster.fetchRequest()) {
            context.delete(cluster)
        }
    }

    private static func makeCrossLibraryMatches(
        localRecords: [AssetRecord],
        amazonRecords: [AssetRecord],
        metadataDateTolerance: TimeInterval,
        metadataDurationTolerance: TimeInterval
    ) -> [PlannedCrossLibraryMatch] {
        var matches: [PlannedCrossLibraryMatch] = []
        var matchedLocal = Set<String>()
        var matchedAmazon = Set<String>()

        var amazonByExactKey: [String: [AssetRecord]] = [:]
        for amazonRecord in amazonRecords {
            guard let key = amazonRecord.exactKey else { continue }
            amazonByExactKey[key, default: []].append(amazonRecord)
        }

        for localRecord in localRecords {
            guard let key = localRecord.exactKey,
                  var candidates = amazonByExactKey[key],
                  let amazonRecord = candidates.popLast() else {
                continue
            }

            amazonByExactKey[key] = candidates
            matchedLocal.insert(localRecord.sourceIdentifier)
            matchedAmazon.insert(amazonRecord.sourceIdentifier)
            matches.append(
                PlannedCrossLibraryMatch(
                    localIdentifier: localRecord.sourceIdentifier,
                    amazonNodeId: amazonRecord.sourceIdentifier,
                    kind: .exact,
                    confidence: 1,
                    evidence: MatchEvidence(
                        contentHashMatched: true,
                        metadataMatched: localRecord.hasMetadataMatch(with: amazonRecord, dateTolerance: metadataDateTolerance, durationTolerance: metadataDurationTolerance),
                        perceptualDistance: nil,
                        featurePrintDistance: nil,
                        confidence: 1,
                        summary: "Exact hash match."
                    )
                )
            )
        }

        var amazonByDimension: [String: [AssetRecord]] = [:]
        for amazonRecord in amazonRecords where !matchedAmazon.contains(amazonRecord.sourceIdentifier) {
            amazonByDimension[amazonRecord.dimensionBucket, default: []].append(amazonRecord)
        }

        for localRecord in localRecords where !matchedLocal.contains(localRecord.sourceIdentifier) {
            var candidates = amazonByDimension[localRecord.dimensionBucket] ?? []
            guard let matchIndex = candidates.firstIndex(where: { candidate in
                !matchedAmazon.contains(candidate.sourceIdentifier)
                    && localRecord.hasMetadataMatch(
                        with: candidate,
                        dateTolerance: metadataDateTolerance,
                        durationTolerance: metadataDurationTolerance
                    )
            }) else {
                continue
            }

            let amazonRecord = candidates.remove(at: matchIndex)
            amazonByDimension[localRecord.dimensionBucket] = candidates
            matchedLocal.insert(localRecord.sourceIdentifier)
            matchedAmazon.insert(amazonRecord.sourceIdentifier)

            let confidence = localRecord.normalizedFilename == amazonRecord.normalizedFilename ? 0.92 : 0.82
            matches.append(
                PlannedCrossLibraryMatch(
                    localIdentifier: localRecord.sourceIdentifier,
                    amazonNodeId: amazonRecord.sourceIdentifier,
                    kind: .nearDuplicate,
                    confidence: confidence,
                    evidence: MatchEvidence(
                        contentHashMatched: false,
                        metadataMatched: true,
                        perceptualDistance: nil,
                        featurePrintDistance: nil,
                        confidence: confidence,
                        summary: "Dimensions, capture time, and duration are within tolerance."
                    )
                )
            )
        }

        return matches
    }

    private static func makeDuplicateClusters(
        records: [AssetRecord],
        nearDuplicateHammingThreshold: Int
    ) -> [PlannedDuplicateCluster] {
        var clusters: [PlannedDuplicateCluster] = []

        for source in AssetSource.allCases {
            let sourceRecords = records.filter { $0.source == source }
            clusters.append(contentsOf: makeExactDuplicateClusters(source: source, records: sourceRecords))
            clusters.append(
                contentsOf: makeNearDuplicateClusters(
                    source: source,
                    records: sourceRecords,
                    nearDuplicateHammingThreshold: nearDuplicateHammingThreshold
                )
            )
        }

        return clusters
    }

    private static func makeExactDuplicateClusters(
        source: AssetSource,
        records: [AssetRecord]
    ) -> [PlannedDuplicateCluster] {
        var recordsByKey: [String: [AssetRecord]] = [:]
        for record in records {
            guard let exactKey = record.exactKey else { continue }
            recordsByKey[exactKey, default: []].append(record)
        }

        return recordsByKey.compactMap { key, members in
            guard members.count > 1 else { return nil }
            let sortedMembers = members.sorted { $0.sourceIdentifier < $1.sourceIdentifier }
            return PlannedDuplicateCluster(
                source: source,
                kind: .exact,
                memberIdentifiers: sortedMembers.map(\.sourceIdentifier),
                keeperIdentifier: sortedMembers.first?.sourceIdentifier,
                confidence: 1,
                evidence: MatchEvidence(
                    contentHashMatched: true,
                    metadataMatched: false,
                    perceptualDistance: nil,
                    featurePrintDistance: nil,
                    confidence: 1,
                    summary: "Duplicate group with exact hash \(key)."
                )
            )
        }
    }

    private static func makeNearDuplicateClusters(
        source: AssetSource,
        records: [AssetRecord],
        nearDuplicateHammingThreshold: Int
    ) -> [PlannedDuplicateCluster] {
        let perceptualRecords = records.compactMap(PerceptualRecord.init(record:))
        guard perceptualRecords.count > 1 else { return [] }

        var unionFind = UnionFind(size: perceptualRecords.count)
        var shortestDistanceByPair: [String: Int] = [:]

        for lhsIndex in perceptualRecords.indices {
            for rhsIndex in (lhsIndex + 1)..<perceptualRecords.count {
                let distance = (perceptualRecords[lhsIndex].hash ^ perceptualRecords[rhsIndex].hash).nonzeroBitCount
                if distance <= nearDuplicateHammingThreshold {
                    unionFind.union(lhsIndex, rhsIndex)
                    shortestDistanceByPair["\(lhsIndex):\(rhsIndex)"] = distance
                }
            }
        }

        var groupsByRoot: [Int: [Int]] = [:]
        for index in perceptualRecords.indices {
            groupsByRoot[unionFind.find(index), default: []].append(index)
        }

        return groupsByRoot.values.compactMap { memberIndexes in
            guard memberIndexes.count > 1 else { return nil }
            let sortedIndexes = memberIndexes.sorted {
                perceptualRecords[$0].record.sourceIdentifier < perceptualRecords[$1].record.sourceIdentifier
            }

            let distances = pairDistances(indexes: sortedIndexes, distanceByPair: shortestDistanceByPair)
            let averageDistance = distances.isEmpty ? 0 : Double(distances.reduce(0, +)) / Double(distances.count)
            let confidence = max(0.65, 1 - (averageDistance / Double(max(1, nearDuplicateHammingThreshold))))
            let members = sortedIndexes.map { perceptualRecords[$0].record }

            return PlannedDuplicateCluster(
                source: source,
                kind: .nearDuplicate,
                memberIdentifiers: members.map(\.sourceIdentifier),
                keeperIdentifier: members.sorted(by: preferredKeeperSort).first?.sourceIdentifier,
                confidence: confidence,
                evidence: MatchEvidence(
                    contentHashMatched: false,
                    metadataMatched: false,
                    perceptualDistance: Int(averageDistance.rounded()),
                    featurePrintDistance: nil,
                    confidence: confidence,
                    summary: "Near-duplicate perceptual hash cluster."
                )
            )
        }
    }

    private static func pairDistances(indexes: [Int], distanceByPair: [String: Int]) -> [Int] {
        var distances: [Int] = []
        for lhsPosition in indexes.indices {
            for rhsPosition in indexes.index(after: lhsPosition)..<indexes.endIndex {
                let lhs = indexes[lhsPosition]
                let rhs = indexes[rhsPosition]
                let key = lhs < rhs ? "\(lhs):\(rhs)" : "\(rhs):\(lhs)"
                if let distance = distanceByPair[key] {
                    distances.append(distance)
                }
            }
        }
        return distances
    }

    private static func preferredKeeperSort(_ lhs: AssetRecord, _ rhs: AssetRecord) -> Bool {
        if lhs.isFavorite != rhs.isFavorite {
            return lhs.isFavorite
        }

        if lhs.longestEdge != rhs.longestEdge {
            return lhs.longestEdge > rhs.longestEdge
        }

        if lhs.fileSizeBytes != rhs.fileSizeBytes {
            return lhs.fileSizeBytes > rhs.fileSizeBytes
        }

        return lhs.sourceIdentifier < rhs.sourceIdentifier
    }

    private static func makeSyncPlanItems(
        localOnly: [AssetRecord],
        amazonOnly: [AssetRecord]
    ) -> [PlannedSyncPlanItem] {
        let uploads = localOnly.map { record in
            PlannedSyncPlanItem(
                actionKind: .uploadToAmazon,
                primarySource: .applePhotos,
                primaryIdentifier: record.sourceIdentifier,
                relatedSource: nil,
                relatedIdentifier: nil,
                reason: "Only found in Apple Photos."
            )
        }

        let imports = amazonOnly.map { record in
            PlannedSyncPlanItem(
                actionKind: .importToApplePhotos,
                primarySource: .amazonPhotos,
                primaryIdentifier: record.sourceIdentifier,
                relatedSource: nil,
                relatedIdentifier: nil,
                reason: "Only found in Amazon Photos."
            )
        }

        return uploads + imports
    }

    private static func upsert(match: PlannedCrossLibraryMatch, in context: NSManagedObjectContext) throws {
        let identifier = "cross:\(match.localIdentifier):\(match.amazonNodeId)"
        let request: NSFetchRequest<CrossLibraryMatch> = CrossLibraryMatch.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "matchIdentifier == %@", identifier)

        let now = Date()
        let managed = try context.fetch(request).first ?? CrossLibraryMatch(context: context)
        managed.matchIdentifier = identifier
        managed.localIdentifier = match.localIdentifier
        managed.amazonNodeId = match.amazonNodeId
        managed.kind = match.kind
        managed.confidence = match.confidence
        managed.evidenceJSON = try JSONEncoder().encode(match.evidence)
        managed.createdAt = managed.createdAt ?? now
        managed.updatedAt = now
    }

    private static func upsert(cluster: PlannedDuplicateCluster, in context: NSManagedObjectContext) throws {
        let identifier = "cluster:\(cluster.source.rawValue):\(cluster.kind.rawValue):\(cluster.memberIdentifiers.joined(separator: ","))"
        let request: NSFetchRequest<DuplicateCluster> = DuplicateCluster.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "clusterIdentifier == %@", identifier)

        let now = Date()
        let managed = try context.fetch(request).first ?? DuplicateCluster(context: context)
        managed.clusterIdentifier = identifier
        managed.source = cluster.source
        managed.kind = cluster.kind
        managed.memberIdentifiers = cluster.memberIdentifiers
        managed.keeperIdentifier = cluster.keeperIdentifier
        managed.confidence = cluster.confidence
        managed.evidenceJSON = try JSONEncoder().encode(cluster.evidence)
        managed.createdAt = managed.createdAt ?? now
        managed.updatedAt = now
    }

    private static func upsert(syncItem: PlannedSyncPlanItem, in context: NSManagedObjectContext) throws {
        let identifier = syncPlanIdentifier(for: syncItem)
        let request: NSFetchRequest<SyncPlanItem> = SyncPlanItem.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "itemIdentifier == %@", identifier)

        let now = Date()
        let existing = try context.fetch(request).first
        let managed = existing ?? SyncPlanItem(context: context)
        managed.itemIdentifier = identifier
        managed.actionKind = syncItem.actionKind
        if existing == nil {
            managed.status = .proposed
        }
        managed.primarySource = syncItem.primarySource
        managed.primaryIdentifier = syncItem.primaryIdentifier
        managed.relatedSource = syncItem.relatedSource
        managed.relatedIdentifier = syncItem.relatedIdentifier
        managed.reason = syncItem.reason
        if managed.status == .proposed || managed.status == .approved {
            managed.errorMessage = nil
            managed.completedAt = nil
        }
        managed.createdAt = managed.createdAt ?? now
        managed.updatedAt = now
    }

    private static func reconcileSyncPlanItems(
        plannedIdentifiers: Set<String>,
        in context: NSManagedObjectContext
    ) throws {
        let request: NSFetchRequest<SyncPlanItem> = SyncPlanItem.fetchRequest()
        let existingItems = try context.fetch(request)
        let now = Date()

        for item in existingItems {
            if item.status == .running {
                item.status = .failed
                item.errorMessage = "Interrupted before completion. Review and retry if this action is still needed."
                item.updatedAt = now
            }

            guard !plannedIdentifiers.contains(item.itemIdentifier) else {
                continue
            }

            switch item.status {
            case .proposed, .approved, .failed:
                item.status = .completed
                item.errorMessage = nil
                item.completedAt = now
                item.reason = "No longer needed after comparison reconciliation."
                item.updatedAt = now
            case .running, .completed, .skipped:
                break
            }
        }
    }

    private static func syncPlanIdentifier(for syncItem: PlannedSyncPlanItem) -> String {
        "sync:\(syncItem.actionKind.rawValue):\(syncItem.primarySource.rawValue):\(syncItem.primaryIdentifier)"
    }

    private struct AssetRecord: Sendable {
        let source: AssetSource
        let sourceIdentifier: String
        let normalizedFilename: String?
        let captureDate: Date?
        let pixelWidth: Int32
        let pixelHeight: Int32
        let duration: Double
        let fileSizeBytes: Int64
        let isFavorite: Bool
        let contentHash: String?
        let md5: String?
        let perceptualHash: String?

        init(asset: AssetAnalysis) {
            self.source = asset.source
            self.sourceIdentifier = asset.sourceIdentifier
            self.normalizedFilename = asset.normalizedFilename
            self.captureDate = asset.captureDate
            self.pixelWidth = asset.pixelWidth
            self.pixelHeight = asset.pixelHeight
            self.duration = asset.duration
            self.fileSizeBytes = asset.fileSizeBytes
            self.isFavorite = asset.isFavorite
            self.contentHash = asset.contentHash
            self.md5 = asset.md5
            self.perceptualHash = asset.perceptualHash
        }

        var exactKey: String? {
            if let md5, !md5.isEmpty {
                return "md5:\(md5)"
            }

            if let contentHash, !contentHash.isEmpty {
                return "content:\(contentHash)"
            }

            return nil
        }

        var dimensionBucket: String {
            "\(pixelWidth)x\(pixelHeight)"
        }

        var longestEdge: Int32 {
            max(pixelWidth, pixelHeight)
        }

        func hasMetadataMatch(
            with candidate: AssetRecord,
            dateTolerance: TimeInterval,
            durationTolerance: TimeInterval
        ) -> Bool {
            guard dimensionBucket == candidate.dimensionBucket else { return false }

            let durationMatches = abs(duration - candidate.duration) <= durationTolerance
            let dateMatches: Bool
            if let captureDate, let candidateDate = candidate.captureDate {
                dateMatches = abs(captureDate.timeIntervalSince(candidateDate)) <= dateTolerance
            } else {
                dateMatches = false
            }

            let filenameMatches = normalizedFilename != nil && normalizedFilename == candidate.normalizedFilename
            return dateMatches && (durationMatches || filenameMatches)
        }
    }

    private struct PerceptualRecord {
        let record: AssetRecord
        let hash: UInt64

        init?(record: AssetRecord) {
            guard let perceptualHash = record.perceptualHash,
                  let hash = UInt64(perceptualHash, radix: 16) else {
                return nil
            }

            self.record = record
            self.hash = hash
        }
    }

    private struct PlannedCrossLibraryMatch {
        let localIdentifier: String
        let amazonNodeId: String
        let kind: MatchKind
        let confidence: Double
        let evidence: MatchEvidence
    }

    private struct PlannedDuplicateCluster {
        let source: AssetSource
        let kind: MatchKind
        let memberIdentifiers: [String]
        let keeperIdentifier: String?
        let confidence: Double
        let evidence: MatchEvidence
    }

    private struct PlannedSyncPlanItem {
        let actionKind: SyncActionKind
        let primarySource: AssetSource
        let primaryIdentifier: String
        let relatedSource: AssetSource?
        let relatedIdentifier: String?
        let reason: String
    }
}

private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(size: Int) {
        parent = Array(0..<size)
        rank = Array(repeating: 0, count: size)
    }

    mutating func find(_ value: Int) -> Int {
        if parent[value] != value {
            parent[value] = find(parent[value])
        }
        return parent[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = find(lhs)
        let rhsRoot = find(rhs)
        guard lhsRoot != rhsRoot else { return }

        if rank[lhsRoot] < rank[rhsRoot] {
            parent[lhsRoot] = rhsRoot
        } else if rank[lhsRoot] > rank[rhsRoot] {
            parent[rhsRoot] = lhsRoot
        } else {
            parent[rhsRoot] = lhsRoot
            rank[lhsRoot] += 1
        }
    }
}
