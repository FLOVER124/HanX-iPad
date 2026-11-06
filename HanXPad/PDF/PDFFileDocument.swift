import UIKit
import PDFKit

extension Notification.Name {
    static let pdfDocumentChanged = Notification.Name("HanXPDFDocumentChanged")
}

/// A PDF being edited. Every revision is a complete PDF; undo swaps revisions.
final class PDFFileDocument: HanXBaseDocument {
    private(set) var data = Data()
    private(set) var pdf: PDFDocument?
    private(set) var revision = 0

    override var exportFormats: [ExportFormat] {
        ExportFormat.pdf + [ExportFormat(title: "Word 문서로 변환 (.docx)", ext: "docx"), ExportFormat(title: "한글 표준 문서로 변환 (.hwpx)", ext: "hwpx")]
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let bytes = contents as? Data, let doc = PDFDocument(data: bytes) else {
            let error = PDFEditEngine.Failure(message: "PDF 문서를 열 수 없습니다.")
            recordLoadError(error)
            throw error
        }
        data = bytes
        pdf = doc
    }

    var isLocked: Bool { pdf?.isLocked ?? false }

    /// Unlocks an encrypted PDF; edits then work on a decrypted copy.
    func unlock(_ password: String) -> Bool {
        guard let pdf, pdf.unlock(withPassword: password) else { return false }
        if let decrypted = pdf.dataRepresentation(), let reopened = PDFDocument(data: decrypted), !reopened.isLocked {
            data = decrypted
            self.pdf = reopened
            revision += 1
        }
        return true
    }

    func apply(_ op: PDFEditOperation) throws {
        let updated = try PDFEditEngine.apply(op, to: data)
        setData(updated, actionName: op.title)
    }

    func setData(_ new: Data, actionName: String) {
        let old = data
        data = new
        pdf = PDFDocument(data: new)
        revision += 1
        undoManager.registerUndo(withTarget: self) { $0.setData(old, actionName: actionName) }
        undoManager.setActionName(actionName)
        NotificationCenter.default.post(name: .pdfDocumentChanged, object: self)
    }

    override func exportData(for ext: String) throws -> Data {
        switch ext {
        case "pdf": return data
        case "docx": return DOCXWriter(try PDFReader.read(data)).write()
        case "hwpx":
            let doc = try PDFReader.read(data)
            doc.source = .hwpx
            return HWPXWriter(doc).write()
        default: throw HanXError.message("PDF는 PDF 형식으로 저장하세요.")
        }
    }

    override func pdfData() -> Data { data }
}
