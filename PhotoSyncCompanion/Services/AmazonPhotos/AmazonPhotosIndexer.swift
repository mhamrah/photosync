import CoreData
import Foundation

@MainActor
final class AmazonPhotosIndexer: ObservableObject {
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
    private let settingsStore: AmazonPhotosSettingsStore
    private var indexingTask: Task<Void, Never>?

    init(
        persistenceController: PersistenceController,
        settingsStore: AmazonPhotosSettingsStore,
        initialState: State = .idle
    ) {
        self.persistenceController = persistenceController
        self.settingsStore = settingsStore
        self.state = initialState
    }

    deinit {
        indexingTask?.cancel()
    }

    func startIndexingIfNeeded(force: Bool = false) {
        if let indexingTask, !indexingTask.isCancelled, !force {
            return
        }

        indexingTask?.cancel()
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
            let credentials = settingsStore.credentials
            guard credentials.isComplete else {
                throw AmazonPhotosClientError.missingCredentials
            }

            let config = settingsStore.syncConfig
            let limit = min(max(config.pageLimit, 1), 200)
            let configuredMaxPages = max(config.maxPages, 0)
            let pageCap: Int? = configuredMaxPages > 0 ? configuredMaxPages : nil

            let client = try AmazonPhotosClient(config: config, credentials: credentials)
            var currentOffset = 0
            var currentPage = try await client.fetchSearchPage(offset: currentOffset, limit: limit)
            var estimatedTotal = max(currentPage.count, currentPage.data.count)
            if let pageCap {
                estimatedTotal = min(estimatedTotal, pageCap * limit)
            }

            await MainActor.run {
                self.state = .indexing(.init(processed: 0, total: max(estimatedTotal, 1)))
            }

            var processed = 0
            var pagesFetched = 0

            while true {
                try Task.checkCancellation()

                let nodes = currentPage.data
                guard !nodes.isEmpty else { break }

                try await upsert(nodes: nodes)
                processed += nodes.count
                pagesFetched += 1

                let reportedCount = currentPage.count
                if let pageCap {
                    estimatedTotal = min(max(estimatedTotal, reportedCount, processed), pageCap * limit)
                } else {
                    estimatedTotal = max(estimatedTotal, reportedCount, processed)
                }

                await MainActor.run {
                    self.state = .indexing(.init(processed: min(processed, estimatedTotal), total: max(estimatedTotal, processed)))
                }

                let reachedPageCap = pageCap.map { pagesFetched >= $0 } ?? false
                let reachedEndOfData = nodes.count < limit
                let hasReliableReportedTotal = reportedCount > limit
                let reachedReportedTotal = hasReliableReportedTotal && processed >= reportedCount
                if reachedPageCap || reachedEndOfData || reachedReportedTotal {
                    break
                }

                currentOffset += limit
                currentPage = try await client.fetchSearchPage(offset: currentOffset, limit: limit)
            }

            let completion = State.Completion(
                processed: processed,
                total: processed,
                completedAt: Date()
            )

            await MainActor.run {
                self.state = .completed(completion)
                self.indexingTask = nil
                self.settingsStore.recordSyncSuccess(at: completion.completedAt)
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
                self.settingsStore.recordSyncFailure(error.localizedDescription)
            }
        }
    }

    private func upsert(nodes: [AmazonNode]) async throws {
        guard !nodes.isEmpty else { return }

        let backgroundContext = persistenceController.container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        backgroundContext.automaticallyMergesChangesFromParent = false

        try await backgroundContext.perform {
            let nodeIDs = nodes.map(\.id)

            let request: NSFetchRequest<AmazonAsset> = AmazonAsset.fetchRequest()
            request.predicate = NSPredicate(format: "nodeId IN %@", nodeIDs)
            let existing = try backgroundContext.fetch(request)
            var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.nodeId, $0) })

            for node in nodes {
                let asset = existingByID[node.id] ?? AmazonAsset(context: backgroundContext)
                asset.nodeId = node.id
                asset.name = node.name
                asset.md5 = node.contentProperties?.md5
                asset.sizeBytes = node.contentProperties?.size ?? 0
                asset.contentType = node.contentProperties?.contentType
                asset.extensionName = node.contentProperties?.ext
                asset.createdDate = node.createdDate
                asset.modifiedDate = node.modifiedDate
                asset.contentDate = node.contentProperties?.contentDate
                asset.width = node.resolvedWidth
                asset.height = node.resolvedHeight
                asset.duration = node.resolvedDuration
                asset.ownerId = node.ownerId
                asset.parentsRaw = node.parents?.joined(separator: ",")
                asset.rawJSON = try? JSONEncoder.amazonPhotosEncoder().encode(node)
                asset.indexedAt = Date()
                existingByID[node.id] = asset
            }

            if backgroundContext.hasChanges {
                try backgroundContext.save()
            }
        }
    }
}

extension AmazonPhotosIndexer {
    static var previewIdle: AmazonPhotosIndexer {
        AmazonPhotosIndexer(
            persistenceController: .preview,
            settingsStore: AmazonPhotosSettingsStore(),
            initialState: .idle
        )
    }
}
