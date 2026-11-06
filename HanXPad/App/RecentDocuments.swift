import Foundation

/// Recently opened files, kept as bookmarks so files from iCloud Drive or
/// other providers can be reopened from the start screen.
enum RecentDocuments {
    private static let key = "HanXRecentDocumentBookmarks"
    private static let limit = 20

    private static var bookmarks: [Data] {
        get { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(limit)), forKey: key) }
    }

    /// Call while the URL's security scope is open (i.e. while the document is open).
    static func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let path = url.standardizedFileURL.path
        var list = bookmarks.filter { resolve($0)?.standardizedFileURL.path != path }
        list.insert(bookmark, at: 0)
        bookmarks = list
    }

    static var urls: [URL] {
        var seen = Set<String>()
        return bookmarks.compactMap(resolve).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        bookmarks = bookmarks.filter { resolve($0)?.standardizedFileURL.path != path }
    }

    static func clear() { bookmarks = [] }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
