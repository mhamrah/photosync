import CoreData
import Foundation

final class CatalogSearchService {
    private let persistenceController: PersistenceController

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    func searchAssets(
        _ query: UnifiedSearchQuery,
        limit: Int = 500,
        offset: Int = 0
    ) async throws -> [CatalogAssetSnapshot] {
        let context = persistenceController.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return try await context.perform {
            let request: NSFetchRequest<AssetAnalysis> = AssetAnalysis.fetchRequest()
            request.fetchLimit = max(limit, 1)
            request.fetchOffset = max(offset, 0)
            request.fetchBatchSize = min(max(limit, 1), 200)
            request.sortDescriptors = [
                NSSortDescriptor(key: "captureDate", ascending: false),
                NSSortDescriptor(key: "normalizedFilename", ascending: true),
                NSSortDescriptor(key: "sourceIdentifier", ascending: true)
            ]
            request.predicate = Self.makePredicate(for: query)

            return try context.fetch(request).map(CatalogAssetSnapshot.init(asset:))
        }
    }

    func countAssets(_ query: UnifiedSearchQuery) async throws -> Int {
        let context = persistenceController.container.newBackgroundContext()

        return try await context.perform {
            let request: NSFetchRequest<AssetAnalysis> = AssetAnalysis.fetchRequest()
            request.predicate = Self.makePredicate(for: query)
            return try context.count(for: request)
        }
    }

    private static func makePredicate(for query: UnifiedSearchQuery) -> NSPredicate {
        var predicates: [NSPredicate] = []

        if !query.sources.isEmpty {
            predicates.append(NSPredicate(format: "sourceRaw IN %@", query.sources.map(\.rawValue)))
        }

        if !query.includesHidden {
            predicates.append(NSPredicate(format: "isHidden == NO"))
        }

        if query.includesFavoritesOnly {
            predicates.append(NSPredicate(format: "isFavorite == YES"))
        }

        if let dateRange = query.dateRange {
            predicates.append(
                NSPredicate(
                    format: "captureDate >= %@ AND captureDate <= %@",
                    dateRange.lowerBound as NSDate,
                    dateRange.upperBound as NSDate
                )
            )
        }

        if let minimumLongestEdge = query.minimumLongestEdge {
            predicates.append(
                NSPredicate(
                    format: "pixelWidth >= %d OR pixelHeight >= %d",
                    minimumLongestEdge,
                    minimumLongestEdge
                )
            )
        }

        let searchTerms = SearchTerms(rawText: query.text)
        predicates.append(contentsOf: searchTerms.requiredPredicates)

        if !searchTerms.freeText.isEmpty {
            let containsText = "*\(searchTerms.freeText)*"
            predicates.append(
                NSCompoundPredicate(
                    orPredicateWithSubpredicates: [
                        NSPredicate(format: "normalizedFilename LIKE[cd] %@", containsText),
                        NSPredicate(format: "sourceIdentifier LIKE[cd] %@", containsText),
                        NSPredicate(format: "ocrText LIKE[cd] %@", containsText),
                        NSPredicate(format: "labelsRaw LIKE[cd] %@", containsText),
                        NSPredicate(format: "faceClusterIDsRaw LIKE[cd] %@", containsText),
                        NSPredicate(format: "ownerId LIKE[cd] %@", containsText),
                        NSPredicate(format: "parentsRaw LIKE[cd] %@", containsText),
                        NSPredicate(format: "mediaType LIKE[cd] %@", containsText)
                    ]
                )
            )
        }

        if predicates.isEmpty {
            return NSPredicate(value: true)
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private struct SearchTerms {
        let freeText: String
        let requiredPredicates: [NSPredicate]

        init(rawText: String) {
            let tokens = rawText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .map { String($0).lowercased() }

            var remaining: [String] = []
            var predicates: [NSPredicate] = []

            for token in tokens {
                if token == "has:faces" || token == "has:face" || token == "faces:true" {
                    predicates.append(NSPredicate(format: "faceClusterIDsRaw != nil AND faceClusterIDsRaw != ''"))
                } else if token == "has:text" || token == "ocr:true" {
                    predicates.append(NSPredicate(format: "ocrText != nil AND ocrText != ''"))
                } else if token == "has:labels" || token == "labels:true" {
                    predicates.append(NSPredicate(format: "labelsRaw != nil AND labelsRaw != ''"))
                } else if token.hasPrefix("label:"), let value = Self.tokenValue(token) {
                    predicates.append(NSPredicate(format: "labelsRaw LIKE[cd] %@", "*\(value)*"))
                } else if token.hasPrefix("text:"), let value = Self.tokenValue(token) {
                    predicates.append(NSPredicate(format: "ocrText LIKE[cd] %@", "*\(value)*"))
                } else if token.hasPrefix("owner:"), let value = Self.tokenValue(token) {
                    predicates.append(NSPredicate(format: "ownerId LIKE[cd] %@", "*\(value)*"))
                } else if token.hasPrefix("parent:"), let value = Self.tokenValue(token) {
                    predicates.append(NSPredicate(format: "parentsRaw LIKE[cd] %@", "*\(value)*"))
                } else {
                    remaining.append(token)
                }
            }

            self.freeText = remaining.joined(separator: " ")
            self.requiredPredicates = predicates
        }

        private static func tokenValue(_ token: String) -> String? {
            guard let separator = token.firstIndex(of: ":") else { return nil }
            let value = token[token.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}
