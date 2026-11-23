import AppKit
import QuickLookThumbnailing

/// Photos and videos live in ~/Pictures/Camera; the viewer steps through the newest ones.
final class Library: ObservableObject {
    static let folder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let url = pictures.appendingPathComponent("Camera", isDirectory: true)
        // Captures from before the rename (BetterBooth 0.3 and earlier) move over; retried each launch until they have.
        let fm = FileManager.default, old = pictures.appendingPathComponent("BetterBooth", isDirectory: true)
        if let leftovers = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil), !leftovers.isEmpty {
            if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: old, to: url) }
            for file in leftovers where fm.fileExists(atPath: file.path) {
                try? fm.moveItem(at: file, to: url.appendingPathComponent(file.lastPathComponent))
            }
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `Camera 2026-10-11 01.18.09 cam-link-4k 9x16 1080p 30fps.mp4`, time first to sort.
    static func newURL(ext: String, tags: [String]) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = (["Camera", f.string(from: Date())] + tags).joined(separator: " ")
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    @Published private(set) var items: [URL] = []

    init() { reload() }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        items = urls
            .filter { ["jpg", "mp4"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(30)
            .map(\.0)
    }

    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    static func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
