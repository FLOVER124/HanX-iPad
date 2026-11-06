import UIKit

/// Slide text ↔ TextKit. List items carry a visible marker ("•\t", "1.\t")
/// tagged `.hwListMarker`, which the bridge skips when converting back.
enum SlideText {
    static func attributed(_ paragraphs: [Paragraph], scale: Double = 1) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var number = 0
        let ctx = TextBridge.Context(images: [:], source: .docx)
        for (i, var p) in paragraphs.enumerated() {
            if scale < 0.999 {
                p.markProps.size *= scale
                p.inlines = p.inlines.map {
                    switch $0 {
                    case .text(let t, var c): c.size *= scale; return .text(t, c)
                    case .tab(var c): c.size *= scale; return .tab(c)
                    case .lineBreak(var c): c.size *= scale; return .lineBreak(c)
                    default: return $0
                    }
                }
            }
            let s = NSMutableAttributedString(attributedString: TextBridge.paragraph(p, width: 10_000, ctx: ctx))
            if i == paragraphs.count - 1, s.string.hasSuffix("\n") { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
            if let label = p.props.listLabel {
                number += 1
                let marker = label == "#" ? "\(number).\t" : "\(label)\t"
                let first = TextBridge.firstTextProps(p)
                var attrs = TextBridge.charAttributes(first, eastAsian: false)
                attrs[.hwListMarker] = label
                let current = (s.length > 0 ? s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)
                let ps = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                let indent = max(CGFloat(p.props.indentLeft), CGFloat(first.size) * 1.1)
                ps.headIndent = indent
                ps.firstLineHeadIndent = max(0, indent + CGFloat(min(0, p.props.firstLine == 0 ? -Double(indent) : p.props.firstLine)))
                ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                s.insert(NSAttributedString(string: marker, attributes: attrs), at: 0)
                s.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: s.length))
                s.addAttribute(.hwListLabel, value: label, range: NSRange(location: 0, length: s.length))
            } else {
                number = 0
            }
            out.append(s)
        }
        return out
    }

    static func paragraphs(_ text: NSAttributedString) -> [Paragraph] {
        let doc = UDocument()
        doc.source = .docx
        var out: [Paragraph] = []
        for b in TextBridge.blocks(from: text, doc: doc) {
            if case .paragraph(let p) = b { out.append(p) }
        }
        return out.isEmpty ? [Paragraph()] : out
    }
}

enum SlideRenderer {
    static func cg(_ f: Frame) -> CGRect { CGRect(x: f.x, y: f.y, width: f.w, height: f.h) }

    private static let imageCache = NSCache<NSString, UIImage>()

