import Foundation

public enum AssetSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case applePhotos
    case amazonPhotos

    public var id: String { rawValue }
}

public enum MatchKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case exact
    case nearDuplicate
    case semanticSimilar
    case appleOnly
    case amazonOnly
    case manualReview

    public var id: String { rawValue }
}

public enum SyncActionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case uploadToAmazon
    case importToApplePhotos
    case trashAmazon
    case deleteApple
    case ignore
    case manualReview

    public var id: String { rawValue }
}

public enum SyncPlanStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case proposed
    case approved
    case running
    case completed
    case failed
    case skipped

    public var id: String { rawValue }
}

public struct UnifiedAssetIdentifier: Hashable, Codable, Sendable {
    public let source: AssetSource
    public let sourceIdentifier: String

    public init(source: AssetSource, sourceIdentifier: String) {
        self.source = source
        self.sourceIdentifier = sourceIdentifier
    }
}

public struct UnifiedSearchQuery: Equatable, Sendable {
    public var text: String
    public var sources: Set<AssetSource>
    public var matchKinds: Set<MatchKind>
    public var dateRange: ClosedRange<Date>?
    public var minimumLongestEdge: Int?
    public var includesHidden: Bool
    public var includesFavoritesOnly: Bool

    public static let empty = UnifiedSearchQuery(
        text: "",
        sources: Set(AssetSource.allCases),
        matchKinds: [],
        dateRange: nil,
        minimumLongestEdge: nil,
        includesHidden: true,
        includesFavoritesOnly: false
    )

    public init(
        text: String,
        sources: Set<AssetSource>,
        matchKinds: Set<MatchKind>,
        dateRange: ClosedRange<Date>?,
        minimumLongestEdge: Int?,
        includesHidden: Bool,
        includesFavoritesOnly: Bool
    ) {
        self.text = text
        self.sources = sources
        self.matchKinds = matchKinds
        self.dateRange = dateRange
        self.minimumLongestEdge = minimumLongestEdge
        self.includesHidden = includesHidden
        self.includesFavoritesOnly = includesFavoritesOnly
    }
}

public struct MatchEvidence: Equatable, Codable, Sendable {
    public var contentHashMatched: Bool
    public var metadataMatched: Bool
    public var perceptualDistance: Int?
    public var featurePrintDistance: Float?
    public var confidence: Double
    public var summary: String
}

public struct ProposedSyncAction: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var kind: SyncActionKind
    public var primaryAsset: UnifiedAssetIdentifier
    public var relatedAsset: UnifiedAssetIdentifier?
    public var status: SyncPlanStatus
    public var reason: String

    public init(
        id: UUID = UUID(),
        kind: SyncActionKind,
        primaryAsset: UnifiedAssetIdentifier,
        relatedAsset: UnifiedAssetIdentifier? = nil,
        status: SyncPlanStatus = .proposed,
        reason: String
    ) {
        self.id = id
        self.kind = kind
        self.primaryAsset = primaryAsset
        self.relatedAsset = relatedAsset
        self.status = status
        self.reason = reason
    }
}

public struct CatalogAssetSnapshot: Identifiable, Equatable, Sendable {
    public let id: UnifiedAssetIdentifier
    public var normalizedFilename: String?
    public var captureDate: Date?
    public var pixelWidth: Int32
    public var pixelHeight: Int32
    public var duration: Double
    public var fileSizeBytes: Int64
    public var mediaType: String?
    public var isFavorite: Bool
    public var isHidden: Bool
    public var contentHash: String?
    public var md5: String?
    public var perceptualHash: String?
    public var featureVersion: String?
    public var ocrText: String?
    public var labelsRaw: String?
    public var faceClusterIDsRaw: String?
    public var ownerId: String?
    public var parentsRaw: String?
    public var rawJSON: Data?
    public var indexedAt: Date?
    public var analysisUpdatedAt: Date?
    public var analysisStatus: AssetAnalysis.AnalysisStatus

    init(asset: AssetAnalysis) {
        self.id = UnifiedAssetIdentifier(
            source: asset.source,
            sourceIdentifier: asset.sourceIdentifier
        )
        self.normalizedFilename = asset.normalizedFilename
        self.captureDate = asset.captureDate
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.duration = asset.duration
        self.fileSizeBytes = asset.fileSizeBytes
        self.mediaType = asset.mediaType
        self.isFavorite = asset.isFavorite
        self.isHidden = asset.isHidden
        self.contentHash = asset.contentHash
        self.md5 = asset.md5
        self.perceptualHash = asset.perceptualHash
        self.featureVersion = asset.featureVersion
        self.ocrText = asset.ocrText
        self.labelsRaw = asset.labelsRaw
        self.faceClusterIDsRaw = asset.faceClusterIDsRaw
        self.ownerId = asset.ownerId
        self.parentsRaw = asset.parentsRaw
        self.rawJSON = asset.rawJSON
        self.indexedAt = asset.indexedAt
        self.analysisUpdatedAt = asset.analysisUpdatedAt
        self.analysisStatus = asset.analysisStatus
    }
}
