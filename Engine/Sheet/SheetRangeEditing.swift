import Foundation

/// Shared, bounded data operations. Validate before modifying any cell.
enum SheetRangeEditing {
    struct EditError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    enum Direction: String { case down, right }

    private static func overlaps(_ a: CellRange, _ b: CellRange) -> Bool {
        a.start.row <= b.end.row && a.end.row >= b.start.row && a.start.col <= b.end.col && a.end.col >= b.start.col
    }
    private static func validate(_ sheet: Worksheet, _ range: CellRange, _ engine: FormulaEngine) throws {
        guard range.start.row >= 0, range.start.col >= 0, range.end.row < 1_048_576, range.end.col < 16_384,
              range.end.row - range.start.row < 100_000,
              (range.end.row - range.start.row + 1) * (range.end.col - range.start.col + 1) <= 100_000 else {
            throw EditError(message: "100,000셀 이하의 범위를 선택하세요.")
        }
        guard !sheet.merges.contains(where: { overlaps($0, range) }) else {
            throw EditError(message: "선택 범위와 겹치는 병합 셀이 있습니다. 병합을 해제한 뒤 다시 시도하세요.")
        }
        // Inspect raw results as well as successful spills: blocked arrays must
        // not silently become unblocked when an obstruction is moved or cleared.
        for (ref, cell) in sheet.cells where cell.isFormula && !sheet.legacyFormulas.contains(ref) {
            let value = engine.evaluateFormula(String(cell.input.dropFirst()), sheet: sheet, cell: ref)
            if case .array(let matrix) = value, matrix.rows > 0, matrix.cols > 0, matrix.rows > 1 || matrix.cols > 1 {
                let spill = CellRange(ref, CellRef(row: ref.row + matrix.rows - 1, col: ref.col + matrix.cols - 1))
                if overlaps(spill, range) { throw EditError(message: "배열 수식이 결과를 표시하는 범위와 겹칩니다. 다른 범위를 선택하세요.") }
            }
        }
    }
    private static func translated(_ cell: SheetCell?, from: CellRef, to: CellRef) -> SheetCell? {
        guard var cell else { return nil }
        if cell.isFormula {
            cell.input = "=" + XLSXReader.translate(String(cell.input.dropFirst()), rows: to.row - from.row, cols: to.col - from.col)
        }
        return cell.input.isEmpty && cell.style == CellStyle() ? nil : cell
    }
    private static func put(_ cell: SheetCell?, legacy: Bool, at ref: CellRef, in sheet: Worksheet) {
        sheet.cells[ref] = cell
        sheet.cachedValues[ref] = nil
        if legacy, cell?.isFormula == true { sheet.legacyFormulas.insert(ref) }
        else { sheet.legacyFormulas.remove(ref) }
    }
    static func sort(book: Workbook, sheet: Worksheet, range: CellRange, keyColumn: Int, ascending: Bool, header: Bool) throws {
        guard (range.start.col...range.end.col).contains(keyColumn) else { throw EditError(message: "정렬 기준 열은 선택 범위 안에 있어야 합니다.") }
        let engine = FormulaEngine(book: book, allowExternalIO: false)
        try validate(sheet, range, engine)
        let start = range.start.row + (header ? 1 : 0)
        guard start < range.end.row else { return }
        let rows = Array(start...range.end.row)
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0, engine.value(sheet, CellRef(row: $0, col: keyColumn))) })
        let sorted = rows.sorted { a, b in
            let x = values[a]!, y = values[b]!
            if case .empty = x { if case .empty = y { return a < b }; return false }
            if case .empty = y { return true }
            let order = ArrayFunctions.sortCompare(x, y)
            return order == 0 ? a < b : (ascending ? order < 0 : order > 0)
        }
        let original = sheet.cells
        let legacy = sheet.legacyFormulas
        for (offset, sourceRow) in sorted.enumerated() {
            for column in range.start.col...range.end.col {
                let source = CellRef(row: sourceRow, col: column), target = CellRef(row: start + offset, col: column)
                put(translated(original[source], from: source, to: target), legacy: legacy.contains(source), at: target, in: sheet)
            }
        }
    }
    static func fill(book: Workbook, sheet: Worksheet, range: CellRange, direction: Direction) throws {
        try validate(sheet, range, FormulaEngine(book: book, allowExternalIO: false))
        let original = sheet.cells
        let legacy = sheet.legacyFormulas
        for target in range.cells {
            let source = direction == .down ? CellRef(row: range.start.row, col: target.col) : CellRef(row: target.row, col: range.start.col)
            guard target != source else { continue }
            put(translated(original[source], from: source, to: target), legacy: legacy.contains(source), at: target, in: sheet)
        }
    }
}
