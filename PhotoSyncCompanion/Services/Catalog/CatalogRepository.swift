import CoreData
import Foundation
import Photos

struct CatalogFaceObservationInput: Sendable {
    let faceIndex: Int16
    let boundingBoxX: Double
    let boundingBoxY: Double
    let boundingBoxWidth: Double
    let boundingBoxHeight: Double
}

final class CatalogRepository {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    @discardableResult
    func upsertLocalAssetAnalysis(from asset: LocalAsset) throws -> AssetAnalysis {
        let analysis = try upsertAssetAnalysis(
            source: .applePhotos,
            sourceIdentifier: asset.localIdentifier
        )

        analysis.normalizedFilename = normalizedFilename(asset.originalFilename)
        analysis.captureDate = asset.creationDate
        analysis.pixelWidth = asset.pixelWidth
        analysis.pixelHeight = asset.pixelHeight
        analysis.duration = asset.duration
        analysis.fileSizeBytes = asset.fileSizeBytes
        analysis.mediaType = mediaTypeDescription(rawValue: asset.mediaTypeRaw)
        analysis.isFavorite = asset.isFavorite
        analysis.isHidden = asset.hidden
        analysis.contentHash = asset.contentHash
        analysis.md5 = asset.md5
        analysis.perceptualHash = asset.perceptualHash
        analysis.featureVector = asset.featureVector
        analysis.featureVersion = asset.featureVersion
        analysis.ownerId = nil
        analysis.parentsRaw = nil
        analysis.rawJSON = nil
        analysis.indexedAt = nil
        analysis.analysisUpdatedAt = asset.analysisUpdatedAt
        analysis.analysisStatus = AssetAnalysis.AnalysisStatus(rawValue: asset.analysisStatusRaw) ?? .pending
        analysis.analysisErrorMessage = asset.analysisErrorMessage
        analysis.analysisAttemptCount = asset.analysisAttemptCount
        analysis.analysisNextRetryAt = asset.analysisNextRetryAt

        return analysis
    }

    @discardableResult
    func upsertAmazonAssetAnalysis(from asset: AmazonAsset) throws -> AssetAnalysis {
        let analysis = try upsertAssetAnalysis(
            source: .amazonPhotos,
            sourceIdentifier: asset.nodeId
        )

        analysis.normalizedFilename = normalizedFilename(asset.name)
        analysis.captureDate = asset.contentDate ?? asset.createdDate
        analysis.pixelWidth = asset.width
        analysis.pixelHeight = asset.height
        analysis.duration = asset.duration
        analysis.fileSizeBytes = asset.sizeBytes
        analysis.mediaType = asset.contentType
        analysis.isFavorite = false
        analysis.isHidden = false
        analysis.md5 = asset.md5
        analysis.ownerId = asset.ownerId
        analysis.parentsRaw = asset.parentsRaw
        analysis.rawJSON = asset.rawJSON
        analysis.indexedAt = asset.indexedAt

        if analysis.analysisUpdatedAt == nil {
            analysis.analysisStatus = .pending
        }

        return analysis
    }

    @discardableResult
    func upsertCheckpoint(
        source: AssetSource,
        cursor: String?,
        processedCount: Int64,
        totalCount: Int64,
        startedAt: Date?,
        completedAt: Date?,
        errorMessage: String?
    ) throws -> IngestCheckpoint {
        let checkpoint = try fetchOrCreateCheckpoint(for: source)
        checkpoint.cursor = cursor
        checkpoint.processedCount = processedCount
        checkpoint.totalCount = totalCount
        checkpoint.lastStartedAt = startedAt ?? checkpoint.lastStartedAt
        checkpoint.lastCompletedAt = completedAt
        checkpoint.lastErrorMessage = errorMessage
        return checkpoint
    }

    func upsertFaceObservations(
        source: AssetSource,
        sourceIdentifier: String,
        observations: [CatalogFaceObservationInput]
    ) throws {
        let assetKey = Self.assetKey(source: source, sourceIdentifier: sourceIdentifier)
        let existingRequest: NSFetchRequest<FaceObservation> = FaceObservation.fetchRequest()
        existingRequest.predicate = NSPredicate(format: "assetKey == %@", assetKey)

        let existing = try context.fetch(existingRequest)
        var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.observationIdentifier, $0) })
        let desiredIDs = Set(observations.map { Self.faceObservationID(assetKey: assetKey, faceIndex: $0.faceIndex) })
        let now = Date()

        for stale in existing where !desiredIDs.contains(stale.observationIdentifier) {
            context.delete(stale)
        }

        for observation in observations {
            let observationID = Self.faceObservationID(assetKey: assetKey, faceIndex: observation.faceIndex)
            let managed = existingByID[observationID] ?? FaceObservation(context: context)
            managed.observationIdentifier = observationID
            managed.assetKey = assetKey
            managed.source = source
            managed.sourceIdentifier = sourceIdentifier
            managed.faceIndex = observation.faceIndex
            managed.boundingBoxX = observation.boundingBoxX
            managed.boundingBoxY = observation.boundingBoxY
            managed.boundingBoxWidth = observation.boundingBoxWidth
            managed.boundingBoxHeight = observation.boundingBoxHeight
            managed.createdAt = managed.createdAt ?? now
            managed.updatedAt = now
            existingByID[observationID] = managed
        }
    }

    private func upsertAssetAnalysis(
        source: AssetSource,
        sourceIdentifier: String
    ) throws -> AssetAnalysis {
        let assetKey = Self.assetKey(source: source, sourceIdentifier: sourceIdentifier)
        let request: NSFetchRequest<AssetAnalysis> = AssetAnalysis.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "assetKey == %@", assetKey)

        let analysis = try context.fetch(request).first ?? AssetAnalysis(context: context)
        analysis.assetKey = assetKey
        analysis.source = source
        analysis.sourceIdentifier = sourceIdentifier
        return analysis
    }

    private func fetchOrCreateCheckpoint(for source: AssetSource) throws -> IngestCheckpoint {
        let identifier = source.rawValue
        let request: NSFetchRequest<IngestCheckpoint> = IngestCheckpoint.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "checkpointIdentifier == %@", identifier)

        let checkpoint = try context.fetch(request).first ?? IngestCheckpoint(context: context)
        checkpoint.checkpointIdentifier = identifier
        checkpoint.source = source
        return checkpoint
    }

    private func normalizedFilename(_ filename: String?) -> String? {
        filename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func mediaTypeDescription(rawValue: Int16) -> String? {
        switch PHAssetMediaType(rawValue: Int(rawValue)) {
        case .image:
            return "image"
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .unknown, nil:
            return nil
        @unknown default:
            return nil
        }
    }

    static func assetKey(source: AssetSource, sourceIdentifier: String) -> String {
        "\(source.rawValue):\(sourceIdentifier)"
    }

    static func faceObservationID(assetKey: String, faceIndex: Int16) -> String {
        "\(assetKey):face:\(faceIndex)"
    }
}
