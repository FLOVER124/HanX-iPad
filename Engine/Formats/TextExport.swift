import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTML, Markdown and plain-text exporters for the unified document model.
enum HTMLWriter {
    static func write(_ doc: UDocument) -> String {
        let page = doc.sections.first?.page ?? PageSetup()
        var body = ""
        for (i, s) in doc.sections.enumerated() {
            if i > 0 { body += "<hr class=\"section\">" }
            for b in s.blocks { body += block(b, doc) }
        }
        return """
        <!DOCTYPE html>
        <html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(XMLEscape.text(doc.title ?? "문서"))</title>
        <style>
        body{background:#e8e8e8;margin:0;padding:24px 0}
        .page{background:#fff;max-width:\(Int(page.width))pt;margin:0 auto;padding:\(Int(page.marginTop))pt \(Int(page.marginRight))pt \(Int(page.marginBottom))pt \(Int(page.marginLeft))pt;box-sizing:border-box;box-shadow:0 1px 4px rgba(0,0,0,.25)}
        p{margin:0;white-space:pre-wrap;word-break:keep-all}
        table{border-collapse:collapse;margin:0}
        td{vertical-align:top}
        img{max-width:100%}
        @media print{body{background:none;padding:0}.page{box-shadow:none;margin:0;max-width:none}}
        </style></head><body><div class="page">\(body)</div></body></html>
        """
    }

    private static func css(_ c: CharProps) -> String {
        var s = "font-family:'\(c.eastAsianFontName ?? c.fontName)','\(c.fontName)',sans-serif;font-size:\(fmt(c.size))pt;"
        if c.bold { s += "font-weight:bold;" }
        if c.italic { s += "font-style:italic;" }
        var deco: [String] = []
        if c.underline != .none { deco.append("underline") }
        if c.strike { deco.append("line-through") }
        if !deco.isEmpty { s += "text-decoration:\(deco.joined(separator: " "));" }
        if c.underline == .double { s += "text-decoration-style:double;" }
        if c.underline == .wave { s += "text-decoration-style:wavy;" }
        if c.color != .black { s += "color:#\(c.color.hex);" }
        if let h = c.highlight { s += "background:#\(h.hex);" }
        if c.spacing != 0 { s += "letter-spacing:\(fmt(c.spacing))pt;" }
        if c.verticalAlign != .baseline { s += "vertical-align:\(c.verticalAlign == .superscript ? "super" : "sub");font-size:\(fmt(c.size * 0.7))pt;" }
        return s
    }

    private static func fmt(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }

    private static func paragraph(_ p: Paragraph, _ doc: UDocument) -> String {
        let pr = p.props
        var s = "margin:\(fmt(pr.spaceBefore))pt \(fmt(pr.indentRight))pt \(fmt(pr.spaceAfter))pt \(fmt(pr.indentLeft))pt;text-indent:\(fmt(pr.firstLine))pt;"
        s += "text-align:\(["left": "left", "right": "right", "center": "center", "justify": "justify", "distribute": "justify"][pr.alignment.rawValue]!);"
        switch pr.lineSpacing {
        case .multiple(let m): s += "line-height:\(fmt(m * 1.15));"
        case .percentOfSize(let p): s += "line-height:\(fmt(p / 100));"
        case .exact(let v): s += "line-height:\(fmt(v))pt;"
        case .atLeast(let v): s += "min-height:\(fmt(v))pt;"
        }
        if pr.pageBreakBefore { s += "page-break-before:always;" }
        var inner = ""
        for i in p.inlines {
            switch i {
            case .text(let t, let c): inner += "<span style=\"\(css(c))\">\(XMLEscape.text(t))</span>"
            case .tab: inner += "\t"
            case .field(let k, let c): inner += "<span style=\"\(css(c))\" class=\"\(k == .page ? "page-number" : "page-count")\">1</span>"
            case .lineBreak: inner += "<br>"
            case .pageBreak: inner += "<span style=\"page-break-after:always\"></span>"
            case .image(let id, let w, let h):
                guard let img = doc.images[id] else { continue }
                let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff"][img.ext] ?? "image/png"
                let size = w > 0 && h > 0 ? " style=\"width:\(fmt(w))pt;height:\(fmt(h))pt\"" : ""
                inner += "<img src=\"data:\(mime);base64,\(img.data.base64EncodedString())\"\(size) alt=\"\">"
            }
        }
        if inner.isEmpty { inner = "<span style=\"\(css(p.markProps))\">&#8203;</span>" }
        return "<p style=\"\(s)\">\(inner)</p>"
    }

