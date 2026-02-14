import CoreData
import Foundation
import Photos

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

            let total = PHAsset.fetchAssets(with: makeFetchOptions()).count

            await MainActor.run {
                self.state = .indexing(.init(processed: 0, total: total))
            }

            let backgroundContext = persistenceController.container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            backgroundContext.automaticallyMergesChangesFromParent = false

            var processed = 0
            var lastIdentifier: String?

            while true {
                try Task.checkCancellation()

                let fetchResult = fetchAssetsPage(after: lastIdentifier, limit: batchSize)
                let pageCount = fetchResult.count
                guard pageCount > 0 else { break }

                let assets = (0..<pageCount).map { fetchResult.object(at: $0) }
                lastIdentifier = assets.last?.localIdentifier
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
        options.sortDescriptors = [NSSortDescriptor(key: "localIdentifier", ascending: true)]
        options.includeHiddenAssets = true
        return options
    }

    private func fetchAssetsPage(after lastIdentifier: String?, limit: Int) -> PHFetchResult<PHAsset> {
        let options = makeFetchOptions()
        options.fetchLimit = limit
        if let lastIdentifier {
            options.predicate = NSPredicate(format: "localIdentifier > %@", lastIdentifier)
        }
        return PHAsset.fetchAssets(with: options)
    }

    private nonisolated func update(_ localAsset: LocalAsset, with asset: PHAsset) {
        localAsset.localIdentifier = asset.localIdentifier
        localAsset.creationDate = asset.creationDate
        localAsset.modificationDate = asset.modificationDate
        localAsset.mediaTypeRaw = Int16(asset.mediaType.rawValue)
        localAsset.mediaSubtypesRaw = Int32(truncatingIfNeeded: asset.mediaSubtypes.rawValue)
        localAsset.duration = asset.duration
        localAsset.pixelWidth = Int32(asset.pixelWidth)
        localAsset.pixelHeight = Int32(asset.pixelHeight)
        localAsset.isFavorite = asset.isFavorite
        localAsset.hasAdjustments = assetHasAdjustments(asset)
        localAsset.hidden = asset.isHidden
        localAsset.burstIdentifier = asset.burstIdentifier
        localAsset.sourceTypeRaw = Int16(truncatingIfNeeded: asset.sourceType.rawValue)

        if localAsset.localAddedDate == nil {
            localAsset.localAddedDate = Date()
        }

        localAsset.masterFingerprint = asset.localIdentifier
        if let modificationDate = asset.modificationDate {
            localAsset.variantFingerprint = "\(asset.localIdentifier)-\(modificationDate.timeIntervalSince1970)"
        } else {
            localAsset.variantFingerprint = nil
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
