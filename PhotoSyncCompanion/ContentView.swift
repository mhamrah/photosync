import AppKit
import CoreData
import Photos
import Vision
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case summary
    case libraries
    case comparison
    case transferQueue
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Dashboard"
        case .libraries: return "Libraries"
        case .comparison: return "Comparison"
        case .transferQueue: return "Transfer Queue"
        case .settings: return "Settings"
        }
    }

    var systemImageName: String {
        switch self {
        case .summary: return "rectangle.grid.1x2"
        case .libraries: return "photo.stack"
        case .comparison: return "square.stack.3d.up"
        case .transferQueue: return "arrow.down.circle"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var photoAuthorizationController: PhotoLibraryAuthorizationController
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore
    @EnvironmentObject private var amazonPhotosIndexer: AmazonPhotosIndexer
    @EnvironmentObject private var comparisonViewModel: ComparisonViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: AppSection? = .summary
    @State private var hasStartedInitialAuthorizationFlow = false

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
                        SummarySectionView()
                    case .libraries:
                        LibrariesSectionView()
                    case .comparison:
                        ComparisonSectionView()
                    case .transferQueue:
                        TransferQueueView()
                    case .settings:
                        SettingsSectionView()
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
            guard !hasStartedInitialAuthorizationFlow else { return }
            hasStartedInitialAuthorizationFlow = true
            await prepareWindowForAuthorizationPrompt()
            await photoAuthorizationController.requestAuthorizationIfNeeded(trigger: .automatic)
            handleAuthorizationChange(photoAuthorizationController.state)
            comparisonViewModel.refresh()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                photoAuthorizationController.refreshAuthorizationStatus()
            }
        }
        .onChange(of: photoAuthorizationController.state) { _, newState in
            handleAuthorizationChange(newState)
        }
        .onChange(of: photoLibraryIndexer.state) { _, newState in
            if case .completed = newState {
                comparisonViewModel.refresh()
            }
        }
        .onChange(of: amazonPhotosIndexer.state) { _, newState in
            if case .completed = newState {
                comparisonViewModel.refresh()
            }
        }
    }

    private func handleAuthorizationChange(_ state: PhotoLibraryAuthorizationController.AuthorizationState) {
        switch state {
        case .authorized, .limited:
            photoLibraryIndexer.startIndexingIfNeeded()
        case .denied, .restricted, .error:
            photoLibraryIndexer.cancelIndexing()
        case .notDetermined, .requesting:
            break
        }
    }

    private func prepareWindowForAuthorizationPrompt() async {
        for _ in 0..<12 {
            let windowReady = await MainActor.run { ensurePrimaryWindowIsVisible() }
            if windowReady {
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func ensurePrimaryWindowIsVisible() -> Bool {
        guard let window = primaryWindow,
              let visibleFrame = targetVisibleScreenFrame(for: window)
        else {
            return false
        }

        let frame = window.frame
        let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
        if !visibleFrame.contains(windowCenter) {
            let centeredFrame = CGRect(
                x: visibleFrame.midX - (frame.width / 2),
                y: visibleFrame.midY - (frame.height / 2),
                width: frame.width,
                height: frame.height
            ).integral
            window.setFrame(centeredFrame, display: true)
        }

        window.makeKeyAndOrderFront(nil)
        return true
    }

    @MainActor
    private var primaryWindow: NSWindow? {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })
            ?? NSApplication.shared.windows.first
    }

    @MainActor
    private func targetVisibleScreenFrame(for window: NSWindow) -> CGRect? {
        if let windowScreen = window.screen {
            return windowScreen.visibleFrame
        }

        if let mainScreen = NSScreen.main {
            return mainScreen.visibleFrame
        }

        return NSScreen.screens.first?.visibleFrame
    }
}

private struct SummarySectionView: View {
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer
    @EnvironmentObject private var amazonPhotosIndexer: AmazonPhotosIndexer
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore
    @EnvironmentObject private var comparisonViewModel: ComparisonViewModel

