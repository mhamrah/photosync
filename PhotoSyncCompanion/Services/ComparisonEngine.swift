import CoreData
import Foundation

struct ComparisonSummary: Equatable {
    let totalLocal: Int
    let totalAmazon: Int
    let exactDuplicates: Int
    let likelyDuplicates: Int
    let localOnly: Int
    let amazonOnly: Int
    let computedAt: Date

    static let empty = ComparisonSummary(
        totalLocal: 0,
        totalAmazon: 0,
        exactDuplicates: 0,
        likelyDuplicates: 0,
        localOnly: 0,
        amazonOnly: 0,
        computedAt: .distantPast
    )
}

@MainActor
final class ComparisonViewModel: ObservableObject {
    @Published private(set) var summary: ComparisonSummary = .empty
    @Published private(set) var isComputing: Bool = false
    @Published private(set) var errorMessage: String?

    private let persistenceController: PersistenceController

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    func refresh() {
        if isComputing { return }

        isComputing = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.computeSummary()
                await MainActor.run {
                    self.summary = summary
                    self.isComputing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isComputing = false
                }
            }
        }
    }

    private func computeSummary() async throws -> ComparisonSummary {
        let runSummary = try await CatalogMatchEngine(
            persistenceController: persistenceController
        ).refreshMatches()

        return ComparisonSummary(
            totalLocal: runSummary.totalLocal,
            totalAmazon: runSummary.totalAmazon,
            exactDuplicates: runSummary.exactMatches,
            likelyDuplicates: runSummary.likelyMatches,
            localOnly: runSummary.localOnly,
            amazonOnly: runSummary.amazonOnly,
            computedAt: runSummary.computedAt
        )
    }
}

extension ComparisonViewModel {
    static var preview: ComparisonViewModel {
        let model = ComparisonViewModel(persistenceController: .preview)
        model.summary = ComparisonSummary(
            totalLocal: 5,
            totalAmazon: 4,
            exactDuplicates: 3,
            likelyDuplicates: 1,
            localOnly: 1,
            amazonOnly: 0,
            computedAt: Date().addingTimeInterval(-300)
        )
        return model
    }
}
