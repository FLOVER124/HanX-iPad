import UIKit

/// Unified model ↔ TextKit for UIKit (the iPad counterpart of the macOS
/// AttributedBridge). The editor works on one NSTextStorage shared by every
/// page; custom attributes carry what TextKit cannot express so a load →
/// edit → save round trip keeps face names, HWP line-spacing rules, images,
/// fields and tables. UIKit has no NSTextTable, so each table is one
/// paragraph holding a `TableAttachment` that keeps the exact model table.
extension NSAttributedString.Key {
    static let hwFont = NSAttributedString.Key("HWFontName")
    static let hwEastAsianFont = NSAttributedString.Key("HWEastAsianFontName")
    static let hwFamily = NSAttributedString.Key("HWResolvedFamily")
    static let hwSize = NSAttributedString.Key("HWFontSize")
    static let hwBold = NSAttributedString.Key("HWBold")
    static let hwItalic = NSAttributedString.Key("HWItalic")
    static let hwUnderline = NSAttributedString.Key("HWUnderline")
    static let hwVAlign = NSAttributedString.Key("HWVerticalAlign")
    static let hwLineRule = NSAttributedString.Key("HWLineRule")
    static let hwImage = NSAttributedString.Key("HWImageID")
    static let hwField = NSAttributedString.Key("HWField")
    static let hwStyle = NSAttributedString.Key("HWStyle")
    static let hwBottomBorder = NSAttributedString.Key("HanXParagraphBottomBorder")
    static let hwAlignment = NSAttributedString.Key("HWAlignment")
    static let hwListLabel = NSAttributedString.Key("HWListLabel")
    static let hwListMarker = NSAttributedString.Key("HWListMarker")
}

/// Keys that describe a paragraph (copied when runs are restyled).
let paragraphLevelKeys: [NSAttributedString.Key] = [.paragraphStyle, .hwLineRule, .hwStyle, .hwBottomBorder, .hwAlignment, .hwListLabel]

enum TextBridge {
    struct Context {
        var images: [String: ImageData]
        var source: SourceFormat
        var defaultTab: CGFloat { source == .docx ? 36 : 40 }
    }

    static let superscriptScale = 0.65

    // MARK: Model → attributed string

