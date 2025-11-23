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
    @State private var selection: AppSection? = .summary

    var body: some View {
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
    }
}

private struct SummaryPlaceholder: View {
    var body: some View {
        ContentPlaceholder(
            title: "Sync Overview",
            message: "Status insights, totals, and last synchronization summary will appear here."
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

private struct ContentPlaceholder: View {
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
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

#Preview {
    ContentView()
        .frame(width: 960, height: 600)
}
