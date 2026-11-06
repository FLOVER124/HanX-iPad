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
        let about = UIBarButtonItem(image: UIImage(systemName: "info.circle"), menu: UIMenu(children: [
            UIAction(title: "글꼴 추가…", image: UIImage(systemName: "textformat")) { [weak self] _ in self?.importFonts() },
            UIAction(title: "HanX 정보", image: UIImage(systemName: "info.circle")) { [weak self] _ in self?.showAbout() },
        ]))
        additionalTrailingNavigationBarButtonItems = [about]
    }

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
        EditorFactory.open(url, from: self)
    }

    // MARK: Fonts and about

    private var fontPickerDelegate: FontImportDelegate?

    private func importFonts() {
        let types = ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = FontImportDelegate { [weak self] urls in
            let added = FontResolver.shared.importFonts(urls)
            self?.presentMessage(added.isEmpty ? "글꼴을 추가하지 못했습니다" : "글꼴을 추가했습니다",
                                 added.isEmpty ? "TrueType 또는 OpenType 글꼴 파일을 선택하세요." : added.joined(separator: ", "))
        }
        fontPickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        presentMessage("HanX for iPad \(version)",
                       "HWP·HWPX·DOCX 문서, XLSX 도표, PPTX 프레젠테이션과 PDF를 편집합니다.\n\(LegalNotices.independence). 한글과컴퓨터, Microsoft와 제휴 관계가 없습니다.")
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
