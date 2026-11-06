import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HWP 5.0 binary writer (emits version 5.1.0.1 record layouts, matching the
/// blank Normal.hwt that ships with Hancom Office 2014). Streams:
/// FileHeader, DocInfo, BodyText/Section0…, BinData/BINxxxx.ext, PrvText.
final class HWP5Writer {
    private let doc: UDocument
    private let tables: HancomTables
    private var instance: UInt32 = 0x4855_0000
    private var prvText = ""

    init(_ doc: UDocument) { self.doc = doc; tables = HancomTables(doc) }

    private struct Rec { let tag: UInt16; let level: Int; let data: [UInt8] }

    private static func encode(_ recs: [Rec]) -> [UInt8] {
        var w = ByteWriter()
        for r in recs {
            let size = r.data.count
            let h = UInt32(r.tag & 0x3FF) | UInt32(r.level & 0x3FF) << 10 | UInt32(min(size, 0xFFF)) << 20
            w.u32(h)
            if size >= 0xFFF { w.u32(UInt32(size)) }
            w.bytes(r.data)
        }
        return w.data
    }

    private static func chid(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    func write() -> Data {
        let cfb = CFBWriter()
        var header = ByteWriter()
        header.bytes(Array("HWP Document File".utf8))
        header.pad(to: 32)
        header.u32(0x0501_0001)
        header.u32(1)           // compressed
        header.u32(0)
        header.u32(4)
        header.pad(to: 256)
        cfb.add("FileHeader", header.data)

        var sections: [[UInt8]] = []
        for s in doc.sections { sections.append(section(s)) }
        cfb.add("DocInfo", (try? Deflate.deflate(HWP5Writer.encode(docInfo(sectionCount: sections.count)))) ?? [])
        for (i, s) in sections.enumerated() { cfb.add("BodyText/Section\(i)", (try? Deflate.deflate(s)) ?? []) }
        for img in tables.images {
            let name = String(format: "BinData/BIN%04X.%@", img.index, HancomTables.imageExt(img.data))
            cfb.add(name, (try? Deflate.deflate([UInt8](img.data.data))) ?? [UInt8](img.data.data))
        }
        var prv = ByteWriter()
        prv.utf16(String(prvText.prefix(1024)))
        cfb.add("PrvText", prv.data)
        return Data(cfb.build())
    }

    // MARK: DocInfo

    private func docInfo(sectionCount: Int) -> [Rec] {
        var recs: [Rec] = []
        var p = ByteWriter()
        p.u16(UInt16(sectionCount))
        for _ in 0..<6 { p.u16(1) }
        p.u32(0); p.u32(0); p.u32(0)
        recs.append(Rec(tag: 16, level: 0, data: p.data))

        let fontCount = tables.fonts.count
        var ids = ByteWriter()
        let counts: [Int] = [tables.images.count] + Array(repeating: fontCount, count: 7) +
            [tables.borderFills.count, tables.charShapes.count, 1, 0, 0, tables.paraShapes.count, 1, 0, 0, 0]
        counts.forEach { ids.i32(Int32($0)) }
        recs.append(Rec(tag: 17, level: 0, data: ids.data))

        for img in tables.images {
            var b = ByteWriter()
            b.u16(1)                      // embedding, compression follows the document
            b.u16(UInt16(img.index))
            let ext = HancomTables.imageExt(img.data)
            b.u16(UInt16(ext.utf16.count)); b.utf16(ext)
            recs.append(Rec(tag: 18, level: 1, data: b.data))
        }
        for _ in 0..<7 {
            for f in tables.fonts {
                var b = ByteWriter()
                b.u8(0); b.u16(UInt16(f.utf16.count)); b.utf16(f)
                recs.append(Rec(tag: 19, level: 1, data: b.data))
            }
        }
        for bf in tables.borderFills { recs.append(Rec(tag: 20, level: 1, data: borderFill(bf.borders, fill: bf.fill))) }
        for c in tables.charShapes { recs.append(Rec(tag: 21, level: 1, data: charShape(c))) }
        recs.append(Rec(tag: 22, level: 1, data: [UInt8](repeating: 0, count: 8)))
        for p in tables.paraShapes { recs.append(Rec(tag: 25, level: 1, data: paraShape(p))) }
        var st = ByteWriter()
        st.u16(3); st.utf16("바탕글"); st.u16(6); st.utf16("Normal")
        st.u8(0); st.u8(0); st.u16(0x0412); st.u16(0); st.u16(0); st.u16(0)
        recs.append(Rec(tag: 26, level: 1, data: st.data))
        recs.append(Rec(tag: 30, level: 0, data: [0, 0, 0, 0]))
        recs.append(Rec(tag: 31, level: 1, data: [UInt8](repeating: 0, count: 20)))
        return recs
    }

    private func borderFill(_ borders: CellBorders, fill: RGB?) -> [UInt8] {
        var b = ByteWriter()
        b.u16(0)
        for l in [borders.left, borders.right, borders.top, borders.bottom] {
            b.u8(HancomTables.hwpLineType(l)); b.u8(UInt8(HancomTables.lineWidthIndex(l.width))); b.u32(l.color.colorref)
        }
        b.u8(0); b.u8(1); b.u32(0)        // diagonal
        if let fill {
            b.u32(1); b.u32(fill.colorref); b.u32(0); b.i32(-1); b.u32(0); b.u8(0)
        } else {
            b.u32(0); b.u32(0)
        }
        return b.data
    }

    private func charShape(_ c: CharProps) -> [UInt8] {
        var b = ByteWriter()
        let latin = UInt16(tables.font(c.fontName)), ea = UInt16(tables.font(c.eastAsianFontName ?? c.fontName))
        for id in [ea, latin, ea, ea, latin, latin, latin] { b.u16(id) }
        for _ in 0..<7 { b.u8(UInt8(max(50, min(200, c.widthRatio.rounded())))) }
        let sp = Int8(max(-50, min(50, c.size > 0 ? (c.spacing / c.size * 100).rounded() : 0)))
        for _ in 0..<7 { b.i8(sp) }
        for _ in 0..<7 { b.u8(100) }
        for _ in 0..<7 { b.i8(0) }
        b.i32(Int32((c.size * 100).rounded()))
        var attr: UInt32 = 0
        if c.italic { attr |= 1 }
        if c.bold { attr |= 2 }
        if c.underline != .none {
            attr |= 1 << 2
            let shape: UInt32
            switch c.underline {
            case .dashed: shape = 1
            case .dotted: shape = 2
            case .double: shape = 7
            case .wave: shape = 10
            default: shape = 0
            }
            attr |= shape << 4
        }
        if c.verticalAlign == .superscript { attr |= 1 << 15 }
        if c.verticalAlign == .subscript { attr |= 1 << 16 }
        if c.strike { attr |= 1 << 18 }
        b.u32(attr)
        b.i8(10); b.i8(10)
        b.u32(c.color.colorref)
        b.u32(c.color.colorref)
        b.u32(c.highlight?.colorref ?? 0xFFFF_FFFF)
        b.u32(0xB2B2B2)
        b.u16(1)
        b.u32(c.color.colorref)
        return b.data
    }

    private func paraShape(_ p: ParaProps) -> [UInt8] {
        let align: UInt32
        switch p.alignment {
        case .justify: align = 0
        case .left: align = 1
        case .right: align = 2
        case .center: align = 3
        case .distribute: align = 4
        }
        let m = HancomTables.hwpMargins(p)
        let ls = HancomTables.hwpLineSpacing(p)
        var b = ByteWriter()
        b.u32(0x180 | align << 2 | UInt32(min(ls.kind, 3)))
        b.i32(m.left); b.i32(m.right); b.i32(m.indent); b.i32(m.prev); b.i32(m.next)
        b.i32(ls.value)
        b.u16(0); b.u16(0); b.u16(1)
        b.zeros(8)
        b.u32(0)
        b.u32(UInt32(ls.kind))
        b.u32(UInt32(bitPattern: ls.value))
        b.u32(0)
        return b.data
    }

    // MARK: Body

    private enum Item {
        case text(String, Int)
        case tab(Int)
        case lineBreak(Int)
        case control(code: UInt16, id: String, cs: Int, records: [Rec])   // levels relative to the CTRL_HEADER
    }

    private func section(_ s: Section) -> [UInt8] {
        var recs: [Rec] = []
        var blocks = s.blocks
        if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
        let width = s.page.contentWidth
        for (i, b) in blocks.enumerated() {
            let prefix = i == 0 ? sectionControls(s) : []
            recs += block(b, level: 0, width: width, last: i == blocks.count - 1, prefix: prefix)
        }
        return HWP5Writer.encode(recs)
    }

    private func sectionControls(_ s: Section) -> [Item] {
        let p = s.page
        var sec = ByteWriter()
        sec.u32(HWP5Writer.chid("secd")); sec.u32(0); sec.u16(1134); sec.u16(0); sec.u16(0); sec.u32(8000); sec.u16(1)
        sec.pad(to: 47)
        var page = ByteWriter()
        let landscape = p.width > p.height
        page.u32(UInt32(Units.toHwp(landscape ? p.height : p.width)))
        page.u32(UInt32(Units.toHwp(landscape ? p.width : p.height)))
        let header = Units.toHwp(p.header), footer = Units.toHwp(p.footer)
        page.u32(UInt32(max(0, Units.toHwp(p.marginLeft)))); page.u32(UInt32(max(0, Units.toHwp(p.marginRight))))
        page.u32(UInt32(max(0, Units.toHwp(p.marginTop) - header))); page.u32(UInt32(max(0, Units.toHwp(p.marginBottom) - footer)))
        page.u32(UInt32(max(0, header))); page.u32(UInt32(max(0, footer)))
        page.u32(0); page.u32(landscape ? 1 : 0)
        let fn1: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0x29, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x52, 3, 0x37, 2, 0x1B, 1, 1, 1, 0, 0, 0, 0]
        let fn2: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0x29, 0, 1, 0, 0, 0, 0, 0, 0x52, 3, 0x37, 2, 0, 0, 1, 1, 0, 0, 0, 0]
        let pbf: [UInt8] = [1, 0, 0, 0, 0x89, 5, 0x89, 5, 0x89, 5, 0x89, 5, 1, 0]
        var cold = ByteWriter()
        cold.u32(HWP5Writer.chid("cold")); cold.u16(0x1004); cold.pad(to: 16)
        return [
            .control(code: 2, id: "secd", cs: 0, records: [
                Rec(tag: 71, level: 0, data: sec.data), Rec(tag: 73, level: 1, data: page.data),
                Rec(tag: 74, level: 1, data: fn1), Rec(tag: 74, level: 1, data: fn2),
                Rec(tag: 75, level: 1, data: pbf), Rec(tag: 75, level: 1, data: pbf), Rec(tag: 75, level: 1, data: pbf),
            ]),
            .control(code: 2, id: "cold", cs: 0, records: [Rec(tag: 71, level: 0, data: cold.data)]),
        ] + [("head", s.header, p.header), ("foot", s.footer, p.footer)].compactMap { id, blocks, height -> Item? in
            // CTRL_HEADER(id, attr 0 = both pages) › LIST_HEADER › paragraphs,
            // the same shape Hancom writes (see CLEAN011.hwt).
            guard let blocks, !blocks.isEmpty else { return nil }
            var ch = ByteWriter()
            ch.u32(HWP5Writer.chid(id)); ch.u32(0); ch.u32(0)
            var lh = ByteWriter()
            lh.u16(UInt16(blocks.count)); lh.u16(0); lh.u32(0)
            lh.u32(UInt32(Units.toHwp(p.contentWidth))); lh.u32(UInt32(max(0, Units.toHwp(height))))
            lh.pad(to: 34)
            var recs = [Rec(tag: 71, level: 0, data: ch.data), Rec(tag: 72, level: 1, data: lh.data)]
            for (i, b) in blocks.enumerated() { recs += block(b, level: 1, width: p.contentWidth, last: i == blocks.count - 1, prefix: []) }
            return .control(code: 16, id: id, cs: 0, records: recs)
        }
    }

    private func block(_ b: Block, level: Int, width: Double, last: Bool, prefix: [Item]) -> [Rec] {
        switch b {
        case .paragraph(let p):
            var items = prefix
            for i in p.inlines {
                switch i {
                case .text(let t, let c): items.append(.text(t, tables.charShape(c)))
                case .tab(let c): items.append(.tab(tables.charShape(c)))
                case .lineBreak(let c): items.append(.lineBreak(tables.charShape(c)))
                case .pageBreak: break
                case .image(let id, let w, let h):
                    if let idx = tables.image(id, doc) { items.append(picture(idx, w, h, id: id, cs: tables.charShape(p.markProps))) }
                case .field(let k, let c):
                    // HWP auto-number control ('atno', kind 0 = page). HWP has no
                    // total-page auto number, so a page count is written as text.
                    if k == .pageCount { items.append(.text("", tables.charShape(c))); break }
                    var d = ByteWriter()
                    d.u32(HWP5Writer.chid("atno")); d.u32(0); d.u16(1); d.u16(0); d.u16(0); d.u16(0)
                    items.append(.control(code: 18, id: "atno", cs: tables.charShape(c), records: [Rec(tag: 71, level: 0, data: d.data)]))
                }
            }
            prvText += p.plainText + "\r\n"
            return paragraph(p.props, mark: tables.charShape(p.markProps), items: items, level: level, last: last, width: width)
        case .table(let t):
            var items = prefix
            items.append(table(t, width: width))
            return paragraph(ParaProps(), mark: 0, items: items, level: level, last: last, width: width)
        }
    }

    private func paragraph(_ props: ParaProps, mark: Int, items: [Item], level: Int, last: Bool, width: Double) -> [Rec] {
        var units: [UInt16] = []
        var runs: [(Int, Int)] = []
        var ctrlRecs: [Rec] = []
        var mask: UInt32 = 0
        func shape(_ cs: Int) { if runs.last?.1 != cs { runs.append((units.count, cs)) } }
        for it in items {
            switch it {
            case .text(let t, let cs):
                shape(cs)
                for u in t.utf16 {
                    switch u {
                    case 9: units += [9, 0, 0, 0, 0, 0, 0, 9]; mask |= 1 << 9
                    case 10, 13, 0x2028: units.append(10); mask |= 1 << 10
                    case 0..<32: continue
                    default: units.append(u)
                    }
                }
            case .tab(let cs): shape(cs); units += [9, 0, 0, 0, 0, 0, 0, 9]; mask |= 1 << 9
            case .lineBreak(let cs): shape(cs); units.append(10); mask |= 1 << 10
            case .control(let code, let id, let cs, let recs):
                shape(cs)
                let v = HWP5Writer.chid(id)
                units += [code, UInt16(v & 0xFFFF), UInt16(v >> 16), 0, 0, 0, 0, code]
                mask |= 1 << UInt32(code)
                ctrlRecs += recs.map { Rec(tag: $0.tag, level: $0.level + level + 1, data: $0.data) }
            }
        }
        if runs.isEmpty { runs = [(0, mark)] }
        units.append(13)
        if units.count == 1 { runs = [(0, mark)] }

        var ps = props
        let pageBreak = ps.pageBreakBefore
        ps.pageBreakBefore = false
        var h = ByteWriter()
        h.u32(UInt32(units.count) | (last ? 0x8000_0000 : 0))
        h.u32(mask)
        h.u16(UInt16(tables.paraShape(ps)))
        h.u8(0)
        h.u8(pageBreak ? 0x04 : 0)
        h.u16(UInt16(runs.count)); h.u16(0); h.u16(1)
        instance &+= 1
        h.u32(instance)
        h.u16(0)
        var recs = [Rec(tag: 66, level: level, data: h.data)]
        if units.count > 1 {
            var t = ByteWriter()
            units.forEach { t.u16($0) }
            recs.append(Rec(tag: 67, level: level + 1, data: t.data))
        }
        var cs = ByteWriter()
        for r in runs { cs.u32(UInt32(r.0)); cs.u32(UInt32(r.1)) }
        recs.append(Rec(tag: 68, level: level + 1, data: cs.data))
        let size = Int32(((tables.charShapes[safe: runs[0].1]?.size ?? 10) * 100).rounded())
        var seg = ByteWriter()
        seg.u32(0); seg.i32(0); seg.i32(size); seg.i32(size); seg.i32(size * 85 / 100); seg.i32(size * 6 / 10)
        seg.i32(0); seg.i32(Units.toHwp(width)); seg.u32(0x0006_0000)
        recs.append(Rec(tag: 69, level: level + 1, data: seg.data))
        return recs + ctrlRecs
    }

    private func commonObject(_ id: String, attr: UInt32, w: Int32, h: Int32, margins: Int16) -> ByteWriter {
        var b = ByteWriter()
        b.u32(HWP5Writer.chid(id)); b.u32(attr); b.i32(0); b.i32(0)
        b.u32(UInt32(max(1, w))); b.u32(UInt32(max(1, h)))
        b.i32(0)
        for _ in 0..<4 { b.i16(margins) }
        instance &+= 1
        b.u32(instance)
        b.i32(0)
        b.u16(0)
        return b
    }

    private func table(_ t: Table, width: Double) -> Item {
        let grid = TableGrid(t)
        var widths = (0..<grid.cols).map { $0 < t.columnWidths.count ? t.columnWidths[$0] : 60 }
        let total = widths.reduce(0, +)
        if total > width && total > 0 { widths = widths.map { $0 * width / total } }
        let rowH: Int32 = 1500
        let rows = grid.slots.count
        var recs: [Rec] = []
        let ch = commonObject("tbl ", attr: 0x182A_2211, w: Units.toHwp(widths.reduce(0, +)), h: rowH * Int32(rows), margins: 283)
        recs.append(Rec(tag: 71, level: 0, data: ch.data))
        var tb = ByteWriter()
        tb.u32(0x0400_0004)
        tb.u16(UInt16(rows)); tb.u16(UInt16(grid.cols)); tb.u16(0)
        for m in [510, 510, 141, 141] { tb.u16(UInt16(m)) }
        for row in grid.slots { tb.u16(UInt16(row.filter { if case .origin = $0 { return true }; return false }.count)) }
        tb.u16(1); tb.u16(0)
        recs.append(Rec(tag: 77, level: 1, data: tb.data))
        for (r, row) in grid.slots.enumerated() {
            for (c, slot) in row.enumerated() {
                guard case .origin(let cell) = slot else { continue }
                let cs = max(1, min(cell.colSpan, grid.cols - c)), rs = max(1, min(cell.rowSpan, rows - r))
                let w = widths[c..<(c + cs)].reduce(0, +)
                var blocks = cell.blocks
                if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
                var lh = ByteWriter()
                let va: UInt32 = cell.verticalAlign == .center ? 1 : cell.verticalAlign == .bottom ? 2 : 0
                lh.u16(UInt16(blocks.count)); lh.u16(0); lh.u32(va << 5)
                lh.u16(UInt16(c)); lh.u16(UInt16(r)); lh.u16(UInt16(cs)); lh.u16(UInt16(rs))
                lh.u32(UInt32(Units.toHwp(w))); lh.u32(UInt32(cell.height.map { Units.toHwp($0) } ?? rowH * Int32(rs)))
                let pad = cell.padding ?? .hwpDefault
                for m in [pad.left, pad.right, pad.top, pad.bottom] { lh.u16(UInt16(max(0, Units.toHwp(m)))) }
                lh.u16(UInt16(tables.borderFill(cell)))
                lh.u32(UInt32(Units.toHwp(w)))
                lh.pad(to: 47)
                recs.append(Rec(tag: 72, level: 1, data: lh.data))
                for (i, b) in blocks.enumerated() {
                    recs += block(b, level: 1, width: w - 10, last: i == blocks.count - 1, prefix: [])
                }
            }
        }
        return .control(code: 11, id: "tbl ", cs: 0, records: recs)
    }

    private func picture(_ idx: Int, _ w: Double, _ h: Double, id: String, cs: Int) -> Item {
        var width = w, height = h
        if (width <= 0 || height <= 0), let d = doc.images[id], let s = ImageProbe.size(d.data) { width = s.width; height = s.height }
        if width <= 0 || height <= 0 { width = 100; height = 100 }
        let W = Units.toHwp(width), H = Units.toHwp(height)
        let ch = commonObject("gso ", attr: 0x042A_2211, w: W, h: H, margins: 0)

        var sc = ByteWriter()
        sc.u32(HWP5Writer.chid("$pic")); sc.u32(HWP5Writer.chid("$pic"))
        sc.i32(0); sc.i32(0); sc.u16(0); sc.u16(1)
        sc.u32(UInt32(W)); sc.u32(UInt32(H)); sc.u32(UInt32(W)); sc.u32(UInt32(H))
        sc.u32(0x0008_0000)
        sc.i16(0); sc.i32(W / 2); sc.i32(H / 2)
        sc.u16(1)
        func identity() { for v in [1.0, 0, 0, 0, 1.0, 0] { sc.u64(v.bitPattern) } }
        identity(); identity(); identity()

        var pic = ByteWriter()
        pic.u32(0); pic.u32(0); pic.u32(0)
        for (x, y) in [(0, 0), (W, 0), (W, H), (0, H)] { pic.i32(x); pic.i32(y) }
        pic.i32(0); pic.i32(0); pic.i32(W); pic.i32(H)
        pic.zeros(8)
        pic.u8(0); pic.u8(0); pic.u8(0)
        pic.u16(UInt16(idx))
        pic.u8(0)
        instance &+= 1
        pic.u32(instance)
        pic.u32(0); pic.i32(W); pic.i32(H)
        pic.pad(to: 90)

        return .control(code: 11, id: "gso ", cs: cs, records: [
            Rec(tag: 71, level: 0, data: ch.data),
            Rec(tag: 76, level: 1, data: sc.data),
            Rec(tag: 85, level: 2, data: pic.data),
        ])
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
