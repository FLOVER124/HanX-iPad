import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SpreadsheetML (ECMA-376 Part 1, §18) reader and writer.
enum XLSXReader {
    static let builtinFormats: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00",
        14: "yyyy-mm-dd", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
        20: "h:mm", 21: "h:mm:ss", 22: "yyyy-mm-dd h:mm", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)",
        39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)", 45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 49: "@",
    ]

    static func read(_ zip: ZipReader) throws -> Workbook {
        guard let wb = zip.xml("xl/workbook.xml")?.rootElement() else { throw FormatError.invalid("xl/workbook.xml 없음") }
        var rels: [String: String] = [:]
        if let r = zip.xml("xl/_rels/workbook.xml.rels")?.rootElement() {
            for e in r.children("Relationship") {
                guard let id = e.attr("Id"), let t = e.attr("Target") else { continue }
                rels[id] = t.hasPrefix("/") ? String(t.dropFirst()) : "xl/" + t
            }
        }
        let shared = sharedStrings(zip)
        let styles = loadStyles(zip)
        let book = Workbook()
        book.sheets = []
        for s in wb.first("sheets")?.children("sheet") ?? [] {
            guard let rid = s.attr("id"), let path = rels[rid], let x = zip.xml(path)?.rootElement() else { continue }
            let ws = sheet(x, name: s.attr("name") ?? "Sheet\(book.sheets.count + 1)", shared: shared, styles: styles)
            ws.charts = charts(zip, sheetPath: path, sheetXML: x, ws: ws)
            book.sheets.append(ws)
        }
        if book.sheets.isEmpty { book.sheets = [Worksheet(name: "Sheet1")] }
        for d in wb.first("definedNames")?.children("definedName") ?? [] {
            guard let name = d.attr("name"), let f = d.stringValue, d.attr("localSheetId") == nil || !name.hasPrefix("_xlnm.") else { continue }
            book.definedNames[name.uppercased()] = XLSXFormula.decode(f)
        }
        return book
    }

    private static func sharedStrings(_ zip: ZipReader) -> [String] {
        guard let x = zip.xml("xl/sharedStrings.xml")?.rootElement() else { return [] }
        return x.children("si").map { si in
            if let t = si.child("t") { return t.stringValue ?? "" }
            return si.children("r").compactMap { $0.child("t")?.stringValue }.joined()
        }
    }

    private static func color(_ e: XMLElement?) -> RGB? {
        guard let e, let argb = e.attr("rgb"), argb.count >= 6 else { return nil }
        return RGB(hex: String(argb.suffix(6)))
    }

    private static func loadStyles(_ zip: ZipReader) -> [CellStyle] {
        guard let x = zip.xml("xl/styles.xml")?.rootElement() else { return [] }
        var formats = builtinFormats
        for f in x.first("numFmts")?.children("numFmt") ?? [] {
            if let id = f.attrInt("numFmtId"), let code = f.attr("formatCode") { formats[id] = code }
        }
        let fonts = x.first("fonts")?.children("font") ?? []
        let fills = x.first("fills")?.children("fill") ?? []
        let borders = x.first("borders")?.children("border") ?? []
        return (x.first("cellXfs")?.children("xf") ?? []).map { xf in
            var s = CellStyle()
            if let id = xf.attrInt("numFmtId"), id != 0 { s.numberFormat = formats[id] }
            if let fi = xf.attrInt("fontId"), fi < fonts.count {
                let f = fonts[fi]
                s.bold = f.child("b").map { $0.attr("val") != "0" } ?? false
                s.italic = f.child("i").map { $0.attr("val") != "0" } ?? false
                s.underline = f.child("u") != nil
                s.fontSize = f.child("sz")?.attrDouble("val")
                s.fontName = f.child("name")?.attr("val")
                if let c = color(f.child("color")), c != .black { s.color = c }
            }
            if let fi = xf.attrInt("fillId"), fi < fills.count, let p = fills[fi].child("patternFill"),
               p.attr("patternType") == "solid", let c = color(p.child("fgColor")) { s.fill = c }
            if let bi = xf.attrInt("borderId"), bi < borders.count {
                s.border = ["left", "right", "top", "bottom"].contains { borders[bi].child($0)?.attr("style") != nil }
            }
            if let a = xf.child("alignment") {
                s.align = HAlign(rawValue: a.attr("horizontal") ?? "general") ?? .general
                s.wrap = a.attr("wrapText") == "1"
            }
            return s
        }
    }

    private static func sheet(_ x: XMLElement, name: String, shared: [String], styles: [CellStyle]) -> Worksheet {
        let ws = Worksheet(name: name)
        // Column width unit = width of '0' in the default font (~7px at 96dpi).
        func chars(_ w: Double) -> Double { ((w * 7 + 5) * 0.75).rounded() }
        for c in x.first("cols")?.children("col") ?? [] {
            guard let lo = c.attrInt("min"), let hi = c.attrInt("max"), let w = c.attrDouble("width") else { continue }
            for i in (lo - 1)..<min(hi, lo + 500) { ws.columnWidths[i] = chars(w) }
        }
        var sharedFormulas: [String: (ref: CellRef, text: String)] = [:]
        var arrayRanges: [CellRange] = []
        for row in x.first("sheetData")?.children("row") ?? [] {
            if let r = row.attrInt("r"), let ht = row.attrDouble("ht"), row.attr("customHeight") == "1" { ws.rowHeights[r - 1] = ht }
            for c in row.children("c") {
                guard let a1 = c.attr("r"), let ref = CellRef(a1: a1) else { continue }
                var cell = SheetCell()
                if let si = c.attrInt("s"), si < styles.count { cell.style = styles[si] }
                let v = c.child("v")?.stringValue ?? ""
                if c.child("f") == nil, arrayRanges.contains(where: { $0.contains(ref) && $0.start != ref }) {
                    // Cached value of a spilled/array result: the anchor formula recreates it.
                    if cell.style != CellStyle() { ws.cells[ref] = cell }
                    continue
                }
                if let f = c.child("f") {
                    ws.cachedValues[ref] = (c.attr("t") ?? "n", v)
                    var text = XLSXFormula.decode(f.stringValue ?? "")
                    if f.attr("t") == "array", let r = f.attr("ref") {
                        let parts = r.split(separator: ":").map(String.init)
                        if let a = CellRef(a1: parts[0]) { arrayRanges.append(CellRange(a, parts.count > 1 ? CellRef(a1: parts[1]) ?? a : a)) }
                    } else if c.attr("cm") == nil {
                        ws.legacyFormulas.insert(ref)
                    }
                    if f.attr("t") == "shared", let si = f.attr("si") {
                        if !text.isEmpty { sharedFormulas[si] = (ref, text) }
                        else if let master = sharedFormulas[si] {
                            text = translate(master.text, rows: ref.row - master.ref.row, cols: ref.col - master.ref.col)
                        }
                    }
                    if !text.isEmpty { cell.input = "=" + text }
                }
                if cell.input.isEmpty {
                    switch c.attr("t") {
                    case "s": cell.input = Int(v).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                    case "inlineStr": cell.input = c.first("t")?.stringValue ?? ""
                    case "b": cell.input = v == "1" ? "TRUE" : "FALSE"
                    default: cell.input = v
                    }
                    // Text that looks numeric must stay text.
                    if c.child("f") == nil, ["s", "inlineStr", "str"].contains(c.attr("t") ?? ""), !cell.input.isEmpty {
                    // Only disambiguate text that the input model would treat as
                    // a formula, a forced-text prefix or a non-string literal.
                    let needsQuote: Bool
                    if cell.input.hasPrefix("=") || cell.input.hasPrefix("'") { needsQuote = true }
                    else { if case .string = SheetValue.literal(cell.input) { needsQuote = false } else { needsQuote = true } }
                    if needsQuote { cell.input = "'" + cell.input }
                }
                }
                if !cell.input.isEmpty || cell.style != CellStyle() { ws.cells[ref] = cell }
            }
        }
        for m in x.first("mergeCells")?.children("mergeCell") ?? [] {
            let parts = (m.attr("ref") ?? "").split(separator: ":").map(String.init)
            if parts.count == 2, let a = CellRef(a1: parts[0]), let b = CellRef(a1: parts[1]) { ws.merges.append(CellRange(a, b)) }
        }
        if let pane = x.first("pane"), pane.attr("state") == "frozen" {
            ws.frozenRows = pane.attrInt("ySplit") ?? 0
            ws.frozenCols = pane.attrInt("xSplit") ?? 0
        }
        return ws
    }

    private static func relsOf(_ zip: ZipReader, _ path: String) -> [String: String] {
        let dir = (path as NSString).deletingLastPathComponent
        let relPath = dir + "/_rels/" + (path as NSString).lastPathComponent + ".rels"
        var out: [String: String] = [:]
        for e in zip.xml(relPath)?.rootElement()?.children("Relationship") ?? [] {
            guard let id = e.attr("Id"), let t = e.attr("Target") else { continue }
            var parts: [Substring] = []
            for c in (t.hasPrefix("/") ? String(t.dropFirst()) : dir + "/" + t).split(separator: "/") {
                if c == ".." { _ = parts.popLast() } else if c != "." { parts.append(c) }
            }
            out[id] = parts.joined(separator: "/")
        }
        return out
    }

    /// Reads DrawingML charts anchored on a worksheet.
    private static func charts(_ zip: ZipReader, sheetPath: String, sheetXML: XMLElement, ws: Worksheet) -> [SheetChart] {
        guard let rid = sheetXML.child("drawing")?.relAttr("id"), let drawingPath = relsOf(zip, sheetPath)[rid],
              let drawing = zip.xml(drawingPath)?.rootElement() else { return [] }
        let drawingRels = relsOf(zip, drawingPath)
        func pos(_ e: XMLElement?) -> (Double, Double) {
            let col = e?.child("col")?.stringValue.flatMap { Int($0) } ?? 0, row = e?.child("row")?.stringValue.flatMap { Int($0) } ?? 0
            let colOff = Double(e?.child("colOff")?.stringValue ?? "0") ?? 0, rowOff = Double(e?.child("rowOff")?.stringValue ?? "0") ?? 0
            return ((0..<col).reduce(0) { $0 + ws.width($1) } + colOff / 12700, (0..<row).reduce(0) { $0 + ws.height($1) } + rowOff / 12700)
        }
        var out: [SheetChart] = []
        for anchor in drawing.elementChildren where anchor.local.hasSuffix("Anchor") {
            guard let cid = anchor.first("chart")?.relAttr("id"), let chartPath = drawingRels[cid],
                  let chart = zip.xml(chartPath)?.rootElement(), let plot = chart.first("plotArea") else { continue }
            let (x0, y0) = pos(anchor.child("from"))
            var (x1, y1) = anchor.child("to").map { pos($0) } ?? (x0 + 420, y0 + 260)
            if let ext = anchor.child("ext"), anchor.child("to") == nil {
                x1 = x0 + (ext.attrDouble("cx") ?? 0) / 12700; y1 = y0 + (ext.attrDouble("cy") ?? 0) / 12700
            }
            var kind = ChartKind.column
            for e in plot.elementChildren {
                switch e.local {
                case "barChart", "bar3DChart": kind = e.child("barDir")?.attr("val") == "bar" ? .bar : .column
                case "lineChart", "line3DChart", "scatterChart", "radarChart": kind = .line
                case "areaChart", "area3DChart": kind = .area
                case "pieChart", "pie3DChart", "doughnutChart", "ofPieChart": kind = .pie
                default: continue
                }
                break
            }
            // The data block is the bounding box of every referenced range.
            var cells: [CellRef] = []
            for f in plot.all("f") {
                let ref = (f.stringValue ?? "").split(separator: "!").last.map(String.init) ?? ""
                for part in ref.split(separator: ":") { if let c = CellRef(a1: String(part)) { cells.append(c) } }
            }
            guard !cells.isEmpty else { continue }
            let top = cells.map(\.row).min()!, left = cells.map(\.col).min()!, bottom = cells.map(\.row).max()!, right = cells.map(\.col).max()!
            let title = chart.child("chart")?.child("title")?.all("t").compactMap(\.stringValue).joined() ?? ""
            out.append(SheetChart(kind: kind, title: title, data: CellRange(CellRef(row: top, col: left), CellRef(row: bottom, col: right)),
                                  x: x0, y: y0, w: max(40, x1 - x0), h: max(30, y1 - y0)))
        }
        return out
    }

    /// Moves every relative reference in a formula by (rows, cols).
    static func translate(_ formula: String, rows: Int, cols: Int) -> String {
        // Match references only in code. Quoted text and worksheet names are
        // opaque; an unquoted identifier followed by ! is a sheet, not a cell.
        let pattern = #"(?<![\p{L}\p{N}_.])(?:(\$?[A-Za-z]{1,3}):(\$?[A-Za-z]{1,3})|(\$?[1-9][0-9]*):(\$?[1-9][0-9]*)|(\$?)([A-Za-z]{1,3})(\$?)([1-9][0-9]*))(?![\p{L}\p{N}_!.]|\s*\()"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return formula }
        func shifted(_ token: String, column: Bool) -> String {
            let absolute = token.hasPrefix("$")
            let raw = absolute ? String(token.dropFirst()) : token
            guard let old = column ? CellRef.columnIndex(raw) : Int(raw).map({$0 - 1}) else { return "#REF!" }
            let (n, overflow) = old.addingReportingOverflow(absolute ? 0 : (column ? cols : rows))
            guard !overflow, n >= 0, n < (column ? 16384 : 1048576) else { return "#REF!" }
            return (absolute ? "$" : "") + (column ? CellRef.columnName(n) : String(n + 1))
        }
        var result = ""
        XLSXFormula.scan(formula) { piece, code in
            guard code else { result += piece; return }
            let ns = piece as NSString
            var out = "", last = 0
            for m in re.matches(in: piece, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = NSMaxRange(m.range)
                func group(_ n: Int) -> String { ns.substring(with: m.range(at: n)) }
                if m.range(at: 1).location != NSNotFound {
                    let a = shifted(group(1), column: true), b = shifted(group(2), column: true)
                    out += a == "#REF!" || b == "#REF!" ? "#REF!" : a + ":" + b
                } else if m.range(at: 3).location != NSNotFound {
                    let a = shifted(group(3), column: false), b = shifted(group(4), column: false)
                    out += a == "#REF!" || b == "#REF!" ? "#REF!" : a + ":" + b
                } else {
                    let c = shifted(group(5) + group(6), column: true), r = shifted(group(7) + group(8), column: false)
                    out += c == "#REF!" || r == "#REF!" ? "#REF!" : c + r
                }
            }
            result += out + ns.substring(from: last)
        }
        return result
    }
}

