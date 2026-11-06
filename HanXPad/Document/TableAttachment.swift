import UIKit

/// Holds a document table as one inline object. The exact model table is kept
/// (spans, borders, padding, fixed heights) and redrawn whenever it changes;
/// the table editor sheet edits it. Encoded through NSSecureCoding so copy &
/// paste inside HanX keeps the table.
final class TableAttachment: NSTextAttachment {
    var table: Table { didSet { refresh() } }
    var images: [String: ImageData]
    var source: SourceFormat
    var maxWidth: CGFloat { didSet { if oldValue != maxWidth { refresh() } } }
    private(set) var layout = TableRenderer.Layout(cols: [], rows: [], size: CGSize(width: 1, height: 1))

    /// While exporting PDF the table is drawn as vectors; the raster stays clear.
    static var exportMode = false

    init(table: Table, images: [String: ImageData], source: SourceFormat, maxWidth: CGFloat) {
        self.table = table
        self.images = images
        self.source = source
        self.maxWidth = maxWidth
        super.init(data: nil, ofType: nil)
        refresh()
    }

    required init?(coder: NSCoder) {
        if let data = coder.decodeObject(of: NSData.self, forKey: "hanxTable") as Data?,
           let decoded = try? JSONDecoder().decode(StoredTable.self, from: data) {
            table = decoded.table
            images = decoded.images
            source = SourceFormat(rawValue: decoded.source) ?? .docx
            maxWidth = CGFloat(decoded.maxWidth)
        } else {
            table = Table()
            images = [:]
            source = .docx
            maxWidth = 400
        }
        super.init(coder: coder)
        refresh()
    }

    override class var supportsSecureCoding: Bool { true }

    private struct StoredTable: Codable {
        var table: Table
        var images: [String: ImageData]
        var source: String
        var maxWidth: Double
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        let stored = StoredTable(table: table, images: images, source: source.rawValue, maxWidth: Double(maxWidth))
        if let data = try? JSONEncoder().encode(stored) { coder.encode(data as NSData, forKey: "hanxTable") }
    }

    var context: TextBridge.Context { TextBridge.Context(images: images, source: source) }

    func refresh() {
        layout = TableRenderer.layout(table, maxWidth: maxWidth, ctx: context)
        bounds = CGRect(origin: .zero, size: layout.size)
        image = TableRenderer.image(table, layout: layout, ctx: context)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        if TableAttachment.exportMode {
            return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        }
        return image
    }
}

/// Lays out and draws a model table (used by the document editor, PDF export
/// and the slide renderer for document-style tables).
enum TableRenderer {
    struct Layout {
        var cols: [CGFloat]
        var rows: [CGFloat]
        var size: CGSize
    }

