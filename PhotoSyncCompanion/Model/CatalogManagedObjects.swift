import CoreData
import Foundation

@objc(AssetAnalysis)
public class AssetAnalysis: NSManagedObject {}

@objc(CrossLibraryMatch)
public class CrossLibraryMatch: NSManagedObject {}

@objc(DuplicateCluster)
public class DuplicateCluster: NSManagedObject {}

@objc(FaceObservation)
public class FaceObservation: NSManagedObject {}

@objc(SyncPlanItem)
public class SyncPlanItem: NSManagedObject {}

@objc(PersonCluster)
public class PersonCluster: NSManagedObject {}

@objc(IngestCheckpoint)
public class IngestCheckpoint: NSManagedObject {}

extension AssetAnalysis {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<AssetAnalysis> {
        NSFetchRequest<AssetAnalysis>(entityName: "AssetAnalysis")
    }

    @NSManaged public var assetKey: String
    @NSManaged public var sourceRaw: String
    @NSManaged public var sourceIdentifier: String
    @NSManaged public var normalizedFilename: String?
    @NSManaged public var captureDate: Date?
    @NSManaged public var pixelWidth: Int32
    @NSManaged public var pixelHeight: Int32
    @NSManaged public var duration: Double
    @NSManaged public var fileSizeBytes: Int64
    @NSManaged public var mediaType: String?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var isHidden: Bool
    @NSManaged public var contentHash: String?
    @NSManaged public var md5: String?
    @NSManaged public var perceptualHash: String?
    @NSManaged public var featureVector: Data?
    @NSManaged public var featureVersion: String?
    @NSManaged public var ocrText: String?
    @NSManaged public var labelsRaw: String?
    @NSManaged public var faceClusterIDsRaw: String?
    @NSManaged public var ownerId: String?
    @NSManaged public var parentsRaw: String?
    @NSManaged public var rawJSON: Data?
    @NSManaged public var indexedAt: Date?
    @NSManaged public var analysisUpdatedAt: Date?
    @NSManaged public var analysisStatusRaw: Int16
    @NSManaged public var analysisErrorMessage: String?
    @NSManaged public var analysisAttemptCount: Int16
    @NSManaged public var analysisNextRetryAt: Date?
    @NSManaged public var thumbnailCachedAt: Date?

    public enum AnalysisStatus: Int16, Sendable {
        case pending = 0
        case success = 1
        case failed = 2
    }

    public var source: AssetSource {
        get { AssetSource(rawValue: sourceRaw) ?? .applePhotos }
        set { sourceRaw = newValue.rawValue }
    }

    public var analysisStatus: AnalysisStatus {
        get { AnalysisStatus(rawValue: analysisStatusRaw) ?? .pending }
        set { analysisStatusRaw = newValue.rawValue }
    }
}

extension CrossLibraryMatch {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CrossLibraryMatch> {
        NSFetchRequest<CrossLibraryMatch>(entityName: "CrossLibraryMatch")
    }

    @NSManaged public var matchIdentifier: String
    @NSManaged public var localIdentifier: String
    @NSManaged public var amazonNodeId: String
    @NSManaged public var kindRaw: String
    @NSManaged public var confidence: Double
    @NSManaged public var evidenceJSON: Data?
    @NSManaged public var decidedActionRaw: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    public var kind: MatchKind {
        get { MatchKind(rawValue: kindRaw) ?? .manualReview }
        set { kindRaw = newValue.rawValue }
    }

    public var decidedAction: SyncActionKind? {
        get { decidedActionRaw.flatMap(SyncActionKind.init(rawValue:)) }
        set { decidedActionRaw = newValue?.rawValue }
    }
}

extension DuplicateCluster {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DuplicateCluster> {
        NSFetchRequest<DuplicateCluster>(entityName: "DuplicateCluster")
    }

    @NSManaged public var clusterIdentifier: String
    @NSManaged public var sourceRaw: String
    @NSManaged public var kindRaw: String
    @NSManaged public var memberIdentifiersRaw: String
    @NSManaged public var keeperIdentifier: String?
    @NSManaged public var confidence: Double
    @NSManaged public var evidenceJSON: Data?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    public var source: AssetSource {
        get { AssetSource(rawValue: sourceRaw) ?? .applePhotos }
        set { sourceRaw = newValue.rawValue }
    }

