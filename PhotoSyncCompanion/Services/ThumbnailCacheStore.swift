import AppKit
import CoreData
import Foundation

final class ThumbnailCacheStore {
    static let shared = ThumbnailCacheStore()

    private let fileManager = FileManager.default
    private let memoryCache = NSCache<NSString, NSImage>()
    private let cacheDirectoryURL: URL

    init() {
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        cacheDirectoryURL = baseDirectory.appendingPathComponent("PhotoSyncCompanion/Thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
    }

    func image(for key: String) -> NSImage? {
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let url = cacheURL(for: key)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }

        memoryCache.setObject(image, forKey: key as NSString)
        return image
    }

    func store(_ image: NSImage, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString)

        guard let data = image.tiffRepresentation else { return }
        guard let rep = NSBitmapImageRep(data: data),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }

        try? pngData.write(to: cacheURL(for: key), options: .atomic)
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    private func cacheURL(for key: String) -> URL {
        cacheDirectoryURL.appendingPathComponent(sanitizedFileName(for: key)).appendingPathExtension("png")
    }

    private func sanitizedFileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "") { $0.append($1) }
    }
}
