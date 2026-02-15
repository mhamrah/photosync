import AppKit
import CryptoKit
import CoreData
import Foundation
import Photos
import Vision

@MainActor
final class PhotoLibraryIndexer: ObservableObject {
    enum State: Equatable {
        case idle
        case indexing(Progress)
        case completed(Completion)
        case failed(String)

        struct Progress: Equatable {
            let processed: Int
            let total: Int

            var fractionComplete: Double {
                guard total > 0 else { return 0 }
                return Double(processed) / Double(total)
            }
        }

        struct Completion: Equatable {
            let processed: Int
            let total: Int
            let completedAt: Date
        }
    }

    @Published private(set) var state: State = .idle

    private let persistenceController: PersistenceController
    private let batchSize = 200
    private var indexingTask: Task<Void, Never>?

    deinit {
        indexingTask?.cancel()
    }

    init(persistenceController: PersistenceController, initialState: State = .idle) {
        self.persistenceController = persistenceController
        self.state = initialState
    }

    func startIndexingIfNeeded(force: Bool = false) {
        if let indexingTask, !indexingTask.isCancelled {
            return
        }

        if !force {
            if case .indexing = state { return }
        }

        let authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            return
        }

        indexingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runIndexing()
        }
    }

    func cancelIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        state = .idle
    }

    private func runIndexing() async {
        do {
            try Task.checkCancellation()

            let fetchResult = PHAsset.fetchAssets(with: makeFetchOptions())
            let total = fetchResult.count

            await MainActor.run {
                self.state = .indexing(.init(processed: 0, total: total))
            }

            let backgroundContext = persistenceController.container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            backgroundContext.automaticallyMergesChangesFromParent = false

            var processed = 0

            while processed < total {
                try Task.checkCancellation()

                let remaining = total - processed
                let pageCount = min(batchSize, remaining)
                let rangeEnd = processed + pageCount
                let assets = (processed..<rangeEnd).map { fetchResult.object(at: $0) }
                let identifiers = assets.map(\.localIdentifier)

                try await backgroundContext.perform {
                    let fetchRequest: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "localIdentifier IN %@", identifiers)
                    fetchRequest.fetchBatchSize = self.batchSize

                    let existing = try backgroundContext.fetch(fetchRequest)
                    var existingByIdentifier = Dictionary(uniqueKeysWithValues: existing.map { ($0.localIdentifier, $0) })

                    for asset in assets {
                        let localAsset = existingByIdentifier[asset.localIdentifier] ?? LocalAsset(context: backgroundContext)
                        self.update(localAsset, with: asset)
                        existingByIdentifier[asset.localIdentifier] = localAsset
                    }

                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                        backgroundContext.reset()
                    }
                }

                processed += pageCount

                await MainActor.run {
                    self.state = .indexing(.init(processed: processed, total: max(total, processed)))
                }
            }

            await MainActor.run {
                self.state = .completed(.init(processed: processed, total: max(total, processed), completedAt: Date()))
                self.indexingTask = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                self.state = .idle
                self.indexingTask = nil
            }
        } catch {
            await MainActor.run {
                self.state = .failed(error.localizedDescription)
                self.indexingTask = nil
            }
        }
    }

    private func makeFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        return options
    }

    private nonisolated func update(_ localAsset: LocalAsset, with asset: PHAsset) {
        let previousModificationDate = localAsset.modificationDate
        let previousMediaTypeRaw = localAsset.mediaTypeRaw
        let nextMediaTypeRaw = Int16(asset.mediaType.rawValue)
        let resources = PHAssetResource.assetResources(for: asset)

        localAsset.localIdentifier = asset.localIdentifier
        localAsset.creationDate = asset.creationDate
        localAsset.modificationDate = asset.modificationDate
        localAsset.mediaTypeRaw = nextMediaTypeRaw
        localAsset.mediaSubtypesRaw = Int32(truncatingIfNeeded: asset.mediaSubtypes.rawValue)
        localAsset.duration = asset.duration
        localAsset.pixelWidth = Int32(asset.pixelWidth)
        localAsset.pixelHeight = Int32(asset.pixelHeight)
        localAsset.isFavorite = asset.isFavorite
        localAsset.hasAdjustments = assetHasAdjustments(asset)
        localAsset.hidden = asset.isHidden
        localAsset.burstIdentifier = asset.burstIdentifier
        localAsset.sourceTypeRaw = Int16(truncatingIfNeeded: asset.sourceType.rawValue)
        localAsset.originalFilename = resources.first?.originalFilename
        localAsset.fileSizeBytes = 0
        localAsset.md5 = nil

        if localAsset.localAddedDate == nil {
            localAsset.localAddedDate = Date()
        }

        localAsset.masterFingerprint = asset.localIdentifier
        if let modificationDate = asset.modificationDate {
            localAsset.variantFingerprint = "\(asset.localIdentifier)-\(modificationDate.timeIntervalSince1970)"
        } else {
            localAsset.variantFingerprint = nil
        }

        let isImage = nextMediaTypeRaw == Int16(PHAssetMediaType.image.rawValue)
        let needsAnalysisRefresh = localAsset.contentHash == nil
            || previousModificationDate != asset.modificationDate
            || previousMediaTypeRaw != nextMediaTypeRaw

        if isImage, needsAnalysisRefresh {
            localAsset.contentHash = nil
            localAsset.perceptualHash = nil
            localAsset.featureVector = nil
            localAsset.featureVersion = nil
            localAsset.analysisUpdatedAt = nil
            localAsset.analysisStatus = .pending
            localAsset.analysisErrorMessage = nil
            localAsset.analysisAttemptCount = 0
            localAsset.analysisNextRetryAt = nil
        }
    }

    private nonisolated func assetHasAdjustments(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { resource in
            resource.type == .adjustmentData
        }
    }
}

