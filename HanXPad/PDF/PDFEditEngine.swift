import UIKit
import PDFKit
import CoreText

/// PDF edits that need no external engine. Each operation produces a new
/// complete PDF (so undo is a swap of revisions, like the macOS session):
/// the edited page is redrawn into a fresh one-page PDF — original content
/// as vectors, then the change — and replaces the old page; other pages are
/// left untouched.
enum PDFEditOperation {
    case addText(page: Int, rect: CGRect, text: String, fontSize: CGFloat, color: RGB, fontName: String, bold: Bool)
    case setText(page: Int, object: PDFPageObject, text: String, fontSize: CGFloat, color: RGB)
    case addImage(page: Int, rect: CGRect, data: Data)
    case replaceImage(page: Int, rect: CGRect, data: Data)
    case addRect(page: Int, rect: CGRect, fill: RGB?, stroke: RGB?, lineWidth: CGFloat)
    case delete(page: Int, rects: [CGRect])
    case transform(page: Int, from: CGRect, to: CGRect, quarterTurns: Int)
    case recolor(page: Int, rect: CGRect, color: RGB)
    case textLayer(page: Int, lines: [(String, CGRect)])
    case rotatePage(page: Int, degrees: Int)
    case deletePage(page: Int)
    case insertBlankPage(at: Int, size: CGSize)
    case duplicatePage(page: Int)
    case movePage(from: Int, to: Int)
    case insertPages(at: Int, pdf: Data)

    var title: String {
        switch self {
        case .addText: return "텍스트 추가"
        case .setText: return "텍스트 수정"
        case .addImage: return "이미지 추가"
        case .replaceImage: return "이미지 교체"
        case .addRect: return "도형 추가"
        case .delete: return "삭제"
        case .transform: return "크기와 위치"
        case .recolor: return "채우기"
        case .textLayer: return "검색 가능한 텍스트"
        case .rotatePage: return "페이지 회전"
        case .deletePage: return "페이지 삭제"
        case .insertBlankPage: return "빈 페이지"
        case .duplicatePage: return "페이지 복제"
        case .movePage: return "페이지 이동"
        case .insertPages: return "페이지 삽입"
        }
    }
}

