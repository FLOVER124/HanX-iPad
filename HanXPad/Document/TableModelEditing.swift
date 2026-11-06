import Foundation

/// Structural edits on a model table that keep spans and covered slots
/// consistent (rows hold one slot per grid column).
enum TableModelEditing {
    struct Origin: Equatable { var row: Int; var col: Int }

    static func normalized(_ t: Table) -> Table {
        var t = t
        let cols = max(1, t.columnCount)
        for r in t.rows.indices where t.rows[r].count < cols {
            t.rows[r] += (t.rows[r].count..<cols).map { _ in blank(like: nil) }
        }
        if t.columnWidths.count < cols {
            let avg = t.columnWidths.isEmpty ? 80 : t.columnWidths.reduce(0, +) / Double(t.columnWidths.count)
            t.columnWidths += Array(repeating: avg, count: cols - t.columnWidths.count)
        }
        return t
    }

    /// owner[r][c] = origin slot of the cell covering (r, c).
    static func owners(_ t: Table) -> [[Origin?]] {
        let cols = t.columnCount, rows = t.rows.count
        var owner = [[Origin?]](repeating: [Origin?](repeating: nil, count: cols), count: rows)
        for (r, row) in t.rows.enumerated() {
            for (c, cell) in row.enumerated() where !cell.isMergedAway && c < cols {
                for rr in r..<min(rows, r + max(1, cell.rowSpan)) {
                    for cc in c..<min(cols, c + max(1, cell.colSpan)) where owner[rr][cc] == nil { owner[rr][cc] = Origin(row: r, col: c) }
                }
            }
        }
        for r in 0..<rows { for c in 0..<cols where owner[r][c] == nil { owner[r][c] = Origin(row: r, col: c) } }
        return owner
    }

    static func blank(like cell: TableCell?) -> TableCell {
        var p = Paragraph()
        if let cell, case .paragraph(let first)? = cell.blocks.first {
            p.markProps = first.markProps
            p.props = first.props
            p.props.pageBreakBefore = false
        }
        var c = TableCell(blocks: [.paragraph(p)])
        if let cell {
            c.padding = cell.padding
            c.borders = cell.borders
            c.verticalAlign = cell.verticalAlign
        }
        return c
    }

    static func insertRow(_ t: Table, at index: Int) -> Table {
        var t = normalized(t)
        let i = max(0, min(index, t.rows.count))
        let owner = owners(t)
        let cols = t.columnCount
        var row: [TableCell] = []
        var c = 0
        while c < cols {
            if i > 0, i < t.rows.count, let o = owner[i][c], o.row < i {
                // A cell spanning across the new row grows by one.
                let origin = t.rows[o.row][o.col]
                if o.col == c { t.rows[o.row][o.col].rowSpan = origin.rowSpan + 1 }
                var covered = TableCell(); covered.isMergedAway = true
                row.append(covered)
                c += 1
                continue
            }
            let source = i > 0 ? t.rows[i - 1][min(c, t.rows[i - 1].count - 1)] : (t.rows.isEmpty ? nil : t.rows[0][min(c, t.rows[0].count - 1)])
            row.append(blank(like: source))
            c += 1
        }
        t.rows.insert(row, at: i)
        return t
    }

    static func deleteRow(_ t: Table, at i: Int) -> Table {
        var t = normalized(t)
        guard t.rows.count > 1, t.rows.indices.contains(i) else { return t }
        let owner = owners(t)
        for c in 0..<t.columnCount {
            guard let o = owner[i][c] else { continue }
            let cell = t.rows[o.row][o.col]
            if o.row == i && o.col == c {
                if cell.rowSpan > 1, i + 1 < t.rows.count {
                    var moved = cell; moved.rowSpan -= 1; moved.isMergedAway = false
                    t.rows[i + 1][c] = moved
                }
            } else if o.row < i && o.col == c {
                t.rows[o.row][o.col].rowSpan = max(1, cell.rowSpan - 1)
            }
        }
        t.rows.remove(at: i)
        return t
    }