extension PhotoLibraryIndexer {
    static var previewIdle: PhotoLibraryIndexer {
        PhotoLibraryIndexer(persistenceController: .preview, initialState: .idle)
    }

    static var previewIndexing: PhotoLibraryIndexer {
        PhotoLibraryIndexer(
            persistenceController: .preview,
            initialState: .indexing(.init(processed: 120, total: 500))
        )
    }

    static var previewCompleted: PhotoLibraryIndexer {
        PhotoLibraryIndexer(
            persistenceController: .preview,
            initialState: .completed(.init(processed: 500, total: 500, completedAt: Date().addingTimeInterval(-3600)))
        )
    }

    static var previewFailed: PhotoLibraryIndexer {
        PhotoLibraryIndexer(
            persistenceController: .preview,
            initialState: .failed("Preview indexing failure")
        )
    }
}

struct SimilarityAssetRecord: Identifiable, Equatable {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let keepPreferred: Bool

    var id: String { localIdentifier }
    var longestEdge: Int { max(pixelWidth, pixelHeight) }
}

struct ExactDuplicateGroup: Identifiable, Equatable {
    let contentHash: String
    let assets: [SimilarityAssetRecord]

    var id: String { contentHash }
    var assetCount: Int { assets.count }
}

struct ExactDuplicateSummary: Equatable {
    let hashedAssetCount: Int
    let duplicateGroupCount: Int
    let assetsInDuplicateGroups: Int

    static let empty = ExactDuplicateSummary(
        hashedAssetCount: 0,
        duplicateGroupCount: 0,
        assetsInDuplicateGroups: 0
    )
}

struct NearDuplicateAsset: Identifiable, Equatable {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let keepPreferred: Bool
    let hammingDistanceFromSeed: Int
    let confidence: Double

    var id: String { localIdentifier }
}

struct NearDuplicateGroup: Identifiable, Equatable {
    let clusterID: String
    let seedIdentifier: String
    let averageDistance: Double
    let assets: [NearDuplicateAsset]

    var id: String { clusterID }
    var assetCount: Int { assets.count }
}

struct NearDuplicateSummary: Equatable {
    let hashedAssetCount: Int
    let duplicateGroupCount: Int
    let assetsInDuplicateGroups: Int

    static let empty = NearDuplicateSummary(
        hashedAssetCount: 0,
        duplicateGroupCount: 0,
        assetsInDuplicateGroups: 0
    )
}

struct SimilarAssetMatch: Identifiable, Equatable {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let keepPreferred: Bool
    let distance: Float
    let score: Double

    var id: String { localIdentifier }
}

struct SimilarityPagination: Equatable {
    let page: Int
    let pageSize: Int

    static let `default` = SimilarityPagination(page: 0, pageSize: 50)
}

enum SimilaritySortOrder: Equatable {
    case relevance
    case creationDateDescending
    case creationDateAscending
}

struct SimilaritySearchOptions: Equatable {
    var dateRange: ClosedRange<Date>?
    var minimumLongestEdge: Int?
    var sortOrder: SimilaritySortOrder
    var pagination: SimilarityPagination

    static let `default` = SimilaritySearchOptions(
        dateRange: nil,
        minimumLongestEdge: nil,
        sortOrder: .relevance,
        pagination: .default
    )
}

struct SimilarityPipelineSummary: Equatable {
    let exactSummary: ExactDuplicateSummary
    let nearSummary: NearDuplicateSummary
    let embeddedAssetCount: Int
}

final class SimilaritySearchService {
    private let persistenceController: PersistenceController

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    func fetchExactDuplicateGroups() async throws -> [ExactDuplicateGroup] {
        try await findExactDuplicateGroups()
    }

    func fetchExactDuplicateSummary() async throws -> ExactDuplicateSummary {
        try await findExactDuplicateSummary()
    }

    func findExactDuplicateGroups(
        options: SimilaritySearchOptions = .default
    ) async throws -> [ExactDuplicateGroup] {
        let backgroundContext = persistenceController.container.newBackgroundContext()

        let groups = try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "contentHash != nil")
            request.fetchBatchSize = 500

