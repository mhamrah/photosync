import CoreData
import Photos
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case summary
    case library
    case comparison
    case transferQueue
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Dashboard"
        case .library: return "Libraries"
        case .comparison: return "Comparison"
        case .transferQueue: return "Transfer Queue"
        case .settings: return "Settings"
        }
    }

    var systemImageName: String {
        switch self {
        case .summary: return "rectangle.grid.1x2"
        case .library: return "photo.on.rectangle.angled"
        case .comparison: return "square.stack.3d.up"
        case .transferQueue: return "arrow.down.circle"
        case .settings: return "gear"
        }
    }
}

private enum FeatureFlags {
    static var similarityFeaturesEnabled: Bool {
        UserDefaults.standard.object(forKey: "feature.similarity.enabled") as? Bool ?? true
    }
}

struct ContentView: View {
    @EnvironmentObject private var photoAuthorizationController: PhotoLibraryAuthorizationController
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @EnvironmentObject private var exactDuplicateIndexer: ExactDuplicateIndexer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppSection? = .summary

    var body: some View {
        ZStack {
            NavigationSplitView {
                List(AppSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImageName)
                        .tag(section)
                }
                .navigationTitle("PhotoSync Companion")
            } detail: {
                Group {
                    switch selection ?? .summary {
                    case .summary:
                        SummaryPlaceholder()
                    case .library:
                        PhotoGridPlaceholder()
                    case .comparison:
                        ComparisonPlaceholder()
                    case .transferQueue:
                        TransferQueuePlaceholder()
                    case .settings:
                        SettingsPlaceholder()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .disabled(photoAuthorizationController.state.blocksInteraction)
            .blur(radius: photoAuthorizationController.state.blocksInteraction ? 5 : 0)
            .animation(.easeInOut(duration: 0.2), value: photoAuthorizationController.state.blocksInteraction)

            AuthorizationOverlayView(
                state: photoAuthorizationController.state,
                openSettings: photoAuthorizationController.openPrivacySettings,
                requestAccess: {
                    Task {
                        await photoAuthorizationController.requestAuthorizationIfNeeded(trigger: .userInitiated)
                    }
                }
            )
            .padding()
        }
        .task {
            await photoAuthorizationController.requestAuthorizationIfNeeded(trigger: .automatic)
            handleAuthorizationChange(photoAuthorizationController.state)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                photoAuthorizationController.refreshAuthorizationStatus()
            }
        }
        .onChange(of: photoAuthorizationController.state) { newState in
            handleAuthorizationChange(newState)
        }
        .onChange(of: photoLibraryIndexer.state) { newState in
            if FeatureFlags.similarityFeaturesEnabled, case .completed = newState {
                exactDuplicateIndexer.startIndexingIfNeeded()
            }
        }
    }

    private func handleAuthorizationChange(_ state: PhotoLibraryAuthorizationController.AuthorizationState) {
        switch state {
        case .authorized, .limited:
            photoLibraryIndexer.startIndexingIfNeeded()
            if FeatureFlags.similarityFeaturesEnabled, case .completed = photoLibraryIndexer.state {
                exactDuplicateIndexer.startIndexingIfNeeded()
            }
        case .denied, .restricted, .error:
            photoLibraryIndexer.cancelIndexing()
            exactDuplicateIndexer.cancelIndexing()
        case .notDetermined, .requesting:
            break
        }
    }
}

private struct SummaryPlaceholder: View {
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @EnvironmentObject private var exactDuplicateIndexer: ExactDuplicateIndexer