enum PDFEditEngine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func apply(_ op: PDFEditOperation, to data: Data) throws -> Data {
        guard let doc = PDFDocument(data: data) else { throw Failure(message: "PDF 문서를 열 수 없습니다.") }
        guard !doc.isLocked else { throw Failure(message: "암호로 잠긴 PDF는 편집할 수 없습니다.") }
        switch op {
        case .rotatePage(let i, let degrees):
            guard let page = doc.page(at: i) else { throw Failure(message: "페이지 번호를 확인하세요.") }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        case .deletePage(let i):
            guard doc.pageCount > 1, i < doc.pageCount else { throw Failure(message: "마지막 남은 페이지는 삭제할 수 없습니다.") }
            doc.removePage(at: i)
        case .insertBlankPage(let at, let size):
            let blank = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { ctx in ctx.beginPage() }
            guard let page = PDFDocument(data: blank)?.page(at: 0) else { throw Failure(message: "빈 페이지를 만들지 못했습니다.") }
            doc.insert(page, at: max(0, min(at, doc.pageCount)))
        case .duplicatePage(let i):
            guard let page = doc.page(at: i), let copy = page.copy() as? PDFPage else { throw Failure(message: "페이지를 복제하지 못했습니다.") }
            doc.insert(copy, at: i + 1)
        case .movePage(let from, let to):
            guard from != to, from < doc.pageCount, to < doc.pageCount, let page = doc.page(at: from) else { return data }
            doc.removePage(at: from)
            doc.insert(page, at: to)
        case .insertPages(let at, let pdf):
            guard let other = PDFDocument(data: pdf), !other.isLocked else { throw Failure(message: "삽입할 PDF를 열 수 없습니다.") }
            var index = max(0, min(at, doc.pageCount))
            for i in 0..<other.pageCount { if let p = other.page(at: i) { doc.insert(p, at: index); index += 1 } }
        default:
            let index = op.pageIndex
            guard let page = doc.page(at: index) else { throw Failure(message: "페이지 번호를 확인하세요.") }
            let redrawn = try redraw(page) { ctx, box in try draw(op, page: page, in: ctx, box: box) }
            doc.removePage(at: index)
            doc.insert(redrawn, at: index)
        }
        guard let out = doc.dataRepresentation() else { throw Failure(message: "PDF를 저장하지 못했습니다.") }
        return out
    }

    /// Draws `page` (content and annotations) into a new one-page PDF, then `body`.
    static func redraw(_ page: PDFPage, body: (CGContext, CGRect) throws -> Void) throws -> PDFPage {
        guard let ref = page.pageRef else { throw Failure(message: "PDF 페이지를 읽을 수 없습니다.") }
        var media = page.bounds(for: .mediaBox)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw Failure(message: "PDF 페이지를 만들지 못했습니다.") }
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(cgRect: media)] as CFDictionary)
        ctx.saveGState()
        ctx.drawPDFPage(ref)
        ctx.restoreGState()
        for annotation in page.annotations where annotation.shouldDisplay && annotation.type != "Link" && annotation.type != "Widget" {
            ctx.saveGState()
            annotation.draw(with: .mediaBox, in: ctx)
            ctx.restoreGState()
        }
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        try body(ctx, media)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let page2 = PDFDocument(data: output as Data)?.page(at: 0) else { throw Failure(message: "PDF 페이지를 만들지 못했습니다.") }
        page2.rotation = page.rotation
        let crop = page.bounds(for: .cropBox)
        if crop != media { page2.setBounds(crop, for: .cropBox) }
        // Keep links and form fields as live annotations.
        for annotation in page.annotations where annotation.type == "Link" || annotation.type == "Widget" {
            if let copy = annotation.copy() as? PDFAnnotation { page2.addAnnotation(copy) }
        }
        return page2
    }

    private static func draw(_ op: PDFEditOperation, page: PDFPage, in ctx: CGContext, box: CGRect) throws {
        switch op {
        case .addText(_, let rect, let text, let size, let color, let fontName, let bold):
            drawText(text, in: rect, size: size, color: color, fontName: fontName, bold: bold, italic: false, ctx: ctx)
        case .setText(_, let object, let text, let size, let color):
            let r = object.bounds
            cover(r.insetBy(dx: -0.75, dy: -0.75), page: page, ctx: ctx)
            let width = max(r.width, measure(text, size: size, fontName: object.fontName, bold: object.bold) + 2)
            drawText(text, in: CGRect(x: r.minX, y: r.minY, width: width, height: max(r.height, size * 1.25)), size: size, color: color,
                     fontName: object.fontName, bold: object.bold, italic: object.italic, ctx: ctx)
        case .addImage(_, let rect, let data):
            try drawImage(data, in: rect, ctx: ctx)
        case .replaceImage(_, let rect, let data):
            cover(rect, page: page, ctx: ctx)
            try drawImage(data, in: rect, ctx: ctx)
        case .addRect(_, let rect, let fill, let stroke, let lineWidth):
            if let fill { ctx.setFillColor(fill.cgColor); ctx.fill(rect) }
            if let stroke { ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(lineWidth); ctx.stroke(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)) }
        case .delete(_, let rects):
            for r in rects { cover(r.insetBy(dx: -0.75, dy: -0.75), page: page, ctx: ctx) }
        case .transform(_, let from, let to, let turns):
            guard let ref = page.pageRef, from.width > 0, from.height > 0 else { return }
            let background = sampleBackground(page: page, rect: from)
            ctx.setFillColor(background.cgColor)
            ctx.fill(from.insetBy(dx: -0.75, dy: -0.75))
            ctx.saveGState()
            // Map `from` onto `to`, turning in quarter steps about the centre.
            let q = ((turns % 4) + 4) % 4
            let fw = q % 2 == 0 ? from.width : from.height
            let fh = q % 2 == 0 ? from.height : from.width
            ctx.translateBy(x: to.midX, y: to.midY)
            ctx.scaleBy(x: to.width / fw, y: to.height / fh)
            ctx.rotate(by: -CGFloat(q) * .pi / 2)
            ctx.translateBy(x: -from.midX, y: -from.midY)
            ctx.clip(to: from)
            ctx.drawPDFPage(ref)
            ctx.restoreGState()
        case .recolor(_, let rect, let color):
            guard let ref = page.pageRef else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.drawPDFPage(ref)
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        case .textLayer(_, let lines):
            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            for (text, r) in lines where !text.isEmpty && r.height > 1 {
                let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, max(2, r.height * 0.85), nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]) as CFAttributedString)
                let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.18)
                if natural > 0 { ctx.scaleBy(x: r.width / natural, y: 1) }
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.restoreGState()
        default: break
        }
    }

    // MARK: Drawing helpers (PDF space, y up)

    static func font(name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let resolved = FontResolver.shared.font(name: name.isEmpty ? "Apple SD Gothic Neo" : name, size: Double(size), bold: bold, italic: italic).font
        // Unknown embedded faces fall back to a Korean-capable sans face.
        if name.isEmpty || resolved.familyName == UIFont.systemFont(ofSize: 10).familyName {
            return FontResolver.shared.font(name: "Apple SD Gothic Neo", size: Double(size), bold: bold, italic: italic).font
        }
        return resolved
    }

    static func measure(_ text: String, size: CGFloat, fontName: String, bold: Bool) -> CGFloat {
        let f = font(name: fontName, size: size, bold: bold, italic: false)
        return ceil((text as NSString).size(withAttributes: [.font: f]).width)
    }

    static func drawText(_ text: String, in rect: CGRect, size: CGFloat, color: RGB, fontName: String, bold: Bool, italic: Bool, ctx: CGContext) {
        let f = font(name: fontName, size: size, bold: bold, italic: italic)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        ctx.saveGState()
        ctx.textMatrix = .identity
        // First baseline sits one ascender below the top of the box.
        var y = rect.maxY - f.ascender
        for line in text.components(separatedBy: "\n") {
            let attributed = NSAttributedString(string: line, attributes: [.font: f, colorKey: color.cgColor])
            let ct = CTLineCreateWithAttributedString(attributed as CFAttributedString)
            ctx.textPosition = CGPoint(x: rect.minX, y: y)
            CTLineDraw(ct, ctx)
            y -= f.lineHeight
        }
        ctx.restoreGState()
    }

    static func drawImage(_ data: Data, in rect: CGRect, ctx: CGContext) throws {
        guard let image = UIImage(data: data)?.normalizedOrientation(), let cg = image.cgImage else { throw Failure(message: "그림을 읽을 수 없습니다.") }
        let s = image.size
        let scale = min(rect.width / max(1, s.width), rect.height / max(1, s.height))
        let w = s.width * scale, h = s.height * scale
        ctx.draw(cg, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    static func cover(_ rect: CGRect, page: PDFPage, ctx: CGContext) {
        ctx.setFillColor(sampleBackground(page: page, rect: rect).cgColor)
        ctx.fill(rect)
    }

    /// The most common colour on a thin ring just outside `rect`.
    static func sampleBackground(page: PDFPage, rect: CGRect) -> RGB {
        guard let ref = page.pageRef else { return .white }
        let ring = rect.insetBy(dx: -3, dy: -3)
        let scale: CGFloat = min(2, 600 / max(1, max(ring.width, ring.height)))
        let w = max(4, Int(ring.width * scale)), h = max(4, Int(ring.height * scale))
        guard let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        bitmap.setFillColor(UIColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -ring.minX, y: -ring.minY)
        bitmap.drawPDFPage(ref)
        guard let base = bitmap.data else { return .white }
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var buckets: [Int: (Int, Int, Int, Int)] = [:]
        func sample(_ x: Int, _ y: Int) {
            let p = (y * w + x) * 4
            let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
            let key = (r / 16) << 8 | (g / 16) << 4 | b / 16
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.0 + 1, old.1 + r, old.2 + g, old.3 + b)
        }
        for x in 0..<w { sample(x, 0); sample(x, h - 1); sample(x, 1); sample(x, h - 2) }
        for y in 0..<h { sample(0, y); sample(w - 1, y); sample(1, y); sample(w - 2, y) }
        guard let best = buckets.max(by: { $0.value.0 < $1.value.0 })?.value, best.0 > 0 else { return .white }
        return RGB(r: UInt8(best.1 / best.0), g: UInt8(best.2 / best.0), b: UInt8(best.3 / best.0))
    }
}

extension PDFEditOperation {
    var pageIndex: Int {
        switch self {
        case .addText(let p, _, _, _, _, _, _), .setText(let p, _, _, _, _), .addImage(let p, _, _), .replaceImage(let p, _, _),
             .addRect(let p, _, _, _, _), .delete(let p, _), .transform(let p, _, _, _), .recolor(let p, _, _), .textLayer(let p, _),
             .rotatePage(let p, _), .deletePage(let p), .duplicatePage(let p): return p
        case .insertBlankPage(let at, _), .insertPages(let at, _): return at
        case .movePage(_, let to): return to
        }
    }
}
