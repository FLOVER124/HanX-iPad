import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Writes a minimal, strictly valid WordprocessingML package from the
/// unified model. Every property is written as direct formatting so the
/// output renders identically regardless of the reader's default styles.
final class DOCXWriter {
    private let doc: UDocument
    private var media: [(path: String, data: Data)] = []
    private var mediaRel: [String: String] = [:]      // model image id → rId
    private var relXML = ""
    private var nextRel = 10
    private var drawingId = 1

    init(_ doc: UDocument) { self.doc = doc }

    func write() -> Data {
        var body = ""
        for (si, section) in doc.sections.enumerated() {
            let last = si == doc.sections.count - 1
            var blocks = section.blocks
            if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
            for (bi, b) in blocks.enumerated() {
                let sectPr = !last && bi == blocks.count - 1 ? sectionXML(section) : nil
                if case .table = b, sectPr != nil {
                    body += block(b)
                    body += "<w:p><w:pPr>\(sectPr!)</w:pPr></w:p>"
                } else if case .paragraph(let p) = b {
                    body += paragraph(p, sectPr: sectPr)
                } else {
                    body += block(b)
                }
            }
            if last {
                if case .table? = blocks.last { body += "<w:p/>" }
                body += sectionXML(section)
            }
        }

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """

        let base = doc.sections.first?.blocks.lazy.compactMap { b -> CharProps? in
            if case .paragraph(let p) = b { return p.markProps } else { return nil }
        }.first ?? CharProps()

        let z = ZipWriter()
        z.add("[Content_Types].xml", contentTypes())
        z.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        </Relationships>
        """)
        z.add("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(XMLEscape.text(doc.title ?? ""))</dc:title>\
        <dc:creator>HanX</dc:creator></cp:coreProperties>
        """)
        z.add("word/document.xml", documentXML)
        z.add("word/styles.xml", stylesXML(base))
        z.add("word/settings.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:defaultTabStop w:val="800"/><w:compat><w:compatSetting w:name="compatibilityMode" \
        w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
        """)
        z.add("word/_rels/document.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>\
        \(relXML)</Relationships>
        """)
        for m in media { z.add(m.path, m.data, compress: false) }
        for h in headerParts { z.add(h.path, h.xml) }
        return z.finish()
    }

    private func contentTypes() -> String {
        var defaults = ""
        let types = ["png": "image/png", "jpeg": "image/jpeg", "jpg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp",
                     "tif": "image/tiff", "tiff": "image/tiff", "emf": "image/x-emf", "wmf": "image/x-wmf"]
        for (ext, mime) in types.sorted(by: { $0.key < $1.key }) { defaults += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>" }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(defaults)\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        \(headerParts.map { "<Override PartName=\"/\($0.path)\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.\($0.isHeader ? "header" : "footer")+xml\"/>" }.joined())\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """
    }

