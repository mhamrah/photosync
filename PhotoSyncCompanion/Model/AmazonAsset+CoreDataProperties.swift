import CoreData

extension AmazonAsset {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<AmazonAsset> {
        NSFetchRequest<AmazonAsset>(entityName: "AmazonAsset")
    }

    @NSManaged public var nodeId: String
    @NSManaged public var name: String?
    @NSManaged public var md5: String?
    @NSManaged public var sizeBytes: Int64
    @NSManaged public var contentType: String?
    @NSManaged public var extensionName: String?
    @NSManaged public var createdDate: Date?
    @NSManaged public var modifiedDate: Date?
    @NSManaged public var contentDate: Date?
    @NSManaged public var width: Int32
    @NSManaged public var height: Int32
    @NSManaged public var duration: Double
    @NSManaged public var ownerId: String?
    @NSManaged public var parentsRaw: String?
    @NSManaged public var rawJSON: Data?
    @NSManaged public var indexedAt: Date?
}

extension AmazonAsset: Identifiable {}
