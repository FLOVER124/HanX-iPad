import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HWP 5.0 binary reader, written from Hancom's public "한글 문서 파일 형식 5.0"
/// specification. Structure (confirmed in HwpMac2014's storage names):
///   FileHeader | DocInfo | BodyText/SectionN | BinData/BINxxxx.ext
/// DocInfo and sections are record streams, raw-deflated when FileHeader
/// bit 0 is set. Records nest by an explicit level field.
enum HWPTag {
    static let begin: UInt16 = 16
    static let idMappings: UInt16 = 17, binData: UInt16 = 18, faceName: UInt16 = 19
    static let borderFill: UInt16 = 20, charShape: UInt16 = 21, numbering: UInt16 = 23
    static let bullet: UInt16 = 24, paraShape: UInt16 = 25, style: UInt16 = 26
    static let paraHeader: UInt16 = 66, paraText: UInt16 = 67, paraCharShape: UInt16 = 68
    static let paraLineSeg: UInt16 = 69, ctrlHeader: UInt16 = 71, listHeader: UInt16 = 72
    static let pageDef: UInt16 = 73, shapeComponent: UInt16 = 76, table: UInt16 = 77
    static let picture: UInt16 = 85
}

struct HWPRecord {
    let tag: UInt16
    let level: Int
    let data: [UInt8]

    static func parse(_ bytes: [UInt8]) -> [HWPRecord] {
        var out: [HWPRecord] = []
        var r = ByteReader(bytes)
        while r.remaining >= 4 {
            let h = r.u32()
            let tag = UInt16(h & 0x3FF)
            let level = Int((h >> 10) & 0x3FF)
            var size = Int(h >> 20)
            if size == 0xFFF { size = Int(r.u32()) }
            if size > r.remaining { size = r.remaining }
            out.append(HWPRecord(tag: tag, level: level, data: r.bytes(size)))
        }
        return out
    }
}

final class HWPNode {
    let rec: HWPRecord
    var children: [HWPNode] = []
    init(_ r: HWPRecord) { rec = r }

    var tag: UInt16 { rec.tag }

    static func tree(_ records: [HWPRecord]) -> [HWPNode] {
        var roots: [HWPNode] = []
        var stack: [HWPNode] = []
        for r in records {
            let n = HWPNode(r)
            while let last = stack.last, last.rec.level >= r.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(n) } else { roots.append(n) }
            stack.append(n)
        }
        return roots
    }

    func descendants(_ tag: UInt16) -> [HWPNode] {
        var out: [HWPNode] = []
        for c in children {
            if c.tag == tag { out.append(c) }
            out.append(contentsOf: c.descendants(tag))
        }
        return out
    }

    /// 4-char control id ('tbl ', 'gso ', 'secd', …) of a CTRL_HEADER.
    var ctrlId: String {
        let v = ByteReader.u32(rec.data, 0)
        let b = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: b, as: UTF8.self)
    }
}

final class HWP5Reader {
    private let cfb: CFBReader
    private var compressed = false
    private var version: UInt32 = 0

    private var faceNames: [[String]] = Array(repeating: [], count: 7)
    private var charShapes: [CharProps] = []
    private var paraShapes: [(ParaProps, head: Int, bulletId: Int)] = []
    private var bullets: [String] = []
    private var borderFills: [(borders: CellBorders, fill: RGB?)] = []
    private var binItems: [(id: Int, ext: String, compress: Int)] = []
    private var styleNames: [String] = []

    private let doc = UDocument()
    private var sectionPage: PageSetup?
    private var sectionHeader: [Block]?
    private var sectionFooter: [Block]?

    init(data: Data) throws {
        cfb = try CFBReader(data: data)
    }

