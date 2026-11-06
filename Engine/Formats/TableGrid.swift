import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves which grid slot belongs to which origin cell. The model keeps a
/// full rows×cols grid with covered slots flagged; writers need to know
/// whether a covered slot is a horizontal or vertical continuation.
struct TableGrid {
    enum Slot {
        case origin(TableCell)
        case vertical(owner: TableCell)     // continuation from a row above, same column start
        case covered                         // horizontal continuation; emit nothing
    }

    let slots: [[Slot]]
    let cols: Int

    init(_ t: Table) {
        cols = t.columnCount
        let nrows = t.rows.count
        var owner = [[(Int, Int)?]](repeating: [(Int, Int)?](repeating: nil, count: cols), count: nrows)
        for (r, row) in t.rows.enumerated() {
            for (c, cell) in row.enumerated() where !cell.isMergedAway && c < cols {
                for rr in r..<min(nrows, r + cell.rowSpan) {
                    for cc in c..<min(cols, c + cell.colSpan) where owner[rr][cc] == nil { owner[rr][cc] = (r, c) }
                }
            }
        }
        var out: [[Slot]] = []
        for r in 0..<nrows {
            var row: [Slot] = []
            for c in 0..<cols {
                let cell = c < t.rows[r].count ? t.rows[r][c] : TableCell(blocks: [.paragraph(Paragraph())])
                guard let o = owner[r][c] else {
                    var filler = cell
                    filler.isMergedAway = false
                    if filler.blocks.isEmpty { filler.blocks = [.paragraph(Paragraph())] }
                    row.append(.origin(filler)); continue
                }
                if o == (r, c) { row.append(.origin(cell)) }
                else if o.1 == c { row.append(.vertical(owner: t.rows[o.0][o.1])) }
                else { row.append(.covered) }
            }
            out.append(row)
        }
        slots = out
    }

    /// Horizontal span of the cell at a slot (origin or vertical continuation).
    func span(_ slot: Slot) -> Int {
        switch slot {
        case .origin(let c): return max(1, c.colSpan)
        case .vertical(let o): return max(1, o.colSpan)
        case .covered: return 0
        }
    }
}
