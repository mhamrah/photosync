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
}

extension LocalAsset {
    public var timezoneOffsetSecondsValue: Int? {
        get { timezoneOffsetSeconds?.intValue }
        set { timezoneOffsetSeconds = newValue.map { NSNumber(value: $0) } }
    }
}

extension LocalAsset: Identifiable {}
