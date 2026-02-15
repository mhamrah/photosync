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
            let maxPages = max(config.maxPages, 1)

            let client = try AmazonPhotosClient(config: config, credentials: credentials)
            let firstPage = try await client.fetchSearchPage(offset: 0, limit: limit)
            let targetTotal = min(firstPage.count, limit * maxPages)

            await MainActor.run {
                self.state = .indexing(.init(processed: 0, total: targetTotal))
            }

            var processed = 0
            try await upsert(nodes: firstPage.data)
            processed += firstPage.data.count

            await MainActor.run {
                self.state = .indexing(.init(processed: min(processed, targetTotal), total: targetTotal))
            }

            if targetTotal > firstPage.data.count {
                let remainingPages = maxPages - 1
                for pageIndex in 0..<remainingPages {
                    try Task.checkCancellation()
                    let offset = (pageIndex + 1) * limit
                    if offset >= targetTotal { break }

                    let page = try await client.fetchSearchPage(offset: offset, limit: limit)
                    if page.data.isEmpty { break }

                    try await upsert(nodes: page.data)
                    processed += page.data.count

                    await MainActor.run {
                        self.state = .indexing(.init(processed: min(processed, targetTotal), total: targetTotal))
                    }
                }
            }

            let completion = State.Completion(
                processed: min(processed, targetTotal),
                total: targetTotal,
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
