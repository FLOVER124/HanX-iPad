import UIKit

/// Builds the right editor for a file and presents it full screen. Opening
/// from inside an editor (templates, PDF → 문서) stacks the new editor on top,
/// so closing it returns to the document underneath.
enum EditorFactory {
    static func make(_ url: URL) -> HanXEditorViewController? {
        guard let kind = FileKinds.kind(for: url) else { return nil }
        switch kind {
        case .document: return DocumentEditorViewController(document: TextDocument(fileURL: url))
        case .spreadsheet: return SheetEditorViewController(document: SheetFileDocument(fileURL: url))
        case .presentation: return SlideEditorViewController(document: SlideFileDocument(fileURL: url))
        case .pdf: return PDFEditorViewController(document: PDFFileDocument(fileURL: url))
        }
    }

    static func open(_ url: URL, from host: UIViewController) {
        guard let editor = make(url) else {
            host.presentMessage("열 수 없는 파일입니다", "hwp, hwpx, docx, xlsx, csv, pptx, pdf, hanx, txt, md, html 파일을 열 수 있습니다.")
            return
        }
        editor.baseDocument.open { success in
            guard success else {
                let reason = editor.baseDocument.loadError.map(HanXError.describe) ?? "파일 형식을 확인하세요."
                host.presentMessage("문서를 열 수 없습니다", reason)
                return
            }
            let nav = UINavigationController(rootViewController: editor)
            nav.modalPresentationStyle = .fullScreen
            host.topmostPresenter.present(nav, animated: true) { editor.didFinishPresenting() }
        }
    }
}

extension UIViewController {
    /// Saves bytes HanX produced (template, conversion) to On My iPad › HanX and opens them.
    func openGeneratedDocument(data: Data, name: String, ext: String) {
        do {
            let url = try GeneratedFiles.write(data, name: name, ext: ext)
            HanXBaseDocument.trust(url)
            EditorFactory.open(url, from: self)
        } catch { presentError(error) }
    }
}