    var body: some View {
        SectionContainer(
            title: "Sync Overview",
            message: "Local and Amazon index status plus duplicate summary."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                IndexerStatusView(state: photoLibraryIndexer.state)
                AmazonIndexerStatusView(state: amazonPhotosIndexer.state)
                ComparisonSummaryCard(
                    summary: comparisonViewModel.summary,
                    isComputing: comparisonViewModel.isComputing,
                    errorMessage: comparisonViewModel.errorMessage
                )
                ProjectProgressCard()
                HStack(spacing: 12) {
                    Button("Sync Amazon Metadata") {
                        amazonPhotosSettingsStore.save()
                        amazonPhotosIndexer.startIndexingIfNeeded(force: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!amazonPhotosSettingsStore.hasCompleteCredentials)

                    Button("Refresh Comparison") {
                        comparisonViewModel.refresh()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private enum ProjectMilestoneStatus: String {
    case completed
    case inProgress
    case remaining

    var title: String {
        switch self {
        case .completed:
            return "Done"
        case .inProgress:
            return "In Progress"
        case .remaining:
            return "Remaining"
        }
    }

    var systemImageName: String {
        switch self {
        case .completed:
            return "checkmark.circle.fill"
        case .inProgress:
            return "clock.fill"
        case .remaining:
            return "circle"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            return .green
        case .inProgress:
            return .orange
        case .remaining:
            return .secondary
        }
    }
}

private struct ProjectMilestone: Identifiable {
    let title: String
    let status: ProjectMilestoneStatus

    var id: String { title }
}

private struct ProjectProgressCard: View {
    private let milestones: [ProjectMilestone] = [
        .init(title: "Restore build and modernize macOS target", status: .completed),
        .init(title: "Unified catalog database", status: .completed),
        .init(title: "Apple Photos metadata ingest", status: .completed),
        .init(title: "Amazon Photos metadata ingest", status: .completed),
        .init(title: "Image similarity pipeline", status: .completed),
        .init(title: "Persistent match and sync plan generation", status: .completed),
        .init(title: "Unified catalog grid and search", status: .completed),
        .init(title: "Inspectable duplicate and comparison views", status: .completed),
        .init(title: "Apple AI labels, OCR, people, and semantic indexing", status: .completed),
        .init(title: "Approval-based sync execution", status: .completed),
        .init(title: "Queue reconciliation and focused tests", status: .inProgress),
        .init(title: "Final UI polish and large-library performance", status: .inProgress)
    ]

    private var completedCount: Int {
        milestones.filter { $0.status == .completed }.count
    }

    private var fractionComplete: Double {
        Double(completedCount) / Double(max(milestones.count, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project Progress")
                    .font(.headline)
                Spacer()
                Text("\(completedCount) of \(milestones.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: fractionComplete)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 8) {
                ForEach(milestones) { milestone in
                    HStack(spacing: 8) {
                        Image(systemName: milestone.status.systemImageName)
                            .foregroundStyle(milestone.status.tint)
                            .frame(width: 18)
                        Text(milestone.title)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }
}

private struct LibrariesSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Libraries")
                .font(.largeTitle)
                .bold()
            Text("Browse iPhoto and Amazon Photos in tile view, navigate local photos by month/year, and delete from Amazon, iCloud, or both.")
                .foregroundStyle(.secondary)

            TabView {
                UnifiedCatalogTabView()
                    .tabItem {
                        Label("Catalog", systemImage: "rectangle.grid.2x2")
                    }

                LocalLibraryTabView()
                    .tabItem {
                        Label("iPhoto", systemImage: "photo.on.rectangle")
                    }

                AmazonLibraryTabView()
                    .tabItem {
                        Label("Amazon Photos", systemImage: "shippingbox")
                    }
            }
        }
        .padding(24)
    }
}

private enum CatalogSourceFilter: String, CaseIterable, Identifiable {
    case all
    case applePhotos
    case amazonPhotos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .applePhotos:
            return "iPhoto"
        case .amazonPhotos:
            return "Amazon"
        }
    }

    var sources: Set<AssetSource> {
        switch self {
        case .all:
            return Set(AssetSource.allCases)
        case .applePhotos:
            return [.applePhotos]
        case .amazonPhotos:
            return [.amazonPhotos]
        }
    }
}

private extension AssetSource {
    var displayName: String {
        switch self {
        case .applePhotos:
            return "iPhoto"
        case .amazonPhotos:
            return "Amazon"
        }
    }
}

private extension AssetAnalysis.AnalysisStatus {
    var displayName: String {
        switch self {
        case .pending:
            return "Pending"
        case .success:
            return "Complete"
        case .failed:
            return "Failed"
        }
    }
}

private extension CatalogAssetSnapshot {
    var labelSummary: String {
        guard let labelsRaw, !labelsRaw.isEmpty else { return "none" }
        let labels = labelsRaw
            .split(separator: "\n")
            .prefix(5)
            .map { row -> String in
                let parts = row.split(separator: "|", maxSplits: 1).map(String.init)
                return parts.first ?? String(row)
            }
        return labels.isEmpty ? "none" : labels.joined(separator: ", ")
    }

    var faceSummary: String {
        let count = faceClusterIDsRaw?
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .count ?? 0
        return count == 0 ? "No faces" : "\(count.formatted()) face\(count == 1 ? "" : "s")"
    }

    var ocrSummary: String {
        guard let ocrText, !ocrText.isEmpty else { return "No text" }
        return ocrText.replacingOccurrences(of: "\n", with: " ")
    }
}

private extension MatchKind {
    var displayName: String {
        switch self {
        case .exact:
            return "Exact"
        case .nearDuplicate:
            return "Near Duplicate"
        case .semanticSimilar:
            return "Semantic"
        case .appleOnly:
            return "iPhoto Only"
        case .amazonOnly:
            return "Amazon Only"
        case .manualReview:
            return "Manual Review"
        }
    }
}

private extension SyncActionKind {
    var displayName: String {
        switch self {
        case .uploadToAmazon:
            return "Upload to Amazon"
        case .importToApplePhotos:
            return "Import to iPhoto"
        case .trashAmazon:
            return "Move Amazon to Trash"
        case .deleteApple:
            return "Delete iPhoto Asset"
        case .ignore:
            return "Ignore"
        case .manualReview:
            return "Manual Review"
        }
    }

    var systemImageName: String {
        switch self {
        case .uploadToAmazon:
            return "icloud.and.arrow.up"
        case .importToApplePhotos:
            return "square.and.arrow.down"
        case .trashAmazon:
            return "trash"
        case .deleteApple:
            return "trash.slash"
        case .ignore:
            return "minus.circle"
        case .manualReview:
            return "questionmark.circle"
        }
    }
}

private extension SyncPlanStatus {
    var displayName: String {
        switch self {
        case .proposed:
            return "Proposed"
        case .approved:
            return "Approved"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }

    var systemImageName: String {
        switch self {
        case .proposed:
            return "circle"
        case .approved:
            return "checkmark.circle"
        case .running:
            return "clock"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .skipped:
            return "forward.circle"
        }
    }

    var tint: Color {
        switch self {
        case .proposed:
            return .secondary
        case .approved:
            return .blue
        case .running:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .secondary
        }
    }
}

private struct UnifiedCatalogTabView: View {
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "creationDate", ascending: false)],
        animation: .default
    )
    private var localAssets: FetchedResults<LocalAsset>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "createdDate", ascending: false)],
        animation: .default
    )
    private var amazonAssets: FetchedResults<AmazonAsset>

    @State private var searchText = ""
    @State private var sourceFilter: CatalogSourceFilter = .all
    @State private var assets: [CatalogAssetSnapshot] = []
    @State private var selectedIdentifier: UnifiedAssetIdentifier?
    @State private var thumbnailCache: [UnifiedAssetIdentifier: NSImage] = [:]
    @State private var fullImageCache: [UnifiedAssetIdentifier: NSImage] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("catalogGridThumbnailSize") private var thumbnailSize = 170.0
    @AppStorage("catalogPreviewPaneWidth") private var previewPaneWidth = 460.0

    private let searchService = CatalogSearchService(persistenceController: .shared)

    private var selectedAsset: CatalogAssetSnapshot? {
        if let selectedIdentifier {
            return assets.first(where: { $0.id == selectedIdentifier }) ?? assets.first
        }
        return assets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            catalogToolbar

            if isLoading && assets.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                EmptyStateView(title: "Catalog Search Failed", message: errorMessage)
            } else if assets.isEmpty {
                EmptyStateView(
                    title: "No Catalog Results",
                    message: "Run local and Amazon indexing, then refresh the catalog."
                )
            } else {
                HStack(spacing: 0) {
                    catalogGrid
                    Divider()
                    catalogDetail
                }
            }
        }
        .task {
            await reloadCatalog()
        }
        .onChange(of: sourceFilter) { _, _ in
            Task { await reloadCatalog() }
        }
        .onSubmit(of: .search) {
            Task { await reloadCatalog() }
        }
    }

    private var catalogToolbar: some View {
        HStack(spacing: 12) {
            TextField("Search filename, id, label:dog, has:faces, has:text", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .help("Search filenames, IDs, OCR, labels, and media type. Tokens: has:faces, has:text, has:labels, label:<term>, text:<term>.")
                .onChange(of: searchText) { _, _ in
                    Task { await reloadCatalog() }
                }

            Picker("Source", selection: $sourceFilter) {
                ForEach(CatalogSourceFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Button {
                Task { await reloadCatalog() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)

            Spacer()

            Text("\(assets.count.formatted()) results")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            GridSizeSlider(value: $thumbnailSize)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var catalogGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)], spacing: 12) {
                ForEach(assets) { asset in
                    Button {
                        selectedIdentifier = asset.id
                        loadFullImage(for: asset)
                    } label: {
                        LibraryTile(
                            image: thumbnailCache[asset.id],
                            title: asset.normalizedFilename ?? asset.id.sourceIdentifier,
                            subtitle: assetSubtitle(asset),
                            isSelected: asset.id == selectedAsset?.id,
                            thumbnailSize: thumbnailSize
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if selectedIdentifier == nil {
                            selectedIdentifier = asset.id
                        }
                        loadThumbnail(for: asset)
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var catalogDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Catalog Asset")
                    .font(.headline)
                Spacer()
                PreviewPaneWidthSlider(value: $previewPaneWidth)
            }

            if let selectedAsset {
                DetailImageCard(
                    image: fullImageCache[selectedAsset.id] ?? thumbnailCache[selectedAsset.id],
                    placeholderText: "Loading image..."
                )
                .frame(height: 320)
                .onAppear {
                    loadFullImage(for: selectedAsset)
                }

                metadataBlock(
                    title: selectedAsset.normalizedFilename ?? selectedAsset.id.sourceIdentifier,
                    line1: "\(selectedAsset.id.source.displayName)  \(selectedAsset.pixelWidth)x\(selectedAsset.pixelHeight)",
                    line2: "Date: \(DateFormatter.libraryDate(selectedAsset.captureDate))"
                )

                Divider()

                metadataBlock(
                    title: "Analysis",
                    line1: "Status: \(selectedAsset.analysisStatus.displayName)",
                    line2: "Hash: \(selectedAsset.contentHash ?? selectedAsset.md5 ?? selectedAsset.perceptualHash ?? "none")"
                )

                metadataBlock(
                    title: "Apple AI",
                    line1: "Labels: \(selectedAsset.labelSummary)",
                    line2: "\(selectedAsset.faceSummary)  Text: \(selectedAsset.ocrSummary)"
                )

                if selectedAsset.id.source == .amazonPhotos {
                    metadataBlock(
                        title: "Amazon Metadata",
                        line1: "Owner: \(selectedAsset.ownerId ?? "unknown")",
                        line2: "Parents: \(selectedAsset.parentsRaw ?? "none")"
                    )
                    metadataBlock(
                        title: "Amazon Payload",
                        line1: "Indexed: \(selectedAsset.indexedAt?.formatted(date: .abbreviated, time: .standard) ?? "unknown")",
                        line2: "Raw JSON bytes: \(selectedAsset.rawJSON?.count.formatted() ?? "0")"
                    )
                }
            } else {
                Text("Select a catalog asset.")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: previewPaneWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func reloadCatalog() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let query = UnifiedSearchQuery(
                text: searchText,
                sources: sourceFilter.sources,
                matchKinds: [],
                dateRange: nil,
                minimumLongestEdge: nil,
                includesHidden: true,
                includesFavoritesOnly: false
            )
            let results = try await searchService.searchAssets(query, limit: 1_000)
            await MainActor.run {
                assets = results
                if let selectedIdentifier, results.contains(where: { $0.id == selectedIdentifier }) {
                    self.selectedIdentifier = selectedIdentifier
                } else {
                    selectedIdentifier = results.first?.id
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    @ViewBuilder
    private func metadataBlock(title: String, line1: String, line2: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(line1)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(line2)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("\(title)\n\(line1)\n\(line2)")
    }

    private func assetSubtitle(_ asset: CatalogAssetSnapshot) -> String {
        "\(asset.id.source.displayName)  \(DateFormatter.libraryDate(asset.captureDate))"
    }

    private func loadThumbnail(for asset: CatalogAssetSnapshot) {
        guard thumbnailCache[asset.id] == nil else { return }
        Task {
            let image = await loadImage(for: asset, fullSize: false)
            guard let image else { return }
            await MainActor.run {
                thumbnailCache[asset.id] = image
            }
        }
    }

    private func loadFullImage(for asset: CatalogAssetSnapshot) {
        guard fullImageCache[asset.id] == nil else { return }
        Task {
            let image = await loadImage(for: asset, fullSize: true)
            guard let image else { return }
            await MainActor.run {
                fullImageCache[asset.id] = image
            }
        }
    }

    private func loadImage(for asset: CatalogAssetSnapshot, fullSize: Bool) async -> NSImage? {
        switch asset.id.source {
        case .applePhotos:
            return fullSize
                ? await LocalPhotoLibraryBridge.fullImage(localIdentifier: asset.id.sourceIdentifier)
                : await LocalPhotoLibraryBridge.thumbnailImage(localIdentifier: asset.id.sourceIdentifier)
        case .amazonPhotos:
            guard let amazonAsset = amazonAssets.first(where: { $0.nodeId == asset.id.sourceIdentifier }) else {
                return nil
            }
            let config = amazonPhotosSettingsStore.syncConfig
            let credentials = amazonPhotosSettingsStore.credentials
            let fallbackOwnerID = amazonPhotosSettingsStore.lastValidatedOwnerID
            return fullSize
                ? await AmazonMediaBridge.fullImage(for: amazonAsset, config: config, credentials: credentials, fallbackOwnerID: fallbackOwnerID)
                : await AmazonMediaBridge.thumbnailImage(for: amazonAsset, config: config, credentials: credentials, fallbackOwnerID: fallbackOwnerID)
        }
    }
}

private enum LocalGridDateFilter: Hashable {
    case all
    case year(Int)
    case month(Int, Int)
}

private enum LocalDeleteTarget: String, CaseIterable, Identifiable {
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
            return "Delete from Both"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .amazon:
            return "Delete from Amazon?"
        case .iCloud:
            return "Move to iPhoto Trash?"
        case .both:
            return "Delete from Amazon and iCloud?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .amazon:
            return "This deletes the matched asset from Amazon Photos."
        case .iCloud:
            return "This moves the selected asset to Recently Deleted in Photos."
        case .both:
            return "This deletes the matched Amazon asset and moves the selected iPhoto asset to Recently Deleted."
        }
    }
}

private struct LocalGridMonthBucket: Identifiable {
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

private struct LocalGridYearBucket: Identifiable {
    let year: Int
    let totalCount: Int
    let months: [LocalGridMonthBucket]

    var id: Int { year }
}

private struct LocalLibraryTabView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "creationDate", ascending: false)],
        predicate: NSPredicate(format: "mediaTypeRaw == %d", Int16(PHAssetMediaType.image.rawValue)),
        animation: .default
    )
    private var localAssets: FetchedResults<LocalAsset>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "createdDate", ascending: false)],
        animation: .default
    )
    private var amazonAssets: FetchedResults<AmazonAsset>

    @StateObject private var syncController = LibrarySyncController()
    @State private var selectedLocalObjectID: NSManagedObjectID?
    @State private var localThumbnailCache: [NSManagedObjectID: NSImage] = [:]
    @State private var localFullCache: [NSManagedObjectID: NSImage] = [:]
    @State private var amazonThumbnailCache: [NSManagedObjectID: NSImage] = [:]
    @State private var selectedDateFilter: LocalGridDateFilter? = .all
    @State private var pendingDeleteObjectID: NSManagedObjectID?
    @State private var pendingDeleteTarget: LocalDeleteTarget?
    @State private var showDeleteConfirmation = false
    @State private var isPerformingDelete = false
    @AppStorage("localGridThumbnailSize") private var thumbnailSize = 170.0
    @AppStorage("localPreviewPaneWidth") private var previewPaneWidth = 460.0

    private let calendar = Calendar.autoupdatingCurrent

    private var allLocalAssets: [LocalAsset] {
        Array(localAssets)
    }

    private var filteredLocalAssets: [LocalAsset] {
        let filter = selectedDateFilter ?? .all
        return allLocalAssets.filter { asset in
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
    }

    private var selectedLocal: LocalAsset? {
        if let selectedLocalObjectID {
            return filteredLocalAssets.first(where: { $0.objectID == selectedLocalObjectID }) ?? filteredLocalAssets.first
        }
        return filteredLocalAssets.first
    }

    private var matchedAmazon: AmazonAsset? {
        guard let selectedLocal else { return nil }
        return AssetMatcher.matchAmazon(for: selectedLocal, among: Array(amazonAssets))
    }

    private var timelineBuckets: [LocalGridYearBucket] {
        var monthCounts: [MonthKey: Int] = [:]

        for asset in allLocalAssets {
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
                    LocalGridMonthBucket(
                        year: key.year,
                        month: key.month,
                        count: monthCounts[key] ?? 0
                    )
                }

            return LocalGridYearBucket(
                year: year,
                totalCount: months.reduce(0) { $0 + $1.count },
                months: months
            )
        }
        .sorted { $0.year > $1.year }
    }

    var body: some View {
        Group {
            if allLocalAssets.isEmpty {
                EmptyStateView(
                    title: "No iPhoto Assets Indexed",
                    message: "Grant Photos access and allow local indexing to finish."
                )
            } else {
                populatedLocalLibraryContent
            }
        }
    }

    private var populatedLocalLibraryContent: some View {
        HStack(spacing: 0) {
            timelineSidebar
                .frame(minWidth: 240, idealWidth: 250, maxWidth: 270)

            Divider()
            localGridPane
            Divider()
            localDetailPane
        }
        .onAppear {
            if selectedLocalObjectID == nil {
                selectedLocalObjectID = filteredLocalAssets.first?.objectID
            }
        }
        .onChange(of: selectedDateFilter) { _, _ in
            guard let selectedLocalObjectID else {
                selectedLocalObjectID = filteredLocalAssets.first?.objectID
                return
            }
            if !filteredLocalAssets.contains(where: { $0.objectID == selectedLocalObjectID }) {
                self.selectedLocalObjectID = filteredLocalAssets.first?.objectID
            }
        }
        .onChange(of: selectedLocalObjectID) { _, _ in
            guard let selectedLocal else { return }
            loadLocalFullImage(for: selectedLocal)
            if let matchedAmazon {
                loadAmazonThumbnail(for: matchedAmazon)
            }
        }
        .alert(
            pendingDeleteTarget?.confirmationTitle ?? "Delete?",
            isPresented: $showDeleteConfirmation,
            presenting: pendingDeleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                Task {
                    await performDelete(target: target)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteObjectID = nil
                pendingDeleteTarget = nil
            }
        } message: { target in
            Text(target.confirmationMessage)
        }
    }

    private var localGridPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(filteredLocalAssets.count.formatted()) photos")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                GridSizeSlider(value: $thumbnailSize)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)], spacing: 12) {
                    ForEach(filteredLocalAssets, id: \.objectID) { asset in
                        localTile(for: asset)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func localTile(for asset: LocalAsset) -> some View {
        Button {
            selectedLocalObjectID = asset.objectID
            loadLocalFullImage(for: asset)
        } label: {
            LibraryTile(
                image: localThumbnailCache[asset.objectID],
                title: asset.originalFilename ?? "Untitled",
                subtitle: DateFormatter.libraryDate(asset.creationDate),
                isSelected: asset.objectID == selectedLocal?.objectID,
                thumbnailSize: thumbnailSize
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            if selectedLocalObjectID == nil {
                selectedLocalObjectID = asset.objectID
            }
            loadLocalThumbnail(for: asset)
        }
    }

    private var localDetailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected iPhoto Asset")
                    .font(.headline)
                Spacer()
                PreviewPaneWidthSlider(value: $previewPaneWidth)
            }

            if let selectedLocal {
                DetailImageCard(
                    image: localFullCache[selectedLocal.objectID],
                    placeholderText: "Loading full-size iPhoto image…"
                )
                .frame(height: 280)
                .onAppear {
                    loadLocalFullImage(for: selectedLocal)
                }

                metadataBlock(
                    title: selectedLocal.originalFilename ?? selectedLocal.localIdentifier,
                    line1: "Size: \(selectedLocal.pixelWidth)x\(selectedLocal.pixelHeight)",
                    line2: "Date: \(DateFormatter.libraryDate(selectedLocal.creationDate))"
                )

                Divider()

                Text("Matched Amazon Photo")
                    .font(.headline)

                if let matchedAmazon {
                    DetailImageCard(
                        image: amazonThumbnailCache[matchedAmazon.objectID],
                        placeholderText: "Loading Amazon thumbnail…"
                    )
                    .frame(height: 170)
                    .onAppear {
                        loadAmazonThumbnail(for: matchedAmazon)
                    }

                    metadataBlock(
                        title: matchedAmazon.name ?? matchedAmazon.nodeId,
                        line1: "Size: \(matchedAmazon.width)x\(matchedAmazon.height)",
                        line2: "Date: \(DateFormatter.libraryDate(matchedAmazon.contentDate ?? matchedAmazon.createdDate))"
                    )
                } else {
                    Text("No corresponding Amazon asset found.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await syncController.syncLocalToAmazon(
                                localAsset: selectedLocal,
                                settingsStore: amazonPhotosSettingsStore
                            )
                        }
                    } label: {
                        Label("Sync This To Amazon", systemImage: "icloud.and.arrow.up")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)
                    .help("Sync This To Amazon")

                    Menu {
                        ForEach(LocalDeleteTarget.allCases) { target in
                            Button(target.label, role: .destructive) {
                                pendingDeleteObjectID = selectedLocal.objectID
                                pendingDeleteTarget = target
                                showDeleteConfirmation = true
                            }
                            .disabled(isDeleteTargetDisabled(target))
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(syncController.isSyncing || isPerformingDelete)
                    .help("Delete")
                }
            } else {
                Text("Select a local image.")
                    .foregroundStyle(.secondary)
            }

            SyncStatusView(controller: syncController)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: previewPaneWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var timelineSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Text(activeFilterText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            List(selection: $selectedDateFilter) {
                timelineRow(title: "All Photos", count: allLocalAssets.count, filter: .all, leadingPadding: 0)

                ForEach(timelineBuckets) { year in
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

    private var activeFilterText: String {
        switch selectedDateFilter ?? .all {
        case .all:
            return "Showing all \(allLocalAssets.count.formatted()) photos."
        case .year(let year):
            return "Showing \(filteredLocalAssets.count.formatted()) photos in \(year)."
        case .month(let year, let month):
            let monthName = LocalGridMonthBucket(year: year, month: month, count: 0).title
            return "Showing \(filteredLocalAssets.count.formatted()) photos in \(monthName) \(year)."
        }
    }

    private func timelineRow(
        title: String,
        count: Int,
        filter: LocalGridDateFilter,
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

    private func isDeleteTargetDisabled(_ target: LocalDeleteTarget) -> Bool {
        switch target {
        case .iCloud:
            return selectedLocal == nil
        case .amazon, .both:
            return selectedLocal == nil || matchedAmazon == nil || !amazonPhotosSettingsStore.hasCompleteCredentials
        }
    }

    @MainActor
    private func performDelete(target: LocalDeleteTarget) async {
        guard let objectID = pendingDeleteObjectID else { return }
        guard let localAsset = localAssets.first(where: { $0.objectID == objectID }) else {
            syncController.statusIsError = true
            syncController.statusMessage = "Selected iPhoto asset is no longer available."
            pendingDeleteObjectID = nil
            pendingDeleteTarget = nil
            return
        }

        let matchedAmazonAsset = AssetMatcher.matchAmazon(for: localAsset, among: Array(amazonAssets))
        isPerformingDelete = true
        defer {
            isPerformingDelete = false
            pendingDeleteObjectID = nil
            pendingDeleteTarget = nil
        }

        switch target {
        case .amazon:
            guard let matchedAmazonAsset else {
                syncController.statusIsError = true
                syncController.statusMessage = "No matching Amazon asset was found for this photo."
                return
            }
            let success = await syncController.deleteAmazonAsset(
                nodeID: matchedAmazonAsset.nodeId,
                displayName: matchedAmazonAsset.name,
                settingsStore: amazonPhotosSettingsStore
            )
            if success {
                removeDeletedAmazonAsset(nodeID: matchedAmazonAsset.nodeId)
            }
        case .iCloud:
            let success = await syncController.deleteLocalAsset(
                localIdentifier: localAsset.localIdentifier,
                displayName: localAsset.originalFilename
            )
            if success {
                removeDeletedLocalAsset(objectID: objectID)
            }
        case .both:
            guard let matchedAmazonAsset else {
                syncController.statusIsError = true
                syncController.statusMessage = "No matching Amazon asset was found for this photo."
                return
            }
            let amazonSuccess = await syncController.deleteAmazonAsset(
                nodeID: matchedAmazonAsset.nodeId,
                displayName: matchedAmazonAsset.name,
                settingsStore: amazonPhotosSettingsStore
            )
            if amazonSuccess {
                removeDeletedAmazonAsset(nodeID: matchedAmazonAsset.nodeId)
            }

            let localSuccess = await syncController.deleteLocalAsset(
                localIdentifier: localAsset.localIdentifier,
                displayName: localAsset.originalFilename
            )
            if localSuccess {
                removeDeletedLocalAsset(objectID: objectID)
            }

            if amazonSuccess && localSuccess {
                syncController.statusIsError = false
                syncController.statusMessage = "Deleted from Amazon and moved to iPhoto trash."
            } else if !amazonSuccess && !localSuccess {
                syncController.statusIsError = true
                syncController.statusMessage = "Unable to delete from Amazon or iPhoto."
            } else if !amazonSuccess {
                syncController.statusIsError = true
                syncController.statusMessage = "Deleted from iPhoto, but Amazon deletion failed."
            } else {
                syncController.statusIsError = true
                syncController.statusMessage = "Deleted from Amazon, but iPhoto deletion failed."
            }
        }
    }

    @ViewBuilder
    private func metadataBlock(title: String, line1: String, line2: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(line1)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(line2)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("\(title)\n\(line1)\n\(line2)")
    }

    private func loadLocalThumbnail(for asset: LocalAsset) {
        if localThumbnailCache[asset.objectID] != nil { return }
        Task {
            let image = await LocalPhotoLibraryBridge.thumbnailImage(localIdentifier: asset.localIdentifier)
            guard let image else { return }
            await MainActor.run {
                localThumbnailCache[asset.objectID] = image
            }
        }
    }

    private func loadLocalFullImage(for asset: LocalAsset) {
        if localFullCache[asset.objectID] != nil { return }
        Task {
            let image = await LocalPhotoLibraryBridge.fullImage(localIdentifier: asset.localIdentifier)
            guard let image else { return }
            await MainActor.run {
                localFullCache[asset.objectID] = image
            }
        }
    }

    private func loadAmazonThumbnail(for asset: AmazonAsset) {
        if amazonThumbnailCache[asset.objectID] != nil { return }
        let config = amazonPhotosSettingsStore.syncConfig
        let credentials = amazonPhotosSettingsStore.credentials
        let fallbackOwnerID = amazonPhotosSettingsStore.lastValidatedOwnerID
        Task {
            let image = await AmazonMediaBridge.thumbnailImage(
                for: asset,
                config: config,
                credentials: credentials,
                fallbackOwnerID: fallbackOwnerID
            )
            guard let image else { return }
            await MainActor.run {
                amazonThumbnailCache[asset.objectID] = image
            }
        }
    }

    private func removeDeletedLocalAsset(objectID: NSManagedObjectID) {
        localThumbnailCache.removeValue(forKey: objectID)
        localFullCache.removeValue(forKey: objectID)

        guard let asset = localAssets.first(where: { $0.objectID == objectID }) else {
            selectedLocalObjectID = filteredLocalAssets.first?.objectID
            return
        }

        let nextSelection = filteredLocalAssets.first(where: { $0.objectID != objectID })?.objectID
        viewContext.delete(asset)

        do {
            try viewContext.save()
            selectedLocalObjectID = nextSelection
        } catch {
            viewContext.rollback()
            syncController.statusIsError = true
            syncController.statusMessage = "iPhoto asset was deleted, but local index update failed: \(error.localizedDescription)"
        }
    }

    private func removeDeletedAmazonAsset(nodeID: String) {
        guard let asset = amazonAssets.first(where: { $0.nodeId == nodeID }) else { return }
        amazonThumbnailCache.removeValue(forKey: asset.objectID)
        viewContext.delete(asset)

        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            syncController.statusIsError = true
            syncController.statusMessage = "Amazon asset was deleted remotely, but local index update failed: \(error.localizedDescription)"
        }
    }

    private struct MonthKey: Hashable {
        let year: Int
        let month: Int
    }
}

private struct AmazonLibraryTabView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore
    @EnvironmentObject private var amazonPhotosIndexer: AmazonPhotosIndexer

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "createdDate", ascending: false)],
        animation: .default
    )
    private var amazonAssets: FetchedResults<AmazonAsset>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "creationDate", ascending: false)],
        animation: .default
    )
    private var localAssets: FetchedResults<LocalAsset>

    @StateObject private var syncController = LibrarySyncController()
    @State private var selectedAmazonObjectID: NSManagedObjectID?
    @State private var amazonThumbnailCache: [NSManagedObjectID: NSImage] = [:]
    @State private var amazonFullCache: [NSManagedObjectID: NSImage] = [:]
    @State private var localThumbnailCache: [NSManagedObjectID: NSImage] = [:]
    @State private var pendingPermanentDeleteObjectID: NSManagedObjectID?
    @State private var showPermanentDeleteConfirmation = false
    @AppStorage("amazonGridThumbnailSize") private var thumbnailSize = 170.0
    @AppStorage("amazonPreviewPaneWidth") private var previewPaneWidth = 500.0

    private var selectedAmazon: AmazonAsset? {
        if let selectedAmazonObjectID {
            return amazonAssets.first(where: { $0.objectID == selectedAmazonObjectID }) ?? amazonAssets.first
        }
        return amazonAssets.first
    }

    private var matchedLocal: LocalAsset? {
        guard let selectedAmazon else { return nil }
        return AssetMatcher.matchLocal(for: selectedAmazon, among: Array(localAssets))
    }

    var body: some View {
        if amazonAssets.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                amazonSyncControls

                EmptyStateView(
                    title: "No Amazon Assets Indexed",
                    message: "Use Sync Amazon Metadata or Refresh to run an on-demand sync from this tab."
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                amazonSyncControls

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(amazonAssets.count.formatted()) photos")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            GridSizeSlider(value: $thumbnailSize)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)], spacing: 12) {
                                ForEach(amazonAssets, id: \.objectID) { asset in
                                    Button {
                                        selectedAmazonObjectID = asset.objectID
                                        loadAmazonFullImage(for: asset)
                                    } label: {
                                        LibraryTile(
                                            image: amazonThumbnailCache[asset.objectID],
                                            title: asset.name ?? asset.nodeId,
                                            subtitle: DateFormatter.libraryDate(asset.contentDate ?? asset.createdDate),
                                            isSelected: asset.objectID == selectedAmazon?.objectID,
                                            thumbnailSize: thumbnailSize
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .onAppear {
                                        if selectedAmazonObjectID == nil {
                                            selectedAmazonObjectID = asset.objectID
                                        }
                                        loadAmazonThumbnail(for: asset)
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Selected Amazon Asset")
                                .font(.headline)
                            Spacer()
                            PreviewPaneWidthSlider(value: $previewPaneWidth)
                        }

                        if let selectedAmazon {
                            DetailImageCard(
                                image: amazonFullCache[selectedAmazon.objectID],
                                placeholderText: "Loading full-size Amazon image…"
                            )
                            .frame(height: 280)
                            .onAppear {
                                loadAmazonFullImage(for: selectedAmazon)
                            }

                            metadataBlock(
                                title: selectedAmazon.name ?? selectedAmazon.nodeId,
                                line1: "Size: \(selectedAmazon.width)x\(selectedAmazon.height)",
                                line2: "Date: \(DateFormatter.libraryDate(selectedAmazon.contentDate ?? selectedAmazon.createdDate))"
                            )

                            Divider()

                            Text("Matched iPhoto Asset")
                                .font(.headline)

                            if let matchedLocal {
                                DetailImageCard(
                                    image: localThumbnailCache[matchedLocal.objectID],
                                    placeholderText: "Loading iPhoto thumbnail…"
                                )
                                .frame(height: 170)
                                .onAppear {
                                    loadLocalThumbnail(for: matchedLocal)
                                }

                                metadataBlock(
                                    title: matchedLocal.originalFilename ?? matchedLocal.localIdentifier,
                                    line1: "Size: \(matchedLocal.pixelWidth)x\(matchedLocal.pixelHeight)",
                                    line2: "Date: \(DateFormatter.libraryDate(matchedLocal.creationDate))"
                                )
                            } else {
                                Text("No corresponding iPhoto asset found.")
                                    .foregroundStyle(.secondary)
                            }

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) {
                                    amazonActionButtons(selectedAmazon: selectedAmazon)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    amazonActionButtons(selectedAmazon: selectedAmazon)
                                }
                            }
                        } else {
                            Text("Select an Amazon image.")
                                .foregroundStyle(.secondary)
                        }

                        SyncStatusView(controller: syncController)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(width: previewPaneWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .onChange(of: selectedAmazonObjectID) { _, _ in
                    guard let selectedAmazon else { return }
                    loadAmazonFullImage(for: selectedAmazon)
                    if let matchedLocal {
                        loadLocalThumbnail(for: matchedLocal)
                    }
                }
                .alert("Delete Permanently?", isPresented: $showPermanentDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        guard let objectID = pendingPermanentDeleteObjectID else { return }
                        guard let asset = amazonAssets.first(where: { $0.objectID == objectID }) else {
                            syncController.statusIsError = true
                            syncController.statusMessage = "Selected Amazon asset is no longer available."
                            pendingPermanentDeleteObjectID = nil
                            return
                        }

                        let nodeID = asset.nodeId
                        let displayName = asset.name
                        Task {
                            let success = await syncController.deleteAmazonAsset(
                                nodeID: nodeID,
                                displayName: displayName,
                                settingsStore: amazonPhotosSettingsStore
                            )
                            await MainActor.run {
                                if success {
                                    removeDeletedAmazonAsset(objectID: objectID)
                                }
                                pendingPermanentDeleteObjectID = nil
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        pendingPermanentDeleteObjectID = nil
                    }
                } message: {
                    Text("This action removes the file from Amazon Photos and cannot be undone.")
                }
            }
        }
    }

    @ViewBuilder
    private func amazonActionButtons(selectedAmazon: AmazonAsset) -> some View {
        Button {
            Task {
                await syncController.syncAmazonToLocal(
                    amazonAsset: selectedAmazon,
                    settingsStore: amazonPhotosSettingsStore
                )
            }
        } label: {
            Label("Sync This To iPhoto", systemImage: "square.and.arrow.down")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)
        .help("Sync This To iPhoto")

        Button(role: .destructive) {
            let objectID = selectedAmazon.objectID
            let nodeID = selectedAmazon.nodeId
            let displayName = selectedAmazon.name
            Task {
                let success = await syncController.trashAmazonAsset(
                    nodeID: nodeID,
                    displayName: displayName,
                    settingsStore: amazonPhotosSettingsStore
                )
                if success {
                    await MainActor.run {
                        removeDeletedAmazonAsset(objectID: objectID)
                    }
                }
            }
        } label: {
            Label("Move to Trash", systemImage: "trash")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)
        .help("Move this Amazon Photos item to Amazon Trash")

        Button(role: .destructive) {
            pendingPermanentDeleteObjectID = selectedAmazon.objectID
            showPermanentDeleteConfirmation = true
        } label: {
            Label("Delete Permanently", systemImage: "trash.slash")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)
        .help("Delete Permanently")
    }

    private var amazonSyncControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Sync Amazon Metadata") {
                    runAmazonSyncOrRefresh()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!amazonPhotosSettingsStore.hasCompleteCredentials)

                Button("Refresh") {
                    runAmazonSyncOrRefresh()
                }
                .buttonStyle(.bordered)
                .disabled(!amazonPhotosSettingsStore.hasCompleteCredentials)
            }

            AmazonIndexerStatusView(state: amazonPhotosIndexer.state)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func runAmazonSyncOrRefresh() {
        amazonPhotosSettingsStore.save()
        amazonPhotosIndexer.startIndexingIfNeeded(force: true)
    }

    @ViewBuilder
    private func metadataBlock(title: String, line1: String, line2: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(line1)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(line2)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("\(title)\n\(line1)\n\(line2)")
    }

    private func loadAmazonThumbnail(for asset: AmazonAsset) {
        if amazonThumbnailCache[asset.objectID] != nil { return }
        let config = amazonPhotosSettingsStore.syncConfig
        let credentials = amazonPhotosSettingsStore.credentials
        let fallbackOwnerID = amazonPhotosSettingsStore.lastValidatedOwnerID
        Task {
            let image = await AmazonMediaBridge.thumbnailImage(
                for: asset,
                config: config,
                credentials: credentials,
                fallbackOwnerID: fallbackOwnerID
            )
            guard let image else { return }
            await MainActor.run {
                amazonThumbnailCache[asset.objectID] = image
            }
        }
    }

    private func loadAmazonFullImage(for asset: AmazonAsset) {
        if amazonFullCache[asset.objectID] != nil { return }
        let config = amazonPhotosSettingsStore.syncConfig
        let credentials = amazonPhotosSettingsStore.credentials
        let fallbackOwnerID = amazonPhotosSettingsStore.lastValidatedOwnerID
        Task {
            let image = await AmazonMediaBridge.fullImage(
                for: asset,
                config: config,
                credentials: credentials,
                fallbackOwnerID: fallbackOwnerID
            )
            guard let image else { return }
            await MainActor.run {
                amazonFullCache[asset.objectID] = image
            }
        }
    }

    private func loadLocalThumbnail(for asset: LocalAsset) {
        if localThumbnailCache[asset.objectID] != nil { return }
        Task {
            let image = await LocalPhotoLibraryBridge.thumbnailImage(localIdentifier: asset.localIdentifier)
            guard let image else { return }
            await MainActor.run {
                localThumbnailCache[asset.objectID] = image
            }
        }
    }

    private func removeDeletedAmazonAsset(objectID: NSManagedObjectID) {
        amazonThumbnailCache.removeValue(forKey: objectID)
        amazonFullCache.removeValue(forKey: objectID)

        guard let asset = amazonAssets.first(where: { $0.objectID == objectID }) else {
            selectedAmazonObjectID = amazonAssets.first?.objectID
            return
        }

        let nextSelection = amazonAssets.first(where: { $0.objectID != objectID })?.objectID
        viewContext.delete(asset)

        do {
            try viewContext.save()
            selectedAmazonObjectID = nextSelection
        } catch {
            viewContext.rollback()
            syncController.statusIsError = true
            syncController.statusMessage = "Amazon photo was deleted remotely, but local index update failed: \(error.localizedDescription)"
        }
    }
}

