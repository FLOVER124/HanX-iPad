import Foundation

/// Stage every worksheet and defined name before committing any changes.
enum SheetStructuralEditing {
    enum Axis { case row, column }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    struct Snapshot {
        private let restoreSheets: [() -> Void]
        private let restoreNames: () -> Void

        init(_ book: Workbook) {
            let names = book.definedNames
            restoreNames = { book.definedNames = names }
            restoreSheets = book.sheets.map { sheet in
                let cells = sheet.cells, legacy = sheet.legacyFormulas, cached = sheet.cachedValues
                let widths = sheet.columnWidths, heights = sheet.rowHeights, merges = sheet.merges
                let rows = sheet.frozenRows, cols = sheet.frozenCols, charts = sheet.charts
                return {
                    sheet.cells = cells; sheet.legacyFormulas = legacy; sheet.cachedValues = cached
                    sheet.columnWidths = widths; sheet.rowHeights = heights; sheet.merges = merges
                    sheet.frozenRows = rows; sheet.frozenCols = cols; sheet.charts = charts
                }
            }
        }

        func restore() { restoreSheets.forEach { $0() }; restoreNames() }
    }

    static func apply(book: Workbook, sheet: Worksheet, cell: CellRef, axis: Axis, inserting: Bool) throws {
        let edit = Edit(target: sheet.name, axis: axis, at: axis == .row ? cell.row : cell.col, inserting: inserting)
        guard book.sheets.contains(where: { $0 === sheet }), (0..<edit.limit).contains(edit.at) else {
            throw Failure("The selection is outside the worksheet.")
        }
        let engine = FormulaEngine(book: book, allowExternalIO: false)
        for (ref, value) in sheet.cells where value.isFormula && !sheet.legacyFormulas.contains(ref) {
            let start = axis == .row ? ref.row : ref.col
            guard start <= edit.at else { continue }
            if case .array(let matrix) = engine.evaluateFormula(String(value.input.dropFirst()), sheet: sheet, cell: ref) {
                let extent = axis == .row ? matrix.rows : matrix.cols
                if extent > 1 && edit.at - start < extent && (edit.at > start || !inserting) {
                    throw Failure("The selection intersects a spilled formula result.")
                }
            }
        }
        var commits: [() -> Void] = []
        for ws in book.sheets {
            let moving = ws === sheet
            var cells: [CellRef: SheetCell] = [:]
            for (ref, source) in ws.cells {
                let destination: CellRef? = moving ? try edit.move(ref) : ref
                guard let destination else { continue }
                var value = source
                if value.isFormula {
                    value.input = "=" + (try edit.rewrite(String(value.input.dropFirst()), owner: ws.name))
                }
                cells[destination] = value
            }
            commits.append {
                ws.cells = cells
                // A dependent formula can change even when its own text did not.
                ws.cachedValues.removeAll()
            }
        }
        let legacy = Set(try sheet.legacyFormulas.compactMap(edit.move))
        let merges = try sheet.merges.compactMap(edit.range).filter { $0.start != $0.end }
        let charts = try sheet.charts.map { chart in
            guard let source = try edit.range(chart.data) else {
                throw Failure("Remove the chart before deleting its entire data range.")
            }
            var updated = chart
            updated.data = source
            return updated
        }
        let dimensions = try edit.dimensions(axis == .row ? sheet.rowHeights : sheet.columnWidths)
        let frozen = try edit.frozen(axis == .row ? sheet.frozenRows : sheet.frozenCols)
        let names = try book.definedNames.mapValues { try edit.rewrite($0, owner: nil) }

        commits.forEach { $0() }
        sheet.legacyFormulas = legacy
        sheet.merges = merges
        sheet.charts = charts
        if axis == .row {
            sheet.rowHeights = dimensions
            sheet.frozenRows = frozen
        } else {
            sheet.columnWidths = dimensions
            sheet.frozenCols = frozen
        }
        book.definedNames = names
    }

    private struct Edit {
        let target: String
        let axis: Axis
        let at: Int
        let inserting: Bool
        var limit: Int { axis == .row ? 1_048_576 : 16_384 }

        func index(_ n: Int) throws -> Int? {
            guard (0..<limit).contains(n), !(inserting && n >= at && n == limit - 1) else {
                throw Failure("This edit would move data or a reference beyond the worksheet boundary.")
            }
            if n < at { return n }
            if !inserting && n == at { return nil }
            return n + (inserting ? 1 : -1)
        }

        func frozen(_ count: Int) throws -> Int {
            guard count > at else { return count }
            let moved = (try index(count - 1)).map { $0 + 1 } ?? at
            guard moved < limit else { throw Failure("The frozen pane would exceed the worksheet boundary.") }
            return moved
        }

