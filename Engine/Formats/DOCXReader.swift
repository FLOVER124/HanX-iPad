import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WordprocessingML (ECMA-376) reader. Mirrors Word's own resolution order:
/// docDefaults → paragraph style chain → run style chain → direct formatting.
final class DOCXReader {
    private struct Style {
        var type: String
        var basedOn: String?
        var name: String?
        var pPr: XMLElement?
        var rPr: XMLElement?
        var tblPr: XMLElement?
        var tcPr: XMLElement?
    }

    private struct Level { var fmt: String; var text: String; var start: Int }

    private let zip: ZipReader
    private let doc = UDocument()
    private var rels: [String: String] = [:]
    private var styles: [String: Style] = [:]
    private var defaultParaStyle: String?
    private var defaultRPr: XMLElement?
    private var defaultPPr: XMLElement?
    private var themeFonts: [String: String] = [:]
    private var numToAbstract: [String: String] = [:]
    private var abstractLevels: [String: [Int: Level]] = [:]
    private var counters: [String: [Int: Int]] = [:]

    init(zip: ZipReader) { self.zip = zip }

    func read() throws -> UDocument {
        doc.source = .docx
        guard let xml = zip.xml("word/document.xml"), let root = xml.rootElement(), let body = root.first("body") else {
            throw FormatError.invalid("word/document.xml 없음")
        }
        loadRels()
        loadTheme()
        loadStyles()
        loadNumbering()

        var blocks: [Block] = []
        func walk(_ el: XMLElement) {
            for c in el.elementChildren {
                switch c.local {
                case "p":
                    blocks.append(contentsOf: paragraph(c))
                    if let sp = c.child("pPr")?.child("sectPr") {
                        doc.sections.append(section(sp, blocks))
                        blocks = []
                    }
                case "tbl": blocks.append(.table(table(c)))
                case "sdt": if let content = c.child("sdtContent") { walk(content) }
                case "customXml", "ins": walk(c)
                case "sectPr":
                    doc.sections.append(section(c, blocks))
                    blocks = []
                default: break
                }
            }
        }
        walk(body)
        if !blocks.isEmpty || doc.sections.isEmpty {
            doc.sections.append(Section(page: doc.sections.last?.page ?? .letterWord, blocks: blocks))
        }
        return doc
    }

    // MARK: Package parts

    private func loadRels() {
        guard let x = zip.xml("word/_rels/document.xml.rels")?.rootElement() else { return }
        for r in x.children("Relationship") {
            guard let id = r.attr("Id"), let target = r.attr("Target"), r.attr("TargetMode") != "External" else { continue }
            rels[id] = target.hasPrefix("/") ? String(target.dropFirst()) : normalize("word/" + target)
        }
    }