            let assets = try backgroundContext.fetch(request)
            var grouped: [String: [SimilarityAssetRecord]] = [:]
            grouped.reserveCapacity(assets.count)

            for asset in assets {
                guard let hash = asset.contentHash else { continue }
                grouped[hash, default: []].append(
                    SimilarityAssetRecord(
                        localIdentifier: asset.localIdentifier,
                        creationDate: asset.creationDate,
                        pixelWidth: Int(asset.pixelWidth),
                        pixelHeight: Int(asset.pixelHeight),
                        keepPreferred: asset.keepPreferred
                    )
                )
            }

            return grouped
                .compactMap { hash, records -> ExactDuplicateGroup? in
                    guard records.count > 1 else { return nil }
                    return ExactDuplicateGroup(
                        contentHash: hash,
                        assets: records.sorted { $0.localIdentifier < $1.localIdentifier }
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.assetCount == rhs.assetCount {
                        return lhs.contentHash < rhs.contentHash
                    }
                    return lhs.assetCount > rhs.assetCount
                }
        }

        return Self.paginate(groups, pagination: options.pagination)
    }

    func findExactDuplicateSummary() async throws -> ExactDuplicateSummary {
        let backgroundContext = persistenceController.container.newBackgroundContext()

        return try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "contentHash != nil")
            request.fetchBatchSize = 500

            let assets = try backgroundContext.fetch(request)
            var groupedCounts: [String: Int] = [:]
            groupedCounts.reserveCapacity(assets.count)

            for asset in assets {
                guard let hash = asset.contentHash else { continue }
                groupedCounts[hash, default: 0] += 1
            }

            let duplicateGroupCounts = groupedCounts.values.filter { $0 > 1 }
            let assetsInGroups = duplicateGroupCounts.reduce(0, +)

            return ExactDuplicateSummary(
                hashedAssetCount: assets.count,
                duplicateGroupCount: duplicateGroupCounts.count,
                assetsInDuplicateGroups: assetsInGroups
            )
        }
    }

    func findNearDuplicateGroups(
        maxDistance: Int = 6,
        options: SimilaritySearchOptions = .default
    ) async throws -> [NearDuplicateGroup] {
        let distanceThreshold = max(0, maxDistance)
        let backgroundContext = persistenceController.container.newBackgroundContext()

        let assets = try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "perceptualHash != nil")
            request.fetchBatchSize = 500
            return try backgroundContext.fetch(request).compactMap(PerceptualAsset.init)
        }

        guard assets.count > 1 else { return [] }

        var unionFind = UnionFind(size: assets.count)
        for lhsIndex in assets.indices {
            for rhsIndex in (lhsIndex + 1)..<assets.count {
                let distance = Self.hammingDistance(assets[lhsIndex].hash, assets[rhsIndex].hash)
                if distance <= distanceThreshold {
                    unionFind.union(lhsIndex, rhsIndex)
                }
            }
        }

        var groupsByRoot: [Int: [Int]] = [:]
        for index in assets.indices {
            groupsByRoot[unionFind.find(index), default: []].append(index)
        }

        var groups: [NearDuplicateGroup] = []
        for memberIndexes in groupsByRoot.values where memberIndexes.count > 1 {
            let sortedIndexes = memberIndexes.sorted { assets[$0].localIdentifier < assets[$1].localIdentifier }
            guard let seedIndex = sortedIndexes.first else { continue }
            let seedAsset = assets[seedIndex]

            var members: [NearDuplicateAsset] = []
            members.reserveCapacity(sortedIndexes.count)

            var distanceTotal = 0.0
            for index in sortedIndexes {
                let item = assets[index]
                let distance = index == seedIndex ? 0 : Self.hammingDistance(seedAsset.hash, item.hash)
                if index != seedIndex {
                    distanceTotal += Double(distance)
                }

                let denominator = Double(max(1, distanceThreshold))
                let confidence = max(0, min(1, 1 - (Double(distance) / denominator)))

                members.append(
                    NearDuplicateAsset(
                        localIdentifier: item.localIdentifier,
                        creationDate: item.creationDate,
                        pixelWidth: item.pixelWidth,
                        pixelHeight: item.pixelHeight,
                        keepPreferred: item.keepPreferred,
                        hammingDistanceFromSeed: distance,
                        confidence: confidence
                    )
                )
            }

            let averageDistance = distanceTotal / Double(max(1, sortedIndexes.count - 1))
            groups.append(
                NearDuplicateGroup(
                    clusterID: "\(seedAsset.localIdentifier)-\(sortedIndexes.count)",
                    seedIdentifier: seedAsset.localIdentifier,
                    averageDistance: averageDistance,
                    assets: members
                )
            )
        }

        groups.sort { lhs, rhs in
            if lhs.assetCount == rhs.assetCount {
                return lhs.averageDistance < rhs.averageDistance
            }
            return lhs.assetCount > rhs.assetCount
        }

        return Self.paginate(groups, pagination: options.pagination)
    }

    func findNearDuplicateSummary(maxDistance: Int = 6) async throws -> NearDuplicateSummary {
        let backgroundContext = persistenceController.container.newBackgroundContext()
        let hashedAssetCount = try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "perceptualHash != nil")
            return try backgroundContext.count(for: request)
        }

        let groups = try await findNearDuplicateGroups(
            maxDistance: maxDistance,
            options: .init(
                dateRange: nil,
                minimumLongestEdge: nil,
                sortOrder: .relevance,
                pagination: .init(page: 0, pageSize: Int.max)
            )
        )

        let assetsInDuplicateGroups = groups.reduce(0) { $0 + $1.assetCount }
        return NearDuplicateSummary(
            hashedAssetCount: hashedAssetCount,
            duplicateGroupCount: groups.count,
            assetsInDuplicateGroups: assetsInDuplicateGroups
        )
    }

    func findSimilarAssets(
        to localIdentifier: String,
        topK: Int,
        options: SimilaritySearchOptions = .default
    ) async throws -> [SimilarAssetMatch] {
        let backgroundContext = persistenceController.container.newBackgroundContext()

        let queryAndCandidates = try await backgroundContext.perform {
            let queryRequest: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            queryRequest.predicate = NSPredicate(
                format: "localIdentifier == %@ AND featureVector != nil",
                localIdentifier
            )
            queryRequest.fetchLimit = 1
            guard let queryAsset = try backgroundContext.fetch(queryRequest).first,
                  let queryVector = queryAsset.featureVector else {
                return (query: nil as FeatureAsset?, candidates: [FeatureAsset]())
            }

            let query = FeatureAsset(from: queryAsset, featureVector: queryVector)

            let candidateRequest: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            candidateRequest.predicate = NSPredicate(
                format: "featureVector != nil AND localIdentifier != %@",
                localIdentifier
            )
            candidateRequest.fetchBatchSize = 500
            let fetchedCandidates = try backgroundContext.fetch(candidateRequest)
            let filtered = fetchedCandidates.compactMap { item -> FeatureAsset? in
                guard let vector = item.featureVector else { return nil }

                if let dateRange = options.dateRange {
                    guard let creationDate = item.creationDate, dateRange.contains(creationDate) else { return nil }
                }

                if let minimumEdge = options.minimumLongestEdge {
                    let longestEdge = max(Int(item.pixelWidth), Int(item.pixelHeight))
                    guard longestEdge >= minimumEdge else { return nil }
                }

                return FeatureAsset(from: item, featureVector: vector)
            }

            return (query: query, candidates: filtered)
        }

        guard let queryAsset = queryAndCandidates.query else { return [] }
        let queryObservation = try Self.decodeFeaturePrint(from: queryAsset.featureVector)

        var matches: [SimilarAssetMatch] = []
        matches.reserveCapacity(queryAndCandidates.candidates.count)

        for candidate in queryAndCandidates.candidates {
            guard let candidateObservation = try? Self.decodeFeaturePrint(from: candidate.featureVector) else { continue }
            var distance: Float = 0
            try queryObservation.computeDistance(&distance, to: candidateObservation)

            let score = 1 / (1 + Double(distance))
            matches.append(
                SimilarAssetMatch(
                    localIdentifier: candidate.localIdentifier,
                    creationDate: candidate.creationDate,
                    pixelWidth: candidate.pixelWidth,
                    pixelHeight: candidate.pixelHeight,
                    keepPreferred: candidate.keepPreferred,
                    distance: distance,
                    score: score
                )
            )
        }

        matches = Self.sortSimilarMatches(matches, order: options.sortOrder)

        if topK > 0, matches.count > topK {
            matches = Array(matches.prefix(topK))
        }

        return Self.paginate(matches, pagination: options.pagination)
    }

    func countEmbeddedAssets() async throws -> Int {
        let backgroundContext = persistenceController.container.newBackgroundContext()

        return try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "featureVector != nil")
            return try backgroundContext.count(for: request)
        }
    }

    func fetchPipelineSummary(maxNearDistance: Int = 6) async throws -> SimilarityPipelineSummary {
        async let exactSummary = findExactDuplicateSummary()
        async let nearSummary = findNearDuplicateSummary(maxDistance: maxNearDistance)
        async let embeddedCount = countEmbeddedAssets()

        return try await SimilarityPipelineSummary(
            exactSummary: exactSummary,
            nearSummary: nearSummary,
            embeddedAssetCount: embeddedCount
        )
    }

    private static func decodeFeaturePrint(from data: Data) throws -> VNFeaturePrintObservation {
        guard let observation = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data
        ) else {
            throw SimilarityError.invalidFeatureVector
        }
        return observation
    }

    private static func sortSimilarMatches(
        _ matches: [SimilarAssetMatch],
        order: SimilaritySortOrder
    ) -> [SimilarAssetMatch] {
        switch order {
        case .relevance:
            return matches.sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.localIdentifier < rhs.localIdentifier
                }
                return lhs.score > rhs.score
            }
        case .creationDateDescending:
            return matches.sorted { lhs, rhs in
                let lhsDate = lhs.creationDate ?? .distantPast
                let rhsDate = rhs.creationDate ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.localIdentifier < rhs.localIdentifier
                }
                return lhsDate > rhsDate
            }
        case .creationDateAscending:
            return matches.sorted { lhs, rhs in
                let lhsDate = lhs.creationDate ?? .distantFuture
                let rhsDate = rhs.creationDate ?? .distantFuture
                if lhsDate == rhsDate {
                    return lhs.localIdentifier < rhs.localIdentifier
                }
                return lhsDate < rhsDate
            }
        }
    }

    private static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    private static func paginate<T>(_ values: [T], pagination: SimilarityPagination) -> [T] {
        guard !values.isEmpty else { return [] }
        let page = max(0, pagination.page)
        let pageSize = max(1, pagination.pageSize)
        let start = page * pageSize
        guard start < values.count else { return [] }
        let end = min(start + pageSize, values.count)
        return Array(values[start..<end])
    }

    private struct PerceptualAsset {
        let localIdentifier: String
        let creationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        let keepPreferred: Bool
        let hash: UInt64

        init?(_ asset: LocalAsset) {
            guard let hashString = asset.perceptualHash,
                  let hash = UInt64(hashString, radix: 16) else {
                return nil
            }
            self.localIdentifier = asset.localIdentifier
            self.creationDate = asset.creationDate
            self.pixelWidth = Int(asset.pixelWidth)
            self.pixelHeight = Int(asset.pixelHeight)
            self.keepPreferred = asset.keepPreferred
            self.hash = hash
        }
    }

    private struct FeatureAsset {
        let localIdentifier: String
        let creationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        let keepPreferred: Bool
        let featureVector: Data

        init(from asset: LocalAsset, featureVector: Data) {
            self.localIdentifier = asset.localIdentifier
            self.creationDate = asset.creationDate
            self.pixelWidth = Int(asset.pixelWidth)
            self.pixelHeight = Int(asset.pixelHeight)
            self.keepPreferred = asset.keepPreferred
            self.featureVector = featureVector
        }
    }

    private enum SimilarityError: LocalizedError {
        case invalidFeatureVector

        var errorDescription: String? {
            switch self {
            case .invalidFeatureVector:
                return "Feature vector could not be decoded."
            }
        }
    }
}

