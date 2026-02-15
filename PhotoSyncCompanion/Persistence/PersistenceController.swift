import CoreData
import Photos

final class PersistenceController {
    static let shared = PersistenceController()

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // Seed with a few sample assets for SwiftUI previews / tests.
        for index in 0..<5 {
            let asset = LocalAsset(context: viewContext)
            asset.localIdentifier = "preview-local-identifier-\(index)"
            asset.mediaTypeRaw = Int16(PHAssetMediaType.image.rawValue)
            asset.mediaSubtypesRaw = 0
            asset.creationDate = Date().addingTimeInterval(Double(-index) * 86_400)
            asset.modificationDate = asset.creationDate
            asset.isFavorite = index % 2 == 0
            asset.duration = 0
            asset.pixelWidth = 4032
            asset.pixelHeight = 3024
            asset.hasAdjustments = false
            asset.sourceTypeRaw = 1
            asset.originalFilename = "IMG_\(1000 + index).JPG"
            asset.analysisStatus = .success
            asset.analysisUpdatedAt = Date()
            if index < 2 {
                asset.contentHash = "preview-duplicate-hash-a"
            } else {
                asset.contentHash = "preview-unique-hash-\(index)"
            }
        }

        for index in 0..<4 {
            let asset = AmazonAsset(context: viewContext)
            asset.nodeId = "preview-amazon-node-\(index)"
            asset.name = "IMG_\(1000 + index).JPG"
            asset.width = 4032
            asset.height = 3024
            asset.createdDate = Date().addingTimeInterval(Double(-index) * 86_400)
            asset.contentDate = asset.createdDate
            asset.sizeBytes = 1_000_000
            asset.indexedAt = Date()
        }

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }

        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "PhotoSyncCompanionModel")

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }

        for description in container.persistentStoreDescriptions {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.shouldDeleteInaccessibleFaults = true

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved error \(error as NSError)")
            }
        }
    }
}
