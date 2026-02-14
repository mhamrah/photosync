import CoreData

extension LocalAsset {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<LocalAsset> {
        NSFetchRequest<LocalAsset>(entityName: "LocalAsset")
    }

    @NSManaged public var localIdentifier: String
    @NSManaged public var creationDate: Date?
    @NSManaged public var modificationDate: Date?
    @NSManaged public var mediaTypeRaw: Int16
    @NSManaged public var mediaSubtypesRaw: Int32
    @NSManaged public var duration: Double
    @NSManaged public var pixelWidth: Int32
    @NSManaged public var pixelHeight: Int32
    @NSManaged public var isFavorite: Bool
    @NSManaged public var hasAdjustments: Bool
    @NSManaged public var hidden: Bool
    @NSManaged public var burstIdentifier: String?
    @NSManaged public var cloudIdentifier: String?
    @NSManaged public var masterFingerprint: String?
    @NSManaged public var variantFingerprint: String?
    @NSManaged public var timezoneOffsetSeconds: NSNumber?
    @NSManaged public var sourceTypeRaw: Int16
    @NSManaged public var localAddedDate: Date?
    @NSManaged public var contentHash: String?
    @NSManaged public var perceptualHash: String?
    @NSManaged public var featureVector: Data?
    @NSManaged public var featureVersion: String?
    @NSManaged public var analysisUpdatedAt: Date?
    @NSManaged public var analysisStatusRaw: Int16
    @NSManaged public var analysisErrorMessage: String?
    @NSManaged public var analysisAttemptCount: Int16
    @NSManaged public var analysisNextRetryAt: Date?
    @NSManaged public var keepPreferred: Bool
}

extension LocalAsset {
    public enum AnalysisStatus: Int16, Sendable {
        case pending = 0
        case success = 1
        case failed = 2
    }

    public var timezoneOffsetSecondsValue: Int? {
        get { timezoneOffsetSeconds?.intValue }
        set { timezoneOffsetSeconds = newValue.map { NSNumber(value: $0) } }
    }

    public var analysisStatus: AnalysisStatus {
        get { AnalysisStatus(rawValue: analysisStatusRaw) ?? .pending }
        set { analysisStatusRaw = newValue.rawValue }
    }
}

extension LocalAsset: Identifiable {}