@MainActor
final class ExactDuplicateIndexer: ObservableObject {
    enum State: Equatable {
        case idle
        case indexing(Progress)
        case completed(Completion)
        case failed(String)

        struct Progress: Equatable {
            let processed: Int
            let total: Int
            let exactComputed: Int
            let perceptualComputed: Int
            let semanticComputed: Int
            let failed: Int

            var fractionComplete: Double {
                guard total > 0 else { return 0 }
                return Double(processed) / Double(total)
            }
        }

        struct Completion: Equatable {
            let processed: Int
            let total: Int
            let exactComputed: Int
            let perceptualComputed: Int
            let semanticComputed: Int
            let failed: Int
            let retryQueueCount: Int
            let summary: SimilarityPipelineSummary
            let completedAt: Date
        }
    }

    @Published private(set) var state: State = .idle

    private let persistenceController: PersistenceController
    private let similaritySearchService: SimilaritySearchService
    private let imageProvider = PhotoAssetImageProvider()
    private let batchSize = 30
    private let maxRetryAttempts: Int16 = 5
    private var indexingTask: Task<Void, Never>?

    deinit {
        indexingTask?.cancel()
    }

    init(
        persistenceController: PersistenceController,
        similaritySearchService: SimilaritySearchService? = nil,
        initialState: State = .idle
    ) {
        self.persistenceController = persistenceController
        self.similaritySearchService = similaritySearchService ?? SimilaritySearchService(persistenceController: persistenceController)
        self.state = initialState
    }