    static func image(_ id: String?, _ pres: Presentation) -> UIImage? {
        guard let id, let d = pres.images[id] else { return nil }
        let key = "\(id)#\(d.data.count)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(data: d.data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func point(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
    private static func polygon(_ points: [CGPoint]) -> UIBezierPath {
        let p = UIBezierPath()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        p.close()
        return p
    }

    static func path(_ kind: ShapeKind, in r: CGRect) -> UIBezierPath {
        switch kind {
        case .ellipse: return UIBezierPath(ovalIn: r)
        case .roundRect: return UIBezierPath(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.16)
        case .triangle: return polygon([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        case .rightArrow:
            let head = min(r.width * 0.4, r.height)
            return polygon([CGPoint(x: r.minX, y: r.minY + r.height * 0.25), CGPoint(x: r.maxX - head, y: r.minY + r.height * 0.25),
                            CGPoint(x: r.maxX - head, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX - head, y: r.maxY),
                            CGPoint(x: r.maxX - head, y: r.minY + r.height * 0.75), CGPoint(x: r.minX, y: r.minY + r.height * 0.75)])
        case .diamond, .pentagon, .hexagon, .octagon, .star5, .star6:
            let n = [ShapeKind.diamond: 4, .pentagon: 5, .hexagon: 6, .octagon: 8, .star5: 10, .star6: 12][kind]!
            let star = kind == .star5 || kind == .star6
            let pts = (0..<n).map { i -> CGPoint in
                let a = Double(i) * 2 * Double.pi / Double(n) - Double.pi / 2
                let k: CGFloat = star && i % 2 == 1 ? 0.43 : 1
                return CGPoint(x: r.midX + CGFloat(cos(a)) * r.width / 2 * k, y: r.midY + CGFloat(sin(a)) * r.height / 2 * k)
            }
            return polygon(pts)
        case .parallelogram: return polygon([point(r, 0.2, 0), point(r, 1, 0), point(r, 0.8, 1), point(r, 0, 1)])
        case .trapezoid: return polygon([point(r, 0.2, 0), point(r, 0.8, 0), point(r, 1, 1), point(r, 0, 1)])
        case .chevron: return polygon([point(r, 0, 0), point(r, 0.65, 0), point(r, 1, 0.5), point(r, 0.65, 1), point(r, 0, 1), point(r, 0.35, 0.5)])
        case .plus:
            return polygon([(0.35, 0.0), (0.65, 0), (0.65, 0.35), (1, 0.35), (1, 0.65), (0.65, 0.65), (0.65, 1), (0.35, 1), (0.35, 0.65), (0, 0.65), (0, 0.35), (0.35, 0.35)].map { point(r, $0.0, $0.1) })
        case .heart:
            let p = UIBezierPath()
            p.move(to: point(r, 0.5, 1))
            p.addCurve(to: point(r, 0.5, 0.18), controlPoint1: point(r, -0.5, 0.35), controlPoint2: point(r, 0.05, -0.35))
            p.addCurve(to: point(r, 0.5, 1), controlPoint1: point(r, 0.95, -0.35), controlPoint2: point(r, 1.5, 0.35))
            p.close()
            return p
        case .leftArrow, .upArrow, .downArrow:
            let vertical = kind == .upArrow || kind == .downArrow
            let box = CGRect(x: r.midX - (vertical ? r.height : r.width) / 2, y: r.midY - (vertical ? r.width : r.height) / 2,
                             width: vertical ? r.height : r.width, height: vertical ? r.width : r.height)
            let p = path(.rightArrow, in: box)
            let angle: CGFloat = kind == .leftArrow ? .pi : kind == .upArrow ? -.pi / 2 : .pi / 2
            p.apply(CGAffineTransform(translationX: -r.midX, y: -r.midY))
            p.apply(CGAffineTransform(rotationAngle: angle))
            p.apply(CGAffineTransform(translationX: r.midX, y: r.midY))
            return p
        case .leftRightArrow:
            return polygon([(0.0, 0.5), (0.25, 0), (0.25, 0.3), (0.75, 0.3), (0.75, 0), (1, 0.5), (0.75, 1), (0.75, 0.7), (0.25, 0.7), (0.25, 1)].map { point(r, $0.0, $0.1) })
        case .line:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            return p
        default: return UIBezierPath(rect: r)
        }
    }

    /// Draws a slide in slide coordinates into the current UIKit context.
    static func draw(_ slide: Slide, _ pres: Presentation, hideTextOf hidden: Int? = nil, skip: Set<Int> = []) {
        drawBackground(slide, pres)
        for s in slide.shapes where !skip.contains(s.id) { drawShape(s, pres, hideText: s.id == hidden && !s.locked) }
    }

    static func drawBackground(_ slide: Slide, _ pres: Presentation) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let bounds = CGRect(x: 0, y: 0, width: pres.width, height: pres.height)
        g.setFillColor((slide.background?.uiColor ?? .white).cgColor)
        g.fill(bounds)
        if let start = slide.background, let end = slide.backgroundEnd {
            let radians = slide.gradientAngle * .pi / 180
            let dx = CGFloat(cos(radians)), dy = CGFloat(sin(radians))
            let half = (abs(dx) * bounds.width + abs(dy) * bounds.height) / 2
            let from = CGPoint(x: bounds.midX - dx * half, y: bounds.midY - dy * half)
            let to = CGPoint(x: bounds.midX + dx * half, y: bounds.midY + dy * half)
            let colors = [start, slide.backgroundMiddle, end].compactMap { $0 }.map(\.cgColor) as CFArray
            let locations: [CGFloat] = slide.backgroundMiddle == nil ? [0, 1] : [0, CGFloat(slide.middleFraction), 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) {
                g.saveGState()
                g.clip(to: bounds)
                g.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                g.restoreGState()
            }
        }
        if let img = image(slide.backgroundImage, pres) { img.draw(in: bounds) }
    }

    static func drawShape(_ s: SlideShape, _ pres: Presentation, hideText: Bool = false) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let r = cg(s.frame)
        g.saveGState()
        if s.rotation != 0 {
            g.translateBy(x: r.midX, y: r.midY)
            g.rotate(by: CGFloat(s.rotation) * .pi / 180)
            g.translateBy(x: -r.midX, y: -r.midY)
        }
        g.saveGState()
        if s.flipH || s.flipV {
            g.translateBy(x: r.midX, y: r.midY)
            g.scaleBy(x: s.flipH ? -1 : 1, y: s.flipV ? -1 : 1)
            g.translateBy(x: -r.midX, y: -r.midY)
        }
        switch s.kind {
        case .image:
            if let img = image(s.imageID, pres) { img.draw(in: r) }
            else { g.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor); g.fill(r) }
            if s.videoID != nil { drawPlayBadge(in: r, g) }
        case .table:
            if let t = s.table { drawTable(t, s, in: r) }
        default:
            let p = path(s.kind, in: r)
            if let f = s.fill, s.kind != .line { f.uiColor.setFill(); p.fill() }
            if let l = s.line { l.uiColor.setStroke(); p.lineWidth = CGFloat(s.lineWidth); p.stroke() }
        }
        g.restoreGState()
        if !hideText && s.kind != .image && s.kind != .table && s.kind != .line && s.hasText {
            drawText(s.paragraphs, scale: s.autofitScale, in: textRect(s), anchor: s.anchor, wrap: s.wrap)
        }
        g.restoreGState()
    }