    func read() throws -> UDocument {
        doc.source = .hwp
        guard let header = cfb.stream("FileHeader"), header.count >= 40 else {
            throw FormatError.invalid("FileHeader 스트림 없음 — HWP 5.0 문서가 아닙니다")
        }
        let sig = String(decoding: header.prefix(17), as: UTF8.self)
        guard sig == "HWP Document File" else { throw FormatError.invalid("HWP 시그니처 불일치") }
        version = ByteReader.u32(header, 32)
        let props = ByteReader.u32(header, 36)
        compressed = props & 1 != 0
        if props & 2 != 0 { throw FormatError.unsupported("암호가 설정된 HWP 문서") }
        if props & 4 != 0 { throw FormatError.unsupported("배포용(읽기 전용 암호화) HWP 문서") }

        guard let docInfoRaw = cfb.stream("DocInfo") else { throw FormatError.invalid("DocInfo 없음") }
        parseDocInfo(HWPRecord.parse(try unpack(docInfoRaw)))

        var index = 0
        while let raw = cfb.stream("BodyText/Section\(index)") {
            let roots = HWPNode.tree(HWPRecord.parse(try unpack(raw)))
            sectionPage = nil
            sectionHeader = nil; sectionFooter = nil
            var blocks: [Block] = []
            for n in roots where n.tag == HWPTag.paraHeader { blocks.append(contentsOf: paragraph(n)) }
            var section = Section(page: sectionPage ?? doc.sections.last?.page ?? .a4Hwp, blocks: blocks)
            section.header = sectionHeader ?? doc.sections.last?.header
            section.footer = sectionFooter ?? doc.sections.last?.footer
            doc.sections.append(section)
            index += 1
        }
        if index == 0 { throw FormatError.invalid("BodyText 섹션 없음") }
        return doc
    }

    private func unpack(_ raw: [UInt8]) throws -> [UInt8] {
        compressed ? try Deflate.inflate(raw) : raw
    }

    // MARK: DocInfo

    private func parseDocInfo(_ records: [HWPRecord]) {
        var fontCounts = [Int](repeating: 0, count: 7)
        var faceIndex = 0
        for r in records {
            var b = ByteReader(r.data)
            switch r.tag {
            case HWPTag.idMappings:
                _ = b.i32()
                for i in 0..<7 { fontCounts[i] = Int(b.i32()) }
            case HWPTag.faceName:
                _ = b.u8()
                let name = b.utf16(Int(b.u16()))
                var lang = 0, acc = 0
                for i in 0..<7 { acc += fontCounts[i]; if faceIndex < acc { lang = i; break }; lang = 6 }
                faceNames[lang].append(name)
                faceIndex += 1
            case HWPTag.charShape:
                charShapes.append(parseCharShape(r.data))
            case HWPTag.paraShape:
                paraShapes.append(parseParaShape(r.data))
            case HWPTag.bullet:
                bullets.append(r.data.count >= 14 ? String(decoding: [ByteReader.u16(r.data, 12)], as: UTF16.self) : "•")
            case HWPTag.borderFill:
                borderFills.append(parseBorderFill(r.data))
            case HWPTag.binData:
                let attr = b.u16()
                let type = attr & 0xF
                if type == 0 {
                    binItems.append((0, "", 2))
                } else {
                    let id = Int(b.u16())
                    let ext = type == 1 ? b.utf16(Int(b.u16())) : "ole"
                    binItems.append((id, ext, Int((attr >> 4) & 3)))
                }
            case HWPTag.style:
                styleNames.append(b.utf16(Int(b.u16())))
            default: break
            }
        }
    }

    private func face(_ lang: Int, _ id: Int) -> String? {
        let list = faceNames[lang]
        return id < list.count ? list[id] : nil
    }

    private func parseCharShape(_ d: [UInt8]) -> CharProps {
        var r = ByteReader(d)
        let faces = (0..<7).map { _ in Int(r.u16()) }
        let ratios = (0..<7).map { _ in r.u8() }
        let spacings = (0..<7).map { _ in r.i8() }
        let relSizes = (0..<7).map { _ in r.u8() }
        r.skip(7)                                      // vertical offsets
        let base = r.i32()
        let attr = r.u32()
        r.skip(2)
        let color = r.u32()
        _ = r.u32()                                    // underline color
        let shade = r.u32()

        var p = CharProps()
        let hangul = face(0, faces[0]), latin = face(1, faces[1])
        p.fontName = latin ?? hangul ?? "함초롬바탕"
        p.eastAsianFontName = hangul
        let rel = relSizes[0] == 0 ? 100 : Double(relSizes[0])
        p.size = max(1, Double(base) / 100 * rel / 100)
        p.italic = attr & 1 != 0
        p.bold = attr & 2 != 0
        let ulKind = (attr >> 2) & 3
        if ulKind != 0 {
            switch (attr >> 4) & 0xF {
            case 1, 6: p.underline = .dashed
            case 2, 3, 5: p.underline = .dotted
            case 7, 8, 9: p.underline = .double
            case 10, 11: p.underline = .wave
            default: p.underline = .single
            }
        }
        p.strike = (attr >> 18) & 7 != 0
        if attr & (1 << 15) != 0 { p.verticalAlign = .superscript }
        if attr & (1 << 16) != 0 { p.verticalAlign = .subscript }
        p.color = RGB(colorref: color)
        if shade != 0xFFFF_FFFF && shade & 0xFFFFFF != 0xFFFFFF { p.highlight = RGB(colorref: shade) }
        p.spacing = p.size * Double(spacings[0]) / 100
        if ratios[0] > 0 { p.widthRatio = Double(ratios[0]) }
        return p
    }