    func startIndexingIfNeeded(force: Bool = false) {
        if let indexingTask, !indexingTask.isCancelled {
            return
        }

        let authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            return
        }

        indexingTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runIndexing(force: force)
        }
    }

    func cancelIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        state = .idle
    }

    private func runIndexing(force: Bool) async {
        do {
            try Task.checkCancellation()
            let candidates = try await fetchCandidates(force: force)
            let total = candidates.count

            await MainActor.run {
                self.state = .indexing(
                    .init(
                        processed: 0,
                        total: total,
                        exactComputed: 0,
                        perceptualComputed: 0,
                        semanticComputed: 0,
                        failed: 0
                    )
                )
            }

            if total == 0 {
                let summary = try await similaritySearchService.fetchPipelineSummary()
                let retryQueueCount = try await fetchRetryQueueCount()
                await MainActor.run {
                    self.state = .completed(
                        .init(
                            processed: 0,
                            total: 0,
                            exactComputed: 0,
                            perceptualComputed: 0,
                            semanticComputed: 0,
                            failed: 0,
                            retryQueueCount: retryQueueCount,
                            summary: summary,
                            completedAt: Date()
                        )
                    )
                    self.indexingTask = nil
                }
                return
            }

            var processed = 0
            var exactComputed = 0
            var perceptualComputed = 0
            var semanticComputed = 0
            var failed = 0

            for start in stride(from: 0, to: total, by: batchSize) {
                try Task.checkCancellation()

                let end = min(start + batchSize, total)
                let batchCandidates = Array(candidates[start..<end])
                let batchResults = await analyzeBatch(batchCandidates)
                try await persistAnalysisResults(batchResults)

                for result in batchResults {
                    if result.contentHash != nil {
                        exactComputed += 1
                    }
                    if result.perceptualHash != nil {
                        perceptualComputed += 1
                    }
                    if result.featureVector != nil {
                        semanticComputed += 1
                    }
                    if result.status == .failed {
                        failed += 1
                    }
                }

                processed = end
                await MainActor.run {
                    self.state = .indexing(
                        .init(
                            processed: processed,
                            total: total,
                            exactComputed: exactComputed,
                            perceptualComputed: perceptualComputed,
                            semanticComputed: semanticComputed,
                            failed: failed
                        )
                    )
                }
            }

            let summary = try await similaritySearchService.fetchPipelineSummary()
            let retryQueueCount = try await fetchRetryQueueCount()

            await MainActor.run {
                self.state = .completed(
                    .init(
                        processed: processed,
                        total: total,
                        exactComputed: exactComputed,
                        perceptualComputed: perceptualComputed,
                        semanticComputed: semanticComputed,
                        failed: failed,
                        retryQueueCount: retryQueueCount,
                        summary: summary,
                        completedAt: Date()
                    )
                )
                self.indexingTask = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                self.state = .idle
                self.indexingTask = nil
            }
        } catch {
            await MainActor.run {
                self.state = .failed(error.localizedDescription)
                self.indexingTask = nil
            }
        }
    }

    private func fetchCandidates(force: Bool) async throws -> [Candidate] {
        let now = Date()
        let maxRetryAttempts = self.maxRetryAttempts
        let batchSize = self.batchSize
        let backgroundContext = persistenceController.container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        backgroundContext.automaticallyMergesChangesFromParent = false

        return try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.fetchBatchSize = batchSize
            request.sortDescriptors = [NSSortDescriptor(key: "localAddedDate", ascending: true)]
            request.predicate = Self.makeCandidatePredicate(force: force, now: now, maxRetryAttempts: maxRetryAttempts)

            let assets = try backgroundContext.fetch(request)
            return assets.map {
                Candidate(localIdentifier: $0.localIdentifier, analysisAttemptCount: $0.analysisAttemptCount)
            }
        }
    }

    nonisolated private static func makeCandidatePredicate(force: Bool, now: Date, maxRetryAttempts: Int16) -> NSPredicate {
        let imageType = Int16(PHAssetMediaType.image.rawValue)

        if force {
            return NSPredicate(format: "mediaTypeRaw == %d", imageType)
        }

        return NSPredicate(
            format: """
            mediaTypeRaw == %d AND (
                contentHash == nil OR
                perceptualHash == nil OR
                featureVector == nil OR
                analysisUpdatedAt == nil OR
                (modificationDate != nil AND analysisUpdatedAt < modificationDate) OR
                (
                    analysisStatusRaw == %d AND
                    analysisAttemptCount < %d AND
                    (analysisNextRetryAt == nil OR analysisNextRetryAt <= %@)
                ) OR
                analysisStatusRaw == %d
            )
            """,
            imageType,
            LocalAsset.AnalysisStatus.failed.rawValue,
            maxRetryAttempts,
            now as NSDate,
            LocalAsset.AnalysisStatus.pending.rawValue
        )
    }

    private func analyzeBatch(_ candidates: [Candidate]) async -> [AnalysisResult] {
        var results: [AnalysisResult] = []
        results.reserveCapacity(candidates.count)

        for candidate in candidates {
            if Task.isCancelled { break }
            let result = await analyzeAsset(candidate)
            results.append(result)
        }

        return results
    }

    private func analyzeAsset(_ candidate: Candidate) async -> AnalysisResult {
        var partialContentHash: String?

        do {
            partialContentHash = try await Self.computeContentHash(for: candidate.localIdentifier)
            let normalizedImage = try await imageProvider.fetchNormalizedCGImage(localIdentifier: candidate.localIdentifier)
            let perceptualHash = try Self.computePerceptualHashHex(from: normalizedImage)
            let feature = try Self.computeFeatureVector(from: normalizedImage)

            return AnalysisResult(
                localIdentifier: candidate.localIdentifier,
                contentHash: partialContentHash,
                perceptualHash: perceptualHash,
                featureVector: feature.data,
                featureVersion: feature.version,
                status: .success,
                errorMessage: nil,
                nextRetryAt: nil
            )
        } catch {
            let nextAttempt = min(Int(candidate.analysisAttemptCount) + 1, Int(maxRetryAttempts))
            let nextRetryAt = nextAttempt >= Int(maxRetryAttempts) ? nil : Self.retryDate(attempt: nextAttempt)
            return AnalysisResult(
                localIdentifier: candidate.localIdentifier,
                contentHash: partialContentHash,
                perceptualHash: nil,
                featureVector: nil,
                featureVersion: nil,
                status: .failed,
                errorMessage: error.localizedDescription,
                nextRetryAt: nextRetryAt
            )
        }
    }

    private func persistAnalysisResults(_ results: [AnalysisResult]) async throws {
        guard !results.isEmpty else { return }

        let backgroundContext = persistenceController.container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        backgroundContext.automaticallyMergesChangesFromParent = false

        let identifiers = results.map(\.localIdentifier)
        let resultByIdentifier = Dictionary(uniqueKeysWithValues: results.map { ($0.localIdentifier, $0) })

        try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "localIdentifier IN %@", identifiers)
            request.fetchBatchSize = results.count

            let assets = try backgroundContext.fetch(request)
            let now = Date()

            for asset in assets {
                guard let result = resultByIdentifier[asset.localIdentifier] else { continue }
                asset.analysisUpdatedAt = now
                asset.analysisAttemptCount = min(Int16.max, asset.analysisAttemptCount + 1)

                if let contentHash = result.contentHash {
                    asset.contentHash = contentHash
                }
                if let perceptualHash = result.perceptualHash {
                    asset.perceptualHash = perceptualHash
                }
                if let featureVector = result.featureVector {
                    asset.featureVector = featureVector
                }
                if let featureVersion = result.featureVersion {
                    asset.featureVersion = featureVersion
                }

                asset.analysisStatus = result.status
                asset.analysisErrorMessage = result.errorMessage
                asset.analysisNextRetryAt = result.nextRetryAt

                if result.status == .success {
                    asset.analysisErrorMessage = nil
                    asset.analysisNextRetryAt = nil
                }
            }

            if backgroundContext.hasChanges {
                try backgroundContext.save()
                backgroundContext.reset()
            }
        }
    }

    private func fetchRetryQueueCount() async throws -> Int {
        let backgroundContext = persistenceController.container.newBackgroundContext()
        let now = Date()
        let maxRetryAttempts = self.maxRetryAttempts
        return try await backgroundContext.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(
                format: "analysisStatusRaw == %d AND analysisAttemptCount < %d AND analysisNextRetryAt > %@",
                LocalAsset.AnalysisStatus.failed.rawValue,
                maxRetryAttempts,
                now as NSDate
            )
            return try backgroundContext.count(for: request)
        }
    }

    private static func computeContentHash(for localIdentifier: String) async throws -> String {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw HashingError.assetNotFound(localIdentifier)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = preferredHashResource(from: resources) else {
            throw HashingError.assetResourceNotFound(localIdentifier)
        }

        return try await hash(resource: resource)
    }

    private static func preferredHashResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        let preferredTypes: [PHAssetResourceType] = [
            .fullSizePhoto,
            .photo,
            .alternatePhoto,
            .adjustmentBasePhoto
        ]

        for resourceType in preferredTypes {
            if let resource = resources.first(where: { $0.type == resourceType }) {
                return resource
            }
        }

        return resources.first
    }

    private static func hash(resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let manager = PHAssetResourceManager.default()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            let accumulator = SHA256Accumulator()
            _ = manager.requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    accumulator.update(with: data)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    continuation.resume(returning: accumulator.finalize())
                }
            )
        }
    }

    private static func computePerceptualHashHex(from image: CGImage) throws -> String {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw HashingError.imageProcessingFailed("Unable to create grayscale bitmap context.")
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<8 {
                let left = pixels[(y * width) + x]
                let right = pixels[(y * width) + x + 1]
                let bitIndex = (y * 8) + x
                if left > right {
                    hash |= (1 << UInt64(63 - bitIndex))
                }
            }
        }

        return String(format: "%016llx", hash)
    }

    private static func computeFeatureVector(from image: CGImage) throws -> (data: Data, version: String) {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw HashingError.imageProcessingFailed("Unable to generate image feature print.")
        }

        let data = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        return (data: data, version: "vision-featureprint-r\(request.revision)")
    }

    private static func retryDate(attempt: Int) -> Date {
        let seconds = min(pow(2, Double(attempt)) * 15, 3600)
        return Date().addingTimeInterval(seconds)
    }

    private struct Candidate: Sendable {
        let localIdentifier: String
        let analysisAttemptCount: Int16
    }

    private struct AnalysisResult: Sendable {
        let localIdentifier: String
        let contentHash: String?
        let perceptualHash: String?
        let featureVector: Data?
        let featureVersion: String?
        let status: LocalAsset.AnalysisStatus
        let errorMessage: String?
        let nextRetryAt: Date?
    }

    private enum HashingError: LocalizedError {
        case assetNotFound(String)
        case assetResourceNotFound(String)
        case imageProcessingFailed(String)

        var errorDescription: String? {
            switch self {
            case .assetNotFound(let identifier):
                return "Missing photo asset for identifier \(identifier)."
            case .assetResourceNotFound(let identifier):
                return "Missing photo resource for identifier \(identifier)."
            case .imageProcessingFailed(let message):
                return message
            }
        }
    }
}