    private static func drawPlayBadge(in r: CGRect, _ g: CGContext) {
        let d = min(48, min(r.width, r.height) * 0.4)
        let c = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        g.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        g.fillEllipse(in: c)
        let tri = UIBezierPath()
        tri.move(to: CGPoint(x: c.minX + d * 0.38, y: c.minY + d * 0.28))
        tri.addLine(to: CGPoint(x: c.minX + d * 0.74, y: c.midY))
        tri.addLine(to: CGPoint(x: c.minX + d * 0.38, y: c.maxY - d * 0.28))
        tri.close()
        UIColor.white.setFill()
        tri.fill()
    }

    static func textRect(_ s: SlideShape) -> CGRect {
        let r = cg(s.frame)
        return CGRect(x: r.minX + CGFloat(s.insets.left), y: r.minY + CGFloat(s.insets.top),
                      width: max(4, r.width - CGFloat(s.insets.left + s.insets.right)), height: max(4, r.height - CGFloat(s.insets.top + s.insets.bottom)))
    }

    static func drawText(_ paragraphs: [Paragraph], scale: Double, in r: CGRect, anchor: CellVAlign, wrap: Bool) {
        let text = SlideText.attributed(paragraphs, scale: scale)
        let width = wrap ? r.width : 100_000
        let h = ceil(text.boundingRect(with: CGSize(width: width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        var y = r.minY
        switch anchor {
        case .center: y = r.midY - h / 2
        case .bottom: y = r.maxY - h
        case .top: break
        }
        text.draw(with: CGRect(x: r.minX, y: y, width: width, height: max(h, r.height)), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    static func drawTable(_ t: Table, _ s: SlideShape, in r: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let count = max(1, t.columnCount)
        let rawCols = t.columnWidths.count >= count ? Array(t.columnWidths.prefix(count)) : Array(repeating: Double(r.width) / Double(count), count: count)
        let rawHeights = t.rows.indices.map { $0 < s.tableRowHeights.count && s.tableRowHeights[$0] > 0 ? s.tableRowHeights[$0] : Double(r.height) / Double(max(1, t.rows.count)) }
        let cols = rawCols.map { $0 * Double(r.width) / max(1, rawCols.reduce(0, +)) }
        let heights = rawHeights.map { $0 * Double(r.height) / max(1, rawHeights.reduce(0, +)) }
        let grid = TableGrid(t)
        for (ri, row) in grid.slots.enumerated() {
            for (ci, slot) in row.enumerated() where ci < cols.count {
                guard case .origin(let cell) = slot else { continue }
                let x = r.minX + CGFloat(cols.prefix(ci).reduce(0, +))
                let y = r.minY + CGFloat(heights.prefix(ri).reduce(0, +))
                let w = CGFloat(cols[ci..<min(cols.count, ci + max(1, cell.colSpan))].reduce(0, +))
                let h = CGFloat(heights[ri..<min(heights.count, ri + max(1, cell.rowSpan))].reduce(0, +))
                let cr = CGRect(x: x, y: y, width: w, height: h)
                if let bg = cell.background { g.setFillColor(bg.cgColor); g.fill(cr) }
                g.setStrokeColor(UIColor.black.cgColor)
                g.setLineWidth(0.75)
                g.stroke(cr)
                let paras = cell.blocks.compactMap { b -> Paragraph? in if case .paragraph(let p) = b { return p }; return nil }
                drawText(paras, scale: 1, in: cr.insetBy(dx: 6, dy: 3), anchor: cell.verticalAlign, wrap: true)
            }
        }
    }

    static func thumbnail(_ slide: Slide, _ pres: Presentation, width: CGFloat) -> UIImage {
        let scale = width / CGFloat(pres.width)
        let size = CGSize(width: width, height: CGFloat(pres.height) * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.scaleBy(x: scale, y: scale)
            draw(slide, pres)
        }
    }

    /// One shape rendered alone into a transparent image the size of its bounds (slide show layers).
    static func shapeImage(_ s: SlideShape, _ pres: Presentation, scale: CGFloat) -> (UIImage, CGRect) {
        let b = ShapeGeometry.bounds(s)
        let pad: CGFloat = CGFloat(s.lineWidth) + 2
        let rect = CGRect(x: b.x, y: b.y, width: b.w, height: b.h).insetBy(dx: -pad, dy: -pad)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            drawShape(s, pres)
        }
        return (image, rect)
    }

    /// Vector PDF, one page per slide.
    static func pdf(_ pres: Presentation) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: pres.width, height: pres.height)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for slide in pres.slides {
                ctx.beginPage()
                ctx.cgContext.clip(to: bounds)
                draw(slide, pres)
            }
            if pres.slides.isEmpty { ctx.beginPage() }
        }
    }
}