private struct ComparisonSectionView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var comparisonViewModel: ComparisonViewModel

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "kindRaw", ascending: true),
            NSSortDescriptor(key: "confidence", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ],
        animation: .default
    )
    private var matches: FetchedResults<CrossLibraryMatch>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "sourceRaw", ascending: true),
            NSSortDescriptor(key: "kindRaw", ascending: true),
            NSSortDescriptor(key: "confidence", ascending: false)
        ],
        animation: .default
    )
    private var duplicateClusters: FetchedResults<DuplicateCluster>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "actionKindRaw", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ],
        predicate: NSPredicate(format: "statusRaw == %@", SyncPlanStatus.proposed.rawValue),
        animation: .default
    )
    private var proposedSyncItems: FetchedResults<SyncPlanItem>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "sourceIdentifier", ascending: true),
            NSSortDescriptor(key: "faceIndex", ascending: true)
        ],
        animation: .default
    )
    private var faceObservations: FetchedResults<FaceObservation>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "displayName", ascending: true)
        ],
        animation: .default
    )
    private var personClusters: FetchedResults<PersonCluster>

    var body: some View {
        SectionContainer(
            title: "Catalog Comparison",
            message: "Duplicate groups, cross-library matches, and missing-asset proposals."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ComparisonSummaryCard(
                    summary: comparisonViewModel.summary,
                    isComputing: comparisonViewModel.isComputing,
                    errorMessage: comparisonViewModel.errorMessage
                )
                Button("Recompute Comparison") {
                    comparisonViewModel.refresh()
                }
                .buttonStyle(.borderedProminent)

                comparisonResultTabs
            }
        }
    }

    private var comparisonResultTabs: some View {
        TabView {
            resultList(
                count: matches.count,
                emptyTitle: "No Matches Yet",
                emptyMessage: "Run Recompute Comparison after indexing both libraries."
            ) {
                ForEach(matches, id: \.objectID) { match in
                    CrossLibraryMatchRow(match: match)
                }
            }
            .tabItem {
                Label("Matches", systemImage: "link")
            }

            resultList(
                count: duplicateClusters.count,
                emptyTitle: "No Duplicate Clusters",
                emptyMessage: "Run local similarity analysis and recompute comparison."
            ) {
                ForEach(duplicateClusters, id: \.objectID) { cluster in
                    DuplicateClusterRow(
                        cluster: cluster,
                        onSelectKeeper: { keeper in
                            selectKeeper(keeper, for: cluster)
                        },
                        onCreateCleanupPlan: {
                            createCleanupPlan(for: cluster)
                        }
                    )
                }
            }
            .tabItem {
                Label("Duplicates", systemImage: "square.stack.3d.up")
            }

            resultList(
                count: faceObservations.count,
                emptyTitle: "No Faces Indexed",
                emptyMessage: "Run local similarity analysis to populate Vision face observations."
            ) {
                ForEach(faceObservations, id: \.objectID) { face in
                    FaceObservationRow(
                        face: face,
                        onCreatePerson: {
                            createPersonCluster(for: face)
                        }
                    )
                }
            }
            .tabItem {
                Label("Faces", systemImage: "face.smiling")
            }

            resultList(
                count: personClusters.count,
                emptyTitle: "No People Yet",
                emptyMessage: "Create people from the Faces tab, then rename and merge them as needed."
            ) {
                ForEach(personClusters, id: \.objectID) { cluster in
                    PersonClusterRow(cluster: cluster, allClusters: Array(personClusters))
                }
            }
            .tabItem {
                Label("People", systemImage: "person.2")
            }

            resultList(
                count: proposedSyncItems.count,
                emptyTitle: "No Missing Assets",
                emptyMessage: "When one library has an asset the other does not, it will appear here."
            ) {
                ForEach(proposedSyncItems, id: \.objectID) { item in
                    SyncPlanItemRow(item: item)
                }
            }
            .tabItem {
                Label("Missing", systemImage: "arrow.left.arrow.right")
            }
        }
        .frame(minHeight: 420)
    }

    private func resultList<Rows: View>(
        count: Int,
        emptyTitle: String,
        emptyMessage: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(count.formatted()) records")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if count == 0 {
                EmptyStateView(title: emptyTitle, message: emptyMessage)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        rows()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 12)
    }

    private func selectKeeper(_ keeperIdentifier: String, for cluster: DuplicateCluster) {
        cluster.keeperIdentifier = keeperIdentifier
        cluster.updatedAt = Date()
        saveComparisonChanges()
    }

    private func createCleanupPlan(for cluster: DuplicateCluster) {
        let members = cluster.memberIdentifiers
        guard let keeper = cluster.keeperIdentifier ?? members.first else { return }

        cluster.keeperIdentifier = keeper
        cluster.updatedAt = Date()

        for member in members where member != keeper {
            upsertDuplicateCleanupItem(memberIdentifier: member, keeperIdentifier: keeper, cluster: cluster)
        }

        saveComparisonChanges()
    }

    private func createPersonCluster(for face: FaceObservation) {
        let cluster = PersonCluster(context: viewContext)
        cluster.clusterIdentifier = UUID().uuidString
        cluster.displayName = "Person \(personClusters.count + 1)"
        cluster.memberObservationIDs = [face.observationIdentifier]
        cluster.representativeAssetKey = face.assetKey
        cluster.createdAt = Date()
        cluster.updatedAt = Date()

        face.clusterIdentifier = cluster.clusterIdentifier
        face.updatedAt = Date()
        saveComparisonChanges()
    }

    private func upsertDuplicateCleanupItem(
        memberIdentifier: String,
        keeperIdentifier: String,
        cluster: DuplicateCluster
    ) {
        let itemIdentifier = "duplicate-cleanup:\(cluster.clusterIdentifier):\(memberIdentifier)"
        let request: NSFetchRequest<SyncPlanItem> = SyncPlanItem.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "itemIdentifier == %@", itemIdentifier)

        let item = (try? viewContext.fetch(request).first) ?? SyncPlanItem(context: viewContext)
        item.itemIdentifier = itemIdentifier
        item.actionKind = cluster.source == .amazonPhotos ? .trashAmazon : .deleteApple
        item.status = .proposed
        item.primarySource = cluster.source
        item.primaryIdentifier = memberIdentifier
        item.relatedSource = cluster.source
        item.relatedIdentifier = keeperIdentifier
        item.reason = "Duplicate cleanup from \(cluster.source.displayName) \(cluster.kind.displayName) cluster. Keep \(keeperIdentifier)."
        item.errorMessage = nil
        item.completedAt = nil
        item.createdAt = item.createdAt ?? Date()
        item.updatedAt = Date()
    }

    private func saveComparisonChanges() {
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
        }
    }
}