    public var kind: MatchKind {
        get { MatchKind(rawValue: kindRaw) ?? .nearDuplicate }
        set { kindRaw = newValue.rawValue }
    }

    public var memberIdentifiers: [String] {
        get { memberIdentifiersRaw.split(separator: "\n").map(String.init) }
        set { memberIdentifiersRaw = newValue.joined(separator: "\n") }
    }
}

extension FaceObservation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<FaceObservation> {
        NSFetchRequest<FaceObservation>(entityName: "FaceObservation")
    }

    @NSManaged public var observationIdentifier: String
    @NSManaged public var assetKey: String
    @NSManaged public var sourceRaw: String
    @NSManaged public var sourceIdentifier: String
    @NSManaged public var faceIndex: Int16
    @NSManaged public var boundingBoxX: Double
    @NSManaged public var boundingBoxY: Double
    @NSManaged public var boundingBoxWidth: Double
    @NSManaged public var boundingBoxHeight: Double
    @NSManaged public var clusterIdentifier: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    public var source: AssetSource {
        get { AssetSource(rawValue: sourceRaw) ?? .applePhotos }
        set { sourceRaw = newValue.rawValue }
    }
}

extension SyncPlanItem {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<SyncPlanItem> {
        NSFetchRequest<SyncPlanItem>(entityName: "SyncPlanItem")
    }

    @NSManaged public var itemIdentifier: String
    @NSManaged public var actionKindRaw: String
    @NSManaged public var statusRaw: String
    @NSManaged public var primarySourceRaw: String
    @NSManaged public var primaryIdentifier: String
    @NSManaged public var relatedSourceRaw: String?
    @NSManaged public var relatedIdentifier: String?
    @NSManaged public var reason: String
    @NSManaged public var errorMessage: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var completedAt: Date?

    public var actionKind: SyncActionKind {
        get { SyncActionKind(rawValue: actionKindRaw) ?? .manualReview }
        set { actionKindRaw = newValue.rawValue }
    }

    public var status: SyncPlanStatus {
        get { SyncPlanStatus(rawValue: statusRaw) ?? .proposed }
        set { statusRaw = newValue.rawValue }
    }

    public var primarySource: AssetSource {
        get { AssetSource(rawValue: primarySourceRaw) ?? .applePhotos }
        set { primarySourceRaw = newValue.rawValue }
    }

    public var relatedSource: AssetSource? {
        get { relatedSourceRaw.flatMap(AssetSource.init(rawValue:)) }
        set { relatedSourceRaw = newValue?.rawValue }
    }
}

extension PersonCluster {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PersonCluster> {
        NSFetchRequest<PersonCluster>(entityName: "PersonCluster")
    }

    @NSManaged public var clusterIdentifier: String
    @NSManaged public var displayName: String?
    @NSManaged public var memberObservationIDsRaw: String?
    @NSManaged public var representativeAssetKey: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    public var memberObservationIDs: [String] {
        get { memberObservationIDsRaw?.split(separator: "\n").map(String.init) ?? [] }
        set { memberObservationIDsRaw = newValue.joined(separator: "\n") }
    }
}

extension IngestCheckpoint {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<IngestCheckpoint> {
        NSFetchRequest<IngestCheckpoint>(entityName: "IngestCheckpoint")
    }

    @NSManaged public var checkpointIdentifier: String
    @NSManaged public var sourceRaw: String
    @NSManaged public var cursor: String?
    @NSManaged public var lastStartedAt: Date?
    @NSManaged public var lastCompletedAt: Date?
    @NSManaged public var lastErrorMessage: String?
    @NSManaged public var processedCount: Int64
    @NSManaged public var totalCount: Int64

    public var source: AssetSource {
        get { AssetSource(rawValue: sourceRaw) ?? .applePhotos }
        set { sourceRaw = newValue.rawValue }
    }
}

extension AssetAnalysis: Identifiable {}
extension CrossLibraryMatch: Identifiable {}
extension DuplicateCluster: Identifiable {}
extension FaceObservation: Identifiable {}
extension SyncPlanItem: Identifiable {}
extension PersonCluster: Identifiable {}
extension IngestCheckpoint: Identifiable {}