    private func parseParaShape(_ d: [UInt8]) -> (ParaProps, head: Int, bulletId: Int) {
        var r = ByteReader(d)
        let attr1 = r.u32()
        let left = r.i32(), right = r.i32(), indent = r.i32()
        let prev = r.i32(), next = r.i32(), lineOld = r.i32()
        _ = r.u16()
        let numBullet = Int(r.u16())
        r.skip(2 + 8)
        _ = r.u32()                       // attr2
        let attr3 = r.u32()
        let lineNew = r.u32()

        var p = ParaProps()
        switch (attr1 >> 2) & 7 {
        case 1: p.alignment = .left
        case 2: p.alignment = .right
        case 3: p.alignment = .center
        case 4, 5: p.alignment = .distribute
        default: p.alignment = .justify
        }
        // Margins and paragraph spacing are stored doubled (pyhwp names them
        // doubled_margin_*); indent is stored as-is.
        p.indentLeft = Units.hwp(left) / 2
        p.indentRight = Units.hwp(right) / 2
        p.firstLine = Units.hwp(indent) / 2
        p.spaceBefore = Units.hwp(prev) / 2
        p.spaceAfter = Units.hwp(next) / 2
        // HWP 내어쓰기 indents the following lines past the left margin;
        // the unified model uses Word semantics (left = body lines).
        if p.firstLine < 0 { p.indentLeft -= p.firstLine }
        let newLayout = version >= 0x0500_0205 && d.count >= 54
        let kind = newLayout ? Int(attr3 & 0x1F) : Int(attr1 & 3)
        let value = newLayout ? Double(lineNew) : Double(lineOld)
        switch kind {
        case 1: p.lineSpacing = .exact(value / 100 / 2)
        case 2: p.lineSpacing = .percentOfSize(160)   // "여백만 지정" — approximate
        case 3: p.lineSpacing = .atLeast(value / 100 / 2)
        default: p.lineSpacing = .percentOfSize(value > 0 ? value : 160)
        }
        return (p, Int((attr1 >> 23) & 3), numBullet)
    }

