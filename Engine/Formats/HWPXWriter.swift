import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared ID tables for the two Hancom writers: HWP keeps every distinct
/// character/paragraph shape once in the document header and references it
/// by index, so the per-run properties of the unified model are interned here.
final class HancomTables {
    var fonts: [String] = []
    var charShapes: [CharProps] = []
    var paraShapes: [ParaProps] = []
    struct BorderFill: Equatable { var borders: CellBorders; var fill: RGB? }
    /// Border-fill IDs are 1-based: 1 = no border (paragraphs, characters,
    /// pages), 2 = thin solid (table default), 3… = per-cell combinations.
    var borderFills: [BorderFill] = [BorderFill(borders: .none, fill: nil), BorderFill(borders: .all, fill: nil)]
    var images: [(id: String, data: ImageData, index: Int)] = []

    init(_ doc: UDocument) {
        _ = font(HWDocumentDefaults.font)
        _ = charShape(CharProps())
        _ = paraShape(ParaProps())
        func walk(_ blocks: [Block]) {
            for b in blocks {
                switch b {
                case .paragraph(let p):
                    _ = paraShape(p.props)
                    _ = charShape(p.markProps)
                    for i in p.inlines {
                        switch i {
                        case .text(_, let c), .tab(let c), .lineBreak(let c), .field(_, let c): _ = charShape(c)
                        case .image(let id, _, _): _ = image(id, doc)
                        case .pageBreak: break
                        }
                    }
                case .table(let t):
                    for row in t.rows { for cell in row where !cell.isMergedAway {
                        _ = borderFill(cell)
                        walk(cell.blocks)
                    } }
                }
            }
        }
        doc.sections.forEach { walk($0.blocks) }
    }

    func font(_ name: String) -> Int {
        if let i = fonts.firstIndex(of: name) { return i }
        fonts.append(name); return fonts.count - 1
    }

    func charShape(_ c: CharProps) -> Int {
        _ = font(c.fontName); _ = font(c.eastAsianFontName ?? c.fontName)
        if let i = charShapes.firstIndex(of: c) { return i }
        charShapes.append(c); return charShapes.count - 1
    }

    func paraShape(_ p: ParaProps) -> Int {
        var key = p
        key.styleName = nil; key.listLabel = nil; key.pageBreakBefore = false
        if let i = paraShapes.firstIndex(of: key) { return i }
        paraShapes.append(key); return paraShapes.count - 1
    }

    func borderFill(_ cell: TableCell) -> Int {
        let bf = BorderFill(borders: cell.borders, fill: cell.background)
        if let i = borderFills.firstIndex(of: bf) { return i + 1 }
        borderFills.append(bf); return borderFills.count
    }

    /// Nearest entry of HWP's fixed line-width table.
    static func lineWidthIndex(_ pt: Double) -> Int {
        let mm = pt / 72 * 25.4
        return HWP5Reader.lineWidthsMM.enumerated().min { abs($0.element - mm) < abs($1.element - mm) }!.offset
    }

    static func hwpLineType(_ l: BorderLine) -> UInt8 {
        guard l.visible else { return 0 }
        switch l.style {
        case .none: return 0
        case .solid: return 1
        case .dashed: return 2
        case .dotted: return 3
        case .double: return 7
        }
    }

    /// 1-based bin item index, or nil when the image payload is missing.
    func image(_ id: String, _ doc: UDocument) -> Int? {
        if let e = images.first(where: { $0.id == id }) { return e.index }
        guard let d = doc.images[id] else { return nil }
        images.append((id, d, images.count + 1)); return images.count
    }

    static func imageExt(_ d: ImageData) -> String {
        let e = d.ext
        return ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "wmf", "emf"].contains(e) ? (e == "jpeg" ? "jpg" : e) : "png"
    }

    /// HWP stores paragraph margins doubled, with HWP indent semantics
    /// (내어쓰기 pushes the following lines right of the left margin).
    static func hwpMargins(_ p: ParaProps) -> (left: Int32, right: Int32, indent: Int32, prev: Int32, next: Int32) {
        var left = p.indentLeft
        if p.firstLine < 0 { left += p.firstLine }
        return (Units.toHwp(max(0, left)) * 2, Units.toHwp(p.indentRight) * 2, Units.toHwp(p.firstLine) * 2,
                Units.toHwp(p.spaceBefore) * 2, Units.toHwp(p.spaceAfter) * 2)
    }

    /// (type, value): 0 percent, 1 fixed, 3 at least — values doubled like margins.
    static func hwpLineSpacing(_ p: ParaProps) -> (kind: Int, value: Int32) {
        switch p.lineSpacing {
        case .percentOfSize(let pct): return (0, Int32(pct.rounded()))
        case .multiple(let m): return (0, Int32((m * 120).rounded()))   // Word single ≈ HWP 120%
        case .exact(let v): return (1, Units.toHwp(v) * 2)
        case .atLeast(let v): return (3, Units.toHwp(v) * 2)
        }
    }
}