enum XLSXWriter {
    /// `includeFormulas: false` creates a calculated snapshot for external PDF
    /// renderers. They must never evaluate workbook expressions or names.
    static func write(_ book: Workbook, allowExternalIO: Bool = true, includeFormulas: Bool = true) -> Data {
        let engine = FormulaEngine(book: book, allowExternalIO: allowExternalIO)
        var shared: [String] = []
        var sharedIndex: [String: Int] = [:]
        var styles: [CellStyle] = [CellStyle()]
        func styleId(_ s: CellStyle) -> Int {
            if let i = styles.firstIndex(of: s) { return i }
            styles.append(s); return styles.count - 1
        }

        var sheetsXML: [String] = []
        var usesDynamicArrays = false
        /// Full-precision number text for <v>.
        func xmlNumber(_ d: Double) -> String {
            if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
            return "\(d)".replacingOccurrences(of: "e", with: "E")
        }
        for ws in book.sheets {
            var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            if ws.frozenRows > 0 || ws.frozenCols > 0 {
                let tl = CellRef(row: ws.frozenRows, col: ws.frozenCols).a1
                x += "<sheetViews><sheetView workbookViewId=\"0\"><pane xSplit=\"\(ws.frozenCols)\" ySplit=\"\(ws.frozenRows)\" topLeftCell=\"\(tl)\" state=\"frozen\"/></sheetView></sheetViews>"
            }
            if !ws.columnWidths.isEmpty {
                x += "<cols>"
                for (c, w) in ws.columnWidths.sorted(by: { $0.key < $1.key }) {
                    let chars = max(1, (w / 0.75 - 5) / 7)
                    x += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.2f", chars))\" customWidth=\"1\"/>"
                }
                x += "</cols>"
            }
            x += "<sheetData>"
            // Spilled results are stored as cached values around their anchors.
            var spillValues: [CellRef: SheetValue] = [:]
            var spillRanges: [CellRef: CellRange] = [:]
            for (ref, cell) in ws.cells where cell.isFormula && !ws.legacyFormulas.contains(ref) {
                guard let m = engine.spillArray(ws, ref) else { continue }
                spillRanges[ref] = CellRange(ref, CellRef(row: ref.row + m.rows - 1, col: ref.col + m.cols - 1))
                for r in 0..<m.rows { for c in 0..<m.cols where r > 0 || c > 0 {
                    spillValues[CellRef(row: ref.row + r, col: ref.col + c)] = m[r, c]
                } }
            }
            if includeFormulas && !spillRanges.isEmpty { usesDynamicArrays = true }
            func valueXML(_ v: SheetValue) -> (String, String) {
                switch v {
                case .number(let d): return ("", "<v>\(xmlNumber(d))</v>")
                case .bool(let b): return (" t=\"b\"", "<v>\(b ? 1 : 0)</v>")
                case .error(let e): return (" t=\"e\"", "<v>\(XMLEscape.text(e))</v>")
                case .string(let s): return (" t=\"str\"", "<v>\(XMLEscape.text(s))</v>")
                default: return ("", "")
                }
            }
            let keys = Set(ws.cells.keys).union(spillValues.keys)
            let byRow = Dictionary(grouping: keys, by: \.row)
            let rows = Set(byRow.keys).union(ws.rowHeights.keys).sorted()
            for r in rows {
                x += "<row r=\"\(r + 1)\""
                if let h = ws.rowHeights[r] { x += " ht=\"\(h)\" customHeight=\"1\"" }
                x += ">"
                for ref in (byRow[r] ?? []).sorted() {
                    let cell = ws.cells[ref] ?? SheetCell()
                    let sid = styleId(cell.style)
                    let sAttr = sid == 0 ? "" : " s=\"\(sid)\""
                    if cell.isFormula {
                        if !includeFormulas {
                            let (t, v) = valueXML(engine.value(ws, ref))
                            x += "<c r=\"\(ref.a1)\"\(sAttr)\(t)>\(v)</c>"
                            continue
                        }
                        let f = XMLEscape.text(XLSXFormula.encode(String(cell.input.dropFirst())))
                        let (t, v) = valueXML(engine.value(ws, ref))
                        if ws.legacyFormulas.contains(ref) {
                            x += "<c r=\"\(ref.a1)\"\(sAttr)\(t)><f>\(f)</f>\(v)</c>"
                        } else {
                            // Dynamic-array formula (cm → XLDAPR metadata), spilling over its range.
                            usesDynamicArrays = true
                            let range = spillRanges[ref] ?? CellRange(ref, ref)
                            x += "<c r=\"\(ref.a1)\"\(sAttr)\(t) cm=\"1\"><f t=\"array\" ref=\"\(range.a1)\">\(f)</f>\(v)</c>"
                        }
                        continue
                    }
                    if cell.input.isEmpty, let sv = spillValues[ref] {
                        let (t, v) = valueXML(sv)
                        x += "<c r=\"\(ref.a1)\"\(sAttr)\(t)>\(v)</c>"
                        continue
                    }
                    var text = cell.input
                    let forcedText = text.hasPrefix("'")
                    if forcedText { text.removeFirst() }
                    switch forcedText ? .string(text) : SheetValue.literal(text) {
                    case .empty: x += "<c r=\"\(ref.a1)\"\(sAttr)/>"
                    case .number(let d): x += "<c r=\"\(ref.a1)\"\(sAttr)><v>\(xmlNumber(d))</v></c>"
                    case .bool(let b): x += "<c r=\"\(ref.a1)\"\(sAttr) t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                    case .error(let e): x += "<c r=\"\(ref.a1)\"\(sAttr) t=\"e\"><v>\(XMLEscape.text(e))</v></c>"
                    default:
                        let idx = sharedIndex[text] ?? { shared.append(text); sharedIndex[text] = shared.count - 1; return shared.count - 1 }()
                        x += "<c r=\"\(ref.a1)\"\(sAttr) t=\"s\"><v>\(idx)</v></c>"
                    }
                }
                x += "</row>"
            }
            x += "</sheetData>"
            if !ws.merges.isEmpty {
                x += "<mergeCells count=\"\(ws.merges.count)\">" + ws.merges.map { "<mergeCell ref=\"\($0.a1)\"/>" }.joined() + "</mergeCells>"
            }
            x += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            if !ws.charts.isEmpty { x += "<drawing r:id=\"rId1\"/>" }
            x += "</worksheet>"
            sheetsXML.append(x)
        }

        let z = ZipWriter()
        var overrides = ""
        for i in sheetsXML.indices {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        var chartCount = 0
        for (i, ws) in book.sheets.enumerated() where !ws.charts.isEmpty {
            overrides += "<Override PartName=\"/xl/drawings/drawing\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
            for _ in ws.charts {
                chartCount += 1
                overrides += "<Override PartName=\"/xl/charts/chart\(chartCount).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>"
            }
        }
        z.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\(overrides)\(usesDynamicArrays ? "<Override PartName=\"/xl/metadata.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheetMetadata+xml\"/>" : "")</Types>
        """)
        z.add("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        var sheetsList = "", rels = ""
        for (i, ws) in book.sheets.enumerated() {
            sheetsList += "<sheet name=\"\(XMLEscape.text(ws.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        let n = book.sheets.count
        rels += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        rels += "<Relationship Id=\"rId\(n + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        if usesDynamicArrays {
            rels += "<Relationship Id=\"rId\(n + 3)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sheetMetadata\" Target=\"metadata.xml\"/>"
            z.add("xl/metadata.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><metadata xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:xda=\"http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray\"><metadataTypes count=\"1\"><metadataType name=\"XLDAPR\" minSupportedVersion=\"120000\" copy=\"1\" pasteAll=\"1\" pasteValues=\"1\" merge=\"1\" splitFirst=\"1\" rowColShift=\"1\" clearFormats=\"1\" clearComments=\"1\" assign=\"1\" coerce=\"1\" cellMeta=\"1\"/></metadataTypes><futureMetadata name=\"XLDAPR\" count=\"1\"><bk><extLst><ext uri=\"{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}\"><xda:dynamicArrayProperties fDynamic=\"1\" fCollapsed=\"0\"/></ext></extLst></bk></futureMetadata><cellMetadata count=\"1\"><bk><rc t=\"1\" v=\"0\"/></bk></cellMetadata></metadata>")
        }
        let names = includeFormulas ? book.definedNames.sorted { $0.key < $1.key }.map { "<definedName name=\"\(XMLEscape.text($0.key))\">\(XMLEscape.text(XLSXFormula.encode($0.value)))</definedName>" }.joined() : ""
        z.add("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><bookViews><workbookView/></bookViews><sheets>\(sheetsList)</sheets>\(names.isEmpty ? "" : "<definedNames>" + names + "</definedNames>")</workbook>")
        z.add("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>")
        for (i, x) in sheetsXML.enumerated() { z.add("xl/worksheets/sheet\(i + 1).xml", x) }
        // Charts: sheet → drawingN → chartK (DrawingML).
        var chartNo = 0
        for (i, ws) in book.sheets.enumerated() where !ws.charts.isEmpty {
            z.add("xl/worksheets/_rels/sheet\(i + 1).xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\" Target=\"../drawings/drawing\(i + 1).xml\"/></Relationships>")
            var anchors = "", drawingRels = ""
            for (k, chart) in ws.charts.enumerated() {
                chartNo += 1
                anchors += ChartXML.anchor(chart, ws, rid: "rId\(k + 1)", id: k + 2)
                drawingRels += "<Relationship Id=\"rId\(k + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\" Target=\"../charts/chart\(chartNo).xml\"/>"
                z.add("xl/charts/chart\(chartNo).xml", ChartXML.chart(chart, ws, engine: engine))
            }
            z.add("xl/drawings/drawing\(i + 1).xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">\(anchors)</xdr:wsDr>")
            z.add("xl/drawings/_rels/drawing\(i + 1).xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(drawingRels)</Relationships>")
        }
        z.add("xl/sharedStrings.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(shared.count)\" uniqueCount=\"\(shared.count)\">" + shared.map { "<si><t xml:space=\"preserve\">\(XMLEscape.text($0))</t></si>" }.joined() + "</sst>")
        z.add("xl/styles.xml", stylesXML(styles))
        return z.finish()
    }

    private static func stylesXML(_ styles: [CellStyle]) -> String {
        var fonts: [String] = [], fills = ["<fill><patternFill patternType=\"none\"/></fill>", "<fill><patternFill patternType=\"gray125\"/></fill>"]
        var numFmts: [String: Int] = [:]
        let builtinByCode = Dictionary(XLSXReader.builtinFormats.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        var xfs = ""
        for s in styles {
            var f = "<font>"
            if s.bold { f += "<b/>" }
            if s.italic { f += "<i/>" }
            if s.underline { f += "<u/>" }
            f += "<sz val=\"\(s.fontSize ?? 11)\"/>"
            if let c = s.color { f += "<color rgb=\"FF\(c.hex)\"/>" }
            f += "<name val=\"\(XMLEscape.text(s.fontName ?? "맑은 고딕"))\"/><family val=\"2\"/></font>"
            let fontId = fonts.firstIndex(of: f) ?? { fonts.append(f); return fonts.count - 1 }()
            var fillId = 0
            if let c = s.fill {
                let fx = "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(c.hex)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
                fillId = fills.firstIndex(of: fx) ?? { fills.append(fx); return fills.count - 1 }()
            }
            var numId = 0
            if let code = s.numberFormat, code != "General" {
                numId = builtinByCode[code] ?? numFmts[code] ?? { let id = 164 + numFmts.count; numFmts[code] = id; return id }()
            }
            xfs += "<xf numFmtId=\"\(numId)\" fontId=\"\(fontId)\" fillId=\"\(fillId)\" borderId=\"\(s.border ? 1 : 0)\" xfId=\"0\""
            xfs += numId != 0 ? " applyNumberFormat=\"1\"" : ""
            if s.align != .general || s.wrap {
                xfs += " applyAlignment=\"1\"><alignment" + (s.align != .general ? " horizontal=\"\(s.align.rawValue)\"" : "") + (s.wrap ? " wrapText=\"1\"" : "") + "/></xf>"
            } else { xfs += "/>" }
        }
        let nf = numFmts.isEmpty ? "" : "<numFmts count=\"\(numFmts.count)\">" + numFmts.sorted { $0.value < $1.value }.map {
            "<numFmt numFmtId=\"\($0.value)\" formatCode=\"\(XMLEscape.text($0.key))\"/>"
        }.joined() + "</numFmts>"
        let thin = "<border><left style=\"thin\"><color auto=\"1\"/></left><right style=\"thin\"><color auto=\"1\"/></right><top style=\"thin\"><color auto=\"1\"/></top><bottom style=\"thin\"><color auto=\"1\"/></bottom><diagonal/></border>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(nf)"
            + "<fonts count=\"\(fonts.count)\">\(fonts.joined())</fonts><fills count=\"\(fills.count)\">\(fills.joined())</fills>"
            + "<borders count=\"2\"><border><left/><right/><top/><bottom/><diagonal/></border>\(thin)</borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"\(styles.count)\">\(xfs)</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    }
}

enum DelimitedText {
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) ?? "" }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Korean Excel exports CSV in CP949 (EUC-KR superset).
        let cp949 = UInt(0x80000422)
        return String(data: data, encoding: String.Encoding(rawValue: cp949)) ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String, separator: Character) -> Worksheet {
        let ws = Worksheet(name: "Sheet1")
        var row = 0, col = 0, field = "", quoted = false, inQuotes = false
        var chars = Array(text)
        if chars.last != "\n" { chars.append("\n") }
        var i = 0
        func commit() {
            if !field.isEmpty {
                let isNumericText = quoted && SheetValue.literal(field) != .string(field)
                ws.set(CellRef(row: row, col: col), input: isNumericText ? "'" + field : field)
            }
            field = ""; quoted = false
        }
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(ch) }
            } else if ch == "\"" && field.isEmpty { inQuotes = true; quoted = true }
            else if ch == separator { commit(); col += 1 }
            else if ch == "\r\n" || ch == "\n" || ch == "\r" { commit(); row += 1; col = 0 }
            else { field.append(ch) }
            i += 1
        }
        return ws
    }

    static func write(_ ws: Worksheet, engine: FormulaEngine, separator: Character) -> Data {
        guard let used = ws.usedRange else { return Data([0xEF, 0xBB, 0xBF]) }
        var out = ""
        for r in 0...used.end.row {
            var fields: [String] = []
            for c in 0...used.end.col {
                var s = engine.display(ws, CellRef(row: r, col: c))
                if s.contains(separator) || s.contains("\"") || s.contains("\n") {
                    s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                fields.append(s)
            }
            out += fields.joined(separator: String(separator)) + "\r\n"
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data(out.utf8)
    }
}

enum SheetIO {
    static func load(url: URL) throws -> Workbook {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "csv": let b = Workbook(); b.sheets = [DelimitedText.parse(DelimitedText.decode(data), separator: ",")]; b.source = "csv"; return b
        case "tsv", "tab": let b = Workbook(); b.sheets = [DelimitedText.parse(DelimitedText.decode(data), separator: "\t")]; b.source = "tsv"; return b
        default:
            guard ZipReader.isZip(data) else { throw FormatError.unsupported("xlsx, csv, tsv 형식만 열 수 있습니다") }
            let b = try XLSXReader.read(ZipReader(data: data))
            b.source = "xlsx"
            return b
        }
    }

    static func save(_ book: Workbook, to url: URL, sheetIndex: Int = 0) throws {
        let engine = FormulaEngine(book: book)
        let data: Data
        switch url.pathExtension.lowercased() {
        case "csv": data = DelimitedText.write(book.sheets[sheetIndex], engine: engine, separator: ",")
        case "tsv": data = DelimitedText.write(book.sheets[sheetIndex], engine: engine, separator: "\t")
        case "html", "htm": data = Data(SheetHTML.html(book, engine: engine).utf8)
        default: data = XLSXWriter.write(book)
        }
        try data.write(to: url, options: .atomic)
    }
}

enum SheetHTML {
    static func html(_ book: Workbook, engine: FormulaEngine) -> String {
        var s = "<!DOCTYPE html><html lang=\"ko\"><head><meta charset=\"utf-8\"><title>Workbook</title><style>"
            + "body{font-family:-apple-system,'Apple SD Gothic Neo',sans-serif}table{border-collapse:collapse;margin:1em 0}"
            + "td{border:1px solid #ccc;padding:2px 6px;font-size:13px;white-space:nowrap}</style></head><body>"
        for ws in book.sheets {
            s += "<h2>\(XMLEscape.text(ws.name))</h2>"
            guard let used = ws.usedRange else { continue }
            s += "<table>"
            var covered = Set<CellRef>()
            for m in ws.merges { for c in m.cells where c != m.start { covered.insert(c) } }
            for r in 0...used.end.row {
                s += "<tr>"
                for c in 0...used.end.col {
                    let ref = CellRef(row: r, col: c)
                    if covered.contains(ref) { continue }
                    let st = ws.cells[ref]?.style ?? CellStyle()
                    var css = ""
                    if st.bold { css += "font-weight:bold;" }
                    if st.italic { css += "font-style:italic;" }
                    if let col = st.color { css += "color:#\(col.hex);" }
                    if let f = st.fill { css += "background:#\(f.hex);" }
                    let v = engine.value(ws, ref)
                    let align = st.align == .general ? (v.number != nil && !(v == .empty) && !{ if case .string = v { return true }; return false }() ? "right" : "left") : st.align.rawValue
                    css += "text-align:\(align);"
                    var span = ""
                    if let m = ws.merges.first(where: { $0.start == ref }) {
                        span = " rowspan=\"\(m.end.row - m.start.row + 1)\" colspan=\"\(m.end.col - m.start.col + 1)\""
                    }
                    s += "<td style=\"\(css)\"\(span)>\(XMLEscape.text(engine.display(ws, ref)))</td>"
                }
                s += "</tr>"
            }
            s += "</table>"
        }
        return s + "</body></html>"
    }
}

/// DrawingML chart parts for SpreadsheetML.
enum ChartXML {
    private static func cellAt(_ ws: Worksheet, x: Double, y: Double) -> (col: Int, colOff: Int, row: Int, rowOff: Int) {
        var c = 0, accX = 0.0
        while accX + ws.width(c) <= x && c < 16000 { accX += ws.width(c); c += 1 }
        var r = 0, accY = 0.0
        while accY + ws.height(r) <= y && r < 1_000_000 { accY += ws.height(r); r += 1 }
        return (c, Int((x - accX) * 12700), r, Int((y - accY) * 12700))
    }

    static func anchor(_ ch: SheetChart, _ ws: Worksheet, rid: String, id: Int) -> String {
        let a = cellAt(ws, x: ch.x, y: ch.y), b = cellAt(ws, x: ch.x + ch.w, y: ch.y + ch.h)
        func pt(_ tag: String, _ p: (col: Int, colOff: Int, row: Int, rowOff: Int)) -> String {
            "<xdr:\(tag)><xdr:col>\(p.col)</xdr:col><xdr:colOff>\(p.colOff)</xdr:colOff><xdr:row>\(p.row)</xdr:row><xdr:rowOff>\(p.rowOff)</xdr:rowOff></xdr:\(tag)>"
        }
        return "<xdr:twoCellAnchor>\(pt("from", a))\(pt("to", b))<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"\(id)\" name=\"차트 \(id - 1)\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>"
            + "<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">"
            + "<c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" r:id=\"\(rid)\"/>"
            + "</a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>"
    }

    private static func ref(_ ws: Worksheet, _ a: CellRef, _ b: CellRef) -> String {
        let name = ws.name.contains(where: { !$0.isLetter && !$0.isNumber }) ? "'\(ws.name.replacingOccurrences(of: "'", with: "''"))'" : ws.name
        func abs(_ r: CellRef) -> String { "$" + CellRef.columnName(r.col) + "$" + String(r.row + 1) }
        return XMLEscape.text(name + "!" + abs(a) + (a == b ? "" : ":" + abs(b)))
    }

    static func chart(_ ch: SheetChart, _ ws: Worksheet, engine: FormulaEngine) -> String {
        let (cats, series) = ch.resolve(ws, engine)
        let r = ch.data
        func isText(_ v: SheetValue) -> Bool { if case .string = v { return true }; return false }
        let headerRow = r.end.row > r.start.row && (r.start.col...r.end.col).contains { isText(engine.value(ws, CellRef(row: r.start.row, col: $0))) }
        let labelCol = cats.first.map { _ in r.end.col > r.start.col && ((headerRow ? r.start.row + 1 : r.start.row)...r.end.row).contains { isText(engine.value(ws, CellRef(row: $0, col: r.start.col))) } } ?? false
        let firstRow = headerRow ? r.start.row + 1 : r.start.row
        let firstCol = labelCol ? r.start.col + 1 : r.start.col
        var sers = ""
        for (i, s) in series.enumerated() {
            let col = firstCol + i
            sers += "<c:ser><c:idx val=\"\(i)\"/><c:order val=\"\(i)\"/>"
            if headerRow {
                sers += "<c:tx><c:strRef><c:f>\(ref(ws, CellRef(row: r.start.row, col: col), CellRef(row: r.start.row, col: col)))</c:f>"
                    + "<c:strCache><c:ptCount val=\"1\"/><c:pt idx=\"0\"><c:v>\(XMLEscape.text(s.name))</c:v></c:pt></c:strCache></c:strRef></c:tx>"
            }
            if ch.kind == .line { sers += "<c:marker><c:symbol val=\"circle\"/><c:size val=\"5\"/></c:marker>" }
            if labelCol {
                sers += "<c:cat><c:strRef><c:f>\(ref(ws, CellRef(row: firstRow, col: r.start.col), CellRef(row: r.end.row, col: r.start.col)))</c:f><c:strCache><c:ptCount val=\"\(cats.count)\"/>"
                    + cats.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\(XMLEscape.text($0.element))</c:v></c:pt>" }.joined() + "</c:strCache></c:strRef></c:cat>"
            }
            sers += "<c:val><c:numRef><c:f>\(ref(ws, CellRef(row: firstRow, col: col), CellRef(row: r.end.row, col: col)))</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"\(s.values.count)\"/>"
                + s.values.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\(SheetValue.general($0.element))</c:v></c:pt>" }.joined() + "</c:numCache></c:numRef></c:val>"
            if ch.kind == .line { sers += "<c:smooth val=\"0\"/>" }
            sers += "</c:ser>"
        }
        let axes = "<c:axId val=\"500000001\"/><c:axId val=\"500000002\"/>"
        let plot: String
        switch ch.kind {
        case .column, .bar:
            plot = "<c:barChart><c:barDir val=\"\(ch.kind == .bar ? "bar" : "col")\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>\(sers)<c:gapWidth val=\"150\"/>\(axes)</c:barChart>"
        case .line: plot = "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(sers)<c:marker val=\"1\"/>\(axes)</c:lineChart>"
        case .area: plot = "<c:areaChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(sers)\(axes)</c:areaChart>"
        case .pie: plot = "<c:pieChart><c:varyColors val=\"1\"/>\(sers)<c:firstSliceAng val=\"0\"/></c:pieChart>"
        }
        let catPos = ch.kind == .bar ? "l" : "b", valPos = ch.kind == .bar ? "b" : "l"
        let axisXML = ch.kind == .pie ? "" :
            "<c:catAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(catPos)\"/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/><c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>"
            + "<c:valAx><c:axId val=\"500000002\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(valPos)\"/><c:majorGridlines/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"500000001\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"between\"/></c:valAx>"
        let title = ch.title.isEmpty ? "<c:autoTitleDeleted val=\"1\"/>" :
            "<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(XMLEscape.text(ch.title))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title><c:autoTitleDeleted val=\"0\"/>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<c:roundedCorners val=\"0\"/><c:chart>\(title)<c:plotArea><c:layout/>\(plot)\(axisXML)</c:plotArea><c:legend><c:legendPos val=\"\(ch.kind == .pie ? "r" : "b")\"/><c:overlay val=\"0\"/></c:legend><c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart></c:chartSpace>"
    }
}