    /// HWP line widths are an index into a fixed millimetre table.
    static let lineWidthsMM: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]

    static func borderLine(type: UInt8, width: UInt8, color: UInt32) -> BorderLine {
        let w = lineWidthsMM[Int(min(width, 15))] / 25.4 * 72
        let style: BorderStyle
        switch type {
        case 0: style = .none
        case 1: style = .solid
        case 2, 4, 5: style = .dashed
        case 3, 6: style = .dotted
        case 7, 8, 9, 10: style = .double
        default: style = .solid
        }
        return BorderLine(style: style, width: style == .none ? 0 : w, color: RGB(colorref: color))
    }

    private func parseBorderFill(_ d: [UInt8]) -> (CellBorders, RGB?) {
        func side(_ i: Int) -> BorderLine {
            let o = 2 + i * 6
            guard o + 5 < d.count else { return .none }
            return HWP5Reader.borderLine(type: d[o], width: d[o + 1], color: ByteReader.u32(d, o + 2))
        }
        let borders = CellBorders(left: side(0), right: side(1), top: side(2), bottom: side(3))
        guard d.count >= 40, ByteReader.u32(d, 32) & 1 != 0 else { return (borders, nil) }
        let c = ByteReader.u32(d, 36)
        if c == 0xFFFF_FFFF || c & 0xFFFFFF == 0xFFFFFF { return (borders, nil) }
        return (borders, RGB(colorref: c))
    }

    // MARK: Body

    private func charProps(_ id: Int) -> CharProps { id < charShapes.count ? charShapes[id] : CharProps() }

    /// One HWP paragraph can yield several blocks: tables and text boxes are
    /// controls anchored inside a paragraph, but blocks in the unified model.
    private func paragraph(_ node: HWPNode) -> [Block] {
        var hr = ByteReader(node.rec.data)
        _ = hr.u32()
        _ = hr.u32()
        let shapeId = Int(hr.u16())
        let styleId = Int(hr.u8())
        let breakType = hr.u8()

        var props = ParaProps()
        var listLabel: String?
        if shapeId < paraShapes.count {
            let ps = paraShapes[shapeId]
            props = ps.0
            if ps.head == 3, ps.bulletId >= 1, ps.bulletId <= bullets.count { listLabel = bullets[ps.bulletId - 1] }
        }
        if styleId < styleNames.count { props.styleName = styleNames[styleId] }
        if breakType & 0b101 != 0 { props.pageBreakBefore = true }

        var units: [UInt16] = []
        var shapeRuns: [(pos: Int, id: Int)] = []
        var controls: [HWPNode] = []
        for c in node.children {
            switch c.tag {
            case HWPTag.paraText:
                var r = ByteReader(c.rec.data)
                while r.remaining >= 2 { units.append(r.u16()) }
            case HWPTag.paraCharShape:
                var r = ByteReader(c.rec.data)
                while r.remaining >= 8 { shapeRuns.append((Int(r.u32()), Int(r.u32()))) }
            case HWPTag.ctrlHeader:
                controls.append(c)
            default: break
            }
        }
        if shapeRuns.isEmpty { shapeRuns = [(0, 0)] }
        func shapeAt(_ pos: Int) -> CharProps {
            var id = shapeRuns[0].id
            for s in shapeRuns where s.pos <= pos { id = s.id }
            return charProps(id)
        }

        var blocks: [Block] = []
        var current = Paragraph(props: props, inlines: [], markProps: shapeAt(0))
        var pending = ""
        var pendingProps = shapeAt(0)
        if let label = listLabel {
            current.inlines.append(.text(label + " ", pendingProps))
            current.props.listLabel = label
        }

        func flushText() {
            if !pending.isEmpty { current.inlines.append(.text(pending, pendingProps)); pending = "" }
        }
        func flushParagraph() {
            flushText()
            blocks.append(.paragraph(current))
            current = Paragraph(props: props, inlines: [], markProps: pendingProps)
            current.props.pageBreakBefore = false
        }

        var i = 0, ctrlIndex = 0
        var sawSplit = false
        while i < units.count {
            let u = units[i]
            let cp = shapeAt(i)
            if cp != pendingProps { flushText(); pendingProps = cp }
            switch u {
            case 13:
                i = units.count
                continue
            case 10:
                flushText(); current.inlines.append(.lineBreak(cp)); i += 1
            case 9:
                flushText(); current.inlines.append(.tab(cp)); i += 8
            case 24: pending += "-"; i += 1
            case 30: pending += "\u{00A0}"; i += 1
            case 31: pending += " "; i += 1
            case 1, 2, 3, 11, 12, 14, 15, 16, 17, 18, 21, 22, 23:
                let ctrl = ctrlIndex < controls.count ? controls[ctrlIndex] : nil
                ctrlIndex += 1
                i += 8
                guard let ctrl else { continue }
                switch ctrl.ctrlId {
                case "secd":
                    if let pd = ctrl.descendants(HWPTag.pageDef).first { sectionPage = pageSetup(pd.rec.data) }
                case "tbl ":
                    let hadText = !current.inlines.isEmpty || !pending.isEmpty
                    if hadText { flushParagraph() }
                    blocks.append(.table(table(ctrl)))
                    sawSplit = true
                case "gso ":
                    let (images, boxes) = drawing(ctrl)
                    flushText()
                    for img in images { current.inlines.append(img) }
                    if !boxes.isEmpty {
                        if !current.inlines.isEmpty { flushParagraph() }
                        blocks.append(contentsOf: boxes)
                        sawSplit = true
                    }
                case "head", "foot":
                    // attr bits 0-1: 0 both pages, 1 even, 2 odd. Prefer "both".
                    let apply = ByteReader.u32(ctrl.rec.data, 4) & 3
                    let content = lists(in: ctrl.children).flatMap { $0.paras.flatMap(paragraph) }
                    if ctrl.ctrlId == "head" { if sectionHeader == nil || apply == 0 { sectionHeader = content } }
                    else if sectionFooter == nil || apply == 0 { sectionFooter = content }
                case "pgnp":
                    pageNumber(ctrl.rec.data)
                case "atno":
                    // kind 0 = page number
                    if ByteReader.u32(ctrl.rec.data, 4) & 0xF == 0 { flushText(); current.inlines.append(.field(.page, cp)) }
                default: break
                }
            case 4, 5, 6, 7, 8, 19, 20:
                i += 8
            case 0..<32:
                i += 1
            default:
                // Surrogate pairs arrive as two units; String(decoding:) joins them.
                var run = [u]
                if (0xD800...0xDBFF).contains(u), i + 1 < units.count { run.append(units[i + 1]); i += 1 }
                pending += String(decoding: run, as: UTF16.self)
                i += 1
            }
        }
        flushText()
        if !current.inlines.isEmpty || !sawSplit { blocks.append(.paragraph(current)) }
        return blocks
    }

    /// 'pgnp' (쪽 번호 위치): becomes a header/footer paragraph holding a
    /// page-number field, e.g. "- 1 -" centred at the bottom.
    private func pageNumber(_ d: [UInt8]) {
        let attr = ByteReader.u32(d, 4)
        let position = Int((attr >> 8) & 0xF)
        guard position != 0 else { return }
        let prefix = ByteReader.u16(d, 10), suffix = ByteReader.u16(d, 12), dash = ByteReader.u16(d, 14)
        var c = charProps(0)
        c.size = max(c.size, 9)
        var p = Paragraph()
        p.markProps = c
        p.props.alignment = [1, 4, 7, 9].contains(position) ? .left : [3, 6, 8, 10].contains(position) ? .right : .center
        p.props.indentLeft = 0; p.props.firstLine = 0
        let dashText = dash > 0 && dash != 32 ? String(decoding: [dash], as: UTF16.self) : ""
        let pre = (prefix > 0 ? String(decoding: [prefix], as: UTF16.self) : "") + (dashText.isEmpty ? "" : dashText + " ")
        let post = (dashText.isEmpty ? "" : " " + dashText) + (suffix > 0 ? String(decoding: [suffix], as: UTF16.self) : "")
        if !pre.isEmpty { p.inlines.append(.text(pre, c)) }
        p.inlines.append(.field(.page, c))
        if !post.isEmpty { p.inlines.append(.text(post, c)) }
        let top = [1, 2, 3, 7, 9].contains(position)
        if top { sectionHeader = (sectionHeader ?? []) + [.paragraph(p)] } else { sectionFooter = (sectionFooter ?? []) + [.paragraph(p)] }
    }

    private func pageSetup(_ d: [UInt8]) -> PageSetup {
        var r = ByteReader(d)
        var p = PageSetup()
        let w = Units.hwp(r.u32()), h = Units.hwp(r.u32())
        p.marginLeft = Units.hwp(r.u32()); p.marginRight = Units.hwp(r.u32())
        p.marginTop = Units.hwp(r.u32()); p.marginBottom = Units.hwp(r.u32())
        p.header = Units.hwp(r.u32()); p.footer = Units.hwp(r.u32())
        let gutter = Units.hwp(r.u32())
        let attr = r.u32()
        let landscape = attr & 1 != 0
        p.width = landscape ? max(w, h) : w
        p.height = landscape ? min(w, h) : h
        if w <= 0 || h <= 0 { return .a4Hwp }
        // HWP measures body from the header/footer edge; Word from the page edge.
        p.marginTop += p.header
        p.marginBottom += p.footer
        p.marginLeft += gutter
        return p
    }

    /// Group the paragraphs that follow each LIST_HEADER sibling.
    private func lists(in nodes: [HWPNode]) -> [(header: HWPNode, paras: [HWPNode])] {
        var out: [(HWPNode, [HWPNode])] = []
        for n in nodes {
            if n.tag == HWPTag.listHeader { out.append((n, [])) }
            else if n.tag == HWPTag.paraHeader, !out.isEmpty { out[out.count - 1].1.append(n) }
        }
        return out
    }

    private func table(_ ctrl: HWPNode) -> Table {
        var rows = 0, cols = 0
        if let t = ctrl.children.first(where: { $0.tag == HWPTag.table }) {
            rows = Int(ByteReader.u16(t.rec.data, 4))
            cols = Int(ByteReader.u16(t.rec.data, 6))
        }
        struct RawCell {
            var col, row, colSpan, rowSpan: Int
            var width, height: Double
            var padding: Insets; var vAlign: CellVAlign; var borders: CellBorders
            var fill: RGB?; var blocks: [Block]
        }
        var cells: [RawCell] = []
        for (header, paras) in lists(in: ctrl.children) {
            let d = header.rec.data
            var r = ByteReader(d, at: 8)
            let col = Int(r.u16()), row = Int(r.u16())
            let cs = max(1, Int(r.u16())), rs = max(1, Int(r.u16()))
            let width = Units.hwp(r.u32())
            let height = Units.hwp(r.u32())
            let pad = Insets(left: Units.hwp(UInt32(r.u16())), right: Units.hwp(UInt32(r.u16())),
                             top: Units.hwp(UInt32(r.u16())), bottom: Units.hwp(UInt32(r.u16())))
            let bf = Int(r.u16())
            let vAlign: CellVAlign = [.top, .center, .bottom][Int(min(2, (ByteReader.u32(d, 4) >> 5) & 3))]
            var blocks: [Block] = []
            for p in paras { blocks.append(contentsOf: paragraph(p)) }
            if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
            let entry: (borders: CellBorders, fill: RGB?) = bf >= 1 && bf <= borderFills.count ? borderFills[bf - 1] : (CellBorders.all, nil)
            cells.append(RawCell(col: col, row: row, colSpan: cs, rowSpan: rs, width: width, height: height, padding: pad,
                                 vAlign: vAlign, borders: entry.borders, fill: entry.fill, blocks: blocks))
        }
        rows = max(rows, cells.map { $0.row + $0.rowSpan }.max() ?? 0)
        cols = max(cols, cells.map { $0.col + $0.colSpan }.max() ?? 0)

        var t = Table()
        var grid = [[TableCell?]](repeating: [TableCell?](repeating: nil, count: cols), count: rows)
        for c in cells where c.row < rows && c.col < cols {
            var cell = TableCell(blocks: c.blocks, colSpan: c.colSpan, rowSpan: c.rowSpan, width: c.width, height: c.height,
                                 padding: c.padding, verticalAlign: c.vAlign, borders: c.borders, background: c.fill)
            cell.isMergedAway = false
            grid[c.row][c.col] = cell
            for rr in c.row..<min(rows, c.row + c.rowSpan) {
                for cc in c.col..<min(cols, c.col + c.colSpan) where !(rr == c.row && cc == c.col) {
                    var m = TableCell(); m.isMergedAway = true
                    grid[rr][cc] = m
                }
            }
        }
        var widths = [Double](repeating: 0, count: cols)
        for c in cells where c.colSpan == 1 && c.col < cols && widths[c.col] == 0 { widths[c.col] = c.width }
        for c in cells where c.colSpan > 1 && c.col + c.colSpan <= cols {
            let known = (c.col..<(c.col + c.colSpan)).reduce(0.0) { $0 + widths[$1] }
            let unknown = (c.col..<(c.col + c.colSpan)).filter { widths[$0] == 0 }
            if !unknown.isEmpty { for k in unknown { widths[k] = max(0, c.width - known) / Double(unknown.count) } }
        }
        let fallback = widths.filter { $0 > 0 }.reduce(0, +) / Double(max(1, widths.filter { $0 > 0 }.count))
        t.columnWidths = widths.map { $0 > 0 ? $0 : (fallback > 0 ? fallback : 60) }
        t.rows = grid.map { row in row.map { $0 ?? TableCell(blocks: [.paragraph(Paragraph())]) } }
        return t
    }

    /// Pictures become inline images; text boxes (and grouped shapes holding
    /// them) are flattened into blocks so their text stays editable.
    private func drawing(_ ctrl: HWPNode) -> ([Inline], [Block]) {
        var images: [Inline] = []
        var blocks: [Block] = []
        let w = Units.hwp(ByteReader.u32(ctrl.rec.data, 16))
        let h = Units.hwp(ByteReader.u32(ctrl.rec.data, 20))
        let pictures = ctrl.descendants(HWPTag.picture)
        for pic in pictures {
            let item = Int(ByteReader.u16(pic.rec.data, 71))
            if let id = loadBinItem(item) {
                var iw = w, ih = h
                if pictures.count > 1 || iw <= 0 || ih <= 0 { iw = 0; ih = 0 }
                images.append(.image(id: id, width: iw, height: ih))
            }
        }
        func collect(_ n: HWPNode) {
            for (_, paras) in lists(in: n.children) {
                for p in paras { blocks.append(contentsOf: paragraph(p)) }
            }
            for c in n.children where c.tag != HWPTag.paraHeader { collect(c) }
        }
        collect(ctrl)
        return (images, blocks)
    }

    private func loadBinItem(_ index: Int) -> String? {
        guard index >= 1, index <= binItems.count else { return nil }
        let item = binItems[index - 1]
        guard item.id > 0 else { return nil }
        let name = String(format: "BIN%04X.%@", item.id, item.ext)
        let key = "BinData/" + name
        if doc.images[key] != nil { return key }
        let path = cfb.streamNames.first { $0.lowercased() == key.lowercased() } ?? key
        guard let raw = cfb.stream(path) else { return nil }
        let wantInflate = item.compress == 1 || (item.compress == 0 && compressed)
        var bytes = raw
        if wantInflate, let inflated = try? Deflate.inflate(raw), !inflated.isEmpty { bytes = inflated }
        doc.images[key] = ImageData(name: name, data: Data(bytes))
        return key
    }
}

