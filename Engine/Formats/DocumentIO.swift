import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Format router: sniff container signature first, extension second.
enum DocumentIO {
    static func load(url: URL) throws -> UDocument {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
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
        doc.title = url.deletingPathExtension().lastPathComponent
        return doc
    }

    static func save(_ doc: UDocument, to url: URL) throws {
        let data: Data
        switch url.pathExtension.lowercased() {
        case "docx": data = DOCXWriter(doc).write()
        case "hwpx": data = HWPXWriter(doc).write()
        case "hwp": data = HWP5Writer(doc).write()
        case "html", "htm": data = Data(HTMLWriter.write(doc).utf8)
        case "md": data = Data(MarkdownWriter.write(doc).utf8)
        case "txt": data = Data(doc.plainText.utf8)
        default: throw FormatError.unsupported("저장 형식 \(url.pathExtension)")
        }
        try data.write(to: url, options: .atomic)
    }
}