private struct CrossLibraryMatchRow: View {
    let match: CrossLibraryMatch

    private var evidenceSummary: String {
        guard let evidenceJSON = match.evidenceJSON,
              let evidence = try? JSONDecoder().decode(MatchEvidence.self, from: evidenceJSON) else {
            return "No evidence summary stored."
        }
        return evidence.summary
    }

    var body: some View {
        ResultRowCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: match.kind == .exact ? "checkmark.seal.fill" : "exclamationmark.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(match.kind == .exact ? .green : .orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(match.kind.displayName)
                            .font(.headline)
                        Spacer()
                        ConfidenceBadge(confidence: match.confidence)
                    }

                    Text("iPhoto: \(match.localIdentifier)")
                        .font(.caption)
                        .textSelection(.enabled)
                    Text("Amazon: \(match.amazonNodeId)")
                        .font(.caption)
                        .textSelection(.enabled)
                    Text(evidenceSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DuplicateClusterRow: View {
    let cluster: DuplicateCluster
    var onSelectKeeper: ((String) -> Void)? = nil
    var onCreateCleanupPlan: (() -> Void)? = nil

    var body: some View {
        ResultRowCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: cluster.kind == .exact ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.title3)
                    .foregroundStyle(cluster.kind == .exact ? .green : .orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(cluster.source.displayName) \(cluster.kind.displayName)")
                            .font(.headline)
                        Spacer()
                        ConfidenceBadge(confidence: cluster.confidence)
                    }

                    Text("\(cluster.memberIdentifiers.count.formatted()) assets")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let keeperIdentifier = cluster.keeperIdentifier {
                        Text("Suggested keeper: \(keeperIdentifier)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    Text(cluster.memberIdentifiers.prefix(6).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(cluster.memberIdentifiers.joined(separator: "\n"))

                    if onSelectKeeper != nil || onCreateCleanupPlan != nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                duplicateControls
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                duplicateControls
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var duplicateControls: some View {
        if let onSelectKeeper {
            Menu {
                ForEach(cluster.memberIdentifiers, id: \.self) { identifier in
                    Button {
                        onSelectKeeper(identifier)
                    } label: {
                        Label(
                            identifier,
                            systemImage: identifier == cluster.keeperIdentifier ? "checkmark" : "photo"
                        )
                    }
                }
            } label: {
                Label("Keeper", systemImage: "person.crop.square")
            }
            .help("Choose the asset to keep from this duplicate cluster")
        }

        if let onCreateCleanupPlan {
            Button(action: onCreateCleanupPlan) {
                Label("Plan Cleanup", systemImage: "text.badge.checkmark")
            }
            .disabled(cluster.memberIdentifiers.count < 2)
            .help("Create proposed transfer queue actions for every duplicate except the keeper")
        }
    }
}

private struct FaceObservationRow: View {
    let face: FaceObservation
    var onCreatePerson: (() -> Void)? = nil
    @State private var faceThumbnail: NSImage?

    private var boxSummary: String {
        "x \(face.boundingBoxX.formatted(.number.precision(.fractionLength(2)))), y \(face.boundingBoxY.formatted(.number.precision(.fractionLength(2)))), w \(face.boundingBoxWidth.formatted(.number.precision(.fractionLength(2)))), h \(face.boundingBoxHeight.formatted(.number.precision(.fractionLength(2))))"
    }

    var body: some View {
        ResultRowCard {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let faceThumbnail {
                        Image(nsImage: faceThumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: face.clusterIdentifier == nil ? "face.smiling" : "person.crop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(face.clusterIdentifier == nil ? Color.accentColor : .green)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.16))
                )
                .onAppear {
                    loadFaceThumbnail()
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Face \(face.faceIndex)")
                            .font(.headline)
                        Spacer()
                        Text(face.source.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }

                    Text(face.sourceIdentifier)
                        .font(.caption)
                        .textSelection(.enabled)
                        .help(face.sourceIdentifier)

                    Text(boxSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let clusterIdentifier = face.clusterIdentifier {
                        Text("Person cluster: \(clusterIdentifier)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let onCreatePerson {
                        Button(action: onCreatePerson) {
                            Label("New Person", systemImage: "person.badge.plus")
                        }
                        .help("Create a person cluster from this face observation")
                    }
                }
            }
        }
    }

    @MainActor
    private func loadFaceThumbnail() {
        guard faceThumbnail == nil else { return }
        guard face.source == .applePhotos else { return }

        Task {
            let image = await LocalPhotoLibraryBridge.faceThumbnailImage(
                localIdentifier: face.sourceIdentifier,
                boundingBox: CGRect(
                    x: face.boundingBoxX,
                    y: face.boundingBoxY,
                    width: face.boundingBoxWidth,
                    height: face.boundingBoxHeight
                )
            )
            guard let image else { return }
            await MainActor.run {
                faceThumbnail = image
            }
        }
    }
}

private struct PersonClusterRow: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var cluster: PersonCluster
    let allClusters: [PersonCluster]

    var body: some View {
        ResultRowCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Person name", text: Binding(
                        get: { cluster.displayName ?? "" },
                        set: { cluster.displayName = $0 }
                    ))
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        save()
                    }
                    .help("Name this person cluster")

                    Text("\(cluster.memberObservationIDs.count.formatted()) face observation\(cluster.memberObservationIDs.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let representativeAssetKey = cluster.representativeAssetKey {
                        Text("Representative: \(representativeAssetKey)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Menu {
                            ForEach(allClusters.filter { $0.clusterIdentifier != cluster.clusterIdentifier }, id: \.objectID) { target in
                                Button {
                                    merge(into: target)
                                } label: {
                                    Label(target.displayName ?? target.clusterIdentifier, systemImage: "person.2.fill")
                                }
                            }
                        } label: {
                            Label("Merge Into", systemImage: "person.2.arrow.left")
                        }
                        .disabled(allClusters.filter { $0.clusterIdentifier != cluster.clusterIdentifier }.isEmpty)
                        .help("Merge this cluster into another person cluster")
                    }
                }
            }
        }
    }

    private func merge(into target: PersonCluster) {
        let currentMembers = Set(cluster.memberObservationIDs)
        let targetMembers = Set(target.memberObservationIDs)
        let mergedMembers = Array(targetMembers.union(currentMembers)).sorted()

        target.memberObservationIDs = mergedMembers
        target.updatedAt = Date()

        let request: NSFetchRequest<FaceObservation> = FaceObservation.fetchRequest()
        request.predicate = NSPredicate(format: "clusterIdentifier == %@", cluster.clusterIdentifier)

        if let faces = try? viewContext.fetch(request) {
            for face in faces {
                face.clusterIdentifier = target.clusterIdentifier
                face.updatedAt = Date()
            }
        }

        viewContext.delete(cluster)
        saveContext()
    }

    private func save() {
        cluster.updatedAt = Date()
        saveContext()
    }

    private func saveContext() {
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
        }
    }
}

