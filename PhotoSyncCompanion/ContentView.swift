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

    struct AssetComparisonDiagnostics {
        let localMD5: String?
        let amazonMD5: String?
        let md5Match: Bool?

        let localFilename: String?
        let amazonFilename: String?
        let filenameMatch: Bool?

        let localPixelSize: (Int32, Int32)
        let amazonPixelSize: (Int32, Int32)
        let pixelSizeMatch: Bool?

        let localDate: Date?
        let amazonDate: Date?
        let dateMatch: Bool?

        let localFileSize: Int64?
        let amazonFileSize: Int64?
        let fileSizeMatch: Bool?

        let summary: String
    }

    static func diagnosticCompare(local: LocalAsset, amazon: AmazonAsset) -> AssetComparisonDiagnostics {
        // MD5
        let localMD5 = normalized(local.md5)
        let amazonMD5 = normalized(amazon.md5)
        let md5Match: Bool? = {
            guard let l = localMD5, let r = amazonMD5 else { return nil }
            return l == r
        }()

        // Filename (stripped and lowercased, no extension)
        let localName = normalizedFileName(local.originalFilename)
        let amazonName = normalizedFileName(amazon.name)
        let filenameMatch: Bool? = {
            guard let l = localName, let r = amazonName else { return nil }
            return l == r
        }()

        // Pixel size
        let localSize = (local.pixelWidth, local.pixelHeight)
        let amazonSize = (amazon.width, amazon.height)
        let pixelSizeMatch: Bool? = {
            if local.pixelWidth > 0, local.pixelHeight > 0, amazon.width > 0, amazon.height > 0 {
                return local.pixelWidth == amazon.width && local.pixelHeight == amazon.height
            }
            return nil
        }()

        // Date
        let localDate = local.creationDate
        let amazonDate = amazon.contentDate ?? amazon.createdDate
        let dateMatch: Bool? = {
            guard let l = localDate, let r = amazonDate else { return nil }
            return abs(l.timeIntervalSince(r)) <= 300
        }()

        // File size
        let localFileSize = local.fileSizeBytes > 0 ? local.fileSizeBytes : nil
        let amazonFileSize = amazon.sizeBytes > 0 ? amazon.sizeBytes : nil
        let fileSizeMatch: Bool? = {
            guard let l = localFileSize, let r = amazonFileSize else { return nil }
            return abs(l - r) <= 8192
        }()

        // Summary string
        var summaryParts: [String] = []
        summaryParts.append("MD5 match: \(md5Match.map { $0 ? "YES" : "NO" } ?? "N/A")")
        summaryParts.append("Filename match: \(filenameMatch.map { $0 ? "YES" : "NO" } ?? "N/A")")
        summaryParts.append("Pixel size match: \(pixelSizeMatch.map { $0 ? "YES" : "NO" } ?? "N/A")")
        summaryParts.append("Date match: \(dateMatch.map { $0 ? "YES" : "NO" } ?? "N/A")")
        summaryParts.append("File size match: \(fileSizeMatch.map { $0 ? "YES" : "NO" } ?? "N/A")")
        let summary = summaryParts.joined(separator: " | ")

        return AssetComparisonDiagnostics(
            localMD5: localMD5,
            amazonMD5: amazonMD5,
            md5Match: md5Match,
            localFilename: local.originalFilename,
            amazonFilename: amazon.name,
            filenameMatch: filenameMatch,
            localPixelSize: localSize,
            amazonPixelSize: amazonSize,
            pixelSizeMatch: pixelSizeMatch,
            localDate: localDate,
            amazonDate: amazonDate,
            dateMatch: dateMatch,
            localFileSize: localFileSize,
            amazonFileSize: amazonFileSize,
            fileSizeMatch: fileSizeMatch,
            summary: summary
        )
    }
}

import SwiftUI
import CoreData

fileprivate struct SectionContainer<Content: View>: View {
    let title: String
    let message: String
    let content: Content

    init(title: String, message: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.message = message
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .bold()
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            content
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary, lineWidth: 1))
        }
        .padding(.vertical, 8)
    }
}