enum HWDocumentDefaults { static let font = "함초롬바탕" }

final class HWPXWriter {
    private let doc: UDocument
    private let tables: HancomTables
    private var paraId = 0
    private var objId = 1

    init(_ doc: UDocument) { self.doc = doc; tables = HancomTables(doc) }

    private static let ns = """
    xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" \
    xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" \
    xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf" \
    xmlns:opf="http://www.idpf.org/2007/opf/"
    """

    func write() -> Data {
        var sections: [String] = []
        for s in doc.sections { sections.append(section(s)) }
        let z = ZipWriter()
        z.add("mimetype", "application/hwp+zip", compress: false)
        z.add("version.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hv:HCFVersion xmlns:hv="http://www.hancom.co.kr/hwpml/2011/version" \
        tagetApplication="WORDPROCESSOR" major="5" minor="1" micro="0" buildNumber="1" os="1" xmlVersion="1.4" application="HanX" appVersion="1.0"/>
        """)
        z.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes" ?><ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container" \
        xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf"><ocf:rootfiles><ocf:rootfile full-path="Contents/content.hpf" \
        media-type="application/hwpml-package+xml"/></ocf:rootfiles></ocf:container>
        """)
        z.add("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?><odf:manifest xmlns:odf=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"/>")
        z.add("Contents/content.hpf", contentHpf(sectionCount: sections.count))
        z.add("Contents/header.xml", header(sectionCount: sections.count))
        for (i, s) in sections.enumerated() { z.add("Contents/section\(i).xml", s) }
        for img in tables.images {
            z.add("BinData/image\(img.index).\(HancomTables.imageExt(img.data))", img.data.data, compress: false)
        }
        z.add("settings.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?><ha:HWPApplicationSetting xmlns:ha=\"http://www.hancom.co.kr/hwpml/2011/app\" xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\"><ha:CaretPosition listIDRef=\"0\" paraIDRef=\"0\" pos=\"0\"/></ha:HWPApplicationSetting>")
        return z.finish()
    }

    private func contentHpf(sectionCount: Int) -> String {
        var items = "<opf:item id=\"header\" href=\"Contents/header.xml\" media-type=\"application/xml\"/>"
        var spine = "<opf:itemref idref=\"header\" linear=\"yes\"/>"
        for img in tables.images {
            let ext = HancomTables.imageExt(img.data)
            let mime = ext == "jpg" ? "image/jpeg" : ext == "wmf" ? "image/x-wmf" : ext == "emf" ? "image/x-emf" : "image/\(ext)"
            items += "<opf:item id=\"image\(img.index)\" href=\"BinData/image\(img.index).\(ext)\" media-type=\"\(mime)\" isEmbeded=\"1\"/>"
        }
        for i in 0..<sectionCount {
            items += "<opf:item id=\"section\(i)\" href=\"Contents/section\(i).xml\" media-type=\"application/xml\"/>"
            spine += "<opf:itemref idref=\"section\(i)\" linear=\"yes\"/>"
        }
        items += "<opf:item id=\"settings\" href=\"settings.xml\" media-type=\"application/xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes" ?><opf:package \(HWPXWriter.ns) version="" unique-identifier="" id="">\
        <opf:metadata><opf:title>\(XMLEscape.text(doc.title ?? ""))</opf:title><opf:language>ko</opf:language></opf:metadata>\
        <opf:manifest>\(items)</opf:manifest><opf:spine>\(spine)</opf:spine></opf:package>
        """
    }

    static let owpmlTypes: [BorderStyle: String] = [.none: "NONE", .solid: "SOLID", .dotted: "DOT", .dashed: "DASH", .double: "DOUBLE_SLIM"]

    private func border(_ b: CellBorders) -> String {
        [("leftBorder", b.left), ("rightBorder", b.right), ("topBorder", b.top), ("bottomBorder", b.bottom)].map { name, l in
            let mm = HWP5Reader.lineWidthsMM[HancomTables.lineWidthIndex(l.width)]
            let t = l.visible ? HWPXWriter.owpmlTypes[l.style]! : "NONE"
            return "<hh:\(name) type=\"\(t)\" width=\"\(mm) mm\" color=\"#\(l.color.hex)\"/>"
        }.joined() + "<hh:diagonal type=\"SOLID\" width=\"0.1 mm\" color=\"#000000\"/>"
    }

    private func header(sectionCount: Int) -> String {
        let langs = ["HANGUL", "LATIN", "HANJA", "JAPANESE", "OTHER", "SYMBOL", "USER"]
        var fontfaces = "<hh:fontfaces itemCnt=\"7\">"
        for l in langs {
            fontfaces += "<hh:fontface lang=\"\(l)\" fontCnt=\"\(tables.fonts.count)\">"
            for (i, f) in tables.fonts.enumerated() {
                fontfaces += "<hh:font id=\"\(i)\" face=\"\(XMLEscape.text(f))\" type=\"TTF\" isEmbedded=\"0\"/>"
            }
            fontfaces += "</hh:fontface>"
        }
        fontfaces += "</hh:fontfaces>"

        var fills = "<hh:borderFills itemCnt=\"\(tables.borderFills.count)\">"
        let bfAttrs = "threeD=\"0\" shadow=\"0\" centerLine=\"NONE\" breakCellSeparateLine=\"0\""
        let slash = "<hh:slash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/><hh:backSlash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/>"
        for (i, bf) in tables.borderFills.enumerated() {
            fills += "<hh:borderFill id=\"\(i + 1)\" \(bfAttrs)>\(slash)\(border(bf.borders))"
            if let c = bf.fill { fills += "<hc:fillBrush><hc:winBrush faceColor=\"#\(c.hex)\" hatchColor=\"#999999\" alpha=\"0\"/></hc:fillBrush>" }
            fills += "</hh:borderFill>"
        }
        fills += "</hh:borderFills>"

        var chars = "<hh:charProperties itemCnt=\"\(tables.charShapes.count)\">"
        for (i, c) in tables.charShapes.enumerated() {
            let latin = tables.font(c.fontName), ea = tables.font(c.eastAsianFontName ?? c.fontName)
            let shade = c.highlight.map { "#\($0.hex)" } ?? "none"
            let sp = c.size > 0 ? Int((c.spacing / c.size * 100).rounded()) : 0
            chars += "<hh:charPr id=\"\(i)\" height=\"\(Int((c.size * 100).rounded()))\" textColor=\"#\(c.color.hex)\" shadeColor=\"\(shade)\" useFontSpace=\"0\" useKerning=\"0\" symMark=\"NONE\" borderFillIDRef=\"1\">"
            chars += "<hh:fontRef hangul=\"\(ea)\" latin=\"\(latin)\" hanja=\"\(ea)\" japanese=\"\(ea)\" other=\"\(latin)\" symbol=\"\(latin)\" user=\"\(latin)\"/>"
            let ra = Int(c.widthRatio.rounded())
            chars += "<hh:ratio hangul=\"\(ra)\" latin=\"\(ra)\" hanja=\"\(ra)\" japanese=\"\(ra)\" other=\"\(ra)\" symbol=\"\(ra)\" user=\"\(ra)\"/>"
            chars += "<hh:spacing hangul=\"\(sp)\" latin=\"\(sp)\" hanja=\"\(sp)\" japanese=\"\(sp)\" other=\"\(sp)\" symbol=\"\(sp)\" user=\"\(sp)\"/>"
            chars += "<hh:relSz hangul=\"100\" latin=\"100\" hanja=\"100\" japanese=\"100\" other=\"100\" symbol=\"100\" user=\"100\"/>"
            chars += "<hh:offset hangul=\"0\" latin=\"0\" hanja=\"0\" japanese=\"0\" other=\"0\" symbol=\"0\" user=\"0\"/>"
            if c.italic { chars += "<hh:italic/>" }
            if c.bold { chars += "<hh:bold/>" }
            let shape: String
            switch c.underline {
            case .double: shape = "DOUBLE_SLIM"
            case .dotted: shape = "DOT"
            case .dashed: shape = "DASH"
            case .wave: shape = "WAVE"
            case .thick: shape = "THICK_SLIM"
            default: shape = "SOLID"
            }
            chars += "<hh:underline type=\"\(c.underline == .none ? "NONE" : "BOTTOM")\" shape=\"\(shape)\" color=\"#\(c.color.hex)\"/>"
            chars += "<hh:strikeout shape=\"\(c.strike ? "SOLID" : "NONE")\" color=\"#\(c.color.hex)\"/>"
            chars += "<hh:outline type=\"NONE\"/><hh:shadow type=\"NONE\" color=\"#B2B2B2\" offsetX=\"10\" offsetY=\"10\"/>"
            if c.verticalAlign == .superscript { chars += "<hh:supscript/>" }
            if c.verticalAlign == .subscript { chars += "<hh:subscript/>" }
            chars += "</hh:charPr>"
        }
        chars += "</hh:charProperties>"

        var paras = "<hh:paraProperties itemCnt=\"\(tables.paraShapes.count)\">"
        for (i, p) in tables.paraShapes.enumerated() {
            let align: String
            switch p.alignment {
            case .left: align = "LEFT"
            case .right: align = "RIGHT"
            case .center: align = "CENTER"
            case .justify: align = "JUSTIFY"
            case .distribute: align = "DISTRIBUTE"
            }
            let m = HancomTables.hwpMargins(p)
            let ls = HancomTables.hwpLineSpacing(p)
            let lsType = ["PERCENT", "FIXED", "BETWEEN_LINES", "AT_LEAST"][ls.kind]
            paras += "<hh:paraPr id=\"\(i)\" tabPrIDRef=\"0\" condense=\"0\" fontLineHeight=\"0\" snapToGrid=\"1\" suppressLineNumbers=\"0\" checked=\"0\">"
            paras += "<hh:align horizontal=\"\(align)\" vertical=\"BASELINE\"/><hh:heading type=\"NONE\" idRef=\"0\" level=\"0\"/>"
            paras += "<hh:breakSetting breakLatinWord=\"KEEP_WORD\" breakNonLatinWord=\"KEEP_WORD\" widowOrphan=\"0\" keepWithNext=\"0\" keepLines=\"0\" pageBreakBefore=\"0\" lineWrap=\"BREAK\"/>"
            paras += "<hh:autoSpacing eAsianEng=\"0\" eAsianNum=\"0\"/>"
            paras += "<hh:margin><hc:intent value=\"\(m.indent)\" unit=\"HWPUNIT\"/><hc:left value=\"\(m.left)\" unit=\"HWPUNIT\"/>"
            paras += "<hc:right value=\"\(m.right)\" unit=\"HWPUNIT\"/><hc:prev value=\"\(m.prev)\" unit=\"HWPUNIT\"/><hc:next value=\"\(m.next)\" unit=\"HWPUNIT\"/></hh:margin>"
            paras += "<hh:lineSpacing type=\"\(lsType)\" value=\"\(ls.value)\" unit=\"HWPUNIT\"/>"
            paras += "<hh:border borderFillIDRef=\"1\" offsetLeft=\"0\" offsetRight=\"0\" offsetTop=\"0\" offsetBottom=\"0\" connect=\"0\" ignoreMargin=\"0\"/></hh:paraPr>"
        }
        paras += "</hh:paraProperties>"

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hh:head \(HWPXWriter.ns) version="1.4" secCnt="\(sectionCount)">\
        <hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/><hh:refList>\(fontfaces)\(fills)\(chars)\
        <hh:tabProperties itemCnt="1"><hh:tabPr id="0" autoTabLeft="0" autoTabRight="0"/></hh:tabProperties>\
        <hh:numberings itemCnt="0"/>\(paras)\
        <hh:styles itemCnt="1"><hh:style id="0" type="PARA" name="바탕글" engName="Normal" paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langID="1042" lockForm="0"/></hh:styles>\
        </hh:refList><hh:compatibleDocument targetProgram="HWP201X"><hh:layoutCompatibility/></hh:compatibleDocument>\
        <hh:docOption><hh:linkinfo path="" pageInherit="0" footnoteInherit="0"/></hh:docOption><hh:trackchageConfig flags="56"/></hh:head>
        """
    }

    private func secPr(_ p: PageSetup) -> String {
        let landscape = p.width > p.height
        let w = Units.toHwp(landscape ? p.height : p.width), h = Units.toHwp(landscape ? p.width : p.height)
        let header = Units.toHwp(p.header), footer = Units.toHwp(p.footer)
        let top = max(0, Units.toHwp(p.marginTop) - header), bottom = max(0, Units.toHwp(p.marginBottom) - footer)
        return """
        <hp:secPr id="" textDirection="HORIZONTAL" spaceColumns="1134" tabStop="8000" tabStopVal="4000" tabStopUnit="HWPUNIT" \
        outlineShapeIDRef="0" memoShapeIDRef="0" textVerticalWidthHead="0" masterPageCnt="0">\
        <hp:grid lineGrid="0" charGrid="0" wonggojiFormat="0"/><hp:startNum pageStartsOn="BOTH" page="0" pic="0" tbl="0" equation="0"/>\
        <hp:visibility hideFirstHeader="0" hideFirstFooter="0" hideFirstMasterPage="0" border="SHOW_ALL" fill="SHOW_ALL" \
        hideFirstPageNum="0" hideFirstEmptyLine="0" showLineNumber="0"/>\
        <hp:lineNumberShape restartType="0" countBy="0" distance="0" startNumber="0"/>\
        <hp:pagePr landscape="\(landscape ? "NARROWLY" : "WIDELY")" width="\(w)" height="\(h)" gutterType="LEFT_ONLY">\
        <hp:margin header="\(header)" footer="\(footer)" gutter="0" left="\(Units.toHwp(p.marginLeft))" right="\(Units.toHwp(p.marginRight))" \
        top="\(top)" bottom="\(bottom)"/></hp:pagePr>\
        <hp:footNotePr><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/>\
        <hp:noteLine length="-1" type="SOLID" width="0.12 mm" color="#000000"/><hp:noteSpacing betweenNotes="283" belowLine="567" aboveLine="850"/>\
        <hp:numbering type="CONTINUOUS" newNum="1"/><hp:placement place="EACH_COLUMN" beneathText="0"/></hp:footNotePr>\
        <hp:endNotePr><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/>\
        <hp:noteLine length="14692344" type="SOLID" width="0.12 mm" color="#000000"/><hp:noteSpacing betweenNotes="0" belowLine="567" aboveLine="850"/>\
        <hp:numbering type="CONTINUOUS" newNum="1"/><hp:placement place="END_OF_DOCUMENT" beneathText="0"/></hp:endNotePr>\
        <hp:pageBorderFill type="BOTH" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER">\
        <hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill>\
        <hp:pageBorderFill type="EVEN" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER">\
        <hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill>\
        <hp:pageBorderFill type="ODD" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER">\
        <hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill></hp:secPr>\
        <hp:ctrl><hp:colPr id="" type="NEWSPAPER" layout="LEFT" colCount="1" sameSz="1" sameGap="0"/></hp:ctrl>
        """
    }

    /// 머리말/꼬리말 controls carried by the section's first run.
    private func headerFooter(_ s: Section) -> String {
        var out = ""
        for (tag, blocks, id) in [("header", s.header, 1), ("footer", s.footer, 2)] {
            guard let blocks, !blocks.isEmpty else { continue }
            let w = Units.toHwp(s.page.contentWidth), h = Units.toHwp(tag == "header" ? s.page.header : s.page.footer)
            out += "<hp:ctrl><hp:\(tag) id=\"\(id)\" applyPageType=\"BOTH\"><hp:subList id=\"\" textDirection=\"HORIZONTAL\" lineWrap=\"BREAK\" "
            out += "vertAlign=\"\(tag == "header" ? "TOP" : "BOTTOM")\" linkListIDRef=\"0\" linkListNextIDRef=\"0\" textWidth=\"\(w)\" textHeight=\"\(h)\" hasTextRef=\"0\" hasNumRef=\"0\">"
            out += blocks.map { block($0, sectPr: nil, width: s.page.contentWidth) }.joined()
            out += "</hp:subList></hp:\(tag)></hp:ctrl>"
        }
        return out
    }

    private func section(_ s: Section) -> String {
        var body = ""
        var first = true
        var blocks = s.blocks
        if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
        // The section definition rides in the first paragraph's first run.
        if case .table = blocks[0] { blocks.insert(.paragraph(Paragraph()), at: 0) }
        for b in blocks {
            body += block(b, sectPr: first ? secPr(s.page) + headerFooter(s) : nil, width: s.page.contentWidth)
            first = false
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?><hs:sec \(HWPXWriter.ns)>\(body)</hs:sec>"
    }

    private func block(_ b: Block, sectPr: String?, width: Double) -> String {
        switch b {
        case .paragraph(let p): return paragraph(p, sectPr: sectPr)
        case .table(let t):
            let pid = paraId; paraId += 1
            return "<hp:p id=\"\(pid)\" paraPrIDRef=\"0\" styleIDRef=\"0\" pageBreak=\"0\" columnBreak=\"0\" merged=\"0\"><hp:run charPrIDRef=\"0\">\(table(t, width: width))<hp:t/></hp:run></hp:p>"
        }
    }

    private func paragraph(_ p: Paragraph, sectPr: String?) -> String {
        let pid = paraId; paraId += 1
        var s = "<hp:p id=\"\(pid)\" paraPrIDRef=\"\(tables.paraShape(p.props))\" styleIDRef=\"0\" pageBreak=\"\(p.props.pageBreakBefore ? 1 : 0)\" columnBreak=\"0\" merged=\"0\">"
        var runs: [(Int, String)] = []
        func add(_ cs: Int, _ xml: String) {
            if let last = runs.last, last.0 == cs { runs[runs.count - 1].1 += xml } else { runs.append((cs, xml)) }
        }
        for i in p.inlines {
            switch i {
            case .text(let t, let c):
                var x = ""
                for ch in t {
                    switch ch {
                    case "\t": x += "<hp:tab/>"
                    case "\n", "\r", "\u{2028}": x += "<hp:lineBreak/>"
                    default: x += XMLEscape.text(String(ch))
                    }
                }
                add(tables.charShape(c), "<hp:t>\(x)</hp:t>")
            case .tab(let c): add(tables.charShape(c), "<hp:t><hp:tab/></hp:t>")
            case .lineBreak(let c): add(tables.charShape(c), "<hp:t><hp:lineBreak/></hp:t>")
            case .pageBreak: break
            case .field(let k, let c):
                if k == .page {
                    add(tables.charShape(c), "<hp:ctrl><hp:autoNum num=\"1\" numType=\"PAGE\"><hp:autoNumFormat type=\"DIGIT\" userChar=\"\" prefixChar=\"\" suffixChar=\"\" supscript=\"0\"/></hp:autoNum></hp:ctrl>")
                }
            case .image(let id, let w, let h):
                if let idx = tables.image(id, doc) { add(tables.charShape(p.markProps), picture(idx, w, h, id: id)) }
            }
        }
        let markCS = tables.charShape(p.markProps)
        if runs.isEmpty { runs = [(markCS, "")] }
        for (n, r) in runs.enumerated() {
            s += "<hp:run charPrIDRef=\"\(r.0)\">\(n == 0 ? (sectPr ?? "") : "")\(r.1)</hp:run>"
        }
        return s + "</hp:p>"
    }

    private func picture(_ idx: Int, _ w: Double, _ h: Double, id: String) -> String {
        var width = w, height = h
        if (width <= 0 || height <= 0), let d = doc.images[id], let s = ImageProbe.size(d.data) { width = s.width; height = s.height }
        if width <= 0 || height <= 0 { width = 100; height = 100 }
        let W = Units.toHwp(width), H = Units.toHwp(height)
        let oid = objId; objId += 1
        return """
        <hp:pic id="\(oid)" zOrder="\(oid)" numberingType="PICTURE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" \
        dropcapstyle="None" href="" groupLevel="0" instid="\(oid)" reverse="0"><hp:offset x="0" y="0"/>\
        <hp:orgSz width="\(W)" height="\(H)"/><hp:curSz width="\(W)" height="\(H)"/><hp:flip horizontal="0" vertical="0"/>\
        <hp:rotationInfo angle="0" centerX="\(W / 2)" centerY="\(H / 2)" rotateimage="1"/><hp:renderingInfo>\
        <hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/>\
        <hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/></hp:renderingInfo>\
        <hc:img binaryItemIDRef="image\(idx)" bright="0" contrast="0" effect="REAL_PIC" alpha="0"/>\
        <hp:imgRect><hc:pt0 x="0" y="0"/><hc:pt1 x="\(W)" y="0"/><hc:pt2 x="\(W)" y="\(H)"/><hc:pt3 x="0" y="\(H)"/></hp:imgRect>\
        <hp:imgClip left="0" right="\(W)" top="0" bottom="\(H)"/><hp:inMargin left="0" right="0" top="0" bottom="0"/>\
        <hp:imgDim dimwidth="\(W)" dimheight="\(H)"/><hp:effects/>\
        <hp:sz width="\(W)" widthRelTo="ABSOLUTE" height="\(H)" heightRelTo="ABSOLUTE" protect="0"/>\
        <hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" \
        horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/>\
        <hp:outMargin left="0" right="0" top="0" bottom="0"/></hp:pic>
        """
    }

    private func table(_ t: Table, width: Double) -> String {
        let grid = TableGrid(t)
        var widths = (0..<grid.cols).map { $0 < t.columnWidths.count ? t.columnWidths[$0] : 60 }
        let total = widths.reduce(0, +)
        if total > width && total > 0 { widths = widths.map { $0 * width / total } }
        let rowH = 1500
        let oid = objId; objId += 1
        var s = """
        <hp:tbl id="\(oid)" zOrder="\(oid)" numberingType="TABLE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" \
        dropcapstyle="None" pageBreak="CELL" repeatHeader="1" rowCnt="\(grid.slots.count)" colCnt="\(grid.cols)" cellSpacing="0" \
        borderFillIDRef="2" noAdjust="0"><hp:sz width="\(Units.toHwp(widths.reduce(0, +)))" widthRelTo="ABSOLUTE" \
        height="\(rowH * grid.slots.count)" heightRelTo="ABSOLUTE" protect="0"/>\
        <hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" \
        horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/>\
        <hp:outMargin left="283" right="283" top="283" bottom="283"/><hp:inMargin left="510" right="510" top="141" bottom="141"/>
        """
        for (r, row) in grid.slots.enumerated() {
            s += "<hp:tr>"
            for (c, slot) in row.enumerated() {
                guard case .origin(let cell) = slot else { continue }
                let cs = max(1, min(cell.colSpan, grid.cols - c)), rs = max(1, min(cell.rowSpan, grid.slots.count - r))
                let w = widths[c..<(c + cs)].reduce(0, +)
                let bf = tables.borderFill(cell)
                let va = ["top": "TOP", "center": "CENTER", "bottom": "BOTTOM"][cell.verticalAlign.rawValue]!
                let pad = cell.padding ?? .hwpDefault
                let cellH = cell.height.map { Int(Units.toHwp($0)) } ?? rowH * rs
                s += "<hp:tc name=\"\" header=\"0\" hasMargin=\"\(cell.padding == nil ? 0 : 1)\" protect=\"0\" editable=\"0\" dirty=\"0\" borderFillIDRef=\"\(bf)\">"
                s += "<hp:subList id=\"\" textDirection=\"HORIZONTAL\" lineWrap=\"BREAK\" vertAlign=\"\(va)\" linkListIDRef=\"0\" linkListNextIDRef=\"0\" textWidth=\"0\" textHeight=\"0\" hasTextRef=\"0\" hasNumRef=\"0\">"
                var blocks = cell.blocks
                if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
                for b in blocks { s += block(b, sectPr: nil, width: w - 10) }
                s += "</hp:subList><hp:cellAddr colAddr=\"\(c)\" rowAddr=\"\(r)\"/><hp:cellSpan colSpan=\"\(cs)\" rowSpan=\"\(rs)\"/>"
                s += "<hp:cellSz width=\"\(Units.toHwp(w))\" height=\"\(cellH)\"/><hp:cellMargin left=\"\(Units.toHwp(pad.left))\" right=\"\(Units.toHwp(pad.right))\" top=\"\(Units.toHwp(pad.top))\" bottom=\"\(Units.toHwp(pad.bottom))\"/></hp:tc>"
            }
            s += "</hp:tr>"
        }
        return s + "</hp:tbl>"
    }
}
