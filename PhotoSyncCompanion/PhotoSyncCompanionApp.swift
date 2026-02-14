import SwiftUI

@main
struct PhotoSyncCompanionApp: App {
    @StateObject private var photoLibraryAuthorizationController = PhotoLibraryAuthorizationController()
    @StateObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @StateObject private var exactDuplicateIndexer: ExactDuplicateIndexer
    private let persistenceController: PersistenceController

    init() {
        let persistenceController = PersistenceController.shared
        self.persistenceController = persistenceController
        _photoLibraryIndexer = StateObject(wrappedValue: PhotoLibraryIndexer(persistenceController: persistenceController))
        _exactDuplicateIndexer = StateObject(wrappedValue: ExactDuplicateIndexer(persistenceController: persistenceController))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(photoLibraryAuthorizationController)
                .environmentObject(photoLibraryIndexer)
                .environmentObject(exactDuplicateIndexer)
        }
        .windowToolbarStyle(.automatic)
    }
}
