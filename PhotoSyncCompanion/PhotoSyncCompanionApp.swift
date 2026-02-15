import SwiftUI

@main
struct PhotoSyncCompanionApp: App {
    @StateObject private var photoLibraryAuthorizationController = PhotoLibraryAuthorizationController()
    @StateObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @StateObject private var exactDuplicateIndexer: ExactDuplicateIndexer
    @StateObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore
    @StateObject private var amazonPhotosIndexer: AmazonPhotosIndexer
    @StateObject private var comparisonViewModel: ComparisonViewModel
    private let persistenceController: PersistenceController

    init() {
        let persistenceController = PersistenceController.shared
        let amazonSettingsStore = AmazonPhotosSettingsStore()
        self.persistenceController = persistenceController
        _photoLibraryIndexer = StateObject(wrappedValue: PhotoLibraryIndexer(persistenceController: persistenceController))
        _exactDuplicateIndexer = StateObject(wrappedValue: ExactDuplicateIndexer(persistenceController: persistenceController))
        _amazonPhotosSettingsStore = StateObject(wrappedValue: amazonSettingsStore)
        _amazonPhotosIndexer = StateObject(
            wrappedValue: AmazonPhotosIndexer(
                persistenceController: persistenceController,
                settingsStore: amazonSettingsStore
            )
        )
        _comparisonViewModel = StateObject(wrappedValue: ComparisonViewModel(persistenceController: persistenceController))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(photoLibraryAuthorizationController)
                .environmentObject(photoLibraryIndexer)
                .environmentObject(exactDuplicateIndexer)
                .environmentObject(amazonPhotosSettingsStore)
                .environmentObject(amazonPhotosIndexer)
                .environmentObject(comparisonViewModel)
        }
        .windowToolbarStyle(.automatic)
    }
}
