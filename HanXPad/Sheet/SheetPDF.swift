import UIKit

/// Vector PDF of every worksheet: used range and charts, split on cell
/// boundaries into A4 landscape pages (as the macOS app prints).
enum SheetPDF {
    static let page = CGSize(width: 842, height: 595)
    static let margin: CGFloat = 36
    static let maxPages = 1000

    static func pdf(_ book: Workbook, engine: FormulaEngine) -> Data {
        let content = CGSize(width: page.width - margin * 2, height: page.height - margin * 2)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page))
        var total = 0
        return renderer.pdfData { ctx in
            for ws in book.sheets {
                let grid = SheetGridView(sheet: ws, engine: engine)
                grid.frame = CGRect(origin: .zero, size: content)
                guard let full = grid.printExtent, full.width > 0, full.height > 0 else { continue }
                // Make sure the edges cover the whole extent (charts can lie beyond the used range).
                while (grid.rowEdgesList().last ?? 0) < full.maxY || (grid.columnEdges().last ?? 0) < full.maxX {
                    let before = (grid.rowEdgesList().count, grid.columnEdges().count)
                    grid.cursor = CellRef(row: grid.rowEdgesList().count + 50, col: grid.columnEdges().count + 20)
                    grid.reloadSize()
                    if before == (grid.rowEdgesList().count, grid.columnEdges().count) { break }
                }
                grid.cursor = CellRef(row: 0, col: 0)
                let rows = slices(from: full.minY, to: full.maxY, edges: grid.rowEdgesList(), length: content.height)
                let cols = slices(from: full.minX, to: full.maxX, edges: grid.columnEdges(), length: content.width)
                for (top, bottom) in rows {
                    for (left, right) in cols {
                        guard total < maxPages else { return }
                        total += 1
                        ctx.beginPage()
                        let g = ctx.cgContext
                        g.saveGState()
                        g.translateBy(x: margin, y: margin)
                        grid.drawForPrint(CGRect(x: left, y: top, width: right - left, height: bottom - top), in: g)
                        g.restoreGState()
                        let footer = "\(ws.name) — \(total)" as NSString
                        footer.draw(at: CGPoint(x: margin, y: page.height - margin + 10),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray])
                    }
                }
            }
            if total == 0 { ctx.beginPage() }
        }
    }

    /// Splits [start, end] into page-sized pieces that end on cell edges where possible.
    static func slices(from start: CGFloat, to end: CGFloat, edges: [CGFloat], length: CGFloat) -> [(CGFloat, CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        var a = start
        while a < end - 0.5, out.count < maxPages {
            var b: CGFloat
            if end - a <= length {
                b = end
            } else {
                // The last cell edge that still fits on this page.
                b = a
                for e in edges where e > a + 0.5 && e - a <= length { b = e }
                if b <= a + 0.5 { b = a + length }   // a single cell taller/wider than a page
            }
            out.append((a, b))
            a = b
        }
        return out
    }
}