private final class SHA256Accumulator {
    private let lock = NSLock()
    private var hasher = SHA256()

    func update(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        hasher.update(data: data)
    }

    func finalize() -> String {
        lock.lock()
        defer { lock.unlock() }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class PhotoAssetImageProvider {
    struct RetryPolicy {
        let maxAttempts: Int
        let initialBackoffMilliseconds: UInt64
        let targetPixelSize: Int

        static let `default` = RetryPolicy(maxAttempts: 3, initialBackoffMilliseconds: 200, targetPixelSize: 256)
    }

    enum ProviderError: LocalizedError {
        case assetNotFound(String)
        case imageRequestFailed(String)
        case missingCGImage(String)

        var errorDescription: String? {
            switch self {
            case .assetNotFound(let identifier):
                return "Missing asset while loading image for \(identifier)."
            case .imageRequestFailed(let message):
                return message
            case .missingCGImage(let identifier):
                return "Image request returned no bitmap for \(identifier)."
            }
        }
    }

    private let imageManager = PHCachingImageManager()

    func fetchNormalizedCGImage(
        localIdentifier: String,
        retryPolicy: RetryPolicy = .default
    ) async throws -> CGImage {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw ProviderError.assetNotFound(localIdentifier)
        }

        var delay = retryPolicy.initialBackoffMilliseconds
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                return try await requestImage(
                    for: asset,
                    localIdentifier: localIdentifier,
                    targetPixelSize: retryPolicy.targetPixelSize
                )
            } catch {
                if attempt >= retryPolicy.maxAttempts {
                    throw error
                }
                try await Task.sleep(nanoseconds: delay * 1_000_000)
                delay = min(delay * 2, 5_000)
            }
        }