    private func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/") {
            if c == ".." { _ = out.popLast() } else if c != "." { out.append(c) }
        }
        return out.joined(separator: "/")
    }

    private func loadTheme() {
        let themePath = zip.order.first { $0.hasPrefix("word/theme/") && $0.hasSuffix(".xml") }
        guard let p = themePath, let x = zip.xml(p)?.rootElement() else { return }
        for (kind, el) in [("minor", x.first("minorFont")), ("major", x.first("majorFont"))] {
            guard let el else { continue }
            themeFonts[kind + "HAnsi"] = el.child("latin")?.attr("typeface")
            var ea = el.child("ea")?.attr("typeface") ?? ""
            if ea.isEmpty { ea = el.children("font").first { $0.attr("script") == "Hang" }?.attr("typeface") ?? "" }
            if !ea.isEmpty { themeFonts[kind + "EastAsia"] = ea }
        }
    }

    private func loadStyles() {
        guard let x = zip.xml("word/styles.xml")?.rootElement() else { return }
        if let dd = x.child("docDefaults") {
            defaultRPr = dd.child("rPrDefault")?.child("rPr")
            defaultPPr = dd.child("pPrDefault")?.child("pPr")
        }
        for s in x.children("style") {
            guard let id = s.attr("styleId") else { continue }
            let type = s.attr("type") ?? "paragraph"
            styles[id] = Style(type: type, basedOn: s.child("basedOn")?.attr("val"), name: s.child("name")?.attr("val"),
                               pPr: s.child("pPr"), rPr: s.child("rPr"), tblPr: s.child("tblPr"), tcPr: s.child("tcPr"))
            if type == "paragraph", s.attr("default") == "1" || s.attr("default") == "true" { defaultParaStyle = id }
        }
    }

    private func loadNumbering() {
        guard let x = zip.xml("word/numbering.xml")?.rootElement() else { return }
        for a in x.children("abstractNum") {
            guard let id = a.attr("abstractNumId") else { continue }
            var levels: [Int: Level] = [:]
            for l in a.children("lvl") {
                guard let i = l.attrInt("ilvl") else { continue }
                levels[i] = Level(fmt: l.child("numFmt")?.attr("val") ?? "decimal",
                                  text: l.child("lvlText")?.attr("val") ?? "",
                                  start: l.child("start")?.attrInt("val") ?? 1)
            }
            abstractLevels[id] = levels
        }
        for n in x.children("num") {
            if let id = n.attr("numId"), let a = n.child("abstractNumId")?.attr("val") { numToAbstract[id] = a }
        }
    }

    // MARK: Property resolution

    private func chain(_ id: String?) -> [Style] {
        var out: [Style] = []
        var cur = id
        var seen = Set<String>()
        while let c = cur, let s = styles[c], !seen.contains(c) {
            seen.insert(c)
            out.insert(s, at: 0)
            cur = s.basedOn
        }
        return out
    }

    private func isOn(_ el: XMLElement?) -> Bool? {
        guard let el else { return nil }
        let v = el.attr("val")?.lowercased()
        return !(v == "0" || v == "false" || v == "off" || v == "none")
    }

    private func apply(rPr el: XMLElement?, to p: inout CharProps) {
        guard let el else { return }
        if let f = el.child("rFonts") {
            if let a = f.attr("ascii") ?? f.attr("hAnsi") { p.fontName = a }
            else if let t = f.attr("asciiTheme") ?? f.attr("hAnsiTheme") {
                p.fontName = themeFonts[t.hasPrefix("major") ? "majorHAnsi" : "minorHAnsi"] ?? p.fontName
            }
            if let e = f.attr("eastAsia") { p.eastAsianFontName = e }
            else if let t = f.attr("eastAsiaTheme") {
                p.eastAsianFontName = themeFonts[t.hasPrefix("major") ? "majorEastAsia" : "minorEastAsia"] ?? p.eastAsianFontName
            }
        }
        if let b = isOn(el.child("b")) { p.bold = b }
        if let i = isOn(el.child("i")) { p.italic = i }
        if let s = isOn(el.child("strike")) ?? isOn(el.child("dstrike")) { p.strike = s }
        if let sz = el.child("sz")?.attrDouble("val") { p.size = sz / 2 }
        if let u = el.child("u")?.attr("val") {
            switch u {
            case "none": p.underline = .none
            case "double": p.underline = .double
            case "dotted", "dottedHeavy": p.underline = .dotted
            case "dash", "dashLong", "dashedHeavy", "dotDash", "dotDotDash": p.underline = .dashed
            case "wave", "wavyDouble", "wavyHeavy": p.underline = .wave
            case "thick": p.underline = .thick
            default: p.underline = .single
            }
        }
        if let c = el.child("color")?.attr("val"), c != "auto", let rgb = RGB(hex: c) { p.color = rgb }
        if let h = el.child("highlight")?.attr("val") { p.highlight = DOCXReader.highlightColors[h] }
        if let s = el.child("shd")?.attr("fill"), s != "auto", let rgb = RGB(hex: s), rgb != RGB(r: 255, g: 255, b: 255) { p.highlight = rgb }
        if let v = el.child("vertAlign")?.attr("val") {
            p.verticalAlign = v == "superscript" ? .superscript : v == "subscript" ? .subscript : .baseline
        }
        if let s = el.child("spacing")?.attrDouble("val") { p.spacing = Units.twips(s) }
        if let w = el.child("w")?.attrDouble("val"), w > 0 { p.widthRatio = w }
    }

    static let highlightColors: [String: RGB] = [
        "yellow": RGB(r: 255, g: 255, b: 0), "green": RGB(r: 0, g: 255, b: 0), "cyan": RGB(r: 0, g: 255, b: 255),
        "magenta": RGB(r: 255, g: 0, b: 255), "blue": RGB(r: 0, g: 0, b: 255), "red": RGB(r: 255, g: 0, b: 0),
        "darkBlue": RGB(r: 0, g: 0, b: 128), "darkCyan": RGB(r: 0, g: 128, b: 128), "darkGreen": RGB(r: 0, g: 128, b: 0),
        "darkMagenta": RGB(r: 128, g: 0, b: 128), "darkRed": RGB(r: 128, g: 0, b: 0), "darkYellow": RGB(r: 128, g: 128, b: 0),
        "darkGray": RGB(r: 128, g: 128, b: 128), "lightGray": RGB(r: 192, g: 192, b: 192), "black": RGB(r: 0, g: 0, b: 0),
    ]

    private func apply(pPr el: XMLElement?, to p: inout ParaProps) {
        guard let el else { return }
        if let j = el.child("jc")?.attr("val") {
            switch j {
            case "left", "start": p.alignment = .left
            case "right", "end": p.alignment = .right
            case "center": p.alignment = .center
            case "both", "justify", "lowKashida", "mediumKashida", "highKashida": p.alignment = .justify
            case "distribute", "thaiDistribute": p.alignment = .distribute
            default: break
            }
        }
        if let ind = el.child("ind") {
            if let l = ind.attrDouble("left") ?? ind.attrDouble("start") { p.indentLeft = Units.twips(l) }
            if let r = ind.attrDouble("right") ?? ind.attrDouble("end") { p.indentRight = Units.twips(r) }
            if let f = ind.attrDouble("firstLine") { p.firstLine = Units.twips(f) }
            if let h = ind.attrDouble("hanging") { p.firstLine = -Units.twips(h) }
        }
        if let s = el.child("spacing") {
            if let b = s.attrDouble("before") { p.spaceBefore = Units.twips(b) }
            if let a = s.attrDouble("after") { p.spaceAfter = Units.twips(a) }
            if let line = s.attrDouble("line") {
                switch s.attr("lineRule") ?? "auto" {
                case "exact": p.lineSpacing = .exact(Units.twips(line))
                case "atLeast": p.lineSpacing = .atLeast(Units.twips(line))
                default: p.lineSpacing = .multiple(line / 240)
                }
            }
        }
        if let border = Self.border(el.child("pBdr")?.child("bottom")) { p.bottomBorder = border }
        if let pb = isOn(el.child("pageBreakBefore")) { p.pageBreakBefore = pb }
    }

    private func baseChar() -> CharProps {
        var c = CharProps()
        c.fontName = themeFonts["minorHAnsi"] ?? "Calibri"
        c.eastAsianFontName = themeFonts["minorEastAsia"]
        c.size = 10
        apply(rPr: defaultRPr, to: &c)
        return c
    }

    private func baseParagraph(styleId: String?) -> (ParaProps, CharProps, XMLElement?) {
        var p = ParaProps()
        p.alignment = .left
        p.lineSpacing = .multiple(1)
        apply(pPr: defaultPPr, to: &p)
        var c = baseChar()
        var numPr = defaultPPr?.child("numPr")
        for s in chain(styleId ?? defaultParaStyle) {
            apply(pPr: s.pPr, to: &p)
            apply(rPr: s.rPr, to: &c)
            if let n = s.pPr?.child("numPr") { numPr = n }
        }
        let sid = styleId ?? defaultParaStyle ?? ""
        p.styleName = DOCXWriter.styleIDs.first { $0.value.id == sid }?.key ?? styles[sid]?.name
        return (p, c, numPr)
    }

    private func listLabel(numPr: XMLElement?) -> String? {
        guard let numPr, let numId = numPr.child("numId")?.attr("val"), numId != "0",
              let abs = numToAbstract[numId], let levels = abstractLevels[abs] else { return nil }
        let ilvl = numPr.child("ilvl")?.attrInt("val") ?? 0
        guard let lvl = levels[ilvl] else { return nil }
        var c = counters[abs] ?? [:]
        c[ilvl] = (c[ilvl] ?? (lvl.start - 1)) + 1
        for k in c.keys where k > ilvl { c[k] = nil }
        counters[abs] = c
        if lvl.fmt == "bullet" {
            let ch = lvl.text.unicodeScalars.first.map { $0.value >= 0xE000 && $0.value <= 0xF8FF ? "•" : String($0) } ?? "•"
            return ch
        }
        if lvl.fmt == "none" { return lvl.text.isEmpty ? nil : lvl.text }
        var text = lvl.text
        for k in 0...8 {
            let token = "%\(k + 1)"
            guard text.contains(token) else { continue }
            let value = c[k] ?? (levels[k]?.start ?? 1)
            text = text.replacingOccurrences(of: token, with: NumberFormat.format(value, levels[k]?.fmt ?? "decimal"))
        }
        return text
    }

    // MARK: Body

    private func paragraph(_ el: XMLElement) -> [Block] {
        let pPr = el.child("pPr")
        let (base, styleChar, styleNum) = baseParagraph(styleId: pPr?.child("pStyle")?.attr("val"))
        var props = base
        apply(pPr: pPr, to: &props)
        var markProps = styleChar
        apply(rPr: pPr?.child("rPr"), to: &markProps)

        var para = Paragraph(props: props, inlines: [], markProps: markProps)
        var extra: [Block] = []
        // Complex fields: instruction text between begin/separate, result
        // between separate/end. Page fields become live fields; the cached
        // result text is dropped.
        struct FieldState { var inCode = true; var instr = ""; var skipResult = false }
        var fields: [FieldState] = []
        var hidden: Bool { fields.contains { $0.inCode || $0.skipResult } }
        func pageField(_ instr: String) -> FieldKind? {
            let words = instr.uppercased().split(whereSeparator: { !$0.isLetter })
            if words.first == "PAGE" { return .page }
            if words.first == "NUMPAGES" || words.first == "SECTIONPAGES" { return .pageCount }
            return nil
        }

        if let label = listLabel(numPr: pPr?.child("numPr") ?? styleNum) {
            para.props.listLabel = label
            para.inlines.append(.text(label + "\t", markProps))
        }

        func runs(_ container: XMLElement) {
            for c in container.elementChildren {
                switch c.local {
                case "r": run(c)
                case "fldSimple":
                    if let k = pageField(c.attr("instr") ?? "") {
                        var cp = styleChar
                        apply(rPr: c.first("rPr"), to: &cp)
                        append(.field(k, cp))
                    } else {
                        runs(c)
                    }
                case "hyperlink", "ins", "smartTag", "customXml", "moveTo", "bdo", "dir":
                    runs(c)
                case "sdt": if let content = c.child("sdtContent") { runs(content) }
                case "AlternateContent":
                    if let choice = c.child("Choice") ?? c.child("Fallback") { runs(choice) }
                default: break
                }
            }
        }

        func run(_ r: XMLElement) {
            var cp = styleChar
            let rPr = r.child("rPr")
            if let rs = rPr?.child("rStyle")?.attr("val") { for s in chain(rs) { apply(rPr: s.rPr, to: &cp) } }
            apply(rPr: rPr, to: &cp)
            for c in r.elementChildren {
                switch c.local {
                case "fldChar":
                    switch c.attr("fldCharType") {
                    case "begin": fields.append(FieldState())
                    case "separate", "end":
                        guard var f = fields.popLast() else { break }
                        if f.inCode, let k = pageField(f.instr) { append(.field(k, cp)); f.skipResult = true }
                        f.inCode = false
                        if c.attr("fldCharType") == "separate" { fields.append(f) }
                    default: break
                    }
                case "instrText":
                    if !fields.isEmpty { fields[fields.count - 1].instr += c.stringValue ?? "" }
                case "t":
                    if hidden { continue }
                    let s = c.stringValue ?? ""
                    if !s.isEmpty { append(.text(s, cp)) }
                case "tab": if !hidden { append(.tab(cp)) }
                case "br":
                    if c.attr("type") == "page" { append(.pageBreak) }
                    else if c.attr("type") != "column" { append(.lineBreak(cp)) }
                case "cr": append(.lineBreak(cp))
                case "noBreakHyphen": append(.text("-", cp))
                case "sym":
                    if let h = c.attr("char"), let v = UInt32(h, radix: 16) {
                        let scalar = v >= 0xF000 && v <= 0xF0FF ? UnicodeScalar(v - 0xF000) : UnicodeScalar(v)
                        if let s = scalar { append(.text(v >= 0xF000 ? "•" : String(Character(s)), cp)) }
                    }
                case "drawing": drawing(c)
                case "pict", "object": vml(c)
                case "AlternateContent":
                    if let choice = c.child("Choice") {
                        if choice.first("drawing") != nil { drawing(choice) } else { vml(choice) }
                    } else if let fb = c.child("Fallback") { vml(fb) }
                default: break
                }
            }
        }

        func append(_ i: Inline) {
            if case .text(let s, let p) = i, case .text(let prev, let pp)? = para.inlines.last, pp == p {
                para.inlines[para.inlines.count - 1] = .text(prev + s, p)
            } else {
                para.inlines.append(i)
            }
        }

        func drawing(_ d: XMLElement) {
            let extent = d.first("extent")
            let w = Units.emu(extent?.attrDouble("cx") ?? 0), h = Units.emu(extent?.attrDouble("cy") ?? 0)
            if let blip = d.first("blip"), let id = blip.attr("embed"), let key = image(rel: id) {
                append(.image(id: key, width: w, height: h))
            }
            if let box = d.first("txbxContent") { extra.append(contentsOf: blocks(in: box)) }
        }

        func vml(_ v: XMLElement) {
            if let img = v.first("imagedata"), let id = img.attr("id"), let key = image(rel: id) {
                var w = 0.0, h = 0.0
                if let style = v.first("shape")?.attr("style") {
                    for part in style.split(separator: ";") {
                        let kv = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                        guard kv.count == 2, kv[1].hasSuffix("pt"), let n = Double(kv[1].dropLast(2)) else { continue }
                        if kv[0] == "width" { w = n } else if kv[0] == "height" { h = n }
                    }
                }
                append(.image(id: key, width: w, height: h))
            }
            if let box = v.first("txbxContent") { extra.append(contentsOf: blocks(in: box)) }
        }

        runs(el)
        return [.paragraph(para)] + extra
    }

    private func blocks(in container: XMLElement) -> [Block] {
        var out: [Block] = []
        for c in container.elementChildren {
            switch c.local {
            case "p": out.append(contentsOf: paragraph(c))
            case "tbl": out.append(.table(table(c)))
            case "sdt": if let content = c.child("sdtContent") { out.append(contentsOf: blocks(in: content)) }
            case "customXml": out.append(contentsOf: blocks(in: c))
            default: break
            }
        }
        return out
    }

    private func image(rel: String) -> String? {
        guard let path = rels[rel] else { return nil }
        if doc.images[path] != nil { return path }
        guard let data = zip.read(path) else { return nil }
        doc.images[path] = ImageData(name: (path as NSString).lastPathComponent, data: data)
        return path
    }

    private static func border(_ e: XMLElement?) -> BorderLine? {
        guard let e else { return nil }
        let v = e.attr("val") ?? "single"
        if v == "nil" || v == "none" { return BorderLine.none }
        let style: BorderStyle
        switch v {
        case "double", "triple", "thinThickSmallGap", "thickThinSmallGap", "thinThickMediumGap", "thickThinMediumGap": style = .double
        case "dotted", "dotDash", "dotDotDash": style = .dotted
        case "dashed", "dashSmallGap", "dashDotStroked": style = .dashed
        default: style = .solid
        }
        let w = max(0.25, (e.attrDouble("sz") ?? 4) / 8)
        let c = e.attr("color").flatMap { $0 == "auto" ? nil : RGB(hex: $0) } ?? .black
        return BorderLine(style: style, width: w, color: c)
    }

    private struct EdgeSet { var top, left, bottom, right, insideH, insideV: BorderLine? }

    private static func edges(_ e: XMLElement?) -> EdgeSet {
        EdgeSet(top: border(e?.child("top")), left: border(e?.child("left") ?? e?.child("start")),
                bottom: border(e?.child("bottom")), right: border(e?.child("right") ?? e?.child("end")),
                insideH: border(e?.child("insideH")), insideV: border(e?.child("insideV")))
    }

    private static func margins(_ e: XMLElement?, base: Insets) -> Insets {
        guard let e else { return base }
        func v(_ names: [String], _ d: Double) -> Double {
            for n in names { if let x = e.child(n)?.attrDouble("w") { return Units.twips(x) } }
            return d
        }
        return Insets(left: v(["left", "start"], base.left), right: v(["right", "end"], base.right),
                      top: v(["top"], base.top), bottom: v(["bottom"], base.bottom))
    }

    private func table(_ el: XMLElement) -> Table {
        var t = Table()
        let tblPr = el.child("tblPr")
        // Table-level borders/margins: table style chain first, then direct.
        var tableEdges = EdgeSet(top: nil, left: nil, bottom: nil, right: nil, insideH: nil, insideV: nil)
        var cellMargins = Insets.wordDefault
        func merge(_ e: EdgeSet) {
            tableEdges.top = e.top ?? tableEdges.top; tableEdges.left = e.left ?? tableEdges.left
            tableEdges.bottom = e.bottom ?? tableEdges.bottom; tableEdges.right = e.right ?? tableEdges.right
            tableEdges.insideH = e.insideH ?? tableEdges.insideH; tableEdges.insideV = e.insideV ?? tableEdges.insideV
        }
        for st in chain(tblPr?.child("tblStyle")?.attr("val")) {
            merge(DOCXReader.edges(st.tblPr?.child("tblBorders")))
            cellMargins = DOCXReader.margins(st.tblPr?.child("tblCellMar"), base: cellMargins)
        }
        merge(DOCXReader.edges(tblPr?.child("tblBorders")))
        cellMargins = DOCXReader.margins(tblPr?.child("tblCellMar"), base: cellMargins)

        t.columnWidths = el.child("tblGrid")?.children("gridCol").map { Units.twips($0.attrDouble("w") ?? 1440) } ?? []
        var rows: [[TableCell]] = []
        var cellEdges: [[EdgeSet?]] = []
        // Origin cell (row, slot index) per grid column for vertical merges.
        var origin: [Int: (row: Int, idx: Int)] = [:]
        for tr in el.children("tr") {
            var row: [TableCell] = []
            var rowEdges: [EdgeSet?] = []
            var col = 0
            let trPr = tr.child("trPr")
            let rowHeight = trPr?.child("trHeight")?.attrDouble("val").map(Units.twips)
            if let before = trPr?.child("gridBefore")?.attrInt("val") {
                for _ in 0..<before {
                    var e = TableCell(blocks: [.paragraph(Paragraph())]); e.borders = .none
                    row.append(e); rowEdges.append(nil); col += 1
                }
            }
            var cellEls: [XMLElement] = []
            for c in tr.elementChildren {
                if c.local == "tc" { cellEls.append(c) }
                else if c.local == "sdt", let content = c.child("sdtContent") { cellEls.append(contentsOf: content.children("tc")) }
            }
            for tc in cellEls {
                let pr = tc.child("tcPr")
                let span = max(1, pr?.child("gridSpan")?.attrInt("val") ?? 1)
                let vm = pr?.child("vMerge")
                var cell = TableCell(blocks: blocks(in: tc), colSpan: span)
                if cell.blocks.isEmpty { cell.blocks = [.paragraph(Paragraph())] }
                if let w = pr?.child("tcW"), w.attr("type") == "dxa" || w.attr("type") == nil, let v = w.attrDouble("w") { cell.width = Units.twips(v) }
                if let fill = pr?.child("shd")?.attr("fill"), fill != "auto", let rgb = RGB(hex: fill) { cell.background = rgb }
                cell.padding = DOCXReader.margins(pr?.child("tcMar"), base: cellMargins)
                switch pr?.child("vAlign")?.attr("val") {
                case "center": cell.verticalAlign = .center
                case "bottom": cell.verticalAlign = .bottom
                default: cell.verticalAlign = .top
                }
                if let h = rowHeight { cell.height = h }
                if vm != nil && vm?.attr("val") != "restart", let o = origin[col], o.row < rows.count {
                    cell.isMergedAway = true
                    rows[o.row][o.idx].rowSpan += 1
                    rows[o.row][o.idx].height = nil
                } else if vm?.attr("val") == "restart" {
                    origin[col] = (rows.count, row.count)
                } else {
                    origin[col] = nil
                }
                rowEdges.append(DOCXReader.edges(pr?.child("tcBorders")))
                row.append(cell)
                for _ in 1..<span { var m = TableCell(); m.isMergedAway = true; row.append(m); rowEdges.append(nil) }
                col += span
            }
            rows.append(row)
            cellEdges.append(rowEdges)
        }
        // Normalise: every row gets exactly columnCount slots.
        let cols = max(t.columnWidths.count, rows.map(\.count).max() ?? 0)
        for i in rows.indices where rows[i].count < cols {
            for _ in rows[i].count..<cols {
                var e = TableCell(blocks: [.paragraph(Paragraph())]); e.borders = .none
                rows[i].append(e); cellEdges[i].append(nil)
            }
        }
        // Resolve each cell's four edges: cell override, else the table's
        // outer edge on the boundary or its inside line in the interior.
        for r in rows.indices {
            for c in rows[r].indices where !rows[r][c].isMergedAway {
                let span = rows[r][c].colSpan, rs = rows[r][c].rowSpan
                let own = c < cellEdges[r].count ? cellEdges[r][c] : nil
                let none = BorderLine.none
                rows[r][c].borders = CellBorders(
                    left: own?.left ?? (c == 0 ? tableEdges.left : tableEdges.insideV) ?? none,
                    right: own?.right ?? (c + span >= cols ? tableEdges.right : tableEdges.insideV) ?? none,
                    top: own?.top ?? (r == 0 ? tableEdges.top : tableEdges.insideH) ?? none,
                    bottom: own?.bottom ?? (r + rs >= rows.count ? tableEdges.bottom : tableEdges.insideH) ?? none)
            }
        }
        while t.columnWidths.count < cols { t.columnWidths.append(t.columnWidths.last ?? 72) }
        t.rows = rows
        return t
    }

    private func section(_ sp: XMLElement, _ body: [Block]) -> Section {
        var s = Section(page: page(sp), blocks: body)
        func part(_ kind: String) -> [Block]? {
            let refs = sp.children(kind + "Reference")
            guard let ref = refs.first(where: { $0.attr("type") == "default" }) ?? refs.first,
                  let rid = ref.relAttr("id"), let path = rels[rid], let x = zip.xml(path)?.rootElement() else {
                return doc.sections.last.flatMap { kind == "header" ? $0.header : $0.footer }
            }
            return blocks(in: x)
        }
        s.header = part("header")
        s.footer = part("footer")
        return s
    }

    private func page(_ sp: XMLElement) -> PageSetup {
        var p = PageSetup.letterWord
        if let sz = sp.child("pgSz") {
            if let w = sz.attrDouble("w") { p.width = Units.twips(w) }
            if let h = sz.attrDouble("h") { p.height = Units.twips(h) }
        }
        if let m = sp.child("pgMar") {
            if let v = m.attrDouble("top") { p.marginTop = abs(Units.twips(v)) }
            if let v = m.attrDouble("bottom") { p.marginBottom = abs(Units.twips(v)) }
            if let v = m.attrDouble("left") { p.marginLeft = Units.twips(v) }
            if let v = m.attrDouble("right") { p.marginRight = Units.twips(v) }
            if let v = m.attrDouble("header") { p.header = Units.twips(v) }
            if let v = m.attrDouble("footer") { p.footer = Units.twips(v) }
        }
        return p
    }
}

enum NumberFormat {
    static func format(_ n: Int, _ fmt: String) -> String {
        switch fmt {
        case "lowerLetter": return letters(n).lowercased()
        case "upperLetter": return letters(n)
        case "lowerRoman": return roman(n).lowercased()
        case "upperRoman": return roman(n)
        case "ganada", "koreanCounting":
            let g = Array("가나다라마바사아자차카타파하")
            return String(g[(max(1, n) - 1) % g.count])
        case "chosung":
            let g = Array("ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ")
            return String(g[(max(1, n) - 1) % g.count])
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese":
            return n >= 1 && n <= 20 ? String(UnicodeScalar(0x2460 + n - 1)!) : "\(n)"
        default: return "\(n)"
        }
    }

    static func letters(_ n: Int) -> String {
        var n = max(1, n), s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = max(1, n), s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }
}