extension HWP5Reader {
    /// Debug: style name → raw ParaShape (left, right, indent, prev, next) in HWPUNIT.
    static func inspectStyles(data: Data) throws -> String {
        let cfb = try CFBReader(data: data)
        guard let h = cfb.stream("FileHeader"), let raw = cfb.stream("DocInfo") else { return "" }
        let bytes = ByteReader.u32(h, 36) & 1 != 0 ? try Deflate.inflate(raw) : raw
        var shapes: [[Int32]] = []
        var out = ""
        for r in HWPRecord.parse(bytes) {
            var b = ByteReader(r.data)
            if r.tag == HWPTag.paraShape { _ = b.u32(); shapes.append((0..<5).map { _ in b.i32() }) }
            if r.tag == HWPTag.style {
                let name = b.utf16(Int(b.u16()))
                b.skip(Int(b.u16()) * 2)
                b.skip(4)
                let pid = Int(b.u16())
                out += "\(name)\t\(pid < shapes.count ? shapes[pid].map(String.init).joined(separator: ",") : "?")\n"
            }
        }
        return out
    }
}

extension HWP5Reader {
    /// Debug: raw record listing of one stream (DocInfo or BodyText/SectionN).
    static func dumpRecords(data: Data, stream: String, limit: Int = 400) throws -> String {
        let cfb = try CFBReader(data: data)
        guard let h = cfb.stream("FileHeader"), let raw = cfb.stream(stream) else { return "no stream \(stream)" }
        if stream == "FileHeader" || stream.hasPrefix("Prv") || stream.hasPrefix("Doc") && stream != "DocInfo" {
            return raw.prefix(160).map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        let bytes = ByteReader.u32(h, 36) & 1 != 0 ? try Deflate.inflate(raw) : raw
        var out = String(format: "version %08X streams: %@\n", ByteReader.u32(h, 32), cfb.streamNames.joined(separator: ","))
        for r in HWPRecord.parse(bytes).prefix(limit) {
            let hex = r.data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: " ")
            out += "\(String(repeating: "  ", count: r.level))tag=\(r.tag) size=\(r.data.count) | \(hex)\n"
        }
        return out
    }
}