    static func attributedString(from doc: UDocument) -> NSMutableAttributedString {
        let ctx = Context(images: doc.images, source: doc.source)
        let out = NSMutableAttributedString()
        let width = doc.sections.first?.page.contentWidth ?? PageSetup().contentWidth
        for (si, section) in doc.sections.enumerated() {
            var blocks = section.blocks
            if si > 0 {
                if case .paragraph(var p)? = blocks.first {
                    p.props.pageBreakBefore = true
                    blocks[0] = .paragraph(p)
                } else {
                    var p = Paragraph(); p.props.pageBreakBefore = true
                    blocks.insert(.paragraph(p), at: 0)
                }
            }
            out.append(build(blocks, width: width, ctx: ctx))
        }
        // A trailing newline shows as an extra empty line in the editor.
        if out.length > 0, (out.string as NSString).character(at: out.length - 1) == 10 {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    static func build(_ blocks: [Block], width: Double, ctx: Context) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for b in blocks {
            switch b {
            case .paragraph(let p): out.append(paragraph(p, width: width, ctx: ctx))
            case .table(let t): out.append(tableParagraph(t, width: width, ctx: ctx))
            }
        }
        return out
    }

    static func charAttributes(_ c: CharProps, eastAsian: Bool) -> [NSAttributedString.Key: Any] {
        let name = eastAsian ? (c.eastAsianFontName ?? c.fontName) : c.fontName
        let scaled = c.verticalAlign == .baseline ? c.size : c.size * superscriptScale
        let r = FontResolver.shared.font(name: name, size: scaled, bold: c.bold, italic: c.italic)
        let color = c.color.uiColor
        var a: [NSAttributedString.Key: Any] = [
            .font: r.font, .foregroundColor: color,
            .hwFont: c.fontName, .hwEastAsianFont: c.eastAsianFontName ?? "", .hwFamily: r.font.familyName,
            .hwSize: c.size, .hwBold: c.bold, .hwItalic: c.italic,
        ]
        if r.syntheticBold { a[.strokeWidth] = -3.0; a[.strokeColor] = color }
        if r.syntheticItalic { a[.obliqueness] = 0.2 }
        switch c.underline {
        case .none: break
        case .single: a[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case .double: a[.underlineStyle] = NSUnderlineStyle.double.rawValue
        case .thick: a[.underlineStyle] = NSUnderlineStyle.thick.rawValue
        case .dotted: a[.underlineStyle] = NSUnderlineStyle.single.union(.patternDot).rawValue
        case .dashed: a[.underlineStyle] = NSUnderlineStyle.single.union(.patternDash).rawValue
        case .wave: a[.underlineStyle] = NSUnderlineStyle.single.rawValue; a[.hwUnderline] = "wave"
        }
        if c.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let h = c.highlight { a[.backgroundColor] = h.uiColor }
        switch c.verticalAlign {
        case .superscript: a[.baselineOffset] = c.size * 0.35; a[.hwVAlign] = "super"
        case .subscript: a[.baselineOffset] = -c.size * 0.15; a[.hwVAlign] = "sub"
        case .baseline: break
        }
        if c.spacing != 0 { a[.kern] = c.spacing }
        if c.widthRatio != 100 && c.widthRatio > 0 { a[.expansion] = log(c.widthRatio / 100) }
        return a
    }

    /// Splits text into East-Asian / other script runs, each with its face.
    static func text(_ s: String, _ c: CharProps) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var buf = ""
        var bufEA: Bool?
        func flush() {
            if let ea = bufEA, !buf.isEmpty { out.append(NSAttributedString(string: buf, attributes: charAttributes(c, eastAsian: ea))) }
            buf = ""
        }
        for ch in s {
            let ch: Character = ch == "\n" || ch == "\r" || ch == "\r\n" ? "\u{2028}" : ch
            let ea = ch.isWhitespace || ch.isPunctuation ? (bufEA ?? ch.isEastAsian) : ch.isEastAsian
            if ea != bufEA { flush(); bufEA = ea }
            buf.append(ch)
        }
        flush()
        return out
    }

    static func paragraphStyle(_ p: ParaProps, mark: CharProps, ctx: Context) -> (NSParagraphStyle, String?) {
        let ps = NSMutableParagraphStyle()
        switch p.alignment {
        case .left: ps.alignment = .left
        case .right: ps.alignment = .right
        case .center: ps.alignment = .center
        case .justify, .distribute: ps.alignment = .justified
        }
        ps.headIndent = CGFloat(max(0, p.indentLeft))
        ps.firstLineHeadIndent = CGFloat(max(0, p.indentLeft + p.firstLine))
        ps.tailIndent = p.indentRight > 0 ? -CGFloat(p.indentRight) : 0
        ps.paragraphSpacingBefore = CGFloat(max(0, p.spaceBefore))
        ps.paragraphSpacing = CGFloat(max(0, p.spaceAfter))
        ps.tabStops = []
        ps.defaultTabInterval = ctx.defaultTab
        var rule: String?
        switch p.lineSpacing {
        case .multiple(let m): ps.lineHeightMultiple = CGFloat(max(0.5, m))
        case .percentOfSize(let pct):
            let font = FontResolver.shared.font(name: mark.eastAsianFontName ?? mark.fontName, size: mark.size, bold: false, italic: false).font
            let natural = font.lineHeight
            let mult = natural > 0 ? CGFloat(mark.size * pct / 100) / natural : 1
            ps.lineHeightMultiple = max(0.5, mult)
            rule = String(format: "pct:%g:%.4f", pct, Double(ps.lineHeightMultiple))
        case .exact(let v): ps.minimumLineHeight = CGFloat(v); ps.maximumLineHeight = CGFloat(v)
        case .atLeast(let v): ps.minimumLineHeight = CGFloat(v)
        }
        return (ps, rule)
    }

    /// Attributes shared by every character of a paragraph.
    static func paragraphAttributes(_ p: ParaProps, mark: CharProps, ctx: Context) -> [NSAttributedString.Key: Any] {
        let (ps, rule) = paragraphStyle(p, mark: mark, ctx: ctx)
        var a: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, .hwAlignment: p.alignment.rawValue]
        if let rule { a[.hwLineRule] = rule }
        if let border = p.bottomBorder, border.visible, let encoded = try? JSONEncoder().encode(border) { a[.hwBottomBorder] = encoded }
        if let st = p.styleName { a[.hwStyle] = st }
        if let label = p.listLabel { a[.hwListLabel] = label }
        return a
    }