private struct SyncPlanItemRow: View {
    let item: SyncPlanItem
    var onApprove: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    var onReset: (() -> Void)? = nil
    var onExecute: (() -> Void)? = nil

    var body: some View {
        ResultRowCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.actionKind.systemImageName)
                    .font(.title3)
                    .foregroundStyle(item.status.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.actionKind.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .help(item.actionKind.displayName)
                        Spacer()
                        statusBadge
                    }

                    Text("\(item.primarySource.displayName): \(item.primaryIdentifier)")
                        .font(.caption)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help("\(item.primarySource.displayName): \(item.primaryIdentifier)")

                    Text(item.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(item.reason)

                    if let errorMessage = item.errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    if showsControls {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                controlButtons
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                controlButtons
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var statusBadge: some View {
        Label(item.status.displayName, systemImage: item.status.systemImageName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(item.status.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(item.status.tint.opacity(0.12), in: Capsule())
            .help("Status: \(item.status.displayName)")
    }

    private var showsControls: Bool {
        onApprove != nil || onSkip != nil || onReset != nil || onExecute != nil
    }

    @ViewBuilder
    private var controlButtons: some View {
        if let onApprove, item.status == .proposed {
            Button(action: onApprove) {
                Label("Approve", systemImage: "checkmark.circle")
            }
            .help("Approve this proposed sync action")
        }

        if let onExecute, item.status == .approved || item.status == .failed {
            Button(action: onExecute) {
                Label(item.status == .failed ? "Retry" : "Run", systemImage: "play.circle")
            }
            .help(item.status == .failed ? "Retry this sync action" : "Run this approved sync action")
        }

        if let onSkip, item.status == .proposed || item.status == .approved || item.status == .failed {
            Button(action: onSkip) {
                Label("Skip", systemImage: "forward.circle")
            }
            .help("Skip this sync action")
        }

        if let onReset, item.status == .skipped || item.status == .failed {
            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.counterclockwise.circle")
            }
            .help("Move this item back to proposed")
        }
    }
}

private struct ResultRowCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
    }
}

private struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text(confidence.formatted(.percent.precision(.fractionLength(0))))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

private struct TransferQueueView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore
    @StateObject private var syncController = LibrarySyncController()
    @State private var statusFilter: SyncPlanStatus?

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "statusRaw", ascending: true),
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ],
        animation: .default
    )
    private var syncPlanItems: FetchedResults<SyncPlanItem>

    private var visibleItems: [SyncPlanItem] {
        syncPlanItems.filter { item in
            statusFilter == nil || item.status == statusFilter
        }
    }

    private var approvedItems: [SyncPlanItem] {
        syncPlanItems.filter { $0.status == .approved }
    }

    var body: some View {
        SectionContainer(
            title: "Transfer Queue",
            message: "Proposed, approved, running, and completed sync operations."
        ) {
            if syncPlanItems.isEmpty {
                EmptyStateView(
                    title: "No Sync Plan Items",
                    message: "Run Recompute Comparison to generate upload/import proposals."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    transferToolbar

                    if visibleItems.isEmpty {
                        EmptyStateView(
                            title: "No Items In This Status",
                            message: "Change the status filter to see other sync plan items."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleItems, id: \.objectID) { item in
                                    SyncPlanItemRow(
                                        item: item,
                                        onApprove: { update(item, status: .approved) },
                                        onSkip: { update(item, status: .skipped) },
                                        onReset: { update(item, status: .proposed) },
                                        onExecute: {
                                            Task {
                                                await execute(item)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }

                    SyncStatusView(controller: syncController)
                }
            }
        }
    }

    private var transferToolbar: some View {
        HStack(spacing: 12) {
            Picker("Status", selection: $statusFilter) {
                Text("All").tag(nil as SyncPlanStatus?)
                ForEach(SyncPlanStatus.allCases) { status in
                    Text("\(status.displayName) (\(count(for: status)))")
                        .tag(status as SyncPlanStatus?)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .help("Filter transfer queue by status")

            Button {
                approveAllProposed()
            } label: {
                Label("Approve Proposed", systemImage: "checkmark.circle")
            }
            .disabled(count(for: .proposed) == 0)
            .help("Approve all proposed sync actions")

            Button {
                Task {
                    await runApproved()
                }
            } label: {
                Label("Run Approved", systemImage: "play.circle")
            }
            .disabled(approvedItems.isEmpty || syncController.isSyncing)
            .help("Run all approved sync actions")

            Spacer()
        }
    }

    private func count(for status: SyncPlanStatus) -> Int {
        syncPlanItems.filter { $0.status == status }.count
    }

    private func approveAllProposed() {
        syncPlanItems
            .filter { $0.status == .proposed }
            .forEach { item in
                item.status = .approved
                item.errorMessage = nil
                item.updatedAt = Date()
            }
        saveQueueChanges()
    }

    private func update(_ item: SyncPlanItem, status: SyncPlanStatus) {
        item.status = status
        item.errorMessage = nil
        item.updatedAt = Date()
        if status == .completed {
            item.completedAt = Date()
        } else {
            item.completedAt = nil
        }
        saveQueueChanges()
    }

    @MainActor
    private func runApproved() async {
        let items = approvedItems
        for item in items where !syncController.isSyncing {
            await execute(item)
        }
    }

    @MainActor
    private func execute(_ item: SyncPlanItem) async {
        item.status = .running
        item.errorMessage = nil
        item.updatedAt = Date()
        saveQueueChanges()

        let succeeded = await perform(item)

        item.status = succeeded ? .completed : .failed
        item.errorMessage = succeeded ? nil : syncController.statusMessage
        item.completedAt = succeeded ? Date() : nil
        item.updatedAt = Date()
        saveQueueChanges()
    }

    @MainActor
    private func perform(_ item: SyncPlanItem) async -> Bool {
        switch item.actionKind {
        case .uploadToAmazon:
            guard let localAsset = fetchLocalAsset(identifier: item.primaryIdentifier) else {
                syncController.statusIsError = true
                syncController.statusMessage = "Could not find iPhoto asset \(item.primaryIdentifier)."
                return false
            }
            return await syncController.syncLocalToAmazon(localAsset: localAsset, settingsStore: amazonPhotosSettingsStore)

        case .importToApplePhotos:
            guard let amazonAsset = fetchAmazonAsset(identifier: item.primaryIdentifier) else {
                syncController.statusIsError = true
                syncController.statusMessage = "Could not find Amazon asset \(item.primaryIdentifier)."
                return false
            }
            return await syncController.syncAmazonToLocal(amazonAsset: amazonAsset, settingsStore: amazonPhotosSettingsStore)

        case .trashAmazon:
            return await syncController.trashAmazonAsset(
                nodeID: item.primaryIdentifier,
                displayName: item.primaryIdentifier,
                settingsStore: amazonPhotosSettingsStore
            )

        case .deleteApple:
            return await syncController.deleteLocalAsset(
                localIdentifier: item.primaryIdentifier,
                displayName: item.primaryIdentifier
            )

        case .ignore:
            syncController.statusIsError = false
            syncController.statusMessage = "Skipped ignored sync item."
            return true

        case .manualReview:
            syncController.statusIsError = true
            syncController.statusMessage = "Manual review items cannot be executed automatically yet."
            return false
        }
    }

    private func fetchLocalAsset(identifier: String) -> LocalAsset? {
        let request: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "localIdentifier == %@", identifier)
        return try? viewContext.fetch(request).first
    }

    private func fetchAmazonAsset(identifier: String) -> AmazonAsset? {
        let request: NSFetchRequest<AmazonAsset> = AmazonAsset.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "nodeId == %@", identifier)
        return try? viewContext.fetch(request).first
    }

    private func saveQueueChanges() {
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            syncController.statusIsError = true
            syncController.statusMessage = error.localizedDescription
        }
    }
}

private struct SettingsSectionView: View {
    @EnvironmentObject private var amazonPhotosSettingsStore: AmazonPhotosSettingsStore
    @EnvironmentObject private var amazonPhotosIndexer: AmazonPhotosIndexer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.largeTitle)
                    .bold()
                Text("Configure Amazon Photos cookies and sync parameters used for metadata indexing.")
                    .foregroundStyle(.secondary)

                GroupBox("Amazon Cookie Credentials") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledField(label: "Session ID") {
                            SecureField("session-id", text: $amazonPhotosSettingsStore.sessionID)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "Ubid Cookie Key") {
                            TextField("ubid_main or ubid-acbca", text: $amazonPhotosSettingsStore.ubidCookieKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "Ubid Cookie Value") {
                            SecureField("cookie value", text: $amazonPhotosSettingsStore.ubidCookieValue)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "At Cookie Key") {
                            TextField("at_main or at-acbca", text: $amazonPhotosSettingsStore.atCookieKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "At Cookie Value") {
                            SecureField("cookie value", text: $amazonPhotosSettingsStore.atCookieValue)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 8)
                }

                GroupBox("Amazon Sync Parameters") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledField(label: "Region") {
                            Picker("Region", selection: $amazonPhotosSettingsStore.regionMode) {
                                ForEach(AmazonRegionMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        LabeledField(label: "TLD Override") {
                            TextField("Optional (e.g. com, ca, it)", text: $amazonPhotosSettingsStore.amazonTLDOverride)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "Search Filter") {
                            TextField("type:(PHOTOS OR VIDEOS)", text: $amazonPhotosSettingsStore.searchFilter)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "Sort") {
                            TextField("['createdDate DESC']", text: $amazonPhotosSettingsStore.searchSort)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField(label: "Search Context") {
                            TextField("customer", text: $amazonPhotosSettingsStore.searchContext)
                                .textFieldStyle(.roundedBorder)
                        }
                        Toggle("Low Resolution Thumbnails", isOn: $amazonPhotosSettingsStore.lowResThumbnail)

                        HStack(spacing: 24) {
                            LabeledNumericField(label: "Page Limit", value: $amazonPhotosSettingsStore.pageLimit)
                            LabeledNumericField(label: "Max Pages (0 = All)", value: $amazonPhotosSettingsStore.maxPages)
                            LabeledNumericField(label: "Max Retries", value: $amazonPhotosSettingsStore.maxRetryCount)
                        }

                        HStack {
                            Text("Timeout Seconds")
                            TextField(
                                "30",
                                value: $amazonPhotosSettingsStore.requestTimeoutSeconds,
                                format: .number.precision(.fractionLength(0 ... 1))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        }
                    }
                    .padding(.top, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button("Save Settings") {
                            amazonPhotosSettingsStore.save()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Validate Connection") {
                            Task {
                                await amazonPhotosSettingsStore.validateConnection()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!amazonPhotosSettingsStore.hasCompleteCredentials)

                        Button("Sync Amazon Now") {
                            amazonPhotosSettingsStore.save()
                            amazonPhotosIndexer.startIndexingIfNeeded(force: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!amazonPhotosSettingsStore.hasCompleteCredentials)
                    }

                    Text(amazonPhotosSettingsStore.authState.title)
                        .font(.headline)

                    if !amazonPhotosSettingsStore.lastValidationMessage.isEmpty {
                        Text(amazonPhotosSettingsStore.lastValidationMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let lastSuccessfulSyncAt = amazonPhotosSettingsStore.lastSuccessfulSyncAt {
                        Text("Last successful sync: \(lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let lastSyncError = amazonPhotosSettingsStore.lastSyncError {
                        Text("Last sync error: \(lastSyncError)")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SectionContainer<Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder let content: () -> Content

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

            content()
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}

private struct ComparisonSummaryCard: View {
    let summary: ComparisonSummary
    let isComputing: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comparison Summary")
                .font(.headline)

            if isComputing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Computing comparison…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if summary.computedAt == .distantPast {
                Text("No comparison computed yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iPhoto assets: \(summary.totalLocal.formatted())")
                    Text("Amazon assets: \(summary.totalAmazon.formatted())")
                    Text("Exact duplicates: \(summary.exactDuplicates.formatted())")
                    Text("Likely duplicates: \(summary.likelyDuplicates.formatted())")
                    Text("iPhoto only: \(summary.localOnly.formatted())")
                    Text("Amazon only: \(summary.amazonOnly.formatted())")
                    Text("Updated \(summary.computedAt.formatted(date: .abbreviated, time: .shortened))")
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

private struct LibraryTile: View {
    let image: NSImage?
    let title: String
    let subtitle: String
    let isSelected: Bool
    let thumbnailSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: max(110, thumbnailSize * 0.75))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .help(title)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(subtitle)
        }
        .padding(8)
        .frame(minHeight: max(170, thumbnailSize + 58), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .help("\(title)\n\(subtitle)")
    }
}

private struct DetailImageCard: View {
    let image: NSImage?
    let placeholderText: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))

            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 220)
                        .padding(6)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(placeholderText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct GridSizeSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $value, in: 120...280, step: 10)
                .frame(width: 130)
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .help("Adjust thumbnail size")
    }
}

private struct PreviewPaneWidthSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .foregroundStyle(.secondary)
            Slider(value: $value, in: 360...760, step: 20)
                .frame(width: 120)
        }
        .help("Adjust preview pane width")
    }
}

private struct SyncStatusView: View {
    @ObservedObject var controller: LibrarySyncController

    var body: some View {
        if !controller.statusMessage.isEmpty {
            Text(controller.statusMessage)
                .font(.callout)
                .foregroundStyle(controller.statusIsError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 160, alignment: .leading)
            field()
        }
    }
}

private struct LabeledNumericField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(label)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView()
                .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
                .environmentObject(PhotoLibraryAuthorizationController.previewAuthorized)
                .environmentObject(PhotoLibraryIndexer.previewCompleted)
                .environmentObject(AmazonPhotosSettingsStore())
                .environmentObject(AmazonPhotosIndexer.previewIdle)
                .environmentObject(ComparisonViewModel.preview)
                .frame(width: 1200, height: 760)
                .previewDisplayName("Authorized")

            ContentView()
                .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
                .environmentObject(PhotoLibraryAuthorizationController.previewDenied)
                .environmentObject(PhotoLibraryIndexer.previewIdle)
                .environmentObject(AmazonPhotosSettingsStore())
                .environmentObject(AmazonPhotosIndexer.previewIdle)
                .environmentObject(ComparisonViewModel.preview)
                .frame(width: 1200, height: 760)
                .previewDisplayName("Denied")
        }
    }
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
            Text("iPhoto Library Index")
                .font(.headline)

            switch state {
            case .idle:
                Text("Indexing begins automatically after photo library access is granted.")
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

private struct AmazonIndexerStatusView: View {
    let state: AmazonPhotosIndexer.State

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Amazon Photos Index")
                .font(.headline)

            switch state {
            case .idle:
                Text("Run sync to index Amazon metadata for comparison.")
                    .foregroundStyle(.secondary)
            case .indexing(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fractionComplete)
                    Text("Indexing \(progress.processed.formatted()) of \(progress.total.formatted()) Amazon assets…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .completed(let completion):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexed \(completion.processed.formatted()) Amazon assets")
                    Text("Last run \(completion.completedAt, style: .relative)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Amazon indexing failed")
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

@MainActor
private final class LibrarySyncController: ObservableObject {
    @Published var isSyncing = false
    @Published var statusMessage: String = ""
    @Published var statusIsError = false

    @discardableResult
    func syncLocalToAmazon(localAsset: LocalAsset, settingsStore: AmazonPhotosSettingsStore) async -> Bool {
        guard settingsStore.hasCompleteCredentials else {
            statusIsError = true
            statusMessage = "Amazon credentials are incomplete."
            return false
        }

        isSyncing = true
        statusIsError = false
        statusMessage = "Preparing local asset upload…"

        defer { isSyncing = false }

        do {
            let (data, fileName) = try await LocalPhotoLibraryBridge.exportResourceData(localIdentifier: localAsset.localIdentifier)
            let client = try AmazonPhotosClient(config: settingsStore.syncConfig, credentials: settingsStore.credentials)
            let root = try await client.validateConnection()
            try await client.uploadFile(data: data, fileName: fileName, parentNodeID: root.id)
            statusIsError = false
            statusMessage = "Uploaded \(fileName) to Amazon Photos."
            return true
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func syncAmazonToLocal(amazonAsset: AmazonAsset, settingsStore: AmazonPhotosSettingsStore) async -> Bool {
        guard settingsStore.hasCompleteCredentials else {
            statusIsError = true
            statusMessage = "Amazon credentials are incomplete."
            return false
        }

        guard let ownerID = amazonAsset.ownerId ?? settingsStore.lastValidatedOwnerID else {
            statusIsError = true
            statusMessage = "Owner ID unavailable. Validate Amazon connection again."
            return false
        }

        isSyncing = true
        statusIsError = false
        statusMessage = "Downloading from Amazon Photos…"

        defer { isSyncing = false }

        do {
            let client = try AmazonPhotosClient(config: settingsStore.syncConfig, credentials: settingsStore.credentials)
            let data = try await client.fetchFullSize(nodeID: amazonAsset.nodeId, ownerID: ownerID)
            let fileName = amazonAsset.name ?? "\(amazonAsset.nodeId).\(amazonAsset.extensionName ?? "jpg")"
            let tempURL = try TemporaryFileStore.write(data: data, suggestedFileName: fileName)
            try await LocalPhotoLibraryBridge.importFile(at: tempURL)
            statusIsError = false
            statusMessage = "Imported \(fileName) into iPhoto."
            return true
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            return false
        }
    }

    func trashAmazonAsset(nodeID: String, displayName: String?, settingsStore: AmazonPhotosSettingsStore) async -> Bool {
        guard settingsStore.hasCompleteCredentials else {
            statusIsError = true
            statusMessage = "Amazon credentials are incomplete."
            return false
        }

        isSyncing = true
        statusIsError = false
        statusMessage = "Moving Amazon photo to trash…"

        defer { isSyncing = false }

        do {
            let client = try AmazonPhotosClient(config: settingsStore.syncConfig, credentials: settingsStore.credentials)
            try await client.trash(nodeIDs: [nodeID])
            statusIsError = false
            statusMessage = "Moved \(displayName ?? nodeID) to Amazon trash."
            return true
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            return false
        }
    }

    func deleteAmazonAsset(nodeID: String, displayName: String?, settingsStore: AmazonPhotosSettingsStore) async -> Bool {
        guard settingsStore.hasCompleteCredentials else {
            statusIsError = true
            statusMessage = "Amazon credentials are incomplete."
            return false
        }

        isSyncing = true
        statusIsError = false
        statusMessage = "Permanently deleting Amazon photo…"

        defer { isSyncing = false }

        do {
            let client = try AmazonPhotosClient(config: settingsStore.syncConfig, credentials: settingsStore.credentials)
            try await client.delete(nodeIDs: [nodeID])
            statusIsError = false
            statusMessage = "Permanently deleted \(displayName ?? nodeID) from Amazon."
            return true
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            return false
        }
    }

    func deleteLocalAsset(localIdentifier: String, displayName: String?) async -> Bool {
        isSyncing = true
        statusIsError = false
        statusMessage = "Moving iPhoto asset to trash…"

        defer { isSyncing = false }

        do {
            try await LocalPhotoLibraryBridge.deleteAsset(localIdentifier: localIdentifier)
            statusIsError = false
            statusMessage = "Moved \(displayName ?? localIdentifier) to iPhoto trash."
            return true
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            return false
        }
    }
}

private enum LocalPhotoLibraryBridge {
    @MainActor
    static func thumbnailImage(localIdentifier: String, targetPixels: CGFloat = 280) async -> NSImage? {
        let cacheKey = "local-thumb:\(localIdentifier):\(Int(targetPixels))"
        if let cached = ThumbnailCacheStore.shared.image(for: cacheKey) {
            return cached
        }

        guard let image = await requestImage(localIdentifier: localIdentifier, targetSize: CGSize(width: targetPixels, height: targetPixels)) else {
            return nil
        }
        ThumbnailCacheStore.shared.store(image, for: cacheKey)
        return image
    }

    @MainActor
    static func faceThumbnailImage(
        localIdentifier: String,
        boundingBox: CGRect,
        targetPixels: CGFloat = 220
    ) async -> NSImage? {
        let cacheKey = "local-face:\(localIdentifier):\(Int(boundingBox.minX * 1000)):\(Int(boundingBox.minY * 1000)):\(Int(boundingBox.width * 1000)):\(Int(boundingBox.height * 1000)):\(Int(targetPixels))"
        if let cached = ThumbnailCacheStore.shared.image(for: cacheKey) {
            return cached
        }

        guard let asset = fetchAsset(localIdentifier: localIdentifier) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        let image: NSImage? = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: targetPixels * 2, height: targetPixels * 2),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if resumed { return }
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    resumed = true
                    continuation.resume(returning: nil)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                }
                resumed = true
                continuation.resume(returning: image)
            }
        }
        guard let image else {
            return nil
        }

        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil as NSGraphicsContext?,
            hints: nil
        ) else {
            return nil
        }

        let cropRect = VNImageRectForNormalizedRect(boundingBox, cgImage.width, cgImage.height).integral
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        let result = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        ThumbnailCacheStore.shared.store(result, for: cacheKey)
        return result
    }

    @MainActor
    static func fullImage(localIdentifier: String, targetPixels: CGFloat = 2200) async -> NSImage? {
        await requestImage(localIdentifier: localIdentifier, targetSize: CGSize(width: targetPixels, height: targetPixels))
    }

    @MainActor
    static func exportResourceData(localIdentifier: String) async throws -> (Data, String) {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            throw NSError(domain: "PhotoSyncCompanion", code: 101, userInfo: [NSLocalizedDescriptionKey: "Local photo not found."])
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = preferredResource(from: resources) else {
            throw NSError(domain: "PhotoSyncCompanion", code: 102, userInfo: [NSLocalizedDescriptionKey: "No exportable resource found for selected photo."])
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            var output = Data()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { chunk in
                output.append(chunk)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let fallbackFileName = "photo-\(UUID().uuidString).jpg"
                continuation.resume(returning: (output, resource.originalFilename.isEmpty ? fallbackFileName : resource.originalFilename))
            }
        }
    }

    @MainActor
    static func importFile(at fileURL: URL) async throws {
        let resourceType = mediaResourceType(for: fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: resourceType, fileURL: fileURL, options: nil)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "PhotoSyncCompanion",
                        code: 103,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown iPhoto import error."]
                    ))
                }
            }
        }
    }

    @MainActor
    static func deleteAsset(localIdentifier: String) async throws {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            throw NSError(
                domain: "PhotoSyncCompanion",
                code: 104,
                userInfo: [NSLocalizedDescriptionKey: "iPhoto asset not found."]
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "PhotoSyncCompanion",
                        code: 105,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown iPhoto delete error."]
                    ))
                }
            }
        }
    }

    @MainActor
    private static func requestImage(localIdentifier: String, targetSize: CGSize) async -> NSImage? {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if resumed { return }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    resumed = true
                    continuation.resume(returning: nil)
                    return
                }
                if info?[PHImageErrorKey] != nil {
                    resumed = true
                    continuation.resume(returning: nil)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    @MainActor
    private static func fetchAsset(localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }

    private static func preferredResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        let preferredOrder: [PHAssetResourceType] = [
            .fullSizePhoto,
            .photo,
            .fullSizeVideo,
            .video
        ]
        for type in preferredOrder {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }
        return resources.first
    }

    private static func mediaResourceType(for fileURL: URL) -> PHAssetResourceType {
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv"]
        let ext = fileURL.pathExtension.lowercased()
        return videoExtensions.contains(ext) ? .video : .photo
    }
}