        func dimensions(_ values: [Int: Double]) throws -> [Int: Double] {
            var result: [Int: Double] = [:]
            for (key, value) in values {
                if let destination = try index(key) { result[destination] = value }
            }
            return result
        }

        func move(_ ref: CellRef) throws -> CellRef? {
            guard let n = try index(axis == .row ? ref.row : ref.col) else { return nil }
            return axis == .row ? CellRef(row: n, col: ref.col) : CellRef(row: ref.row, col: n)
        }

        func endpoints(_ a: Int, _ b: Int) throws -> (Int, Int)? {
            let first = try index(a), last = try index(b)
            if a == b && first == nil { return nil }
            return (first ?? (a < b ? at : at - 1), last ?? (b < a ? at : at - 1))
        }

        func range(_ range: CellRange) throws -> CellRange? {
            var a = range.start, b = range.end
            if axis == .row {
                guard let pair = try endpoints(a.row, b.row) else { return nil }
                (a.row, b.row) = pair
            } else {
                guard let pair = try endpoints(a.col, b.col) else { return nil }
                (a.col, b.col) = pair
            }
            return CellRange(a, b)
        }

        func rewrite(_ formula: String, owner: String?) throws -> String {
            let unsupported = Failure("This workbook contains a formula or defined name that cannot be safely adjusted: " + String(formula.prefix(100)))
            var spans: [(FormulaParser.Token, Range<Int>)] = []
            guard FormulaParser.parse(formula, observe: { spans.append(($0, $1)) }) != nil else { throw unsupported }
            let chars = Array(formula)
            var result = "", cursor = 0
            for (i, item) in spans.enumerated() {
                let (token, span) = item
                if token == .op(":") { throw unsupported }
                guard case .ident(let raw) = token else { continue }
                if i + 1 < spans.count && spans[i + 1].0 == .lparen {
                    guard !raw.contains("!"), !raw.contains(":") else { throw unsupported }
                    continue
                }
                let prefix = raw.lastIndex(of: "!").map { String(raw[...$0]) } ?? ""
                let body = String(raw.dropFirst(prefix.count))
                var qualifier = String(prefix.dropLast())
                if qualifier.hasPrefix("'") {
                    qualifier = String(qualifier.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                } else if qualifier.contains("!") { throw unsupported }
                guard !qualifier.contains(":"), !qualifier.contains("["), !qualifier.contains("]") else { throw unsupported }
                let parts = body.components(separatedBy: ":")
                let expr = FormulaParser.reference(raw)
                let rowOnly: Bool, colOnly: Bool
                switch expr {
                case .ref, .range: rowOnly = false; colOnly = false
                case .rows: rowOnly = true; colOnly = false
                case .cols: rowOnly = false; colOnly = true
                case .name:
                    guard prefix.isEmpty, !body.contains("$"), !body.contains(":") else { throw unsupported }
                    continue
                default: throw unsupported
                }
                guard let sheetName = prefix.isEmpty ? owner : qualifier else { throw unsupported }
                guard sheetName.caseInsensitiveCompare(target) == .orderedSame,
                      !(axis == .row && colOnly), !(axis == .column && rowOnly) else { continue }
                var values: [Int] = [], fields: [(String, String)] = []
                for part in parts {
                    var rest = part[...]
                    let firstDollar = rest.first == "$" ? String(rest.removeFirst()) : ""
                    let letters = rest.prefix(while: { $0.isLetter })
                    rest = rest.dropFirst(letters.count)
                    let rowDollar = !letters.isEmpty && rest.first == "$" ? String(rest.removeFirst()) : ""
                    let digits = rest
                    let column = CellRef.columnIndex(String(letters))
                    let row = Int(digits)
                    guard rowOnly || (column.map { (0..<16_384).contains($0) } ?? false),
                          colOnly || (row.map { (1...1_048_576).contains($0) } ?? false),
                          digits.allSatisfy({ $0.isNumber }), digits.first != "0" else { throw unsupported }
                    if axis == .row, let row {
                        values.append(row - 1)
                        fields.append((firstDollar + String(letters) + rowDollar, ""))
                    } else if axis == .column, let column {
                        values.append(column)
                        fields.append((firstDollar, rowDollar + String(digits)))
                    } else { throw unsupported }
                }
                guard let a = values.first, let b = values.last else { throw unsupported }
                let adjusted = try endpoints(a, b)
                let replacement: String
                if let (first, last) = adjusted {
                    if first == a && last == b { continue }
                    let components = fields.enumerated().map { j, field in
                        let n = j == 0 ? first : last
                        return field.0 + (axis == .row ? String(n + 1) : CellRef.columnName(n)) + field.1
                    }
                    replacement = prefix + components.joined(separator: ":")
                } else { replacement = "#REF!" }
                result += String(chars[cursor..<span.lowerBound]) + replacement
                cursor = span.upperBound
            }
            return result + String(chars[cursor...])
        }
    }
}