    static func firstTextProps(_ p: Paragraph) -> CharProps {
        p.inlines.lazy.compactMap { i -> CharProps? in if case .text(_, let c) = i { return c }; return nil }.first ?? p.markProps
    }

    static func paragraph(_ p: Paragraph, width: Double, ctx: Context) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let mark = firstTextProps(p)
        if p.props.pageBreakBefore {
            s.append(NSAttributedString(string: "\u{0C}", attributes: charAttributes(mark, eastAsian: false)))
        }
        for i in p.inlines {
            switch i {
            case .text(let t, let c): s.append(text(t, c))
            case .tab(let c): s.append(NSAttributedString(string: "\t", attributes: charAttributes(c, eastAsian: false)))
            case .lineBreak(let c): s.append(NSAttributedString(string: "\u{2028}", attributes: charAttributes(c, eastAsian: false)))
            case .pageBreak: s.append(NSAttributedString(string: "\u{0C}", attributes: charAttributes(mark, eastAsian: false)))
            case .field(let k, let c): s.append(field(k, c))
            case .image(let id, let w, let h): s.append(image(id: id, width: w, height: h, maxWidth: width, mark: mark, ctx: ctx))
            }
        }
        s.append(NSAttributedString(string: "\n", attributes: charAttributes(p.markProps, eastAsian: false)))
        s.addAttributes(paragraphAttributes(p.props, mark: mark, ctx: ctx), range: NSRange(location: 0, length: s.length))
        return s
    }

    static func field(_ k: FieldKind, _ c: CharProps) -> NSAttributedString {
        var a = charAttributes(c, eastAsian: true)
        a[.hwField] = k.rawValue
        a[.backgroundColor] = UIColor.systemBlue.withAlphaComponent(0.15)
        return NSAttributedString(string: k == .page ? "쪽" : "전체 쪽", attributes: a)
    }

    /// Replaces field placeholders with numbers (header/footer drawing).
    static func resolveFields(_ s: NSAttributedString, page: Int, pages: Int) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        var ranges: [(NSRange, String)] = []
        m.enumerateAttribute(.hwField, in: NSRange(location: 0, length: m.length)) { v, r, _ in
            if let k = v as? String { ranges.append((r, k == FieldKind.page.rawValue ? "\(page)" : "\(pages)")) }
        }
        for (r, text) in ranges.reversed() {
            var attrs = m.attributes(at: r.location, effectiveRange: nil)
            attrs[.backgroundColor] = nil
            m.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: attrs))
        }
        return m
    }

    static func image(id: String, width: Double, height: Double, maxWidth: Double, mark: CharProps, ctx: Context) -> NSAttributedString {
        let data = ctx.images[id]
        let att = NSTextAttachment()
        var img = data.flatMap { UIImage(data: $0.data) }
        if img == nil { img = placeholder(data?.ext.uppercased() ?? "?", size: CGSize(width: max(40, width), height: max(30, height))) }
        att.image = img
        var w = width, h = height
        if w <= 0 || h <= 0, let size = img?.size { w = size.width; h = size.height }
        if w > maxWidth && maxWidth > 0 { h *= maxWidth / w; w = maxWidth }
        att.bounds = CGRect(x: 0, y: 0, width: max(1, w), height: max(1, h))
        var a = charAttributes(mark, eastAsian: false)
        a[.attachment] = att
        a[.hwImage] = id
        return NSAttributedString(string: "\u{FFFC}", attributes: a)
    }

    static func placeholder(_ label: String, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.92, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.gray.setStroke(); UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)).stroke()
            ("그림 (\(label))" as NSString).draw(at: CGPoint(x: 4, y: size.height / 2 - 7),
                                               withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray])
        }
    }

    /// A table is one paragraph: an attachment character followed by "\n".
    static func tableParagraph(_ t: Table, width: Double, ctx: Context) -> NSAttributedString {
        let attachment = TableAttachment(table: t, images: ctx.images, source: ctx.source, maxWidth: CGFloat(width))
        var p = ParaProps()
        p.alignment = .left
        p.lineSpacing = .multiple(1)
        var mark = CharProps()
        mark.size = 1
        var a = charAttributes(mark, eastAsian: false)
        a[.attachment] = attachment
        let s = NSMutableAttributedString(string: "\u{FFFC}\n", attributes: a)
        s.removeAttribute(.attachment, range: NSRange(location: 1, length: 1))
        s.addAttributes(paragraphAttributes(p, mark: mark, ctx: ctx), range: NSRange(location: 0, length: s.length))
        return s
    }

    static func emptyTable(rows: Int, cols: Int, width: Double, source: SourceFormat, images: [String: ImageData]) -> NSAttributedString {
        var t = Table()
        t.columnWidths = Array(repeating: width / Double(max(1, cols)), count: cols)
        var p = Paragraph()
        p.markProps = TextDocument.defaultCharProps(for: source)
        p.props.lineSpacing = source == .docx ? .multiple(1) : .percentOfSize(160)
        p.props.alignment = .left
        t.rows = (0..<rows).map { _ in (0..<cols).map { _ in TableCell(blocks: [.paragraph(p)]) } }
        return tableParagraph(t, width: width, ctx: Context(images: images, source: source))
    }

    // MARK: Attributed string → model

    static func document(from text: NSAttributedString, base: UDocument, images: [String: ImageData], page: PageSetup) -> UDocument {
        let doc = UDocument()
        doc.source = base.source
        doc.title = base.title
        doc.images = images
        var blocks = blocks(from: text, doc: doc)
        if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
        doc.sections = [Section(page: page, blocks: blocks)]
        return doc
    }

    static func blocks(from text: NSAttributedString, doc: UDocument) -> [Block] {
        let ns = text.string as NSString
        var out: [Block] = []
        var loc = 0
        var userImages = doc.images.keys.filter { $0.hasPrefix("user/") }.count
        while loc < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if let table = tableAttachment(in: r, text: text) {
                var t = table.table
                // Images inside cells live in the document's image table.
                for (k, v) in table.images where doc.images[k] == nil { doc.images[k] = v }
                if t.rows.isEmpty { t.rows = [[TableCell(blocks: [.paragraph(Paragraph())])]] }
                out.append(.table(t))
            } else {
                out.append(.paragraph(paragraph(r, text: text, doc: doc, userImages: &userImages)))
            }
            loc = NSMaxRange(r)
        }
        return out
    }

    /// The paragraph is a table if it holds only a TableAttachment.
    static func tableAttachment(in range: NSRange, text: NSAttributedString) -> TableAttachment? {
        guard range.length >= 1, range.location < text.length else { return nil }
        let ns = text.string as NSString
        var content = range
        while content.length > 0 {
            let ch = ns.character(at: NSMaxRange(content) - 1)
            if ch == 10 || ch == 13 || ch == 0x2029 { content.length -= 1 } else { break }
        }
        var found: TableAttachment?
        var other = false
        var i = content.location
        while i < NSMaxRange(content) {
            let ch = ns.character(at: i)
            if ch == 0x0C { i += 1; continue }
            if ch == 0xFFFC, let t = text.attribute(.attachment, at: i, effectiveRange: nil) as? TableAttachment, found == nil { found = t }
            else { other = true }
            i += 1
        }
        return other ? nil : found
    }

    static func charProps(_ a: [NSAttributedString.Key: Any]) -> CharProps {
        var c = CharProps()
        let font = a[.font] as? UIFont ?? UIFont.systemFont(ofSize: 10)
        let family = font.familyName
        if let fam = a[.hwFamily] as? String, fam == family, let orig = a[.hwFont] as? String {
            c.fontName = orig
            let ea = a[.hwEastAsianFont] as? String ?? ""
            c.eastAsianFontName = ea.isEmpty ? nil : ea
        } else {
            c.fontName = family
            c.eastAsianFontName = family
        }
        let vAlign = a[.hwVAlign] as? String
        if let stored = (a[.hwSize] as? NSNumber)?.doubleValue,
           abs(stored * (vAlign == nil ? 1 : superscriptScale) - Double(font.pointSize)) < 0.05 {
            c.size = stored
        } else {
            c.size = Double(font.pointSize) / (vAlign == nil ? 1 : superscriptScale)
        }
        let traits = font.fontDescriptor.symbolicTraits
        let synthBold = ((a[.strokeWidth] as? NSNumber)?.doubleValue ?? 0) < 0
        let synthItalic = ((a[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0
        c.bold = traits.contains(.traitBold) || synthBold
        c.italic = traits.contains(.traitItalic) || synthItalic
        if let u = (a[.underlineStyle] as? NSNumber)?.intValue, u != 0 {
            let style = NSUnderlineStyle(rawValue: u)
            if a[.hwUnderline] as? String == "wave" { c.underline = .wave }
            else if style.contains(.double) { c.underline = .double }
            else if style.contains(.thick) { c.underline = .thick }
            else if style.contains(.patternDot) { c.underline = .dotted }
            else if style.contains(.patternDash) || style.contains(.patternDashDot) { c.underline = .dashed }
            else { c.underline = .single }
        }
        c.strike = ((a[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        if let fg = a[.foregroundColor] as? UIColor { c.color = RGB(fg) }
        if a[.hwField] == nil, let bg = a[.backgroundColor] as? UIColor { c.highlight = RGB(bg) }
        c.verticalAlign = vAlign == "super" ? .superscript : vAlign == "sub" ? .subscript : .baseline
        c.spacing = (a[.kern] as? NSNumber)?.doubleValue ?? 0
        if let e = (a[.expansion] as? NSNumber)?.doubleValue, e != 0 { c.widthRatio = (exp(e) * 100).rounded() }
        return c
    }

    static func paraProps(_ a: [NSAttributedString.Key: Any]) -> ParaProps {
        var p = ParaProps()
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        if let raw = a[.hwAlignment] as? String, let stored = Alignment(rawValue: raw), ps.map({ matches(stored, $0.alignment) }) ?? true {
            p.alignment = stored
        } else if let ps {
            switch ps.alignment {
            case .right: p.alignment = .right
            case .center: p.alignment = .center
            case .justified: p.alignment = .justify
            default: p.alignment = .left
            }
        }
        if let encoded = a[.hwBottomBorder] as? Data { p.bottomBorder = try? JSONDecoder().decode(BorderLine.self, from: encoded) }
        p.styleName = a[.hwStyle] as? String
        p.listLabel = a[.hwListLabel] as? String
        guard let ps else { return p }
        p.indentLeft = Double(ps.headIndent)
        p.firstLine = Double(ps.firstLineHeadIndent - ps.headIndent)
        p.indentRight = ps.tailIndent < 0 ? Double(-ps.tailIndent) : 0
        p.spaceBefore = Double(ps.paragraphSpacingBefore)
        p.spaceAfter = Double(ps.paragraphSpacing)
        if let rule = a[.hwLineRule] as? String, rule.hasPrefix("pct:") {
            let parts = rule.split(separator: ":")
            if parts.count == 3, let pct = Double(parts[1]), let m = Double(parts[2]), abs(m - Double(ps.lineHeightMultiple)) < 0.001 {
                p.lineSpacing = .percentOfSize(pct)
                return p
            }
        }
        if ps.maximumLineHeight > 0 && ps.maximumLineHeight == ps.minimumLineHeight { p.lineSpacing = .exact(Double(ps.maximumLineHeight)) }
        else if ps.minimumLineHeight > 0 { p.lineSpacing = .atLeast(Double(ps.minimumLineHeight)) }
        else if ps.lineHeightMultiple > 0 { p.lineSpacing = .multiple(Double(ps.lineHeightMultiple)) }
        else { p.lineSpacing = .multiple(1) }
        return p
    }

    private static func matches(_ a: Alignment, _ t: NSTextAlignment) -> Bool {
        switch a {
        case .left: return t == .left || t == .natural
        case .right: return t == .right
        case .center: return t == .center
        case .justify, .distribute: return t == .justified
        }
    }

    static func paragraph(_ range: NSRange, text: NSAttributedString, doc: UDocument, userImages: inout Int) -> Paragraph {
        let ns = text.string as NSString
        var content = range
        while content.length > 0 {
            let ch = ns.character(at: NSMaxRange(content) - 1)
            if ch == 10 || ch == 13 || ch == 0x2029 { content.length -= 1 } else { break }
        }
        let markAt = min(max(0, NSMaxRange(range) - 1), max(0, text.length - 1))
        var para = Paragraph()
        if text.length > 0 {
            let attrs = text.attributes(at: markAt, effectiveRange: nil)
            para.markProps = charProps(attrs)
            let first = text.attributes(at: range.location < text.length ? range.location : markAt, effectiveRange: nil)
            para.props = paraProps(first)
        }
        var pending = ""
        var pendingProps: CharProps?
        func flush() {
            if let pp = pendingProps, !pending.isEmpty { para.inlines.append(.text(pending, pp)) }
            pending = ""
        }
        text.enumerateAttributes(in: content, options: []) { attrs, r, _ in
            if attrs[.hwListMarker] != nil { return }
            if let k = (attrs[.hwField] as? String).flatMap(FieldKind.init(rawValue:)) {
                flush()
                var c = charProps(attrs)
                c.highlight = nil
                para.inlines.append(.field(k, c))
                return
            }
            let cp = charProps(attrs)
            if pendingProps != cp { flush(); pendingProps = cp }
            let sub = ns.substring(with: r)
            for ch in sub {
                switch ch {
                case "\t": flush(); para.inlines.append(.tab(cp))
                case "\u{2028}": flush(); para.inlines.append(.lineBreak(cp))
                case "\u{0C}":
                    flush()
                    if para.inlines.isEmpty { para.props.pageBreakBefore = true } else { para.inlines.append(.pageBreak) }
                case "\u{FFFC}":
                    flush()
                    if let att = attrs[.attachment] as? NSTextAttachment, !(att is TableAttachment),
                       let img = imageInline(att, id: attrs[.hwImage] as? String, doc: doc, userImages: &userImages) {
                        para.inlines.append(img)
                    }
                default: pending.append(ch)
                }
            }
        }
        flush()
        return para
    }

    private static func imageInline(_ att: NSTextAttachment, id: String?, doc: UDocument, userImages: inout Int) -> Inline? {
        let size = att.bounds.size
        if let id, doc.images[id] != nil {
            return .image(id: id, width: Double(size.width), height: Double(size.height))
        }
        var bytes = att.contents ?? att.fileWrapper?.regularFileContents
        var ext = "png"
        if let data = bytes, UIImage(data: data) == nil { bytes = nil }
        if bytes == nil, let image = att.image ?? att.image(forBounds: att.bounds, textContainer: nil, characterIndex: 0), let encoded = image.embeddableData() {
            bytes = encoded.0; ext = encoded.1
        } else if let data = bytes, data.starts(with: [0xFF, 0xD8]) { ext = "jpeg" }
        guard let data = bytes else { return nil }
        repeat { userImages += 1 } while doc.images["user/image\(userImages).\(ext)"] != nil
        let key = "user/image\(userImages).\(ext)"
        doc.images[key] = ImageData(name: "image\(userImages).\(ext)", data: data)
        var w = Double(size.width), h = Double(size.height)
        if w <= 1 || h <= 1, let s = UIImage(data: data)?.size { w = s.width; h = s.height }
        return .image(id: key, width: w, height: h)
    }
}

/// Style names HanX applies; carried as an attribute so they survive editing.
enum EditorStyleNames {
    static let known: [String] = ["바탕글", "제목", "부제목", "제목 1", "제목 2", "제목 3", "본문", "인용", "강조"]
}