    var body: some View {
        ContentPlaceholder(
            title: "Sync Overview",
            message: "Status insights, totals, and last synchronization summary will appear here.",
            accessory: {
                VStack(alignment: .leading, spacing: 16) {
                    IndexerStatusView(state: photoLibraryIndexer.state)
                    DuplicateIndexerStatusView(state: exactDuplicateIndexer.state)
                }
            }
        )
    }
}

private struct PhotoGridPlaceholder: View {
    var body: some View {
        PhotoLibraryGridWorkspaceView()
    }
}

private struct ComparisonPlaceholder: View {
    var body: some View {
        ComparisonWorkspaceView()
    }
}

private struct TransferQueuePlaceholder: View {
    var body: some View {
        ContentPlaceholder(
            title: "Transfer Queue",
            message: "Monitor Amazon-to-Photos imports, retry failures, and review completed transfers."
        )
    }
}

private struct SettingsPlaceholder: View {
    var body: some View {
        ContentPlaceholder(
            title: "Settings",
            message: "Configure accounts, sync preferences, storage options, and privacy controls."
        )
    }
}

private enum PhotoGridDateFilter: Hashable {
    case all
    case year(Int)
    case month(Int, Int)
}

private enum PhotoDeleteTarget: String, CaseIterable, Identifiable {
    case amazon
    case iCloud
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amazon:
            return "Delete from Amazon"
        case .iCloud:
            return "Delete from iCloud"
        case .both:
            return "Delete from Amazon and iCloud"
        }
    }

    func confirmationMessage(photoCount: Int) -> String {
        switch self {
        case .amazon:
            return "Delete \(photoCount) selected photo(s) from Amazon?"
        case .iCloud:
            return "Delete \(photoCount) selected photo(s) from iCloud/Apple Photos?"
        case .both:
            return "Delete \(photoCount) selected photo(s) from Amazon and iCloud/Apple Photos?"
        }
    }
}

private struct PhotoDeletionSummary {
    let requestedCount: Int
    let amazonDeletedCount: Int
    let iCloudDeletedCount: Int
}

private struct PhotoGridMonthBucket: Identifiable {
    let year: Int
    let month: Int
    let count: Int

    var id: String { "\(year)-\(month)" }

    var title: String {
        Self.monthNameFormatter.monthSymbols[max(0, min(month - 1, 11))]
    }

    private static let monthNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()
}

private struct PhotoGridYearBucket: Identifiable {
    let year: Int
    let totalCount: Int
    let months: [PhotoGridMonthBucket]

    var id: Int { year }
}

private struct PhotoDeletionService {
    private let persistenceController: PersistenceController

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    func delete(localIdentifiers: [String], target: PhotoDeleteTarget) async throws -> PhotoDeletionSummary {
        guard !localIdentifiers.isEmpty else {
            return PhotoDeletionSummary(requestedCount: 0, amazonDeletedCount: 0, iCloudDeletedCount: 0)
        }

        var amazonDeletedCount = 0
        var iCloudDeletedCount = 0

        if target == .amazon || target == .both {
            amazonDeletedCount = try await clearAmazonCloudIdentifiers(localIdentifiers: localIdentifiers)
        }

        if target == .iCloud || target == .both {
            try await deleteFromPhotoLibrary(localIdentifiers: localIdentifiers)
            iCloudDeletedCount = try await deleteLocalRecords(localIdentifiers: localIdentifiers)
        }

        return PhotoDeletionSummary(
            requestedCount: localIdentifiers.count,
            amazonDeletedCount: amazonDeletedCount,
            iCloudDeletedCount: iCloudDeletedCount
        )
    }

