import UIKit

/// Shared UIDocument behaviour. Like the macOS app, a file opened from disk
/// in a converted format (HWP, DOCX, PDF …) is never silently rewritten:
/// autosave stays off until the person confirms "원본 형식으로 저장" once.
/// Files HanX created itself, and .hanx files, save in place normally.
class HanXBaseDocument: UIDocument {
    private static var trusted = Set<String>()
    private static let trustLock = NSLock()

    static func trust(_ url: URL) {
        trustLock.lock(); trusted.insert(url.standardizedFileURL.path); trustLock.unlock()
    }
    static func isTrusted(_ url: URL) -> Bool {
        trustLock.lock(); defer { trustLock.unlock() }
        return trusted.contains(url.standardizedFileURL.path)
    }

    var inPlaceSaveConfirmed: Bool
    private(set) var loadError: Error?
    var importWarnings: [String] = []

    override init(fileURL url: URL) {
        inPlaceSaveConfirmed = url.pathExtension.lowercased() == "hanx" || HanXBaseDocument.isTrusted(url)
        super.init(fileURL: url)
    }

    var fileExtension: String { fileURL.pathExtension.lowercased() }
    var displayTitle: String { fileURL.deletingPathExtension().lastPathComponent }

    /// Subclasses: whether the original format can be written back.
    var canWriteOriginalFormat: Bool { true }
    var exportFormats: [ExportFormat] { [] }
    /// Bytes for an export (or for the original format when ext == fileExtension).
    func exportData(for ext: String) throws -> Data { throw HanXError.message("내보낼 수 없는 형식입니다.") }
    func pdfData() throws -> Data { try exportData(for: "pdf") }

    override func autosave(completionHandler: ((Bool) -> Void)? = nil) {
        if inPlaceSaveConfirmed && canWriteOriginalFormat { super.autosave(completionHandler: completionHandler) }
        else { completionHandler?(false) }
    }

    override func contents(forType typeName: String) throws -> Any {
        try exportData(for: fileExtension)
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        loadError = error
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }

    func recordLoadError(_ error: Error) { loadError = error }

    /// Discards unsaved edits so closing does not write them.
    func discardChanges() {
        undoManager?.removeAllActions()
        updateChangeCount(.cleared)
    }
}
