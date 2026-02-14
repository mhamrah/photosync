import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case summary
    case comparison
    case transferQueue
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Dashboard"
        case .comparison: return "Comparison"
        case .transferQueue: return "Transfer Queue"
        case .settings: return "Settings"
        }
    }

    var systemImageName: String {
        switch self {
        case .summary: return "rectangle.grid.1x2"
        case .comparison: return "square.stack.3d.up"
        case .transferQueue: return "arrow.down.circle"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var photoAuthorizationController: PhotoLibraryAuthorizationController
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer
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

private struct SummaryPlaceholder: View {
    @EnvironmentObject private var photoLibraryIndexer: PhotoLibraryIndexer

    var body: some View {
        ContentPlaceholder(
            title: "Sync Overview",
            message: "Status insights, totals, and last synchronization summary will appear here.",
            accessory: {
                IndexerStatusView(state: photoLibraryIndexer.state)
            }
        )
    }
}

private struct ComparisonPlaceholder: View {
    var body: some View {
        ContentPlaceholder(
            title: "Catalog Comparison",
            message: "Browse mismatched assets, filter by location, and drill into metadata differences."
        )
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
        .frame(width: 960, height: 600)
}

#Preview("Denied") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(PhotoLibraryAuthorizationController.previewDenied)
        .environmentObject(PhotoLibraryIndexer.previewIdle)
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