    static func insertColumn(_ t: Table, at index: Int) -> Table {
        var t = normalized(t)
        let j = max(0, min(index, t.columnCount))
        let owner = owners(t)
        for r in t.rows.indices {
            if j > 0, j < t.columnCount, let o = owner[r][j], o.col < j {
                if o.row == r { t.rows[o.row][o.col].colSpan += 1 }
                var covered = TableCell(); covered.isMergedAway = true
                t.rows[r].insert(covered, at: j)
            } else {
                let source = t.rows[r][max(0, min(j - 1, t.rows[r].count - 1))]
                t.rows[r].insert(blank(like: source), at: j)
            }
        }
        let width = t.columnWidths.isEmpty ? 80 : t.columnWidths[max(0, min(j - 1, t.columnWidths.count - 1))]
        t.columnWidths.insert(width, at: min(j, t.columnWidths.count))
        return t
    }

    static func deleteColumn(_ t: Table, at j: Int) -> Table {
        var t = normalized(t)
        guard t.columnCount > 1, j >= 0, j < t.columnCount else { return t }
        let owner = owners(t)
        for r in t.rows.indices {
            guard let o = owner[r][j] else { continue }
            let cell = t.rows[o.row][o.col]
            if o.row == r && o.col == j {
                if cell.colSpan > 1, j + 1 < t.rows[r].count {
                    var moved = cell; moved.colSpan -= 1; moved.isMergedAway = false
                    t.rows[r][j + 1] = moved
                }
            } else if o.col < j && o.row == r {
                t.rows[o.row][o.col].colSpan = max(1, cell.colSpan - 1)
            }
        }
        for r in t.rows.indices where j < t.rows[r].count { t.rows[r].remove(at: j) }
        if j < t.columnWidths.count { t.columnWidths.remove(at: j) }
        return t
    }

    /// Merges the cell at (r, c) with its right (or lower) neighbour when both
    /// have the same extent along the other axis.
    static func merge(_ t: Table, row r: Int, col c: Int, down: Bool) -> Table? {
        var t = normalized(t)
        let owner = owners(t)
        guard t.rows.indices.contains(r), c < t.columnCount, let o = owner[r][c] else { return nil }
        let cell = t.rows[o.row][o.col]
        let nr = down ? o.row + cell.rowSpan : o.row
        let nc = down ? o.col : o.col + cell.colSpan
        guard t.rows.indices.contains(nr), nc < t.columnCount, let n = owner[nr][nc], n.row == nr, n.col == nc else { return nil }
        let neighbour = t.rows[nr][nc]
        if down { guard neighbour.colSpan == cell.colSpan else { return nil } } else { guard neighbour.rowSpan == cell.rowSpan else { return nil } }
        var merged = cell
        let neighbourText = neighbour.blocks.contains { b in if case .paragraph(let p) = b { return !p.plainText.isEmpty }; return true }
        if neighbourText { merged.blocks += neighbour.blocks }
        if down { merged.rowSpan += neighbour.rowSpan } else { merged.colSpan += neighbour.colSpan }
        merged.height = nil
        t.rows[o.row][o.col] = merged
        var covered = TableCell(); covered.isMergedAway = true
        t.rows[nr][nc] = covered
        return t
    }

    static func split(_ t: Table, row r: Int, col c: Int) -> Table {
        var t = normalized(t)
        let owner = owners(t)
        guard t.rows.indices.contains(r), c < t.columnCount, let o = owner[r][c] else { return t }
        let cell = t.rows[o.row][o.col]
        for rr in o.row..<min(t.rows.count, o.row + cell.rowSpan) {
            for cc in o.col..<min(t.columnCount, o.col + cell.colSpan) where !(rr == o.row && cc == o.col) {
                t.rows[rr][cc] = blank(like: cell)
            }
        }
        t.rows[o.row][o.col].rowSpan = 1
        t.rows[o.row][o.col].colSpan = 1
        return t
    }
}
