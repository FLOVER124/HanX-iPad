import UIKit

extension TextBridge {
    /// Rebuilds every run of `s` from transformed CharProps, keeping paragraph
    /// breaks, paragraph attributes, attachments and fields intact.
    static func restyled(_ s: NSAttributedString, _ change: (inout CharProps) -> Void) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let ns = s.string as NSString
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { attrs, r, _ in
            var props = charProps(attrs)
            change(&props)
            let piece: NSMutableAttributedString
            if attrs[.attachment] != nil || attrs[.hwListMarker] != nil {
                piece = NSMutableAttributedString(attributedString: s.attributedSubstring(from: r))
                if attrs[.hwListMarker] != nil {
                    var a = charAttributes(props, eastAsian: false)
                    a[.hwListMarker] = attrs[.hwListMarker]
                    piece.setAttributes(a, range: NSRange(location: 0, length: piece.length))
                }
            } else if let raw = attrs[.hwField] as? String, let kind = FieldKind(rawValue: raw) {
                piece = NSMutableAttributedString()
                let placeholder = kind == .page ? "쪽" : "전체 쪽"
                let count = max(1, ns.substring(with: r).count / max(1, placeholder.count))
                for _ in 0..<count { piece.append(field(kind, props)) }
            } else {
                piece = NSMutableAttributedString()
                let parts = ns.substring(with: r).components(separatedBy: "\n")
                for (i, part) in parts.enumerated() {
                    if i > 0 { piece.append(NSAttributedString(string: "\n", attributes: charAttributes(props, eastAsian: false))) }
                    if !part.isEmpty { piece.append(textKeepingBreaks(part, props)) }
                }
            }
            let whole = NSRange(location: 0, length: piece.length)
            for k in paragraphLevelKeys { if let v = attrs[k] { piece.addAttribute(k, value: v, range: whole) } }
            if let image = attrs[.hwImage] { piece.addAttribute(.hwImage, value: image, range: whole) }
            out.append(piece)
        }
        return out
    }

    /// Like `text(_:_:)` but keeps U+2028 / U+000C / tabs as they are.
    static func textKeepingBreaks(_ s: String, _ c: CharProps) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var buf = ""
        var bufEA: Bool?
        func flush() {
            if let ea = bufEA, !buf.isEmpty { out.append(NSAttributedString(string: buf, attributes: charAttributes(c, eastAsian: ea))) }
            buf = ""
        }
        for ch in s {
            let ea = ch.isWhitespace || ch.isPunctuation || ch == "\u{0C}" ? (bufEA ?? ch.isEastAsian) : ch.isEastAsian
            if ea != bufEA { flush(); bufEA = ea }
            buf.append(ch)
        }
        flush()
        return out
    }

    /// Applies new paragraph properties to every paragraph of `s` (which must
    /// start at a paragraph boundary).
    static func reparagraphed(_ s: NSAttributedString, ctx: Context, _ change: (inout ParaProps) -> Void) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        let ns = out.string as NSString
        var loc = 0
        while loc < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let attrs = out.attributes(at: r.location, effectiveRange: nil)
            var props = paraProps(attrs)
            change(&props)
            let mark = charProps(attrs)
            for k in paragraphLevelKeys { out.removeAttribute(k, range: r) }
            out.addAttributes(paragraphAttributes(props, mark: mark, ctx: ctx), range: r)
            loc = NSMaxRange(r)
        }
        return out
    }
}
