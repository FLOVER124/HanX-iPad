import UIKit
import UniformTypeIdentifiers

/// Root of every window: the system document browser (Files locations,
/// recents, tags) plus HanX's "새로 만들기" sheet, matching the macOS start window.
final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    init() {
        super.init(forOpening: FileKinds.readable)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        shouldShowFileExtensions = true
        localizedCreateDocumentActionTitle = "새로 만들기"
        view.tintColor = HanXTheme.accent
        let close = UIBarButtonItem(title: "닫기", image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        additionalLeadingNavigationBarButtonItems = [close]
    }

    /// Set by the start screen: the browser closes and the start screen opens the file.
    var onOpen: ((URL) -> Void)?

    // MARK: Creating

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        let sheet = NewDocumentViewController()
        var handled = false
        sheet.onCreate = { [weak sheet] request in
            handled = true
            sheet?.dismiss(animated: true) {
                do {
                    let url = try request.makeTemporaryFile()
                    importHandler(url, .move)
                } catch {
                    importHandler(nil, .none)
                    controller.presentError(error)
                }
            }
        }
        sheet.onCancel = {
            guard !handled else { return }
            handled = true
            importHandler(nil, .none)
        }
        let nav = UINavigationController(rootViewController: sheet)
        nav.modalPresentationStyle = .formSheet
        nav.presentationController?.delegate = sheet
        present(nav, animated: true)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
        HanXBaseDocument.trust(destinationURL)
        openDocument(at: destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
        presentMessage("문서를 만들지 못했습니다", error?.localizedDescription ?? "")
    }

    // MARK: Opening

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { openDocument(at: url) }
    }

    func openDocument(at url: URL) {
        if let onOpen { onOpen(url) } else { EditorFactory.open(url, from: self) }
    }

}

final class FontImportDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    init(_ completion: @escaping ([URL]) -> Void) { self.completion = completion }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls) }
}

/// Files HanX makes on its own (conversions, templates) live in the app's
/// Documents folder, which the Files app shows as "On My iPad › HanX".
enum GeneratedFiles {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func uniqueURL(name: String, ext: String, in directory: URL) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = clean.isEmpty ? "제목 없음" : clean
        var url = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func write(_ data: Data, name: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(name: name, ext: ext, in: folder)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func temporary(_ data: Data, name: String, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HanX-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(name: name, ext: ext, in: dir)
        try data.write(to: url, options: .atomic)
        return url
    }
}
