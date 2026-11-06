#if DEBUG
import UIKit

/// Debug-only launch hook for automated screenshots:
///   -HanXDemo document|spreadsheet|presentation|pdf
/// writes a sample file into the app's Documents folder and opens it.
enum DemoDocuments {
    static func openIfRequested(from host: UIViewController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-HanXDemo"), i + 1 < args.count else { return }
        let kind = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let file = sample(kind) else { return }
            host.openGeneratedDocument(data: file.0, name: "데모 \(kind)", ext: file.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exportReport(kind, host: host) }
        }
    }

    /// Exports the open document to every format and writes Documents/export-<kind>.txt.
    static func exportReport(_ kind: String, host: UIViewController) {
        guard let nav = host.topmostPresenter as? UINavigationController,
              let editor = nav.viewControllers.first as? HanXEditorViewController else {
            try? "no editor".write(to: GeneratedFiles.folder.appendingPathComponent("export-\(kind).txt"), atomically: true, encoding: .utf8)
            return
        }
        var lines: [String] = []
        for f in editor.baseDocument.exportFormats {
            do {
                let data = try editor.baseDocument.exportData(for: f.ext)
                var verdict = "ok"
                // Re-read what we wrote with the same readers the app uses.
                switch f.ext {
                case "docx", "hwpx", "hwp", "hanx" where kind == "document" || kind == "pdf":
                    let doc = try TextDocument.read(data, ext: f.ext)
                    verdict = "reread \(doc.stats.paragraphs)p \(doc.stats.tables)t"
                case "xlsx": verdict = "reread \(try XLSXReader.read(ZipReader(data: data)).sheets.count) sheets"
                case "pptx": verdict = "reread \(try PPTXReader(zip: ZipReader(data: data)).read().slides.count) slides"
                case "pdf": verdict = PDFReader.isPDF(data) ? "pdf" : "NOT PDF"
                default: break
                }
                lines.append("\(f.ext)\t\(data.count) bytes\t\(verdict)")
            } catch {
                lines.append("\(f.ext)\tFAILED\t\(HanXError.describe(error))")
            }
        }
        try? lines.joined(separator: "\n").write(to: GeneratedFiles.folder.appendingPathComponent("export-\(kind).txt"), atomically: true, encoding: .utf8)
    }

    static func sampleDocument() -> UDocument {
        let doc = UDocument()
        doc.source = .hwpx
        var title = CharProps(); title.size = 20; title.bold = true; title.fontName = "Apple SD Gothic Neo"; title.eastAsianFontName = title.fontName
        var body = CharProps(); body.size = 11; body.fontName = "Apple SD Gothic Neo"; body.eastAsianFontName = body.fontName
        var h = Paragraph(); h.props.alignment = .center; h.inlines = [.text("HanX iPad 문서 편집기", title)]; h.markProps = title
        var p = Paragraph(); p.props.alignment = .justify
        p.inlines = [.text("한글·Word 문서를 iPad에서 편집합니다. ", body), .text("굵게", { var c = body; c.bold = true; return c }()),
                     .text(", ", body), .text("기울임", { var c = body; c.italic = true; return c }()), .text(", 색", { var c = body; c.color = RGB(r: 220, g: 40, b: 40); return c }())]
        p.markProps = body
        var t = Table(); t.columnWidths = [140, 140, 140]
        t.rows = (0..<3).map { r in (0..<3).map { c in TableCell(blocks: [.paragraph(Paragraph(inlines: [.text("셀 \(r + 1)-\(c + 1)", body)]))]) } }
        t.rows[0][0].background = RGB(r: 230, g: 238, b: 250)
        var footer = Paragraph(); footer.props.alignment = .center; footer.inlines = [.text("- ", body), .field(.page, body), .text(" -", body)]
        var section = Section(page: .a4Hwp, blocks: [.paragraph(h), .paragraph(p), .table(t)] + (0..<30).map { _ in .paragraph(p) })
        section.footer = [.paragraph(footer)]
        doc.sections = [section]
        return doc
    }

    static func sample(_ kind: String) -> (Data, String)? {
        switch kind {
        case "document": return (HWPXWriter(sampleDocument()).write(), "hwpx")
        case "spreadsheet":
            let book = Workbook()
            let ws = book.sheets[0]
            ws.set(CellRef(row: 0, col: 0), input: "월"); ws.set(CellRef(row: 0, col: 1), input: "매출"); ws.set(CellRef(row: 0, col: 2), input: "비용")
            for m in 1...6 {
                ws.set(CellRef(row: m, col: 0), input: "\(m)월")
                ws.set(CellRef(row: m, col: 1), input: "\(100 + m * 17)")
                ws.set(CellRef(row: m, col: 2), input: "\(60 + m * 9)")
            }
            ws.set(CellRef(row: 7, col: 0), input: "합계")
            ws.set(CellRef(row: 7, col: 1), input: "=SUM(B2:B7)")
            ws.set(CellRef(row: 7, col: 2), input: "=SUM(C2:C7)")
            ws.charts = [SheetChart(kind: .column, title: "월별 매출", data: CellRange(CellRef(row: 0, col: 0), CellRef(row: 6, col: 2)), x: 230, y: 10)]
            return (XLSXWriter.write(book), "xlsx")
        case "presentation":
            let pres = Presentation.blank()
            pres.slides[0].shapes[0].paragraphs = [Presentation.textParagraph("HanX for iPad", size: 44, bold: true, align: .center)]
            pres.slides[0].shapes[1].paragraphs = [Presentation.textParagraph("문서 · 도표 · 프레젠테이션 · PDF", size: 24, align: .center)]
            var star = SlideShape(id: 9, name: "별", kind: .star5, frame: Frame(x: 60, y: 60, w: 120, h: 120))
            star.fill = RGB(r: 255, g: 192, b: 0)
            pres.slides[0].shapes.append(star)
            var second = pres.contentSlide()
            second.shapes[0].paragraphs = [Presentation.textParagraph("두 번째 슬라이드", size: 36, bold: true)]
            var item = Presentation.textParagraph("글머리 항목", size: 24); item.props.listLabel = "•"
            second.shapes[1].paragraphs = [item, item]
            second.transition.kind = .push
            pres.slides.append(second)
            return (PPTXWriter.write(pres), "pptx")
        case "pdf":
            let storage = NSTextStorage(attributedString: TextBridge.attributedString(from: sampleDocument()))
            return (PageExporter.pdf(storage: storage, page: .a4Hwp, decorations: PageDecorations()), "pdf")
        default: return nil
        }
    }
}
#endif
