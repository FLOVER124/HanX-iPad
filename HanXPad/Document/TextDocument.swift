import UIKit

/// HWP / HWPX / DOCX / HanX / text documents. The editable content is one
/// NSTextStorage; the model is rebuilt from it when saving or exporting.
final class TextDocument: HanXBaseDocument {
    let storage = NSTextStorage()
    private(set) var model = UDocument()
    var page = PageSetup.a4Hwp
    var header: [Block]?
    var footer: [Block]?
    /// Image payloads referenced by attachments (`.hwImage`).
    var images: [String: ImageData] = [:]
    var sourceFormat: SourceFormat { model.source }

    override var canWriteOriginalFormat: Bool { !["hwt", "dotx"].contains(fileExtension) }
    override var exportFormats: [ExportFormat] { ExportFormat.document }

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "rtf", "html", "htm"]

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else { throw HanXError.message("문서 내용을 읽을 수 없습니다.") }
        do {
            let ext = fileExtension
            let doc: UDocument
            if TextDocument.textExtensions.contains(ext) {
                doc = try TextDocument.readText(data, ext: ext)
            } else {
                doc = try TextDocument.read(data, ext: ext)
            }
            doc.title = displayTitle
            model = doc
            page = doc.sections.first?.page ?? (doc.source == .docx ? .letterWord : .a4Hwp)
            header = doc.sections.first?.header
            footer = doc.sections.first?.footer
            images = doc.images
            importWarnings = doc.warnings
            let attributed = TextBridge.attributedString(from: doc)
            storage.beginEditing()
            storage.setAttributedString(attributed)
            storage.endEditing()
        } catch {
            recordLoadError(error)
            throw error
        }
    }

    /// Same routing as DocumentIO.load(url:), from in-memory bytes.
    static func read(_ data: Data, ext: String) throws -> UDocument {
        let doc: UDocument
        if ext == "hanx" || data.starts(with: Data("HanX/".utf8)) {
            doc = try DOCXReader(zip: HanXFile.payload(data, expecting: .document)).read()
        } else if PDFReader.isPDF(data) || ext == "pdf" {
            doc = try PDFReader.read(data)
        } else if CFBReader.isCFB(data) {
            doc = try HWP5Reader(data: data).read()
        } else if ZipReader.isZip(data) {
            let zip = try ZipReader(data: data)
            if zip.has("word/document.xml") || ext == "docx" || ext == "dotx" {
                doc = try DOCXReader(zip: zip).read()
            } else if zip.has("Contents/header.xml") || ext == "hwpx" {
                doc = try HWPXReader(zip: zip).read()
            } else {
                throw FormatError.unsupported("알 수 없는 ZIP 기반 문서")
            }
        } else {
            throw FormatError.unsupported("hwp, hwpx, docx, pdf 형식만 열 수 있습니다")
        }
        if doc.sections.isEmpty { doc.sections = [Section(page: doc.source == .docx ? .letterWord : .a4Hwp, blocks: [.paragraph(Paragraph())])] }
        for i in doc.sections.indices where doc.sections[i].blocks.isEmpty { doc.sections[i].blocks = [.paragraph(Paragraph())] }
        return doc
    }

    /// Plain text, Markdown, RTF and HTML open as editable documents.
    static func readText(_ data: Data, ext: String) throws -> UDocument {
        if ext == "rtf" || ext == "html" || ext == "htm" {
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .html
            let attr = try NSAttributedString(data: data, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil)
            let base = UDocument(); base.source = .docx
            return TextBridge.document(from: attr, base: base, images: [:], page: .a4Hwp)
        }
        let text = DelimitedText.decode(data).replacingOccurrences(of: "\r\n", with: "\n")
        let doc = UDocument.plain(text, char: defaultCharProps(for: .docx))
        doc.source = .docx
        return doc
    }

    // MARK: Saving

    func currentModel() -> UDocument {
        let d = TextBridge.document(from: storage, base: model, images: images, page: page)
        if !d.sections.isEmpty { d.sections[0].header = header; d.sections[0].footer = footer }
        d.images = usedImages(d)
        return d
    }

    /// Drops payloads no longer referenced so saved files do not grow.
    private func usedImages(_ d: UDocument) -> [String: ImageData] {
        var used = Set<String>()
        func walk(_ blocks: [Block]) {
            for b in blocks {
                switch b {
                case .paragraph(let p): for i in p.inlines { if case .image(let id, _, _) = i { used.insert(id) } }
                case .table(let t): t.rows.forEach { $0.forEach { walk($0.blocks) } }
                }
            }
        }
        for s in d.sections { walk(s.blocks); walk(s.header ?? []); walk(s.footer ?? []) }
        return d.images.filter { used.contains($0.key) }
    }

    override func exportData(for ext: String) throws -> Data {
        let doc = currentModel()
        switch ext {
        case "hanx": return HanXFile.encode(.document, payload: DOCXWriter(doc).write())
        case "txt", "text": return Data(doc.plainText.utf8)
        case "md", "markdown": return Data(MarkdownWriter.write(doc).utf8)
        case "html", "htm": return Data(HTMLWriter.write(doc).utf8)
        case "rtf":
            let plain = NSMutableAttributedString(attributedString: storage)
            return try plain.data(from: NSRange(location: 0, length: plain.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case "pdf": return pdfData()
        case "docx", "dotx": return DOCXWriter(doc).write()
        case "hwpx": return HWPXWriter(doc).write()
        case "hwp", "hwt": return HWP5Writer(doc).write()
        default: throw HanXError.message("이 형식으로는 저장할 수 없습니다: \(ext)")
        }
    }

    override func pdfData() -> Data {
        PageExporter.pdf(storage: storage, page: page, decorations: decorations())
    }

    func decorations() -> PageDecorations {
        PageDecorations.make(header: header, footer: footer, page: page, images: images, source: sourceFormat)
    }

    // MARK: Defaults for new text

    static func defaultCharProps(for f: SourceFormat) -> CharProps {
        var c = CharProps()
        if f == .docx { c.fontName = "Calibri"; c.eastAsianFontName = "맑은 고딕"; c.size = 11 }
        else { c.fontName = "함초롬바탕"; c.eastAsianFontName = "함초롬바탕"; c.size = 10 }
        return c
    }

    static func defaultParaProps(for f: SourceFormat) -> ParaProps {
        var p = ParaProps()
        if f == .docx { p.alignment = .left; p.lineSpacing = .multiple(1.08); p.spaceAfter = 8 }
        return p
    }

    func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        var a = TextBridge.charAttributes(TextDocument.defaultCharProps(for: sourceFormat), eastAsian: true)
        let ctx = TextBridge.Context(images: images, source: sourceFormat)
        for (k, v) in TextBridge.paragraphAttributes(TextDocument.defaultParaProps(for: sourceFormat), mark: TextDocument.defaultCharProps(for: sourceFormat), ctx: ctx) { a[k] = v }
        return a
    }

    func nextImageKey(ext: String) -> String {
        var n = images.count + 1
        while images["user/image\(n).\(ext)"] != nil { n += 1 }
        return "user/image\(n).\(ext)"
    }
}
