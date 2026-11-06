import UIKit

extension Notification.Name {
    static let sheetChanged = Notification.Name("HanXSheetChanged")
}

/// XLSX / CSV / TSV / HanX workbook with undoable edits (same operations as
/// the macOS SheetDocument).
final class SheetFileDocument: HanXBaseDocument {
    private(set) var book: Workbook
    private(set) var engine: FormulaEngine
    var currentSheetIndex = 0

    override init(fileURL url: URL) {
        let blank = Workbook()
        book = blank
        engine = FormulaEngine(book: blank)
        super.init(fileURL: url)
    }

    override var exportFormats: [ExportFormat] { ExportFormat.spreadsheet }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else { throw HanXError.message("도표를 읽을 수 없습니다.") }
        do {
            let loaded: Workbook
            switch fileExtension {
            case "hanx": loaded = try XLSXReader.read(HanXFile.payload(data, expecting: .spreadsheet))
            case "csv": loaded = Workbook(); loaded.sheets = [DelimitedText.parse(DelimitedText.decode(data), separator: ",")]; loaded.source = "csv"
            case "tsv", "tab": loaded = Workbook(); loaded.sheets = [DelimitedText.parse(DelimitedText.decode(data), separator: "\t")]; loaded.source = "tsv"
            default:
                guard ZipReader.isZip(data) else { throw FormatError.unsupported("xlsx, csv, tsv 형식만 열 수 있습니다") }
                loaded = try XLSXReader.read(ZipReader(data: data))
                loaded.source = "xlsx"
            }
            if loaded.sheets.isEmpty { loaded.sheets = [Worksheet(name: "Sheet1")] }
            book = loaded
            engine = FormulaEngine(book: loaded)
            currentSheetIndex = 0
        } catch {
            recordLoadError(error)
            throw error
        }
    }

    var sheet: Worksheet { book.sheets[max(0, min(currentSheetIndex, book.sheets.count - 1))] }

    override func exportData(for ext: String) throws -> Data {
        NotificationCenter.default.post(name: .sheetCommitEditing, object: self)
        switch ext {
        case "hanx": return HanXFile.encode(.spreadsheet, payload: XLSXWriter.write(book))
        case "csv": return DelimitedText.write(sheet, engine: engine, separator: ",")
        case "tsv", "tab": return DelimitedText.write(sheet, engine: engine, separator: "\t")
        case "html", "htm": return Data(SheetHTML.html(book, engine: engine).utf8)
        case "pdf": return SheetPDF.pdf(book, engine: engine)
        default: return XLSXWriter.write(book)
        }
    }

    override func pdfData() -> Data { SheetPDF.pdf(book, engine: engine) }

    private func changed() {
        engine.invalidate()
        NotificationCenter.default.post(name: .sheetChanged, object: self)
    }

    // MARK: Undoable edits

    func setCells(_ changes: [(Worksheet, CellRef, SheetCell?)], actionName: String) {
        var undo: [(Worksheet, CellRef, SheetCell?)] = []
        for (ws, ref, cell) in changes {
            undo.append((ws, ref, ws.cells[ref]))
            ws.cells[ref] = (cell?.input.isEmpty ?? true) && (cell?.style ?? CellStyle()) == CellStyle() ? nil : cell
            ws.legacyFormulas.remove(ref)
            ws.cachedValues[ref] = nil
        }
        undoManager.registerUndo(withTarget: self) { $0.setCells(undo, actionName: actionName) }
        undoManager.setActionName(actionName)
        changed()
    }

    private struct DataSnapshot {
        let cells: [CellRef: SheetCell]
        let cached: [CellRef: (String, String)]
        let legacy: Set<CellRef>
        init(_ sheet: Worksheet) { cells = sheet.cells; cached = sheet.cachedValues; legacy = sheet.legacyFormulas }
    }

    func editData(on sheet: Worksheet, named name: String, _ change: () throws -> Void) throws {
        let before = DataSnapshot(sheet)
        try change()
        registerDataUndo(before, sheet: sheet, name: name)
    }

    private func registerDataUndo(_ snapshot: DataSnapshot, sheet: Worksheet, name: String) {
        undoManager.registerUndo(withTarget: self) { document in
            let inverse = DataSnapshot(sheet)
            sheet.cells = snapshot.cells
            sheet.cachedValues = snapshot.cached
            sheet.legacyFormulas = snapshot.legacy
            document.registerDataUndo(inverse, sheet: sheet, name: name)
        }
        undoManager.setActionName(name)
        changed()
    }

    func structural(_ name: String, sheet: Worksheet, cell: CellRef, axis: SheetStructuralEditing.Axis, inserting: Bool) throws {
        let snapshot = SheetStructuralEditing.Snapshot(book)
        try SheetStructuralEditing.apply(book: book, sheet: sheet, cell: cell, axis: axis, inserting: inserting)
        registerStructuralUndo(snapshot, name: name)
    }

    private func registerStructuralUndo(_ snapshot: SheetStructuralEditing.Snapshot, name: String) {
        undoManager.registerUndo(withTarget: self) { document in
            let inverse = SheetStructuralEditing.Snapshot(document.book)
            snapshot.restore()
            document.registerStructuralUndo(inverse, name: name)
        }
        undoManager.setActionName(name)
        changed()
    }

    func setMerges(_ merges: [CellRange], on ws: Worksheet) {
        let old = ws.merges
        undoManager.registerUndo(withTarget: self) { $0.setMerges(old, on: ws) }
        undoManager.setActionName("셀 병합")
        ws.merges = merges
        changed()
    }

    func setCharts(_ charts: [SheetChart], on ws: Worksheet, name: String) {
        let old = ws.charts
        undoManager.registerUndo(withTarget: self) { $0.setCharts(old, on: ws, name: name) }
        undoManager.setActionName(name)
        ws.charts = charts
        changed()
    }

    func setDimensions(columns: [Int: Double], rows: [Int: Double], on ws: Worksheet) {
        let oldColumns = ws.columnWidths, oldRows = ws.rowHeights
        undoManager.registerUndo(withTarget: self) { $0.setDimensions(columns: oldColumns, rows: oldRows, on: ws) }
        undoManager.setActionName("크기")
        ws.columnWidths = columns
        ws.rowHeights = rows
        changed()
    }

    func setFrozen(rows: Int, cols: Int, on ws: Worksheet) {
        let oldRows = ws.frozenRows, oldCols = ws.frozenCols
        undoManager.registerUndo(withTarget: self) { $0.setFrozen(rows: oldRows, cols: oldCols, on: ws) }
        undoManager.setActionName("틀 고정")
        ws.frozenRows = rows
        ws.frozenCols = cols
        changed()
    }

    func addSheet(named name: String) -> Int {
        let ws = Worksheet(name: name)
        book.sheets.append(ws)
        let index = book.sheets.count - 1
        undoManager.registerUndo(withTarget: self) { doc in _ = doc.removeSheet(at: index) }
        undoManager.setActionName("시트 추가")
        changed()
        return index
    }

    @discardableResult
    func removeSheet(at index: Int) -> Bool {
        guard book.sheets.count > 1, book.sheets.indices.contains(index) else { return false }
        let ws = book.sheets.remove(at: index)
        currentSheetIndex = min(currentSheetIndex, book.sheets.count - 1)
        undoManager.registerUndo(withTarget: self) { doc in doc.insertSheet(ws, at: index) }
        undoManager.setActionName("시트 삭제")
        changed()
        return true
    }

    private func insertSheet(_ ws: Worksheet, at index: Int) {
        book.sheets.insert(ws, at: min(index, book.sheets.count))
        undoManager.registerUndo(withTarget: self) { doc in doc.removeSheet(at: index) }
        changed()
    }

    func renameSheet(_ ws: Worksheet, to name: String) {
        let old = ws.name
        guard old != name else { return }
        // Formulas that point at the sheet follow the new name.
        let quotedOld = old.contains(" ") ? "'\(old)'!" : "\(old)!"
        let quotedNew = name.contains(" ") || name.contains("-") ? "'\(name)'!" : "\(name)!"
        for s in book.sheets {
            for (ref, cell) in s.cells where cell.isFormula && cell.input.contains(quotedOld) {
                s.cells[ref]?.input = cell.input.replacingOccurrences(of: quotedOld, with: quotedNew)
            }
        }
        ws.name = name
        undoManager.registerUndo(withTarget: self) { $0.renameSheet(ws, to: old) }
        undoManager.setActionName("시트 이름")
        changed()
    }

    func touch() { updateChangeCount(.done); changed() }
}

extension Notification.Name {
    static let sheetCommitEditing = Notification.Name("HanXSheetCommitEditing")
}