        throw ProviderError.imageRequestFailed("Unable to load image for \(localIdentifier).")
    }

    private func requestImage(
        for asset: PHAsset,
        localIdentifier: String,
        targetPixelSize: Int
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.version = .current

            let target = CGSize(width: targetPixelSize, height: targetPixelSize)
            let lock = NSLock()
            var hasResumed = false

            _ = imageManager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                lock.lock()
                defer { lock.unlock() }

                if hasResumed {
                    return
                }

                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                    return
                }

                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    hasResumed = true
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    hasResumed = true
                    continuation.resume(
                        throwing: ProviderError.imageRequestFailed("PhotoKit returned no image for \(localIdentifier).")
                    )
                    return
                }

                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    hasResumed = true
                    continuation.resume(throwing: ProviderError.missingCGImage(localIdentifier))
                    return
                }

                guard let normalized = Self.normalizedImage(cgImage, targetPixelSize: targetPixelSize) else {
                    hasResumed = true
                    continuation.resume(throwing: ProviderError.imageRequestFailed("Failed to normalize image for \(localIdentifier)."))
                    return
                }

                hasResumed = true
                continuation.resume(returning: normalized)
            }
        }
    }

    private static func normalizedImage(_ image: CGImage, targetPixelSize: Int) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetPixelSize,
            height: targetPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetPixelSize, height: targetPixelSize))
        return context.makeImage()
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
        if parent[value] == value {
            return value
        }
        parent[value] = find(parent[value])
        return parent[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = find(lhs)
        let rhsRoot = find(rhs)
        if lhsRoot == rhsRoot {
            return
        }

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

typealias PhotoSimilarityIndexer = ExactDuplicateIndexer

extension ExactDuplicateIndexer {
    static var previewIdle: ExactDuplicateIndexer {
        ExactDuplicateIndexer(persistenceController: .preview, initialState: .idle)
    }

    static var previewIndexing: ExactDuplicateIndexer {
        ExactDuplicateIndexer(
            persistenceController: .preview,
            initialState: .indexing(
                .init(
                    processed: 40,
                    total: 200,
                    exactComputed: 36,
                    perceptualComputed: 34,
                    semanticComputed: 30,
                    failed: 4
                )
            )
        )
    }

    static var previewCompleted: ExactDuplicateIndexer {
        ExactDuplicateIndexer(
            persistenceController: .preview,
            initialState: .completed(
                .init(
                    processed: 200,
                    total: 200,
                    exactComputed: 196,
                    perceptualComputed: 190,
                    semanticComputed: 188,
                    failed: 4,
                    retryQueueCount: 2,
                    summary: .init(
                        exactSummary: .init(hashedAssetCount: 200, duplicateGroupCount: 3, assetsInDuplicateGroups: 9),
                        nearSummary: .init(hashedAssetCount: 200, duplicateGroupCount: 5, assetsInDuplicateGroups: 16),
                        embeddedAssetCount: 188
                    ),
                    completedAt: Date().addingTimeInterval(-1800)
                )
            )
        )
    }
}
