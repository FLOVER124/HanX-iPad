import UIKit
import PDFKit
import Vision

/// On-device text recognition (문자 인식) with Vision, Korean and English.
enum PDFOCR {
    struct Line { let text: String; let confidence: Float; let bounds: CGRect }   // bounds in page space

    static func recognize(page: PDFPage, completion: @escaping (Result<[Line], Error>) -> Void) {
        let box = page.bounds(for: .mediaBox)
        let longest = max(box.width, box.height)
        let scale = min(3, 4000 / max(1, longest))
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        guard let ref = page.pageRef, let cg = render(ref, box: box, size: size) else {
            completion(.failure(PDFEditEngine.Failure(message: "OCR 페이지를 준비하지 못했습니다."))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { o -> Line? in
                    guard let top = o.topCandidates(1).first else { return nil }
                    let b = o.boundingBox   // normalised, origin bottom-left, same orientation as page space
                    let r = CGRect(x: box.minX + b.minX * box.width, y: box.minY + b.minY * box.height, width: b.width * box.width, height: b.height * box.height)
                    return Line(text: top.string, confidence: top.confidence, bounds: r)
                }
                DispatchQueue.main.async { completion(.success(lines)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Unrotated page raster (page space maps 1:1 onto the normalised Vision box).
    static func render(_ ref: CGPDFPage, box: CGRect, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: size.width / box.width, y: size.height / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }
}

/// PDF → editable document (the iPad counterpart of the macOS layout worker):
/// text lines keep their page position, size and colour; pages without text
/// become page images. Used by DocumentIO/TextDocument and "문서로 편집".
enum PDFReader {
    static func isPDF(_ data: Data) -> Bool { data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil }

    static func read(_ data: Data) throws -> UDocument {
        guard isPDF(data), let pdf = PDFDocument(data: data) else { throw FormatError.invalid("Cannot read PDF document") }
        guard !pdf.isLocked else { throw FormatError.invalid("암호로 잠긴 PDF입니다.") }
        let doc = UDocument()
        doc.source = .docx
        doc.warnings = ["PDF의 본문 줄과 위치를 복원했습니다. 그림과 도형은 다시 만들지 않으며, 글자가 없는 페이지는 이미지로 가져옵니다. 스캔 페이지는 PDF 편집 화면의 문자 인식을 이용하세요."]
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            var lines: [(text: String, rect: CGRect, size: CGFloat, color: RGB, font: String, bold: Bool, italic: Bool)] = []
            if let all = page.selection(for: box) {
                for line in all.selectionsByLine() {
                    let text = (line.string ?? "").trimmingCharacters(in: .newlines)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let r = line.bounds(for: page)
                    var size = max(4, r.height * 0.8), color = RGB.black, name = "", bold = false, italic = false
                    if let a = line.attributedString, a.length > 0 {
                        let attrs = a.attributes(at: 0, effectiveRange: nil)
                        if let f = attrs[.font] as? UIFont {
                            if f.pointSize > 1 && f.pointSize < r.height * 2 { size = f.pointSize }
                            name = PDFObjectFinder.cleanFontName(f.familyName)
                            bold = f.fontDescriptor.symbolicTraits.contains(.traitBold) || f.fontName.lowercased().contains("bold")
                            italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
                        }
                        if let c = attrs[.foregroundColor] as? UIColor { color = RGB(c) }
                    }
                    lines.append((text, r, size, color, name, bold, italic))
                }
            }
            // Reading order: top to bottom (page space is y-up), then left to right.
            lines.sort { a, b in abs(a.rect.maxY - b.rect.maxY) > 2 ? a.rect.maxY > b.rect.maxY : a.rect.minX < b.rect.minX }
            var section = Section()
            if lines.isEmpty {
                section.page = PageSetup(width: Double(box.width), height: Double(box.height), marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0, header: 0, footer: 0)
                if let ref = page.pageRef, let image = PDFOCR.render(ref, box: page.bounds(for: .mediaBox), size: CGSize(width: box.width * 2, height: box.height * 2)),
                   let png = UIImage(cgImage: image).pngData() {
                    let key = "pdf-page-\(index + 1).png"
                    doc.images[key] = ImageData(name: key, data: png)
                    var p = Paragraph()
                    p.props.lineSpacing = .multiple(1)
                    p.props.alignment = .left
                    p.inlines = [.image(id: key, width: Double(box.width) - 1, height: Double(box.height) - 2)]
                    section.blocks = [.paragraph(p)]
                }
                doc.warnings.append("PDF \(index + 1) 페이지는 이미지로 가져왔습니다.")
                doc.sections.append(section)
                continue
            }
            let left = max(0, (lines.map { $0.rect.minX }.min() ?? box.minX) - box.minX)
            let right = max(0, box.maxX - (lines.map { $0.rect.maxX }.max() ?? box.maxX))
            let top = max(0, box.maxY - (lines.first?.rect.maxY ?? box.maxY))
            section.page = PageSetup(width: Double(box.width), height: Double(box.height), marginTop: Double(max(0, top - 2)), marginBottom: 0,
                                     marginLeft: Double(min(left, box.width / 3)), marginRight: Double(min(right, box.width / 3)), header: 0, footer: 0)
            var previousBottom = box.maxY - CGFloat(section.page.marginTop)
            var blocks: [Block] = []
            for line in lines {
                var c = CharProps()
                c.fontName = line.font.isEmpty ? "Apple SD Gothic Neo" : line.font
                c.eastAsianFontName = c.fontName
                c.size = Double((line.size * 2).rounded() / 2)
                c.color = line.color
                c.bold = line.bold
                c.italic = line.italic
                // Scale glyph widths so each line keeps its original length.
                let measured = (line.text as NSString).size(withAttributes: [.font: FontResolver.shared.font(name: c.fontName, size: c.size, bold: c.bold, italic: c.italic).font]).width
                if measured > 0, line.rect.width > 4 { c.widthRatio = Double(max(50, min(200, (line.rect.width / measured * 100).rounded()))) }
                if abs(c.widthRatio - 100) < 4 { c.widthRatio = 100 }
                var p = Paragraph()
                p.props.alignment = .left
                p.props.indentLeft = Double(max(0, line.rect.minX - box.minX - CGFloat(section.page.marginLeft)))
                p.props.spaceBefore = Double(max(0, previousBottom - line.rect.maxY))
                p.props.lineSpacing = .exact(Double(max(line.rect.height, line.size * 1.1)))
                p.markProps = c
                p.inlines = [.text(line.text, c)]
                blocks.append(.paragraph(p))
                previousBottom = line.rect.maxY - max(line.rect.height, line.size * 1.1)
            }
            section.blocks = blocks
            doc.sections.append(section)
        }
        if doc.sections.isEmpty { doc.sections = [Section(page: .a4Hwp, blocks: [.paragraph(Paragraph())])] }
        return doc
    }
}
