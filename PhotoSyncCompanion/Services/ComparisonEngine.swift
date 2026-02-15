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
        let context = persistenceController.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return try await context.perform {
            let localRequest: NSFetchRequest<LocalAsset> = LocalAsset.fetchRequest()
            let amazonRequest: NSFetchRequest<AmazonAsset> = AmazonAsset.fetchRequest()

            let localAssets = try context.fetch(localRequest)
            let amazonAssets = try context.fetch(amazonRequest)

            let localSignatures = localAssets.map(LocalSignature.init(asset:))
            let amazonSignatures = amazonAssets.map(AmazonSignature.init(asset:))
            return Self.compare(localSignatures: localSignatures, amazonSignatures: amazonSignatures)
        }
    }

    nonisolated private static func compare(localSignatures: [LocalSignature], amazonSignatures: [AmazonSignature]) -> ComparisonSummary {
        let totalLocal = localSignatures.count
        let totalAmazon = amazonSignatures.count

        var unmatchedAmazonByExact: [String: [Int]] = [:]
        for (index, signature) in amazonSignatures.enumerated() {
            unmatchedAmazonByExact[signature.exactKey, default: []].append(index)
        }

        var unmatchedLocalIndices: [Int] = []
        var matchedAmazonIndices = Set<Int>()
        var exactDuplicates = 0

        for (index, local) in localSignatures.enumerated() {
            guard var indices = unmatchedAmazonByExact[local.exactKey], !indices.isEmpty else {
                unmatchedLocalIndices.append(index)
                continue
            }
            let matchedIndex = indices.removeLast()
            unmatchedAmazonByExact[local.exactKey] = indices
            matchedAmazonIndices.insert(matchedIndex)
            exactDuplicates += 1
        }

        var amazonByDimensionBucket: [String: [Int]] = [:]
        for (index, signature) in amazonSignatures.enumerated() where !matchedAmazonIndices.contains(index) {
            amazonByDimensionBucket[signature.dimensionBucket, default: []].append(index)
        }

        var likelyDuplicates = 0
        for localIndex in unmatchedLocalIndices {
            let local = localSignatures[localIndex]
            var candidates = amazonByDimensionBucket[local.dimensionBucket] ?? []

            if let candidatePosition = candidates.firstIndex(where: { candidateIndex in
                let candidate = amazonSignatures[candidateIndex]
                return local.isLikelyMatch(with: candidate)
            }) {
                likelyDuplicates += 1
                let matchedCandidateIndex = candidates.remove(at: candidatePosition)
                amazonByDimensionBucket[local.dimensionBucket] = candidates
                matchedAmazonIndices.insert(matchedCandidateIndex)
            }
        }

        let localOnly = max(totalLocal - exactDuplicates - likelyDuplicates, 0)
        let amazonOnly = max(totalAmazon - exactDuplicates - likelyDuplicates, 0)

        return ComparisonSummary(
            totalLocal: totalLocal,
            totalAmazon: totalAmazon,
            exactDuplicates: exactDuplicates,
            likelyDuplicates: likelyDuplicates,
            localOnly: localOnly,
            amazonOnly: amazonOnly,
            computedAt: Date()
        )
    }
}

private struct LocalSignature {
    let width: Int32
    let height: Int32
    let duration: Double
    let creationDate: Date?
    let md5: String?

    init(asset: LocalAsset) {
        width = asset.pixelWidth
        height = asset.pixelHeight
        duration = asset.duration
        creationDate = asset.creationDate
        md5 = asset.md5
    }

    var exactKey: String {
        if let md5, !md5.isEmpty {
            return "md5:\(md5)"
        }
        return "meta:\(dimensionBucket)|\(roundedDuration)|\(roundedDateBucket)"
    }

    var dimensionBucket: String {
        "\(width)x\(height)"
    }

    private var roundedDuration: Int {
        Int(duration.rounded())
    }

    private var roundedDateBucket: Int {
        guard let creationDate else { return 0 }
        return Int(creationDate.timeIntervalSince1970 / 2)
    }

    func isLikelyMatch(with candidate: AmazonSignature) -> Bool {
        guard dimensionBucket == candidate.dimensionBucket else { return false }
        let durationDifference = abs(duration - candidate.duration)
        let dateDifference = abs((creationDate ?? .distantPast).timeIntervalSince(candidate.creationDate ?? .distantFuture))
        return durationDifference <= 2 && dateDifference <= 120
    }
}

private struct AmazonSignature {
    let width: Int32
    let height: Int32
    let duration: Double
    let creationDate: Date?
    let md5: String?

    init(asset: AmazonAsset) {
        width = asset.width
        height = asset.height
        duration = asset.duration
        creationDate = asset.contentDate ?? asset.createdDate
        md5 = asset.md5
    }

    var exactKey: String {
        if let md5, !md5.isEmpty {
            return "md5:\(md5)"
        }
        return "meta:\(dimensionBucket)|\(roundedDuration)|\(roundedDateBucket)"
    }

    var dimensionBucket: String {
        "\(width)x\(height)"
    }

    private var roundedDuration: Int {
        Int(duration.rounded())
    }

    private var roundedDateBucket: Int {
        guard let creationDate else { return 0 }
        return Int(creationDate.timeIntervalSince1970 / 2)
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
