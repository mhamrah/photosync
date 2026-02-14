import CoreData

final class PersistenceController {
    static let shared = PersistenceController()

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // Seed with a few sample assets for SwiftUI previews / tests.
        for index in 0..<5 {
            let asset = LocalAsset(context: viewContext)
            asset.localIdentifier = "preview-local-identifier-\(index)"
            asset.mediaTypeRaw = Int16(index % 5)
            asset.mediaSubtypesRaw = 0
            asset.creationDate = Date().addingTimeInterval(Double(-index) * 86_400)
            asset.modificationDate = asset.creationDate
            asset.isFavorite = index % 2 == 0
            asset.duration = 0
            asset.pixelWidth = 4032
            asset.pixelHeight = 3024
            asset.hasAdjustments = false
            asset.sourceTypeRaw = 1
            asset.analysisStatus = .success
            asset.analysisUpdatedAt = Date()
            if index < 2 {
                // Seed one duplicate group for UI previews.
                asset.contentHash = "preview-duplicate-hash-a"
            } else {
                asset.contentHash = "preview-unique-hash-\(index)"
            }
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
