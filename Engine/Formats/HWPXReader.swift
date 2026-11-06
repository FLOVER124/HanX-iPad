import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HWPX / OWPML (KS X 6101) reader. Same logical model as HWP 5.0 — shared
/// charPr/paraPr tables in Contents/header.xml, referenced by ID from
/// Contents/sectionN.xml — but serialised as XML in a ZIP package.
final class HWPXReader {
    private let zip: ZipReader
    private let doc = UDocument()
    private var fonts: [String: [String: String]] = [:]     // lang → id → face
    private var charPrs: [String: CharProps] = [:]
    private var paraPrs: [String: (ParaProps, bullet: String?)] = [:]
    private var bullets: [String: String] = [:]
    private var fills: [String: RGB] = [:]
    private var borders: [String: CellBorders] = [:]
    private var styleNames: [String: String] = [:]
    private var manifest: [String: String] = [:]             // item id → href
    private var sectionPage: PageSetup?
    private var sectionHeader: [Block]?
    private var sectionFooter: [Block]?

    init(zip: ZipReader) { self.zip = zip }

    func read() throws -> UDocument {
        doc.source = .hwpx
        loadManifest()
        guard let header = zip.xml("Contents/header.xml")?.rootElement() else { throw FormatError.invalid("Contents/header.xml 없음") }
        loadHeader(header)

        var sectionFiles = manifest.values.filter { $0.lowercased().contains("section") && $0.hasSuffix(".xml") }
        if sectionFiles.isEmpty { sectionFiles = zip.order.filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") } }
        sectionFiles.sort { a, b in
            let na = Int(a.filter(\.isNumber)) ?? 0, nb = Int(b.filter(\.isNumber)) ?? 0
            return na < nb
        }
        for f in sectionFiles {
            let path = f.hasPrefix("Contents/") ? f : "Contents/" + f
            guard let sec = (zip.xml(path) ?? zip.xml(f))?.rootElement() else { continue }
            sectionPage = nil
            sectionHeader = nil; sectionFooter = nil
            let blocks = sec.children("p").flatMap(paragraph)
            var section = Section(page: sectionPage ?? doc.sections.last?.page ?? .a4Hwp, blocks: blocks)
            section.header = sectionHeader ?? doc.sections.last?.header
            section.footer = sectionFooter ?? doc.sections.last?.footer
            doc.sections.append(section)
        }
        if doc.sections.isEmpty { throw FormatError.invalid("HWPX 섹션 없음") }
        return doc
    }

    private func loadManifest() {
        guard let hpf = zip.xml("Contents/content.hpf")?.rootElement() else { return }
        for item in hpf.all("item") {
            if let id = item.attr("id"), let href = item.attr("href") { manifest[id] = href }
        }
    }

    private func loadHeader(_ h: XMLElement) {
        for ff in h.all("fontface") {
            let lang = ff.attr("lang") ?? "HANGUL"
            var map: [String: String] = [:]
            for f in ff.children("font") { if let id = f.attr("id"), let face = f.attr("face") { map[id] = face } }
            fonts[lang] = map
        }
        for b in h.all("borderFill") {
            guard let id = b.attr("id") else { continue }
            func line(_ name: String) -> BorderLine {
                guard let e = b.child(name) else { return .none }
                let t = e.attr("type") ?? "NONE"
                let style: BorderStyle
                switch t {
                case "NONE": style = .none
                case "SOLID": style = .solid
                case "DOT", "CIRCLE": style = .dotted
                case "DASH", "LONG_DASH", "DASH_DOT", "DASH_DOT_DOT": style = .dashed
                case "DOUBLE_SLIM", "SLIM_THICK", "THICK_SLIM", "SLIM_THICK_SLIM": style = .double
                default: style = .solid
                }
                let mm = Double((e.attr("width") ?? "0.12").split(separator: " ").first ?? "0.12") ?? 0.12
                return BorderLine(style: style, width: style == .none ? 0 : mm / 25.4 * 72, color: RGB(hex: e.attr("color") ?? "#000000") ?? .black)
            }
            borders[id] = CellBorders(left: line("leftBorder"), right: line("rightBorder"), top: line("topBorder"), bottom: line("bottomBorder"))
            if let wb = b.first("winBrush"), let c = wb.attr("faceColor"), c.lowercased() != "none", let rgb = RGB(hex: c),
               rgb != RGB(r: 255, g: 255, b: 255) { fills[id] = rgb }
        }
        for b in h.all("bullet") { if let id = b.attr("id") { bullets[id] = b.attr("char") ?? "•" } }
        for s in h.all("style") { if let id = s.attr("id") { styleNames[id] = s.attr("name") } }
        for c in h.all("charPr") {
            guard let id = c.attr("id") else { continue }
            var p = CharProps()
            let rel = (c.child("relSz")?.attrDouble("hangul") ?? 100) / 100
            p.size = max(1, (c.attrDouble("height") ?? 1000) / 100 * (rel > 0 ? rel : 1))
            if let tc = c.attr("textColor"), let rgb = RGB(hex: tc) { p.color = rgb }
            if let sc = c.attr("shadeColor"), sc.lowercased() != "none", let rgb = RGB(hex: sc), rgb != RGB(r: 255, g: 255, b: 255) { p.highlight = rgb }
            if let fr = c.child("fontRef") {
                let hangul = fr.attr("hangul").flatMap { fonts["HANGUL"]?[$0] }
                let latin = fr.attr("latin").flatMap { fonts["LATIN"]?[$0] }
                p.fontName = latin ?? hangul ?? p.fontName
                p.eastAsianFontName = hangul
            }
            p.bold = c.child("bold") != nil
            p.italic = c.child("italic") != nil
            if let u = c.child("underline"), let t = u.attr("type"), t != "NONE" {
                switch u.attr("shape") ?? "SOLID" {
                case "DASH", "LONG_DASH", "DASH_DOT", "DASH_DOT_DOT": p.underline = .dashed
                case "DOT", "CIRCLE": p.underline = .dotted
                case "DOUBLE_SLIM", "SLIM_THICK", "THICK_SLIM", "SLIM_THICK_SLIM": p.underline = .double
                case "WAVE", "DOUBLE_WAVE": p.underline = .wave
                default: p.underline = .single
                }
            }
            if let s = c.child("strikeout"), let shape = s.attr("shape"), shape != "NONE", shape != "3D" { p.strike = true }
            if c.child("supscript") != nil { p.verticalAlign = .superscript }
            if c.child("subscript") != nil { p.verticalAlign = .subscript }
            if let sp = c.child("spacing")?.attrDouble("hangul") { p.spacing = p.size * sp / 100 }
            if let ra = c.child("ratio")?.attrDouble("hangul"), ra > 0 { p.widthRatio = ra }
            charPrs[id] = p
        }
        for pp in h.all("paraPr") {
            guard let id = pp.attr("id") else { continue }
            var p = ParaProps()
            switch pp.child("align")?.attr("horizontal") ?? "JUSTIFY" {
            case "LEFT": p.alignment = .left
            case "RIGHT": p.alignment = .right
            case "CENTER": p.alignment = .center
            case "DISTRIBUTE", "DISTRIBUTE_SPACE": p.alignment = .distribute
            default: p.alignment = .justify
            }
            // Values may sit directly under paraPr or inside hp:switch; the
            // hp:default branch carries plain HWPUNIT values.
            let scope = pp.first("default") ?? pp
            if let m = scope.first("margin") ?? pp.first("margin") {
                p.firstLine = Units.hwp(Int32(m.child("intent")?.attrInt("value") ?? 0)) / 2
                p.indentLeft = Units.hwp(Int32(m.child("left")?.attrInt("value") ?? 0)) / 2
                p.indentRight = Units.hwp(Int32(m.child("right")?.attrInt("value") ?? 0)) / 2
                p.spaceBefore = Units.hwp(Int32(m.child("prev")?.attrInt("value") ?? 0)) / 2
                p.spaceAfter = Units.hwp(Int32(m.child("next")?.attrInt("value") ?? 0)) / 2
                if p.firstLine < 0 { p.indentLeft -= p.firstLine }
            }
            if let ls = scope.first("lineSpacing") ?? pp.first("lineSpacing") {
                let v = ls.attrDouble("value") ?? 160
                switch ls.attr("type") ?? "PERCENT" {
                case "FIXED": p.lineSpacing = .exact(v / 100 / 2)
                case "AT_LEAST": p.lineSpacing = .atLeast(v / 100 / 2)
                case "BETWEEN_LINES": p.lineSpacing = .percentOfSize(160)
                default: p.lineSpacing = .percentOfSize(v)
                }
            }
            var bullet: String?
            if let hd = pp.child("heading"), hd.attr("type") == "BULLET", let ref = hd.attr("idRef") { bullet = bullets[ref] ?? "•" }
            paraPrs[id] = (p, bullet)
        }
    }

    private func paragraph(_ el: XMLElement) -> [Block] {
        var props = ParaProps()
        var bullet: String?
        if let id = el.attr("paraPrIDRef"), let pp = paraPrs[id] { props = pp.0; bullet = pp.bullet }
        if let s = el.attr("styleIDRef") { props.styleName = styleNames[s] }
        if el.attr("pageBreak") == "1" { props.pageBreakBefore = true }

        var blocks: [Block] = []
        let firstRunProps = el.child("run").flatMap { $0.attr("charPrIDRef") }.flatMap { charPrs[$0] } ?? CharProps()
        var para = Paragraph(props: props, inlines: [], markProps: firstRunProps)
        var split = false
        if let b = bullet { para.inlines.append(.text(b + " ", firstRunProps)); para.props.listLabel = b }

        func flush() {
            blocks.append(.paragraph(para))
            para = Paragraph(props: props, inlines: [], markProps: para.markProps)
            para.props.pageBreakBefore = false
        }

        for run in el.children("run") {
            let cp = run.attr("charPrIDRef").flatMap { charPrs[$0] } ?? CharProps()
            for c in run.elementChildren {
                switch c.local {
                case "secPr":
                    if let pg = c.child("pagePr") { sectionPage = page(pg) }
                case "ctrl":
                    for e in c.elementChildren {
                        switch e.local {
                        case "header", "footer":
                            let content = e.child("subList")?.children("p").flatMap(paragraph) ?? []
                            let both = (e.attr("applyPageType") ?? "BOTH") == "BOTH"
                            if e.local == "header" { if sectionHeader == nil || both { sectionHeader = content } }
                            else if sectionFooter == nil || both { sectionFooter = content }
                        case "pageNum":
                            let pos = e.attr("pos") ?? "BOTTOM_CENTER"
                            guard pos != "NONE" else { break }
                            var pn = Paragraph()
                            pn.markProps = cp
                            pn.props.alignment = pos.hasSuffix("LEFT") ? .left : pos.hasSuffix("RIGHT") ? .right : .center
                            let side = e.attr("sideChar") ?? ""
                            if !side.isEmpty { pn.inlines.append(.text(side + " ", cp)) }
                            pn.inlines.append(.field(.page, cp))
                            if !side.isEmpty { pn.inlines.append(.text(" " + side, cp)) }
                            if pos.hasPrefix("TOP") { sectionHeader = (sectionHeader ?? []) + [.paragraph(pn)] }
                            else { sectionFooter = (sectionFooter ?? []) + [.paragraph(pn)] }
                        case "autoNum":
                            if (e.attr("numType") ?? "PAGE") == "PAGE" { para.inlines.append(.field(.page, cp)) }
                        default: break
                        }
                    }
                case "t":
                    for n in c.children ?? [] {
                        if n.kind == .text, let s = n.stringValue, !s.isEmpty { para.inlines.append(.text(s, cp)) }
                        else if let e = n as? XMLElement {
                            switch e.local {
                            case "tab": para.inlines.append(.tab(cp))
                            case "lineBreak": para.inlines.append(.lineBreak(cp))
                            case "nbSpace": para.inlines.append(.text("\u{00A0}", cp))
                            case "fwSpace": para.inlines.append(.text(" ", cp))
                            case "hyphen": para.inlines.append(.text("-", cp))
                            default: break
                            }
                        }
                    }
                case "tbl":
                    if !para.inlines.isEmpty { flush() }
                    blocks.append(.table(table(c)))
                    split = true
                case "pic":
                    if let img = picture(c) { para.inlines.append(img) }
                case "container", "rect", "ellipse", "polygon", "curve", "arc":
                    for p in c.all("pic") { if let img = picture(p) { para.inlines.append(img) } }
                    let boxes = c.all("subList").flatMap { $0.children("p").flatMap(paragraph) }
                    if !boxes.isEmpty {
                        if !para.inlines.isEmpty { flush() }
                        blocks.append(contentsOf: boxes)
                        split = true
                    }
                default: break
                }
            }
        }
        if !para.inlines.isEmpty || !split { blocks.append(.paragraph(para)) }
        return blocks
    }

    private func picture(_ el: XMLElement) -> Inline? {
        guard let ref = el.first("img")?.attr("binaryItemIDRef") else { return nil }
        let href = manifest[ref] ?? "BinData/\(ref)"
        let key = href
        if doc.images[key] == nil {
            let candidates = [href, "Contents/" + href] + zip.order.filter { ($0 as NSString).deletingPathExtension.hasSuffix("/" + ref) }
            guard let data = candidates.lazy.compactMap({ self.zip.read($0) }).first else { return nil }
            doc.images[key] = ImageData(name: (href as NSString).lastPathComponent, data: data)
        }
        let sz = el.child("curSz") ?? el.child("sz")
        var w = Units.hwp(Int32(sz?.attrInt("width") ?? 0)), h = Units.hwp(Int32(sz?.attrInt("height") ?? 0))
        if w <= 0 || h <= 0, let s2 = el.child("sz") { w = Units.hwp(Int32(s2.attrInt("width") ?? 0)); h = Units.hwp(Int32(s2.attrInt("height") ?? 0)) }
        return .image(id: key, width: w, height: h)
    }

    private func table(_ el: XMLElement) -> Table {
        let rows = el.attrInt("rowCnt") ?? el.children("tr").count
        var cols = el.attrInt("colCnt") ?? 0
        struct Raw { var row, col, rs, cs: Int; var w: Double; var fill: RGB?; var blocks: [Block]; var cell: TableCell }
        var raws: [Raw] = []
        for (ri, tr) in el.children("tr").enumerated() {
            var ci = 0
            for tc in tr.children("tc") {
                let addr = tc.child("cellAddr")
                let span = tc.child("cellSpan")
                let r = addr?.attrInt("rowAddr") ?? ri, c = addr?.attrInt("colAddr") ?? ci
                let cs = max(1, span?.attrInt("colSpan") ?? 1), rs = max(1, span?.attrInt("rowSpan") ?? 1)
                let w = Units.hwp(Int32(tc.child("cellSz")?.attrInt("width") ?? 0))
                var blocks = tc.child("subList")?.children("p").flatMap(paragraph) ?? []
                if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
                var meta = TableCell()
                let bfRef = tc.attr("borderFillIDRef") ?? ""
                meta.borders = borders[bfRef] ?? .all
                if let h = tc.child("cellSz")?.attrInt("height"), h > 0 { meta.height = Units.hwp(Int32(h)) }
                if let m = tc.child("cellMargin") {
                    func v(_ k: String) -> Double { Units.hwp(Int32(m.attrInt(k) ?? 0)) }
                    meta.padding = Insets(left: v("left"), right: v("right"), top: v("top"), bottom: v("bottom"))
                }
                switch tc.child("subList")?.attr("vertAlign") ?? "TOP" {
                case "CENTER": meta.verticalAlign = .center
                case "BOTTOM": meta.verticalAlign = .bottom
                default: meta.verticalAlign = .top
                }
                raws.append(Raw(row: r, col: c, rs: rs, cs: cs, w: w, fill: fills[bfRef], blocks: blocks, cell: meta))
                ci = c + cs
            }
        }
        cols = max(cols, raws.map { $0.col + $0.cs }.max() ?? 0)
        let nrows = max(rows, raws.map { $0.row + $0.rs }.max() ?? 0)
        var grid = [[TableCell?]](repeating: [TableCell?](repeating: nil, count: cols), count: nrows)
        var widths = [Double](repeating: 0, count: cols)
        for r in raws where r.row < nrows && r.col < cols {
            var cell = r.cell
            cell.blocks = r.blocks; cell.colSpan = r.cs; cell.rowSpan = r.rs; cell.width = r.w; cell.background = r.fill
            grid[r.row][r.col] = cell
            for rr in r.row..<min(nrows, r.row + r.rs) {
                for cc in r.col..<min(cols, r.col + r.cs) where !(rr == r.row && cc == r.col) {
                    var m = TableCell(); m.isMergedAway = true; grid[rr][cc] = m
                }
            }
            if r.cs == 1 && widths[r.col] == 0 { widths[r.col] = r.w }
        }
        for r in raws where r.cs > 1 && r.col + r.cs <= cols {
            let unknown = (r.col..<(r.col + r.cs)).filter { widths[$0] == 0 }
            let known = (r.col..<(r.col + r.cs)).reduce(0.0) { $0 + widths[$1] }
            for k in unknown { widths[k] = max(0, r.w - known) / Double(unknown.count) }
        }
        var t = Table()
        t.columnWidths = widths.map { $0 > 0 ? $0 : 60 }
        t.rows = grid.map { $0.map { $0 ?? TableCell(blocks: [.paragraph(Paragraph())]) } }
        return t
    }

    private func page(_ pg: XMLElement) -> PageSetup {
        var p = PageSetup()
        let w = Units.hwp(Int32(pg.attrInt("width") ?? 59528)), h = Units.hwp(Int32(pg.attrInt("height") ?? 84188))
        let landscape = pg.attr("landscape") == "NARROWLY"
        p.width = landscape ? max(w, h) : w
        p.height = landscape ? min(w, h) : h
        if let m = pg.child("margin") {
            func v(_ k: String) -> Double { Units.hwp(Int32(m.attrInt(k) ?? 0)) }
            p.header = v("header"); p.footer = v("footer")
            p.marginLeft = v("left") + v("gutter"); p.marginRight = v("right")
            p.marginTop = v("top") + p.header; p.marginBottom = v("bottom") + p.footer
        }
        return p
    }
}