    private static func border(_ l: BorderLine) -> String {
        guard l.visible else { return "none" }
        let style = ["solid": "solid", "dotted": "dotted", "dashed": "dashed", "double": "double", "none": "none"][l.style.rawValue]!
        return "\(fmt(max(0.5, l.width)))pt \(style) #\(l.color.hex)"
    }

    private static func block(_ b: Block, _ doc: UDocument) -> String {
        switch b {
        case .paragraph(let p): return paragraph(p, doc)
        case .table(let t):
            let grid = TableGrid(t)
            var s = "<table>"
            s += "<colgroup>" + (0..<grid.cols).map { c in "<col style=\"width:\(fmt(c < t.columnWidths.count ? t.columnWidths[c] : 60))pt\">" }.joined() + "</colgroup>"
            for row in grid.slots {
                let h = row.compactMap { slot -> Double? in if case .origin(let c) = slot, c.rowSpan == 1 { return c.height } else { return nil } }.max()
                s += h.map { "<tr style=\"height:\(fmt($0))pt\">" } ?? "<tr>"
                for slot in row {
                    guard case .origin(let cell) = slot else { continue }
                    let pad = cell.padding ?? .hwpDefault
                    var st = "border-left:\(border(cell.borders.left));border-right:\(border(cell.borders.right));"
                    st += "border-top:\(border(cell.borders.top));border-bottom:\(border(cell.borders.bottom));"
                    st += "padding:\(fmt(pad.top))pt \(fmt(pad.right))pt \(fmt(pad.bottom))pt \(fmt(pad.left))pt;"
                    st += "vertical-align:\(["top": "top", "center": "middle", "bottom": "bottom"][cell.verticalAlign.rawValue]!);"
                    if let bg = cell.background { st += "background:#\(bg.hex);" }
                    var span = ""
                    if cell.colSpan > 1 { span += " colspan=\"\(cell.colSpan)\"" }
                    if cell.rowSpan > 1 { span += " rowspan=\"\(cell.rowSpan)\"" }
                    s += "<td style=\"\(st)\"\(span)>" + cell.blocks.map { block($0, doc) }.joined() + "</td>"
                }
                s += "</tr>"
            }
            return s + "</table>"
        }
    }
}

enum MarkdownWriter {
    static func write(_ doc: UDocument) -> String {
        doc.sections.flatMap(\.blocks).map(block).joined(separator: "\n\n") + "\n"
    }

    private static func inline(_ p: Paragraph) -> String {
        var out = ""
        for i in p.inlines {
            switch i {
            case .text(let t, let c):
                let core = t.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty else { out += t; continue }
                var s = core.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
                if c.bold && c.italic { s = "***\(s)***" } else if c.bold { s = "**\(s)**" } else if c.italic { s = "*\(s)*" }
                if c.strike { s = "~~\(s)~~" }
                let lead = t.prefix { $0 == " " }, trail = String(t.reversed().prefix { $0 == " " })
                out += String(lead) + s + trail
            case .tab: out += "\t"
            case .field: out += "#"
            case .lineBreak: out += "  \n"
            case .pageBreak: out += "\n\n---\n\n"
            case .image: out += "![그림]()"
            }
        }
        return out
    }

    private static func block(_ b: Block) -> String {
        switch b {
        case .paragraph(let p):
            let text = inline(p)
            // Large bold single-line paragraphs read as headings.
            let size = p.inlines.lazy.compactMap { i -> CharProps? in if case .text(_, let c) = i { return c }; return nil }.first?.size ?? 10
            if !text.contains("\n") && text.count < 80 && !text.isEmpty {
                if size >= 20 { return "# " + text.replacingOccurrences(of: "**", with: "") }
                if size >= 15 { return "## " + text.replacingOccurrences(of: "**", with: "") }
            }
            return text
        case .table(let t):
            let grid = TableGrid(t)
            var rows: [[String]] = []
            for row in grid.slots {
                rows.append(row.map { slot in
                    guard case .origin(let c) = slot else { return "" }
                    return c.blocks.map(block).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
                })
            }
            guard let head = rows.first else { return "" }
            var out = "| " + head.joined(separator: " | ") + " |\n|" + head.map { _ in " --- |" }.joined() + "\n"
            for r in rows.dropFirst() { out += "| " + r.joined(separator: " | ") + " |\n" }
            return out
        }
    }
}