private enum AmazonMediaBridge {
    static func thumbnailImage(
        for asset: AmazonAsset,
        config: AmazonPhotosConfig,
        credentials: AmazonPhotosCredentials,
        fallbackOwnerID: String?,
        targetPixels: Int = 360
    ) async -> NSImage? {
        guard credentials.isComplete else { return nil }
        guard let ownerID = asset.ownerId ?? fallbackOwnerID else { return nil }
        let cacheKey = "amazon-thumb:\(asset.nodeId):\(targetPixels)"
        if let cached = ThumbnailCacheStore.shared.image(for: cacheKey) {
            return cached
        }
        do {
            let client = try AmazonPhotosClient(config: config, credentials: credentials)
            let data = try await client.fetchThumbnail(nodeID: asset.nodeId, ownerID: ownerID, viewBox: targetPixels)
            guard let image = NSImage(data: data) else { return nil }
            ThumbnailCacheStore.shared.store(image, for: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    static func fullImage(
        for asset: AmazonAsset,
        config: AmazonPhotosConfig,
        credentials: AmazonPhotosCredentials,
        fallbackOwnerID: String?
    ) async -> NSImage? {
        guard credentials.isComplete else { return nil }
        guard let ownerID = asset.ownerId ?? fallbackOwnerID else { return nil }
        do {
            let client = try AmazonPhotosClient(config: config, credentials: credentials)
            let data = try await client.fetchFullSize(nodeID: asset.nodeId, ownerID: ownerID)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}

private enum AssetMatcher {
    static func matchAmazon(for local: LocalAsset, among amazonAssets: [AmazonAsset]) -> AmazonAsset? {
        if let localMD5 = normalized(local.md5) {
            if let exact = amazonAssets.first(where: { normalized($0.md5) == localMD5 }) {
                return exact
            }
        }

        let localName = normalizedFileName(local.originalFilename)
        let localDate = local.creationDate
        let localSize = local.fileSizeBytes > 0 ? local.fileSizeBytes : nil

        let candidates = amazonAssets.filter { amazon in
            if local.pixelWidth > 0, local.pixelHeight > 0, amazon.width > 0, amazon.height > 0 {
                if local.pixelWidth != amazon.width || local.pixelHeight != amazon.height {
                    return false
                }
            }

            if let localName, let amazonName = normalizedFileName(amazon.name), localName != amazonName {
                return false
            }

            if let localDate {
                let amazonDate = amazon.contentDate ?? amazon.createdDate
                if let amazonDate, abs(localDate.timeIntervalSince(amazonDate)) > 300 {
                    return false
                }
            }

            if let localSize, amazon.sizeBytes > 0 {
                let delta = abs(amazon.sizeBytes - localSize)
                if delta > 8_192 {
                    return false
                }
            }

            return true
        }

        return candidates.min(by: { lhs, rhs in
            dateDistance(lhs.contentDate ?? lhs.createdDate, localDate) < dateDistance(rhs.contentDate ?? rhs.createdDate, localDate)
        })
    }

    static func matchLocal(for amazon: AmazonAsset, among localAssets: [LocalAsset]) -> LocalAsset? {
        if let amazonMD5 = normalized(amazon.md5) {
            if let exact = localAssets.first(where: { normalized($0.md5) == amazonMD5 }) {
                return exact
            }
        }

        let amazonName = normalizedFileName(amazon.name)
        let amazonDate = amazon.contentDate ?? amazon.createdDate
        let amazonSize = amazon.sizeBytes > 0 ? amazon.sizeBytes : nil

        let candidates = localAssets.filter { local in
            if amazon.width > 0, amazon.height > 0, local.pixelWidth > 0, local.pixelHeight > 0 {
                if amazon.width != local.pixelWidth || amazon.height != local.pixelHeight {
                    return false
                }
            }

            if let amazonName, let localName = normalizedFileName(local.originalFilename), amazonName != localName {
                return false
            }

            if let amazonDate, let localDate = local.creationDate {
                if abs(amazonDate.timeIntervalSince(localDate)) > 300 {
                    return false
                }
            }

            if let amazonSize, local.fileSizeBytes > 0 {
                let delta = abs(amazonSize - local.fileSizeBytes)
                if delta > 8_192 {
                    return false
                }
            }

            return true
        }

        return candidates.min(by: { lhs, rhs in
            dateDistance(lhs.creationDate, amazonDate) < dateDistance(rhs.creationDate, amazonDate)
        })
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.lowercased()
    }

    private static func normalizedFileName(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        let fileName = (value as NSString).lastPathComponent
        return (fileName as NSString).deletingPathExtension.lowercased()
    }

    private static func dateDistance(_ lhs: Date?, _ rhs: Date?) -> TimeInterval {
        guard let lhs, let rhs else { return .greatestFiniteMagnitude }
        return abs(lhs.timeIntervalSince(rhs))
    }
}

private enum TemporaryFileStore {
    static func write(data: Data, suggestedFileName: String) throws -> URL {
        let safeName = sanitizedFileName(suggestedFileName)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fileURL = url.appendingPathComponent(safeName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let fallback = "amazon-photo-\(UUID().uuidString).jpg"
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return fallback }
        return candidate.replacingOccurrences(of: "/", with: "_")
    }
}

private extension DateFormatter {
    static func libraryDate(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
