import AppKit
import CoreData
import Photos
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
                        TransferQueuePlaceholder()
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
            await photoAuthorizationController.requestAuthorizationIfNeeded(trigger: .automatic)
            handleAuthorizationChange(photoAuthorizationController.state)
            comparisonViewModel.refresh()
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
            if case .completed = newState {
                comparisonViewModel.refresh()
            }
        }
        .onChange(of: amazonPhotosIndexer.state) { newState in
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

private struct LibrariesSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Libraries")
                .font(.largeTitle)
                .bold()
            Text("Browse iPhoto and Amazon Photos in tile view, navigate local photos by month/year, and delete from Amazon, iCloud, or both.")
                .foregroundStyle(.secondary)

            TabView {
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
        .onChange(of: selectedDateFilter) { _ in
            guard let selectedLocalObjectID else {
                selectedLocalObjectID = filteredLocalAssets.first?.objectID
                return
            }
            if !filteredLocalAssets.contains(where: { $0.objectID == selectedLocalObjectID }) {
                self.selectedLocalObjectID = filteredLocalAssets.first?.objectID
            }
        }
        .onChange(of: selectedLocalObjectID) { _ in
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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(filteredLocalAssets, id: \.objectID) { asset in
                    localTile(for: asset)
                }
            }
            .padding(16)
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
                isSelected: asset.objectID == selectedLocal?.objectID
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
            Text("Selected iPhoto Asset")
                .font(.headline)

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
                    Button("Sync This To Amazon") {
                        Task {
                            await syncController.syncLocalToAmazon(
                                localAsset: selectedLocal,
                                settingsStore: amazonPhotosSettingsStore
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)

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
                }
            } else {
                Text("Select a local image.")
                    .foregroundStyle(.secondary)
            }

            SyncStatusView(controller: syncController)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 430)
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
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(amazonAssets, id: \.objectID) { asset in
                                Button {
                                    selectedAmazonObjectID = asset.objectID
                                    loadAmazonFullImage(for: asset)
                                } label: {
                                    LibraryTile(
                                        image: amazonThumbnailCache[asset.objectID],
                                        title: asset.name ?? asset.nodeId,
                                        subtitle: DateFormatter.libraryDate(asset.contentDate ?? asset.createdDate),
                                        isSelected: asset.objectID == selectedAmazon?.objectID
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
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Selected Amazon Asset")
                            .font(.headline)

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

                            HStack(spacing: 10) {
                                Button("Sync This To iPhoto") {
                                    Task {
                                        await syncController.syncAmazonToLocal(
                                            amazonAsset: selectedAmazon,
                                            settingsStore: amazonPhotosSettingsStore
                                        )
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)

                                Button("Move To Amazon Trash", role: .destructive) {
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
                                }
                                .buttonStyle(.bordered)
                                .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)

                                Button("Delete Permanently", role: .destructive) {
                                    pendingPermanentDeleteObjectID = selectedAmazon.objectID
                                    showPermanentDeleteConfirmation = true
                                }
                                .buttonStyle(.bordered)
                                .disabled(syncController.isSyncing || !amazonPhotosSettingsStore.hasCompleteCredentials)
                            }
                        } else {
                            Text("Select an Amazon image.")
                                .foregroundStyle(.secondary)
                        }

                        SyncStatusView(controller: syncController)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(width: 430)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .onChange(of: selectedAmazonObjectID) { _ in
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
    @EnvironmentObject private var comparisonViewModel: ComparisonViewModel

    var body: some View {
        SectionContainer(
            title: "Catalog Comparison",
            message: "Duplicate and mismatch counts between iPhoto and Amazon Photos."
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
            }
        }
    }
}

private struct TransferQueuePlaceholder: View {
    var body: some View {
        SectionContainer(
            title: "Transfer Queue",
            message: "Queued and historical sync operations appear here."
        ) {
            Text("Queue details will be added in the next iteration.")
                .foregroundStyle(.secondary)
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
                            LabeledNumericField(label: "Max Pages", value: $amazonPhotosSettingsStore.maxPages)
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
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
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
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
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

#Preview("Authorized") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(PhotoLibraryAuthorizationController.previewAuthorized)
        .environmentObject(PhotoLibraryIndexer.previewCompleted)
        .environmentObject(AmazonPhotosSettingsStore())
        .environmentObject(AmazonPhotosIndexer.previewIdle)
        .environmentObject(ComparisonViewModel.preview)
        .frame(width: 1200, height: 760)
}

#Preview("Denied") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(PhotoLibraryAuthorizationController.previewDenied)
        .environmentObject(PhotoLibraryIndexer.previewIdle)
        .environmentObject(AmazonPhotosSettingsStore())
        .environmentObject(AmazonPhotosIndexer.previewIdle)
        .environmentObject(ComparisonViewModel.preview)
        .frame(width: 1200, height: 760)
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

    func syncLocalToAmazon(localAsset: LocalAsset, settingsStore: AmazonPhotosSettingsStore) async {
        guard settingsStore.hasCompleteCredentials else {
            statusIsError = true
            statusMessage = "Amazon credentials are incomplete."
            return
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
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    func syncAmazonToLocal(amazonAsset: AmazonAsset, settingsStore: AmazonPhotosSettingsStore) async {
        guard settingsStore.hasCompleteCredentials else {
            statusIsError = true
            statusMessage = "Amazon credentials are incomplete."
            return
        }

        guard let ownerID = amazonAsset.ownerId ?? settingsStore.lastValidatedOwnerID else {
            statusIsError = true
            statusMessage = "Owner ID unavailable. Validate Amazon connection again."
            return
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
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
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
        await requestImage(localIdentifier: localIdentifier, targetSize: CGSize(width: targetPixels, height: targetPixels))
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
        do {
            let client = try AmazonPhotosClient(config: config, credentials: credentials)
            let data = try await client.fetchThumbnail(nodeID: asset.nodeId, ownerID: ownerID, viewBox: targetPixels)
            return NSImage(data: data)
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