    private func stylesXML(_ base: CharProps) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr>\(fonts(base))<w:sz w:val="\(Int(base.size * 2))"/><w:lang w:val="ko-KR" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        \(DOCXWriter.styleIDs.values.sorted { $0.id < $1.id }.map { st in
            "<w:style w:type=\"paragraph\" w:styleId=\"\(st.id)\"><w:name w:val=\"\(st.name)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + (st.outline.map { "<w:pPr><w:keepNext/><w:outlineLvl w:val=\"\($0)\"/></w:pPr>" } ?? "") + "</w:style>"
        }.joined())\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>\
        <w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        </w:styles>
        """
    }

    private var headerParts: [(path: String, xml: String, isHeader: Bool)] = []

    /// Writes a header/footer part and returns its relationship id.
    private func headerFooterPart(_ blocks: [Block], header: Bool) -> String {
        // Images inside headers would need the part's own relationships; drop them.
        func strip(_ b: Block) -> Block {
            switch b {
            case .paragraph(var p):
                p.inlines = p.inlines.filter { if case .image = $0 { return false }; return true }
                return .paragraph(p)
            case .table(var t):
                t.rows = t.rows.map { $0.map { var c = $0; c.blocks = c.blocks.map(strip); return c } }
                return .table(t)
            }
        }
        let n = headerParts.filter { $0.isHeader == header }.count + 1
        let tag = header ? "hdr" : "ftr", name = header ? "header\(n).xml" : "footer\(n).xml"
        var inner = blocks.map(strip).map(block).joined()
        if inner.isEmpty || { if case .table? = blocks.last { return true }; return false }() { inner += "<w:p/>" }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:\(tag) xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(inner)</w:\(tag)>"
        headerParts.append(("word/" + name, xml, header))
        let rid = "rId\(nextRel)"; nextRel += 1
        relXML += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(header ? "header" : "footer")\" Target=\"\(name)\"/>"
        return rid
    }

    private func sectionXML(_ section: Section) -> String {
        let p = section.page
        var refs = ""
        if let h = section.header, !h.isEmpty { refs += "<w:headerReference w:type=\"default\" r:id=\"\(headerFooterPart(h, header: true))\"/>" }
        if let f = section.footer, !f.isEmpty { refs += "<w:footerReference w:type=\"default\" r:id=\"\(headerFooterPart(f, header: false))\"/>" }
        let orient = p.width > p.height ? " w:orient=\"landscape\"" : ""
        return "<w:sectPr>\(refs)<w:pgSz w:w=\"\(Units.toTwips(p.width))\" w:h=\"\(Units.toTwips(p.height))\"\(orient)/>"
            + "<w:pgMar w:top=\"\(Units.toTwips(p.marginTop))\" w:right=\"\(Units.toTwips(p.marginRight))\" "
            + "w:bottom=\"\(Units.toTwips(p.marginBottom))\" w:left=\"\(Units.toTwips(p.marginLeft))\" "
            + "w:header=\"\(Units.toTwips(p.header))\" w:footer=\"\(Units.toTwips(p.footer))\" w:gutter=\"0\"/></w:sectPr>"
    }

    private func block(_ b: Block) -> String {
        switch b {
        case .paragraph(let p): return paragraph(p, sectPr: nil)
        case .table(let t): return table(t)
        }
    }

    private func fonts(_ c: CharProps) -> String {
        let latin = XMLEscape.text(c.fontName)
        let ea = XMLEscape.text(c.eastAsianFontName ?? c.fontName)
        return "<w:rFonts w:ascii=\"\(latin)\" w:hAnsi=\"\(latin)\" w:eastAsia=\"\(ea)\" w:cs=\"\(latin)\"/>"
    }

    private func runProps(_ c: CharProps) -> String {
        var s = "<w:rPr>" + fonts(c)
        if c.bold { s += "<w:b/><w:bCs/>" }
        if c.italic { s += "<w:i/><w:iCs/>" }
        if c.strike { s += "<w:strike/>" }
        if c.color != .black { s += "<w:color w:val=\"\(c.color.hex)\"/>" }
        if c.spacing != 0 { s += "<w:spacing w:val=\"\(Units.toTwips(c.spacing))\"/>" }
        if c.widthRatio != 100 && c.widthRatio > 0 { s += "<w:w w:val=\"\(Int(c.widthRatio.rounded()))\"/>" }
        let hp = max(2, Int((c.size * 2).rounded()))
        s += "<w:sz w:val=\"\(hp)\"/><w:szCs w:val=\"\(hp)\"/>"
        switch c.underline {
        case .none: break
        case .single: s += "<w:u w:val=\"single\"/>"
        case .double: s += "<w:u w:val=\"double\"/>"
        case .dotted: s += "<w:u w:val=\"dotted\"/>"
        case .dashed: s += "<w:u w:val=\"dash\"/>"
        case .wave: s += "<w:u w:val=\"wave\"/>"
        case .thick: s += "<w:u w:val=\"thick\"/>"
        }
        if let h = c.highlight { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(h.hex)\"/>" }
        switch c.verticalAlign {
        case .superscript: s += "<w:vertAlign w:val=\"superscript\"/>"
        case .subscript: s += "<w:vertAlign w:val=\"subscript\"/>"
        case .baseline: break
        }
        return s + "</w:rPr>"
    }

    /// HanX style names ↔ WordprocessingML built-in style ids.
    static let styleIDs: [String: (id: String, name: String, outline: Int?)] = [
        "제목": ("Title", "Title", nil), "부제목": ("Subtitle", "Subtitle", nil),
        "제목 1": ("Heading1", "heading 1", 0), "제목 2": ("Heading2", "heading 2", 1), "제목 3": ("Heading3", "heading 3", 2),
        "인용": ("Quote", "Quote", nil), "강조": ("IntenseQuote", "Intense Quote", nil),
    ]

    private func paragraph(_ p: Paragraph, sectPr: String?) -> String {
        let pr = p.props
        var s = "<w:p><w:pPr>"
        if let st = pr.styleName, let id = DOCXWriter.styleIDs[st]?.id { s += "<w:pStyle w:val=\"\(id)\"/>" }
        if pr.pageBreakBefore { s += "<w:pageBreakBefore/>" }
        if let border = pr.bottomBorder { s += "<w:pBdr>" + edge("bottom", border) + "</w:pBdr>" }
        var spacing = "<w:spacing w:before=\"\(Units.toTwips(pr.spaceBefore))\" w:after=\"\(Units.toTwips(pr.spaceAfter))\""
        switch pr.lineSpacing {
        case .multiple(let m): spacing += " w:line=\"\(Int((m * 240).rounded()))\" w:lineRule=\"auto\""
        case .percentOfSize(let pct):
            // HWP measures pitch from the font size, Word from the font's line
            // height (~1.2× size for CJK faces), so rescale.
            spacing += " w:line=\"\(Int((pct / 100 / 1.2 * 240).rounded()))\" w:lineRule=\"auto\""
        case .exact(let v): spacing += " w:line=\"\(Units.toTwips(v))\" w:lineRule=\"exact\""
        case .atLeast(let v): spacing += " w:line=\"\(Units.toTwips(v))\" w:lineRule=\"atLeast\""
        }
        s += spacing + "/>"
        var ind = "<w:ind w:left=\"\(Units.toTwips(pr.indentLeft))\" w:right=\"\(Units.toTwips(pr.indentRight))\""
        if pr.firstLine >= 0 { ind += " w:firstLine=\"\(Units.toTwips(pr.firstLine))\"" }
        else { ind += " w:hanging=\"\(Units.toTwips(-pr.firstLine))\"" }
        s += ind + "/>"
        let jc: String
        switch pr.alignment {
        case .left: jc = "left"
        case .right: jc = "right"
        case .center: jc = "center"
        case .justify: jc = "both"
        case .distribute: jc = "distribute"
        }
        s += "<w:jc w:val=\"\(jc)\"/>"
        s += runProps(p.markProps)
        if let sp = sectPr { s += sp }
        s += "</w:pPr>"
        for i in p.inlines { s += inline(i) }
        return s + "</w:p>"
    }

    private func inline(_ i: Inline) -> String {
        switch i {
        case .text(let t, let c):
            // Embedded newlines/tabs from pasted text become proper elements.
            var out = "<w:r>" + runProps(c)
            var buf = ""
            func flush() { if !buf.isEmpty { out += "<w:t xml:space=\"preserve\">\(XMLEscape.text(buf))</w:t>"; buf = "" } }
            for ch in t {
                switch ch {
                case "\t": flush(); out += "<w:tab/>"
                case "\n", "\r", "\u{2028}": flush(); out += "<w:br/>"
                case "\u{0C}": flush(); out += "<w:br w:type=\"page\"/>"
                default: buf.append(ch)
                }
            }
            flush()
            return out + "</w:r>"
        case .tab(let c): return "<w:r>" + runProps(c) + "<w:tab/></w:r>"
        case .lineBreak(let c): return "<w:r>" + runProps(c) + "<w:br/></w:r>"
        case .pageBreak: return "<w:r><w:br w:type=\"page\"/></w:r>"
        case .field(let k, let c):
            return "<w:fldSimple w:instr=\" \(k == .page ? "PAGE" : "NUMPAGES") \\* MERGEFORMAT \"><w:r>" + runProps(c) + "<w:t>1</w:t></w:r></w:fldSimple>"
        case .image(let id, let w, let h): return image(id, w, h)
        }
    }

    private func image(_ id: String, _ w: Double, _ h: Double) -> String {
        guard let img = doc.images[id] else { return "" }
        let rid: String
        if let existing = mediaRel[id] { rid = existing } else {
            rid = "rId\(nextRel)"; nextRel += 1
            var ext = img.ext.isEmpty ? "png" : img.ext
            if !["png", "jpeg", "jpg", "gif", "bmp", "tif", "tiff", "emf", "wmf"].contains(ext) { ext = "png" }
            let path = "media/image\(media.count + 1).\(ext)"
            media.append(("word/" + path, img.data))
            relXML += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(path)\"/>"
            mediaRel[id] = rid
        }
        var width = w, height = h
        if width <= 0 || height <= 0, let size = ImageProbe.size(img.data) { width = size.width; height = size.height }
        if width <= 0 || height <= 0 { width = 100; height = 100 }
        let cx = Units.toEmu(width), cy = Units.toEmu(height)
        let n = drawingId; drawingId += 1
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(n)" name="Picture \(n)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(n)" name="\(XMLEscape.text(img.name))"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private func table(_ t: Table) -> String {
        let grid = TableGrid(t)
        var s = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>"
        s += "<w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"0\" w:type=\"dxa\"/></w:tblCellMar>"
        s += "<w:tblLook w:val=\"0000\"/></w:tblPr><w:tblGrid>"
        for c in 0..<grid.cols {
            let w = c < t.columnWidths.count ? t.columnWidths[c] : 72
            s += "<w:gridCol w:w=\"\(Units.toTwips(w))\"/>"
        }
        s += "</w:tblGrid>"
        for row in grid.slots {
            // Word stores one height per row; use the tallest single-row cell.
            let heights = row.compactMap { slot -> Double? in
                if case .origin(let c) = slot, c.rowSpan <= 1 { return c.height } else { return nil }
            }
            s += "<w:tr>"
            if let h = heights.max(), h > 0 { s += "<w:trPr><w:trHeight w:val=\"\(Units.toTwips(h))\" w:hRule=\"atLeast\"/></w:trPr>" }
            var c = 0
            for (ci, slot) in row.enumerated() {
                if ci < c { continue }
                let span = grid.span(slot)
                guard span > 0 else { continue }
                let width = (ci..<min(grid.cols, ci + span)).reduce(0.0) { $0 + (($1 < t.columnWidths.count) ? t.columnWidths[$1] : 72) }
                s += "<w:tc><w:tcPr><w:tcW w:w=\"\(Units.toTwips(width))\" w:type=\"dxa\"/>"
                if span > 1 { s += "<w:gridSpan w:val=\"\(span)\"/>" }
                switch slot {
                case .origin(let cell):
                    if cell.rowSpan > 1 { s += "<w:vMerge w:val=\"restart\"/>" }
                    s += cellProps(cell)
                    s += "</w:tcPr>"
                    var blocks = cell.blocks
                    if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
                    for b in blocks { s += block(b) }
                    if case .table? = blocks.last { s += "<w:p/>" }
                case .vertical(let owner):
                    s += "<w:vMerge/>"
                    s += cellProps(owner)
                    s += "</w:tcPr><w:p/>"
                case .covered: break
                }
                s += "</w:tc>"
                c = ci + span
            }
            s += "</w:tr>"
        }
        return s + "</w:tbl>"
    }
}

extension DOCXWriter {
    func edge(_ name: String, _ l: BorderLine) -> String {
        guard l.visible else { return "<w:\(name) w:val=\"nil\"/>" }
        let v: String
        switch l.style {
        case .double: v = "double"
        case .dotted: v = "dotted"
        case .dashed: v = "dashed"
        default: v = "single"
        }
        return "<w:\(name) w:val=\"\(v)\" w:sz=\"\(max(2, Int((l.width * 8).rounded())))\" w:space=\"0\" w:color=\"\(l.color.hex)\"/>"
    }
    /// tcBorders + shading + margins + vertical alignment, in schema order.
    fileprivate func cellProps(_ cell: TableCell) -> String {
        let b = cell.borders
        var s = "<w:tcBorders>" + edge("top", b.top) + edge("left", b.left) + edge("bottom", b.bottom) + edge("right", b.right) + "</w:tcBorders>"
        if let bg = cell.background { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(bg.hex)\"/>" }
        let p = cell.padding ?? .wordDefault
        s += "<w:tcMar><w:top w:w=\"\(Units.toTwips(p.top))\" w:type=\"dxa\"/><w:left w:w=\"\(Units.toTwips(p.left))\" w:type=\"dxa\"/>"
        s += "<w:bottom w:w=\"\(Units.toTwips(p.bottom))\" w:type=\"dxa\"/><w:right w:w=\"\(Units.toTwips(p.right))\" w:type=\"dxa\"/></w:tcMar>"
        switch cell.verticalAlign {
        case .center: s += "<w:vAlign w:val=\"center\"/>"
        case .bottom: s += "<w:vAlign w:val=\"bottom\"/>"
        case .top: break
        }
        return s
    }
}

/// Pixel size → points (assuming 96 dpi) for PNG/JPEG/GIF/BMP headers.
enum ImageProbe {
    static func size(_ data: Data) -> (width: Double, height: Double)? {
        let b = [UInt8](data.prefix(64 * 1024))
        func be16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        func be32(_ o: Int) -> Int { be16(o) << 16 | be16(o + 2) }
        let scale = 72.0 / 96.0
        if b.count > 24, b[0] == 0x89, b[1] == 0x50 { return (Double(be32(16)) * scale, Double(be32(20)) * scale) }
        if b.count > 10, b[0] == 0x47, b[1] == 0x49 {
            return (Double(Int(b[6]) | Int(b[7]) << 8) * scale, Double(Int(b[8]) | Int(b[9]) << 8) * scale)
        }
        if b.count > 26, b[0] == 0x42, b[1] == 0x4D {
            return (Double(ByteReader.u32(b, 18)) * scale, Double(abs(Int32(bitPattern: ByteReader.u32(b, 22)))) * scale)
        }
        if b.count > 4, b[0] == 0xFF, b[1] == 0xD8 {
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { i += 1; continue }
                let m = b[i + 1]
                if (0xC0...0xCF).contains(m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
                    return (Double(be16(i + 7)) * scale, Double(be16(i + 5)) * scale)
                }
                i += 2 + be16(i + 2)
            }
        }
        return nil
    }
}