    private func clearAmazonCloudIdentifiers(localIdentifiers: [String]) async throws -> Int {
        let context = persistenceController.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = false

        return try await context.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(
                format: "localIdentifier IN %@ AND cloudIdentifier != nil",
                localIdentifiers
            )

            let assets = try context.fetch(request)
            for asset in assets {
                asset.cloudIdentifier = nil
            }

            if context.hasChanges {
                try context.save()
                context.reset()
            }

            return assets.count
        }
    }

    private func deleteLocalRecords(localIdentifiers: [String]) async throws -> Int {
        let context = persistenceController.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = false

        return try await context.perform {
            let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            request.predicate = NSPredicate(format: "localIdentifier IN %@", localIdentifiers)

            let assets = try context.fetch(request)
            for asset in assets {
                context.delete(asset)
            }

            if context.hasChanges {
                try context.save()
                context.reset()
            }

            return assets.count
        }
    }

    private func deleteFromPhotoLibrary(localIdentifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
            guard fetchResult.count > 0 else {
                continuation.resume(returning: ())
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: DeletionError.deletionFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private enum DeletionError: LocalizedError {
        case deletionFailed

        var errorDescription: String? {
            switch self {
            case .deletionFailed:
                return "Photo library deletion failed."
            }
        }
    }
}

@MainActor
private final class PhotoLibraryGridViewModel: ObservableObject {
    @Published var selectedFilter: PhotoGridDateFilter? = .all
    @Published var selectedIdentifiers: Set<String> = []
    @Published var isDeleting = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let deletionService: PhotoDeletionService

    init(persistenceController: PersistenceController = .shared) {
        self.deletionService = PhotoDeletionService(persistenceController: persistenceController)
    }

    func toggleSelection(localIdentifier: String) {
        if selectedIdentifiers.contains(localIdentifier) {
            selectedIdentifiers.remove(localIdentifier)
        } else {
            selectedIdentifiers.insert(localIdentifier)
        }
    }

    func clearSelection() {
        selectedIdentifiers.removeAll()
    }

    func pruneSelection(validIdentifiers: Set<String>) {
        selectedIdentifiers.formIntersection(validIdentifiers)
    }

    func deleteSelected(to target: PhotoDeleteTarget) async -> Bool {
        let identifiers = Array(selectedIdentifiers)
        guard !identifiers.isEmpty else {
            return false
        }

        isDeleting = true
        defer { isDeleting = false }

        do {
            let summary = try await deletionService.delete(localIdentifiers: identifiers, target: target)
            selectedIdentifiers.removeAll()
            errorMessage = nil
            statusMessage = Self.makeStatusMessage(summary: summary, target: target)
            return true
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            return false
        }
    }

    private static func makeStatusMessage(summary: PhotoDeletionSummary, target: PhotoDeleteTarget) -> String {
        switch target {
        case .amazon:
            return "Amazon delete completed for \(summary.amazonDeletedCount.formatted()) of \(summary.requestedCount.formatted()) selected photos."
        case .iCloud:
            return "iCloud delete completed for \(summary.iCloudDeletedCount.formatted()) photos."
        case .both:
            return "Delete completed. Amazon: \(summary.amazonDeletedCount.formatted()), iCloud: \(summary.iCloudDeletedCount.formatted())."
        }
    }
}

private struct PhotoLibraryGridWorkspaceView: View {
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @EnvironmentObject private var similarityIndexer: ExactDuplicateIndexer
    @StateObject private var viewModel = PhotoLibraryGridViewModel()
    @State private var pendingDeleteTarget: PhotoDeleteTarget?
    @State private var showDeleteConfirmation = false

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "creationDate", ascending: false),
            NSSortDescriptor(key: "localIdentifier", ascending: true)
        ],
        predicate: NSPredicate(format: "mediaTypeRaw == %d", Int16(PHAssetMediaType.image.rawValue)),
        animation: .default
    )
    private var photoAssets: FetchedResults<LocalAsset>

    private let calendar = Calendar.autoupdatingCurrent
    private let gridColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)]

    var body: some View {
        HStack(spacing: 0) {
            timelineSidebar
                .frame(minWidth: 250, idealWidth: 260, maxWidth: 280)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                header
                filterSummary

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.green)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if filteredAssets.isEmpty {
                    VStack(alignment: .center, spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("No Photos")
                            .font(.headline)
                        Text("No photos match the selected month or year.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(filteredAssets, id: \.localIdentifier) { asset in
                                PhotoGridTile(
                                    localIdentifier: asset.localIdentifier,
                                    creationDate: asset.creationDate,
                                    isFavorite: asset.isFavorite,
                                    keepPreferred: asset.keepPreferred,
                                    isSelected: viewModel.selectedIdentifiers.contains(asset.localIdentifier),
                                    onTap: { viewModel.toggleSelection(localIdentifier: asset.localIdentifier) }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(22)
        }
        .onChange(of: assetIdentifierSnapshot) { snapshot in
            viewModel.pruneSelection(validIdentifiers: Set(snapshot))
        }
        .alert(
            "Delete Selected Photos",
            isPresented: $showDeleteConfirmation,
            presenting: pendingDeleteTarget
        ) { target in
            Button("Cancel", role: .cancel) {
                pendingDeleteTarget = nil
            }
            Button("Delete", role: .destructive) {
                Task {
                    let didDelete = await viewModel.deleteSelected(to: target)
                    pendingDeleteTarget = nil
                    if didDelete {
                        photoLibraryIndexer.startIndexingIfNeeded(force: true)
                        if FeatureFlags.similarityFeaturesEnabled {
                            similarityIndexer.startIndexingIfNeeded(force: true)
                        }
                    }
                }
            }
        } message: { target in
            Text(target.confirmationMessage(photoCount: viewModel.selectedIdentifiers.count))
        }
    }

    private var allAssets: [LocalAsset] {
        Array(photoAssets)
    }

    private var assetIdentifierSnapshot: [String] {
        allAssets.map(\.localIdentifier)
    }

    private var filteredAssets: [LocalAsset] {
        let filter = viewModel.selectedFilter ?? .all
        return allAssets.filter { matches($0, filter: filter) }
    }

    private var yearBuckets: [PhotoGridYearBucket] {
        var monthCounts: [MonthKey: Int] = [:]
        monthCounts.reserveCapacity(allAssets.count)

        for asset in allAssets {
            guard let creationDate = asset.creationDate else { continue }
            let components = calendar.dateComponents([.year, .month], from: creationDate)
            guard let year = components.year, let month = components.month else { continue }
            monthCounts[MonthKey(year: year, month: month), default: 0] += 1
        }

        let groupedByYear = Dictionary(grouping: monthCounts.keys, by: \.year)
        return groupedByYear.map { year, keys in
            let months = keys
                .sorted { $0.month > $1.month }
                .map { key in
                    PhotoGridMonthBucket(
                        year: key.year,
                        month: key.month,
                        count: monthCounts[key] ?? 0
                    )
                }

            return PhotoGridYearBucket(
                year: year,
                totalCount: months.reduce(0) { $0 + $1.count },
                months: months
            )
        }
        .sorted { $0.year > $1.year }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Libraries")
                    .font(.largeTitle)
                    .bold()
                Text("Browse your photo grid by year and month, then delete selected photos from Amazon, iCloud, or both.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isDeleting {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                ForEach(PhotoDeleteTarget.allCases) { target in
                    Button(target.label) {
                        pendingDeleteTarget = target
                        showDeleteConfirmation = true
                    }
                }
            } label: {
                Label("Delete Selected", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedIdentifiers.isEmpty || viewModel.isDeleting)
        }
    }

    private var filterSummary: some View {
        HStack(spacing: 14) {
            Text(activeFilterText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(viewModel.selectedIdentifiers.count.formatted()) selected")
                .font(.callout.weight(.semibold))

            Button("Clear Selection") {
                viewModel.clearSelection()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedIdentifiers.isEmpty)
        }
    }

    private var timelineSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            List(selection: $viewModel.selectedFilter) {
                timelineRow(title: "All Photos", count: allAssets.count, filter: .all, leadingPadding: 0)

                ForEach(yearBuckets) { year in
                    timelineRow(
                        title: "\(year.year)",
                        count: year.totalCount,
                        filter: .year(year.year),
                        leadingPadding: 0
                    )

                    ForEach(year.months) { month in
                        timelineRow(
                            title: month.title,
                            count: month.count,
                            filter: .month(month.year, month.month),
                            leadingPadding: 14
                        )
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func timelineRow(
        title: String,
        count: Int,
        filter: PhotoGridDateFilter,
        leadingPadding: CGFloat
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .padding(.leading, leadingPadding)
            Spacer()
            Text(count.formatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(Optional(filter))
    }

    private var activeFilterText: String {
        switch viewModel.selectedFilter ?? .all {
        case .all:
            return "Showing all \(allAssets.count.formatted()) photos."
        case .year(let year):
            let count = filteredAssets.count
            return "Showing \(count.formatted()) photos in \(year)."
        case .month(let year, let month):
            let monthName = PhotoGridMonthBucket(year: year, month: month, count: 0).title
            return "Showing \(filteredAssets.count.formatted()) photos in \(monthName) \(year)."
        }
    }

    private func matches(_ asset: LocalAsset, filter: PhotoGridDateFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .year(let year):
            guard let creationDate = asset.creationDate else { return false }
            return calendar.component(.year, from: creationDate) == year
        case .month(let year, let month):
            guard let creationDate = asset.creationDate else { return false }
            let components = calendar.dateComponents([.year, .month], from: creationDate)
            return components.year == year && components.month == month
        }
    }

    private struct MonthKey: Hashable {
        let year: Int
        let month: Int
    }
}

private struct PhotoGridTile: View {
    let localIdentifier: String
    let creationDate: Date?
    let isFavorite: Bool
    let keepPreferred: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    AssetThumbnailView(localIdentifier: localIdentifier, dimension: 150)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .blue)
                            .padding(8)
                    }
                }

                Text(creationDate.map(Self.dateFormatter.string(from:)) ?? "Unknown date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                    if keepPreferred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    Spacer()
                }
                .font(.caption)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private enum ComparisonMode: String, CaseIterable, Identifiable {
    case exact
    case near
    case similar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact:
            return "Exact Duplicates"
        case .near:
            return "Near Duplicates"
        case .similar:
            return "Similar Search"
        }
    }
}

@MainActor
private final class ComparisonViewModel: ObservableObject {
    @Published var mode: ComparisonMode = .exact
    @Published var exactGroups: [ExactDuplicateGroup] = []
    @Published var nearGroups: [NearDuplicateGroup] = []
    @Published var similarMatches: [SimilarAssetMatch] = []
    @Published var selectedIdentifier: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var topK = 24
    @Published var minimumLongestEdge = 0
    @Published var lastYearOnly = false

    private let persistenceController: PersistenceController
    private let similaritySearchService: SimilaritySearchService

    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        self.similaritySearchService = SimilaritySearchService(persistenceController: persistenceController)
    }

    func refreshAll() async {
        guard FeatureFlags.similarityFeaturesEnabled else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let options = SimilaritySearchOptions(
                dateRange: nil,
                minimumLongestEdge: nil,
                sortOrder: .relevance,
                pagination: SimilarityPagination(page: 0, pageSize: 300)
            )
            async let exact = similaritySearchService.findExactDuplicateGroups(options: options)
            async let near = similaritySearchService.findNearDuplicateGroups(maxDistance: 6, options: options)
            exactGroups = try await exact
            nearGroups = try await near
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedIdentifier(_ identifier: String) {
        selectedIdentifier = identifier
        mode = .similar
    }

    func runSimilaritySearch() async {
        guard FeatureFlags.similarityFeaturesEnabled else { return }
        guard let selectedIdentifier, !selectedIdentifier.isEmpty else {
            similarMatches = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            var dateRange: ClosedRange<Date>?
            if lastYearOnly {
                let now = Date()
                let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
                dateRange = lastYear...now
            }

            let options = SimilaritySearchOptions(
                dateRange: dateRange,
                minimumLongestEdge: minimumLongestEdge > 0 ? minimumLongestEdge : nil,
                sortOrder: .relevance,
                pagination: SimilarityPagination(page: 0, pageSize: max(1, topK))
            )
            similarMatches = try await similaritySearchService.findSimilarAssets(
                to: selectedIdentifier,
                topK: topK,
                options: options
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleKeepPreferred(for localIdentifier: String) async {
        do {
            let backgroundContext = persistenceController.container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            backgroundContext.automaticallyMergesChangesFromParent = false

            try await backgroundContext.perform {
                let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "localIdentifier == %@", localIdentifier)

                guard let asset = try backgroundContext.fetch(request).first else { return }
                asset.keepPreferred.toggle()
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    backgroundContext.reset()
                }
            }

            await refreshAll()
            if selectedIdentifier != nil {
                await runSimilaritySearch()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ComparisonWorkspaceView: View {
    @EnvironmentObject private var similarityIndexer: ExactDuplicateIndexer
    @StateObject private var viewModel = ComparisonViewModel()
    @State private var expandedExactGroupIDs: Set<String> = []
    @State private var expandedNearGroupIDs: Set<String> = []
    @State private var manualIdentifierInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catalog Comparison")
                        .font(.largeTitle)
                        .bold()
                    Text("Review exact duplicates, near-duplicate clusters, and visually similar photos.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Refresh") {
                    Task {
                        await viewModel.refreshAll()
                        await viewModel.runSimilaritySearch()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if !FeatureFlags.similarityFeaturesEnabled {
                Text("Similarity features are currently disabled. Set `feature.similarity.enabled` in `UserDefaults` to enable indexing and search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Picker("Comparison Mode", selection: $viewModel.mode) {
                    ForEach(ComparisonMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                switch viewModel.mode {
                case .exact:
                    exactGroupsView
                case .near:
                    nearGroupsView
                case .similar:
                    similarSearchView
                }
            }
        }
        .padding(24)
        .task {
            await viewModel.refreshAll()
        }
        .onChange(of: similarityIndexer.state) { newState in
            if case .completed = newState {
                Task {
                    await viewModel.refreshAll()
                    await viewModel.runSimilaritySearch()
                }
            }
        }
    }

    private var exactGroupsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if viewModel.exactGroups.isEmpty {
                    Text("No exact duplicate groups were found in the indexed library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.exactGroups) { group in
                    ExactGroupCard(
                        group: group,
                        isExpanded: binding(for: group.id, in: $expandedExactGroupIDs),
                        onFindSimilar: { identifier in
                            viewModel.setSelectedIdentifier(identifier)
                            manualIdentifierInput = identifier
                            Task { await viewModel.runSimilaritySearch() }
                        },
                        onToggleKeep: { identifier in
                            Task { await viewModel.toggleKeepPreferred(for: identifier) }
                        }
                    )
                }
            }
        }
    }

    private var nearGroupsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if viewModel.nearGroups.isEmpty {
                    Text("No near-duplicate clusters were found at the current Hamming distance threshold.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.nearGroups) { group in
                    NearGroupCard(
                        group: group,
                        isExpanded: binding(for: group.id, in: $expandedNearGroupIDs),
                        onFindSimilar: { identifier in
                            viewModel.setSelectedIdentifier(identifier)
                            manualIdentifierInput = identifier
                            Task { await viewModel.runSimilaritySearch() }
                        },
                        onToggleKeep: { identifier in
                            Task { await viewModel.toggleKeepPreferred(for: identifier) }
                        }
                    )
                }
            }
        }
    }

    private var similarSearchView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TextField("Local identifier", text: $manualIdentifierInput)
                    .textFieldStyle(.roundedBorder)

                Button("Set Seed") {
                    let trimmed = manualIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.setSelectedIdentifier(trimmed)
                    Task { await viewModel.runSimilaritySearch() }
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 18) {
                Stepper("Top K: \(viewModel.topK)", value: $viewModel.topK, in: 5...100, step: 1)
                Stepper("Min edge: \(viewModel.minimumLongestEdge)", value: $viewModel.minimumLongestEdge, in: 0...5000, step: 250)
                Toggle("Last 12 months", isOn: $viewModel.lastYearOnly)
                    .toggleStyle(.checkbox)
                Button("Run Similarity Search") {
                    Task { await viewModel.runSimilaritySearch() }
                }
                .buttonStyle(.borderedProminent)
            }

            if let selectedIdentifier = viewModel.selectedIdentifier {
                HStack(spacing: 10) {
                    AssetThumbnailView(localIdentifier: selectedIdentifier, dimension: 56)
                    Text("Seed: \(selectedIdentifier)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a seed asset from exact/near groups, or set one manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.similarMatches.isEmpty {
                        Text("No similarity matches yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(viewModel.similarMatches) { match in
                        ComparisonAssetRow(
                            localIdentifier: match.localIdentifier,
                            keepPreferred: match.keepPreferred,
                            detailText: "Distance: \(Self.formatDistance(Double(match.distance))) • Score: \(Self.formatDistance(match.score))",
                            trailingText: match.creationDate.map(Self.dateFormatter.string(from:)) ?? "Unknown date",
                            onFindSimilar: {
                                viewModel.setSelectedIdentifier(match.localIdentifier)
                                manualIdentifierInput = match.localIdentifier
                                Task { await viewModel.runSimilaritySearch() }
                            },
                            onToggleKeep: {
                                Task { await viewModel.toggleKeepPreferred(for: match.localIdentifier) }
                            }
                        )
                    }
                }
            }
        }
    }

    private func binding(for key: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    set.wrappedValue.insert(key)
                } else {
                    set.wrappedValue.remove(key)
                }
            }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func formatDistance(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct ComparisonAssetRow: View {
    let localIdentifier: String
    let keepPreferred: Bool
    let detailText: String
    let trailingText: String
    let onFindSimilar: () -> Void
    let onToggleKeep: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnailView(localIdentifier: localIdentifier, dimension: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(localIdentifier)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(trailingText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: onFindSimilar) {
                Label("Similar", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.bordered)

            Button(action: onToggleKeep) {
                Image(systemName: keepPreferred ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help(keepPreferred ? "Unset preferred keep candidate" : "Mark preferred keep candidate")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct ExactGroupCard: View {
    let group: ExactDuplicateGroup
    @Binding var isExpanded: Bool
    let onFindSimilar: (String) -> Void
    let onToggleKeep: (String) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                VStack(spacing: 10) {
                    ForEach(group.assets) { asset in
                        ComparisonAssetRow(
                            localIdentifier: asset.localIdentifier,
                            keepPreferred: asset.keepPreferred,
                            detailText: "\(asset.pixelWidth)×\(asset.pixelHeight)",
                            trailingText: asset.creationDate.map(Self.dateFormatter.string(from:)) ?? "Unknown date",
                            onFindSimilar: { onFindSimilar(asset.localIdentifier) },
                            onToggleKeep: { onToggleKeep(asset.localIdentifier) }
                        )
                    }
                }
                .padding(.top, 8)
            },
            label: {
                HStack {
                    Text("Hash \(group.contentHash.prefix(12))…")
                        .font(.headline)
                    Spacer()
                    Text("\(group.assetCount.formatted()) assets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        )
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct NearGroupCard: View {
    let group: NearDuplicateGroup
    @Binding var isExpanded: Bool
    let onFindSimilar: (String) -> Void
    let onToggleKeep: (String) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                VStack(spacing: 10) {
                    ForEach(group.assets) { asset in
                        ComparisonAssetRow(
                            localIdentifier: asset.localIdentifier,
                            keepPreferred: asset.keepPreferred,
                            detailText: "Distance: \(asset.hammingDistanceFromSeed) • Confidence: \(Self.formatPercent(asset.confidence))",
                            trailingText: asset.creationDate.map(Self.dateFormatter.string(from:)) ?? "Unknown date",
                            onFindSimilar: { onFindSimilar(asset.localIdentifier) },
                            onToggleKeep: { onToggleKeep(asset.localIdentifier) }
                        )
                    }
                }
                .padding(.top, 8)
            },
            label: {
                HStack {
                    Text("Seed \(group.seedIdentifier)")
                        .font(.headline)
                    Spacer()
                    Text("Avg distance \(Self.formatAverage(group.averageDistance))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• \(group.assetCount.formatted()) assets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        )
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        )
    }

    private static func formatAverage(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct AssetThumbnailView: View {
    let localIdentifier: String
    let dimension: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: dimension, height: dimension)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2))
        )
        .task(id: localIdentifier) {
            image = await Self.loadThumbnail(localIdentifier: localIdentifier, dimension: dimension)
        }
    }

    private static func loadThumbnail(localIdentifier: String, dimension: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = result.firstObject else {
                continuation.resume(returning: nil)
                return
            }

            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast

            let manager = PHCachingImageManager()
            let lock = NSLock()
            var resumed = false
            _ = manager.requestImage(
                for: asset,
                targetSize: CGSize(width: dimension * 2, height: dimension * 2),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                lock.lock()
                defer { lock.unlock() }
                if resumed {
                    return
                }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                    return
                }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

private struct ContentPlaceholder<Accessory: View>: View {
    let title: String
    let message: String
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, message: String, accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.message = message
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.largeTitle)
                    .bold()
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accessory()

            Spacer()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Upcoming Implementation")
                    .font(.headline)
                Text("This section will connect to live data sources, Combine publishers, and progress indicators in subsequent milestones.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
    }
}

#Preview("Authorized") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(PhotoLibraryAuthorizationController.previewAuthorized)
        .environmentObject(PhotoLibraryIndexer.previewCompleted)
        .environmentObject(ExactDuplicateIndexer.previewCompleted)
        .frame(width: 960, height: 600)
}

#Preview("Denied") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(PhotoLibraryAuthorizationController.previewDenied)
        .environmentObject(PhotoLibraryIndexer.previewIdle)
        .environmentObject(ExactDuplicateIndexer.previewIdle)
        .frame(width: 960, height: 600)
}

private struct AuthorizationOverlayView: View {
    let state: PhotoLibraryAuthorizationController.AuthorizationState
    let openSettings: () -> Void
    let requestAccess: () -> Void

    var body: some View {
        switch state {
        case .authorized, .limited:
            EmptyView()
        case .notDetermined:
            overlayCard(showProgress: false, showSettingsButton: false, showRequestButton: true)
        case .requesting:
            overlayCard(showProgress: true, showSettingsButton: false, showRequestButton: false)
        case .denied, .restricted:
            overlayCard(showProgress: false, showSettingsButton: state.shouldShowOpenSettings, showRequestButton: false)
        case .error:
            overlayCard(showProgress: false, showSettingsButton: false, showRequestButton: false)
        }
    }

    @ViewBuilder
    private func overlayCard(showProgress: Bool, showSettingsButton: Bool, showRequestButton: Bool) -> some View {
        VStack(spacing: 16) {
            Text(state.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(state.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showProgress {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            if showRequestButton {
                Button("Allow Access", action: requestAccess)
                    .buttonStyle(.borderedProminent)
            }

            if showSettingsButton {
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 20, y: 10)
    }
}

private struct IndexerStatusView: View {
    let state: PhotoLibraryIndexer.State

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Library Index")
                .font(.headline)

            switch state {
            case .idle:
                Text("Indexing will begin automatically once photo library access is granted.")
                    .foregroundStyle(.secondary)
            case .indexing(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fractionComplete)
                    Text("Indexing \(progress.processed.formatted()) of \(progress.total.formatted()) assets…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .completed(let completion):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexed \(completion.processed.formatted()) assets")
                    Text("Last run \(completion.completedAt, style: .relative)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexing failed")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .foregroundStyle(.thinMaterial)
                )
        )
    }
}

private struct DuplicateIndexerStatusView: View {
    let state: ExactDuplicateIndexer.State

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exact Duplicate Index")
                .font(.headline)

            switch state {
            case .idle:
                Text("Duplicate hashing will run after local metadata indexing completes.")
                    .foregroundStyle(.secondary)
            case .indexing(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fractionComplete)
                    Text("Hashing \(progress.processed.formatted()) of \(progress.total.formatted()) assets…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Exact: \(progress.exactComputed.formatted()) • Near: \(progress.perceptualComputed.formatted()) • Semantic: \(progress.semanticComputed.formatted())")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Failed: \(progress.failed.formatted())")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case .completed(let completion):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exact hashes: \(completion.exactComputed.formatted())")
                    Text("Near hashes: \(completion.perceptualComputed.formatted()) • Semantic vectors: \(completion.semanticComputed.formatted())")
                        .font(.callout)
                    Text("Exact groups: \(completion.summary.exactSummary.duplicateGroupCount.formatted()) • Near groups: \(completion.summary.nearSummary.duplicateGroupCount.formatted())")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Retry queue: \(completion.retryQueueCount.formatted()) • Failed: \(completion.failed.formatted())")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Last run \(completion.completedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate indexing failed")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .foregroundStyle(.thinMaterial)
                )
        )
    }
}