fileprivate struct ComparisonSectionView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LocalAsset.creationDate, ascending: false)],
        animation: .default)
    private var localAssets: FetchedResults<LocalAsset>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \AmazonAsset.createdDate, ascending: false)],
        animation: .default)
    private var amazonAssets: FetchedResults<AmazonAsset>

    @State var selectedLocalID: NSManagedObjectID?
    @State var selectedAmazonID: NSManagedObjectID?

    var localSelectedAsset: LocalAsset? {
        guard let id = selectedLocalID else { return nil }
        return localAssets.first(where: { $0.objectID == id })
    }

    var amazonSelectedAsset: AmazonAsset? {
        guard let id = selectedAmazonID else { return nil }
        return amazonAssets.first(where: { $0.objectID == id })
    }

    var diagnostics: AssetMatcher.AssetComparisonDiagnostics? {
        guard let local = localSelectedAsset, let amazon = amazonSelectedAsset else { return nil }
        return AssetMatcher.diagnosticCompare(local: local, amazon: amazon)
    }

    var body: some View {
        VStack(alignment: .leading) {
            // Existing summary area can be here if needed
            // For now, no summary or recompute button is present as per instructions

            // --- Diagnostic Comparison Panel ---
            SectionContainer(
                title: "Diagnostics Compare",
                message: "Select one iPhoto asset and one Amazon asset to compare all matching checks in detail."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if localAssets.isEmpty || amazonAssets.isEmpty {
                        Text("No iPhoto or Amazon assets available for diagnostics.")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Picker("iPhoto Asset", selection: $selectedLocalID) {
                                Text("Select").tag(nil as NSManagedObjectID?)
                                ForEach(localAssets, id: \._self) { asset in
                                    Text(asset.originalFilename ?? asset.localIdentifier).tag(asset.objectID as NSManagedObjectID?)
                                }
                            }
                            .frame(width: 260)

                            Picker("Amazon Asset", selection: $selectedAmazonID) {
                                Text("Select").tag(nil as NSManagedObjectID?)
                                ForEach(amazonAssets, id: \._self) { asset in
                                    Text(asset.name ?? asset.nodeId).tag(asset.objectID as NSManagedObjectID?)
                                }
                            }
                            .frame(width: 260)
                        }

                        if let diagnostics = diagnostics {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("**Field-by-field Comparison Result:**")
                                Group {
                                    Text("MD5: \(diagnostics.localMD5 ?? "nil") vs. \(diagnostics.amazonMD5 ?? "nil") → \(diagnostics.md5Match.map { $0 ? "✅" : "❌" } ?? "N/A")")
                                    Text("Filename: \(diagnostics.localFilename ?? "nil") vs. \(diagnostics.amazonFilename ?? "nil") → \(diagnostics.filenameMatch.map { $0 ? "✅" : "❌" } ?? "N/A")")
                                    Text("Pixel Size: \(diagnostics.localPixelSize.0)x\(diagnostics.localPixelSize.1) vs. \(diagnostics.amazonPixelSize.0)x\(diagnostics.amazonPixelSize.1) → \(diagnostics.pixelSizeMatch.map { $0 ? "✅" : "❌" } ?? "N/A")")
                                    Text("Date: \(diagnostics.localDate.map { "\($0)" } ?? "nil") vs. \(diagnostics.amazonDate.map { "\($0)" } ?? "nil") → \(diagnostics.dateMatch.map { $0 ? "✅" : "❌" } ?? "N/A")")
                                    Text("File Size: \(diagnostics.localFileSize.map { String($0) } ?? "nil") vs. \(diagnostics.amazonFileSize.map { String($0) } ?? "nil") → \(diagnostics.fileSizeMatch.map { $0 ? "✅" : "❌" } ?? "N/A")")
                                }
                                Divider()
                                Text("Summary: \(diagnostics.summary)")
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.09)))
                        } else {
                            Text("Select both an iPhoto and an Amazon asset to compare.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }
            // --- End Diagnostic Comparison Panel ---
        }
        .padding()
    }
}

