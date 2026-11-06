import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Spreadsheet model ("도표"). Cells keep what the user typed (`input`);
/// formulas start with "=" and are evaluated by `FormulaEngine` on demand.

struct CellRef: Hashable, Comparable {
    var row: Int     // 0-based
    var col: Int     // 0-based

    static func < (a: CellRef, b: CellRef) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }

    static func columnName(_ c: Int) -> String {
        var n = c + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    static func columnIndex(_ letters: String) -> Int? {
        var n = 0
        for ch in letters.uppercased().unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { return nil }
            let (product, multiplyOverflow) = n.multipliedReportingOverflow(by: 26)
            let (next, addOverflow) = product.addingReportingOverflow(Int(ch.value - 64))
            guard !multiplyOverflow, !addOverflow else { return nil }
            n = next
        }
        return n > 0 ? n - 1 : nil
    }

    var a1: String { CellRef.columnName(col) + String(row + 1) }

    /// Parses "B12" / "$B$12".
    init?(a1: String) {
        let s = a1.replacingOccurrences(of: "$", with: "")
        let letters = s.prefix { $0.isLetter }
        let digits = s.dropFirst(letters.count)
        guard !letters.isEmpty, let r = Int(digits), r >= 1, let c = CellRef.columnIndex(String(letters)) else { return nil }
        row = r - 1; col = c
    }

    init(row: Int, col: Int) { self.row = row; self.col = col }
}

struct CellRange: Hashable {
    var start: CellRef
    var end: CellRef

    init(_ a: CellRef, _ b: CellRef) {
        start = CellRef(row: min(a.row, b.row), col: min(a.col, b.col))
        end = CellRef(row: max(a.row, b.row), col: max(a.col, b.col))
    }

    func contains(_ r: CellRef) -> Bool { r.row >= start.row && r.row <= end.row && r.col >= start.col && r.col <= end.col }
    var a1: String { start == end ? start.a1 : start.a1 + ":" + end.a1 }
    var cells: [CellRef] {
        (start.row...end.row).flatMap { r in (start.col...end.col).map { CellRef(row: r, col: $0) } }
    }
}

enum HAlign: String { case general, left, center, right }

struct CellStyle: Equatable, Hashable {
    var bold = false
    var italic = false
    var underline = false
    var fontName: String?
    var fontSize: Double?
    var color: RGB?
    var fill: RGB?
    var align: HAlign = .general
    var wrap = false
    /// Excel number format code ("0.00", "#,##0", "0%", "yyyy-mm-dd" …).
    var numberFormat: String?
    var border = false
}

struct SheetCell: Equatable {
    var input: String = ""
    var style = CellStyle()
    var isFormula: Bool { input.hasPrefix("=") && input.count > 1 }
}

enum ChartKind: String, CaseIterable {
    case column, bar, line, area, pie
    var title: String { [.column: "세로 막대형", .bar: "가로 막대형", .line: "꺾은선형", .area: "영역형", .pie: "원형"][self]! }
}

/// A chart floating over the grid. `data` is a block whose first row may
/// hold series names and first column category labels (Excel's convention).
struct SheetChart: Equatable {
    var kind: ChartKind = .column
    var title = ""
    var data: CellRange
    /// Position in points from the top-left of cell A1.
    var x: Double, y: Double, w: Double = 420, h: Double = 260
}

/// Series extracted from a chart's data range.
struct ChartSeries { var name: String; var values: [Double] }

extension SheetChart {
    func resolve(_ ws: Worksheet, _ engine: FormulaEngine) -> (categories: [String], series: [ChartSeries]) {
        let r = data
        func v(_ row: Int, _ col: Int) -> SheetValue { engine.value(ws, CellRef(row: row, col: col)) }
        func isText(_ x: SheetValue) -> Bool { if case .string = x { return true }; return false }
        let headerRow = r.end.row > r.start.row && (r.start.col...r.end.col).contains { isText(v(r.start.row, $0)) }
        let labelCol = r.end.col > r.start.col && ((headerRow ? r.start.row + 1 : r.start.row)...r.end.row).contains { isText(v($0, r.start.col)) }
        let firstDataRow = headerRow ? r.start.row + 1 : r.start.row
        let firstDataCol = labelCol ? r.start.col + 1 : r.start.col
        guard firstDataRow <= r.end.row, firstDataCol <= r.end.col else { return ([], []) }
        let categories = (firstDataRow...r.end.row).map { labelCol ? engine.display(ws, CellRef(row: $0, col: r.start.col)) : String($0 - firstDataRow + 1) }
        let series = (firstDataCol...r.end.col).map { c in
            ChartSeries(name: headerRow ? engine.display(ws, CellRef(row: r.start.row, col: c)) : "계열 \(c - firstDataCol + 1)",
                        values: (firstDataRow...r.end.row).map { v($0, c).number ?? 0 })
        }
        return (categories, series)
    }
}

final class Worksheet {
    var name: String
    var charts: [SheetChart] = []
    var cells: [CellRef: SheetCell] = [:]
    var columnWidths: [Int: Double] = [:]    // points
    var rowHeights: [Int: Double] = [:]
    var merges: [CellRange] = []
    var frozenRows = 0, frozenCols = 0
    /// Formulas loaded from pre-dynamic-array files: their array results are
    /// reduced by implicit intersection (Excel shows them with '@').
    var legacyFormulas: Set<CellRef> = []
    /// Values Excel cached for formula cells in the loaded file (type, text).
    var cachedValues: [CellRef: (String, String)] = [:]

    static let defaultColumnWidth: Double = 64
    static let defaultRowHeight: Double = 20

    init(name: String) { self.name = name }

    func width(_ c: Int) -> Double { columnWidths[c] ?? Worksheet.defaultColumnWidth }
    func height(_ r: Int) -> Double { rowHeights[r] ?? Worksheet.defaultRowHeight }

    var usedRange: CellRange? {
        let keys = cells.filter { !$0.value.input.isEmpty || $0.value.style != CellStyle() }.keys
        guard let first = keys.first else { return nil }
        var lo = first, hi = first
        for k in keys {
            lo = CellRef(row: min(lo.row, k.row), col: min(lo.col, k.col))
            hi = CellRef(row: max(hi.row, k.row), col: max(hi.col, k.col))
        }
        return CellRange(lo, hi)
    }

    func set(_ ref: CellRef, input: String) {
        var c = cells[ref] ?? SheetCell()
        c.input = input
        legacyFormulas.remove(ref)
        if c.input.isEmpty && c.style == CellStyle() { cells[ref] = nil } else { cells[ref] = c }
    }

    func merge(containing r: CellRef) -> CellRange? { merges.first { $0.contains(r) } }

    /// Inserts or deletes rows/columns, shifting cell contents (formulas are
    /// rewritten by the caller via FormulaEngine.shift).
    func shift(rows at: Int? = nil, cols atCol: Int? = nil, by n: Int) {
        var moved: [CellRef: SheetCell] = [:]
        for (k, v) in cells {
            var k2 = k
            if let at, k.row >= at { k2.row += n; if n < 0 && k.row < at - n { continue } }
            if let atCol, k.col >= atCol { k2.col += n; if n < 0 && k.col < atCol - n { continue } }
            if k2.row >= 0 && k2.col >= 0 { moved[k2] = v }
        }
        cells = moved
    }
}

final class Workbook {
    var sheets: [Worksheet] = [Worksheet(name: "Sheet1")]
    var source = "xlsx"
    /// Workbook-level defined names (upper-cased) → formula text without "=".
    var definedNames: [String: String] = [:]

    func sheet(named n: String) -> Worksheet? {
        sheets.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }
}