    private static func cellText(_ cell: TableCell, width: CGFloat, ctx: TextBridge.Context) -> NSAttributedString {
        var blocks = cell.blocks
        if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
        let s = TextBridge.build(blocks, width: Double(max(4, width)), ctx: ctx)
        if s.length > 0, (s.string as NSString).character(at: s.length - 1) == 10 { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
        // Page breaks have no meaning inside a cell.
        s.mutableString.replaceOccurrences(of: "\u{0C}", with: "", options: [], range: NSRange(location: 0, length: s.length))
        return s
    }

    static func padding(_ cell: TableCell, ctx: TextBridge.Context) -> Insets {
        cell.padding ?? (ctx.source == .docx ? .wordDefault : .hwpDefault)
    }

    static func measure(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        if s.length == 0 { return 14 }
        let r = s.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(r.height)
    }

    static func layout(_ t: Table, maxWidth: CGFloat, ctx: TextBridge.Context) -> Layout {
        let grid = TableGrid(t)
        let cols = max(1, grid.cols)
        var widths = (0..<cols).map { CGFloat($0 < t.columnWidths.count ? max(4, t.columnWidths[$0]) : 60) }
        let total = widths.reduce(0, +)
        if maxWidth > 0, total > maxWidth { widths = widths.map { $0 * maxWidth / total } }
        var heights = [CGFloat](repeating: 16, count: grid.slots.count)
        var spanning: [(row: Int, span: Int, need: CGFloat)] = []
        for (r, row) in grid.slots.enumerated() {
            for (c, slot) in row.enumerated() {
                guard case .origin(let cell) = slot else { continue }
                let cs = max(1, min(cell.colSpan, cols - c)), rs = max(1, min(cell.rowSpan, grid.slots.count - r))
                let w = widths[c..<(c + cs)].reduce(0, +)
                let pad = padding(cell, ctx: ctx)
                let content = measure(cellText(cell, width: w - CGFloat(pad.left + pad.right), ctx: ctx), width: w - CGFloat(pad.left + pad.right))
                let need = max(CGFloat(cell.height ?? 0), content + CGFloat(pad.top + pad.bottom) + 1)
                if rs == 1 { heights[r] = max(heights[r], need) } else { spanning.append((r, rs, need)) }
            }
        }
        for s in spanning {
            let have = heights[s.row..<(s.row + s.span)].reduce(0, +)
            if have < s.need { heights[s.row + s.span - 1] += s.need - have }
        }
        return Layout(cols: widths, rows: heights, size: CGSize(width: max(1, widths.reduce(0, +)), height: max(1, heights.reduce(0, +))))
    }

    static func image(_ t: Table, layout: Layout, ctx: TextBridge.Context) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: layout.size, format: format).image { _ in
            draw(t, layout: layout, at: .zero, ctx: ctx)
        }
    }

    /// Draws into the current UIKit context with the table's top-left at `origin`.
    static func draw(_ t: Table, layout: Layout, at origin: CGPoint, ctx: TextBridge.Context) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let grid = TableGrid(t)
        let rows = grid.slots.count, cols = layout.cols.count
        func x(_ c: Int) -> CGFloat { origin.x + layout.cols.prefix(c).reduce(0, +) }
        func y(_ r: Int) -> CGFloat { origin.y + layout.rows.prefix(r).reduce(0, +) }
        // Collapse shared edges: the heavier of two neighbouring lines wins.
        var owner = [[TableCell?]](repeating: [TableCell?](repeating: nil, count: cols), count: rows)
        for (r, row) in grid.slots.enumerated() {
            for (c, slot) in row.enumerated() where c < cols {
                guard case .origin(let cell) = slot else { continue }
                for rr in r..<min(rows, r + max(1, cell.rowSpan)) { for cc in c..<min(cols, c + max(1, cell.colSpan)) { owner[rr][cc] = cell } }
            }
        }
        func heavier(_ a: BorderLine, _ b: BorderLine?) -> BorderLine {
            guard let b, b.visible else { return a }
            return !a.visible || b.width > a.width ? b : a
        }
        for (r, row) in grid.slots.enumerated() {
            for (c, slot) in row.enumerated() where c < cols {
                guard case .origin(let cell) = slot else { continue }
                let rs = max(1, min(cell.rowSpan, rows - r)), cs = max(1, min(cell.colSpan, cols - c))
                let rect = CGRect(x: x(c), y: y(r), width: x(c + cs) - x(c), height: y(r + rs) - y(r))
                if let bg = cell.background { g.setFillColor(bg.cgColor); g.fill(rect) }
                let pad = padding(cell, ctx: ctx)
                let inner = rect.inset(by: UIEdgeInsets(top: CGFloat(pad.top), left: CGFloat(pad.left), bottom: CGFloat(pad.bottom), right: CGFloat(pad.right)))
                let text = cellText(cell, width: inner.width, ctx: ctx)
                let h = measure(text, width: inner.width)
                var ty = inner.minY
                switch cell.verticalAlign {
                case .center: ty = inner.midY - h / 2
                case .bottom: ty = inner.maxY - h
                case .top: break
                }
                text.draw(with: CGRect(x: inner.minX, y: ty, width: max(1, inner.width), height: max(h, inner.height)),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                var b = cell.borders
                if r > 0 { b.top = heavier(b.top, owner[r - 1][c]?.borders.bottom) }
                if c > 0 { b.left = heavier(b.left, owner[r][c - 1]?.borders.right) }
                if r + rs < rows { b.bottom = .none }
                if c + cs < cols { b.right = .none }
                stroke(b.top, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), in: g)
                stroke(b.left, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX, y: rect.maxY), in: g)
                stroke(b.bottom, from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.maxY), in: g)
                stroke(b.right, from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), in: g)
            }
        }
    }

    private static func stroke(_ line: BorderLine, from a: CGPoint, to b: CGPoint, in g: CGContext) {
        guard line.visible else { return }
        g.saveGState()
        g.setStrokeColor(line.color.cgColor)
        let w = CGFloat(max(0.25, line.width))
        g.setLineWidth(w)
        switch line.style {
        case .dotted: g.setLineDash(phase: 0, lengths: [w, w * 2])
        case .dashed: g.setLineDash(phase: 0, lengths: [w * 4, w * 2])
        default: break
        }
        if line.style == .double {
            let vertical = a.x == b.x
            for offset in [-w, w] {
                g.move(to: CGPoint(x: a.x + (vertical ? offset : 0), y: a.y + (vertical ? 0 : offset)))
                g.addLine(to: CGPoint(x: b.x + (vertical ? offset : 0), y: b.y + (vertical ? 0 : offset)))
            }
            g.setLineWidth(max(0.25, w / 2))
        } else {
            g.move(to: a); g.addLine(to: b)
        }
        g.strokePath()
        g.restoreGState()
    }
}
