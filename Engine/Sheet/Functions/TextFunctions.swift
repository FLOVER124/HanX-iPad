import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

enum TextFunctions {
    static let maxLength = 32767

    /// Double-byte width used by the *B functions (Korean/CJK = 2 bytes).
    static func byteWidth(_ ch: Character) -> Int { ch.unicodeScalars.first!.value > 0xFF ? 2 : 1 }

    static func checkLength(_ s: String) throws -> SheetValue {
        guard s.count <= maxLength else { throw XLError.value }
        return .string(s)
    }

    static let cp949 = String.Encoding(rawValue: 0x80000422)
    static let cp1252 = String.Encoding.windowsCP1252

    static func register(_ r: inout Registry) {
        r.scalar("TEXT", "FORMATTEDNUMBER", min: 2, max: 2) { s in
            let fmt = try s.str(1)
            switch s.raw(0) {
            case .number(let d): return .string(NumberFormatter2.format(d, fmt))
            case .bool(let b): return .string(b ? "TRUE" : "FALSE")
            case .empty: return .string(NumberFormatter2.format(0, fmt))
            case .error(let e): throw XLError(e)
            default:
                let t = try s.str(0)
                if let d = SheetValue.parseNumber(t) { return .string(NumberFormatter2.format(d, fmt)) }
                return .string(NumberFormatter2.formatText(t, fmt))
            }
        }
        r.scalar("FIXED", min: 1, max: 3) { s in
            let v = try s.num(0), dec = try s.int(1, 2), noCommas = try s.bool(2, false)
            guard dec <= 127 else { throw XLError.value }
            let rounded = Num.round(v, dec)
            let places = max(0, dec)
            let fmt = (noCommas ? "0" : "#,##0") + (places > 0 ? "." + String(repeating: "0", count: places) : "")
            return .string(NumberFormatter2.format(rounded, fmt))
        }
        func dollar(_ s: Scalars, symbol: String, parens: Bool) throws -> SheetValue {
            let v = try s.num(0), dec = try s.int(1, 2)
            guard dec <= 127 else { throw XLError.value }
            let rounded = Num.round(v, dec)
            let places = max(0, dec)
            let body = "#,##0" + (places > 0 ? "." + String(repeating: "0", count: places) : "")
            let text = NumberFormatter2.format(abs(rounded), body)
            if rounded < 0 { return .string(parens ? "(" + symbol + text + ")" : "-" + symbol + text) }
            return .string(symbol + text)
        }
        r.scalar("DOLLAR", min: 1, max: 2) { s in
            let sym = Locale.current.currencySymbol ?? "₩"
            return try dollar(s, symbol: sym, parens: sym == "$")
        }
        r.scalar("USDOLLAR", min: 1, max: 2) { s in try dollar(s, symbol: "$", parens: true) }
        r.scalar("VALUE", min: 1, max: 1) { s in
            switch s.raw(0) {
            case .number(let d): return .number(d)
            case .empty: return .number(0)
            case .bool: throw XLError.value
            case .error(let e): throw XLError(e)
            default:
                guard let d = SheetValue.parseNumber(try s.str(0)) else { throw XLError.value }
                return .number(d)
            }
        }
        r.scalar("NUMBERVALUE", min: 1, max: 3) { s in
            var t = try s.str(0).filter { !$0.isWhitespace }
            let dec = try s.str(1, Locale.current.decimalSeparator ?? ".").first ?? "."
            let grp = try s.str(2, Locale.current.groupingSeparator ?? ",").first ?? ","
            guard dec != grp else { throw XLError.value }
            if t.isEmpty { return .number(0) }
            var pct = 0
            while t.hasSuffix("%") { pct += 1; t.removeLast() }
            if let di = t.firstIndex(of: dec), t[t.index(after: di)...].contains(grp) { throw XLError.value }
            t = t.replacingOccurrences(of: String(grp), with: "")
            guard t.filter({ $0 == dec }).count <= 1 else { throw XLError.value }
            t = t.replacingOccurrences(of: String(dec), with: ".")
            guard var d = Double(t) else { throw XLError.value }
            for _ in 0..<pct { d /= 100 }
            return .number(d)
        }

        // Characters
        r.scalar("CHAR", min: 1, max: 1) { s in
            let n = try s.int(0)
            guard (1...255).contains(n) else { throw XLError.value }
            return .string(String(data: Data([UInt8(n)]), encoding: cp1252) ?? String(UnicodeScalar(UInt8(n))))
        }
        r.scalar("CODE", min: 1, max: 1) { s in
            let t = try s.str(0)
            guard let ch = t.first else { throw XLError.value }
            if let d = String(ch).data(using: cp1252), d.count == 1 { return .number(Double(d[0])) }
            if let d = String(ch).data(using: cp949), d.count == 2 { return .number(Double(Int(d[0]) << 8 | Int(d[1]))) }
            return .number(63)
        }
        r.scalar("UNICHAR", min: 1, max: 1) { s in
            let n = try s.int(0)
            guard n >= 1, n <= 0x10FFFF, let u = UnicodeScalar(UInt32(n)) else { throw n == 0 ? XLError.value : XLError.value }
            if (0xFDD0...0xFDEF).contains(n) || n & 0xFFFE == 0xFFFE { throw XLError.na }
            return .string(String(Character(u)))
        }
        r.scalar("UNICODE", min: 1, max: 1) { s in
            guard let u = try s.str(0).unicodeScalars.first else { throw XLError.value }
            return .number(Double(u.value))
        }
        r.scalar("CLEAN", min: 1, max: 1) { s in .string(String(try s.str(0).unicodeScalars.filter { $0.value >= 32 }.map(Character.init))) }
        r.scalar("TRIM", min: 1, max: 1) { s in
            let parts = try s.str(0).split(separator: " ", omittingEmptySubsequences: true)
            return .string(parts.joined(separator: " "))
        }
        r.scalar("LOWER", min: 1, max: 1) { s in .string(try s.str(0).lowercased()) }
        r.scalar("UPPER", min: 1, max: 1) { s in .string(try s.str(0).uppercased()) }
        r.scalar("PROPER", min: 1, max: 1) { s in
            var out = "", prevLetter = false
            for ch in try s.str(0) {
                out += prevLetter ? ch.lowercased() : ch.uppercased()
                prevLetter = ch.isLetter
            }
            return .string(out)
        }
        r.scalar("ASC", min: 1, max: 1) { s in
            let text = try s.str(0)
            return .string(text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
        }
        r.scalar("DBCS", "JIS", min: 1, max: 1) { s in
            let text = try s.str(0)
            return .string(text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text)
        }
        r.raw("PHONETIC", min: 1, max: 1) { a in .string(a.value(0).text) }

        // Substrings
        r.scalar("LEN", min: 1, max: 1) { s in .number(Double(try s.str(0).count)) }
        r.scalar("LENB", min: 1, max: 1) { s in .number(Double(try s.str(0).reduce(0) { $0 + byteWidth($1) })) }
        r.scalar("LEFT", min: 1, max: 2) { s in
            let n = try s.int(1, 1)
            guard n >= 0 else { throw XLError.value }
            return .string(String(try s.str(0).prefix(n)))
        }
        r.scalar("RIGHT", min: 1, max: 2) { s in
            let n = try s.int(1, 1)
            guard n >= 0 else { throw XLError.value }
            return .string(String(try s.str(0).suffix(n)))
        }
        r.scalar("MID", min: 3, max: 3) { s in
            let t = Array(try s.str(0)), start = try s.int(1), n = try s.int(2)
            guard start >= 1, n >= 0 else { throw XLError.value }
            guard start <= t.count else { return .string("") }
            return .string(String(t[(start - 1)..<min(t.count, start - 1 + n)]))
        }
        func bytes(_ t: String, from start: Int, count: Int) -> String {
            // Takes characters whose byte span lies within [start, start+count).
            var out = "", pos = 1
            for ch in t {
                let w = byteWidth(ch)
                if pos >= start && pos + w - 1 < start + count { out.append(ch) }
                else if pos < start + count && pos + w - 1 >= start && w == 2 { out.append(" ") }
                pos += w
                if pos >= start + count { break }
            }
            return out
        }
        r.scalar("LEFTB", min: 1, max: 2) { s in
            let n = try s.int(1, 1)
            guard n >= 0 else { throw XLError.value }
            return .string(bytes(try s.str(0), from: 1, count: n))
        }
        r.scalar("RIGHTB", min: 1, max: 2) { s in
            let t = try s.str(0), n = try s.int(1, 1)
            guard n >= 0 else { throw XLError.value }
            let total = t.reduce(0) { $0 + byteWidth($1) }
            return .string(bytes(t, from: max(1, total - n + 1), count: min(n, total)))
        }
        r.scalar("MIDB", min: 3, max: 3) { s in
            let start = try s.int(1), n = try s.int(2)
            guard start >= 1, n >= 0 else { throw XLError.value }
            return .string(bytes(try s.str(0), from: start, count: n))
        }
        func find(_ s: Scalars, insensitive: Bool, bytesMode: Bool) throws -> SheetValue {
            let needle = try s.str(0), hay = try s.str(1)
            let start = try s.int(2, 1)
            let chars = Array(hay)
            // In byte mode the start position and result are byte offsets.
            func charIndex(fromByte b: Int) -> Int {
                var pos = 1
                for (i, ch) in chars.enumerated() { if pos >= b { return i }; pos += byteWidth(ch) }
                return chars.count
            }
            func byteOffset(ofChar i: Int) -> Int { chars[..<i].reduce(1) { $0 + byteWidth($1) } }
            let startChar = bytesMode ? charIndex(fromByte: start) : start - 1
            guard start >= 1, startChar <= chars.count else { throw XLError.value }
            if needle.isEmpty { return .number(Double(start)) }
            let tail = String(chars[startChar...])
            let range: Range<String.Index>?
            if insensitive, let rx = Criteria.wildcard(needle) {
                range = tail.range(of: String(rx.dropFirst().dropLast()), options: [.regularExpression, .caseInsensitive])
            } else {
                range = tail.range(of: needle, options: insensitive ? [.caseInsensitive] : [.literal])
            }
            guard let range else { throw XLError.value }
            let idx = startChar + tail.distance(from: tail.startIndex, to: range.lowerBound)
            return .number(Double(bytesMode ? byteOffset(ofChar: idx) : idx + 1))
        }
        r.scalar("FIND", min: 2, max: 3) { try find($0, insensitive: false, bytesMode: false) }
        r.scalar("FINDB", min: 2, max: 3) { try find($0, insensitive: false, bytesMode: true) }
        r.scalar("SEARCH", min: 2, max: 3) { try find($0, insensitive: true, bytesMode: false) }
        r.scalar("SEARCHB", min: 2, max: 3) { try find($0, insensitive: true, bytesMode: true) }
        r.scalar("REPLACE", min: 4, max: 4) { s in
            var t = Array(try s.str(0))
            let start = try s.int(1), n = try s.int(2), new = try s.str(3)
            guard start >= 1, n >= 0 else { throw XLError.value }
            let a = min(start - 1, t.count), b = min(t.count, a + n)
            t.replaceSubrange(a..<b, with: Array(new))
            return try checkLength(String(t))
        }
        r.scalar("REPLACEB", min: 4, max: 4) { s in
            let t = try s.str(0), start = try s.int(1), n = try s.int(2), new = try s.str(3)
            guard start >= 1, n >= 0 else { throw XLError.value }
            var out = "", pos = 1, inserted = false
            for ch in t {
                let w = byteWidth(ch)
                if pos >= start && pos < start + n { if !inserted { out += new; inserted = true } }
                else { if pos >= start + n && !inserted { out += new; inserted = true }; out.append(ch) }
                pos += w
            }
            if !inserted { out += new }
            return try checkLength(out)
        }
        r.scalar("SUBSTITUTE", min: 3, max: 4) { s in
            let t = try s.str(0), old = try s.str(1), new = try s.str(2)
            if old.isEmpty { return .string(t) }
            if s.has(3) {
                let k = try s.int(3)
                guard k >= 1 else { throw XLError.value }
                var count = 0
                var search = t.startIndex
                while let r = t.range(of: old, range: search..<t.endIndex) {
                    count += 1
                    if count == k { return try checkLength(t.replacingCharacters(in: r, with: new)) }
                    search = r.upperBound
                }
                return .string(t)
            }
            return try checkLength(t.replacingOccurrences(of: old, with: new))
        }
        r.scalar("REPT", min: 2, max: 2) { s in
            let t = try s.str(0), n = try s.int(1)
            guard n >= 0, t.count * n <= maxLength else { throw XLError.value }
            return .string(String(repeating: t, count: n))
        }
        r.scalar("EXACT", min: 2, max: 2) { s in .bool(try s.str(0) == s.str(1)) }

        // Joining
        r.scalar("CONCATENATE", min: 1, max: 255) { s in
            try checkLength(try (0..<s.count).map { try s.str($0) }.joined())
        }
        r.raw("CONCAT", min: 1) { a in
            var out = ""
            for v in a.flat() {
                if case .error(let e) = v { throw XLError(e) }
                out += v.text
            }
            return try checkLength(out)
        }
        r.raw("TEXTJOIN", min: 3) { a in
            let delims = a.flat(from: 0, to: 1).map(\.text)
            let ignore = try a.bool(1)
            var parts: [String] = []
            for v in a.flat(from: 2) {
                if case .error(let e) = v { throw XLError(e) }
                let t = v.text
                if ignore && t.isEmpty { continue }
                parts.append(t)
            }
            var out = ""
            for (i, p) in parts.enumerated() {
                if i > 0 { out += delims.isEmpty ? "" : delims[(i - 1) % delims.count] }
                out += p
            }
            return try checkLength(out)
        }
        r.table["TEXTBEFORE"] = { a in try textAround(a, before: true) }
        r.table["TEXTAFTER"] = { a in try textAround(a, before: false) }
        r.raw("TEXTSPLIT", min: 2, max: 6) { a in try textSplit(a) }
        r.raw("VALUETOTEXT", min: 1, max: 2) { a in
            let strict = try a.int(1, 0)
            guard strict == 0 || strict == 1 else { throw XLError.value }
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
                .string(valueText(s.raw(0), strict: strict == 1))
            }
        }
        r.raw("ARRAYTOTEXT", min: 1, max: 2) { a in
            let strict = try a.int(1, 0)
            guard strict == 0 || strict == 1 else { throw XLError.value }
            let m = a.grid(0)
            if strict == 1 {
                return try checkLength("{" + m.grid.map { $0.map { valueText($0, strict: true) }.joined(separator: ",") }.joined(separator: ";") + "}")
            }
            return try checkLength(m.data.map { valueText($0, strict: false) }.joined(separator: ", "))
        }

        // Regular expressions (ICU syntax, close to Excel's PCRE2)
        func regex(_ pattern: String, _ insensitive: Bool) throws -> NSRegularExpression {
            do { return try NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : []) }
            catch { throw XLError.value }
        }
        r.scalar("REGEXTEST", min: 2, max: 3) { s in
            let t = try s.str(0), rx = try regex(try s.str(1), try s.int(2, 0) == 1)
            return .bool(rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil)
        }
        r.raw("REGEXEXTRACT", min: 2, max: 4) { a in
            let mode = try a.int(2, 0)
            guard (0...2).contains(mode) else { throw XLError.value }
            let insensitive = try a.int(3, 0) == 1
            if mode == 0 {
                return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0)), .value(a.value(1))]), lifted: nil) { s in
                    let t = try s.str(0), rx = try regex(try s.str(1), insensitive)
                    guard let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) else { throw XLError.na }
                    return .string(String(t[r]))
                }
            }
            let t = try a.str(0), rx = try regex(try a.str(1), insensitive)
            let ns = t as NSString
            if mode == 1 {
                let all = rx.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { SheetValue.string(ns.substring(with: $0.range)) }
                guard !all.isEmpty else { throw XLError.na }
                return .array(.column(all))
            }
            guard let m = rx.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { throw XLError.na }
            let groups = (1..<max(1, m.numberOfRanges)).map { i -> SheetValue in
                m.range(at: i).location == NSNotFound ? .string("") : .string(ns.substring(with: m.range(at: i)))
            }
            return groups.isEmpty ? .string(ns.substring(with: m.range)) : .array(.row(groups))
        }
        r.scalar("REGEXREPLACE", min: 3, max: 5) { s in
            let t = try s.str(0), rx = try regex(try s.str(1), try s.int(4, 0) == 1)
            let repl = try s.str(2), occurrence = try s.int(3, 0)
            let ns = t as NSString
            let matches = rx.matches(in: t, range: NSRange(location: 0, length: ns.length))
            if occurrence == 0 {
                return try checkLength(rx.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length), withTemplate: repl))
            }
            let idx = occurrence > 0 ? occurrence - 1 : matches.count + occurrence
            guard idx >= 0, idx < matches.count else { return .string(t) }
            let m = matches[idx]
            let replacement = rx.replacementString(for: m, in: t, offset: 0, template: repl)
            return try checkLength(ns.replacingCharacters(in: m.range, with: replacement))
        }

        r.scalar("ENCODEURL", min: 1, max: 1) { s in
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
            return .string(try s.str(0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        r.scalar("DETECTLANGUAGE", min: 1, max: 1) { s in
            #if canImport(NaturalLanguage)
            let rec = NLLanguageRecognizer()
            rec.processString(try s.str(0))
            guard let lang = rec.dominantLanguage else { throw XLError.value }
            return .string(lang.rawValue)
            #else
            throw XLError.connect
            #endif
        }
        r.raw("TRANSLATE", min: 1, max: 3) { _ in throw XLError.connect }

        // Thai language support
        r.scalar("BAHTTEXT", min: 1, max: 1) { s in .string(Thai.bahtText(try s.num(0))) }
        r.scalar("THAIDIGIT", min: 1, max: 1) { s in
            .string(String(try s.str(0).map { ch -> Character in
                if let d = ch.wholeNumberValue, ch.isASCII { return Character(UnicodeScalar(0x0E50 + UInt32(d))!) }
                return ch
            }))
        }
        r.scalar("ISTHAIDIGIT", min: 1, max: 1) { s in
            let t = try s.str(0)
            return .bool(!t.isEmpty && t.unicodeScalars.allSatisfy { (0x0E50...0x0E59).contains($0.value) })
        }
        r.scalar("THAINUMSOUND", min: 1, max: 1) { s in .string(Thai.words(try s.num(0).rounded(.towardZero))) }
        r.scalar("THAINUMSTRING", min: 1, max: 1) { s in
            let v = try s.num(0)
            let whole = Thai.words(v.rounded(.towardZero))
            let frac = abs(v) - floor(abs(v))
            if frac == 0 { return .string(whole) }
            let digits = String(String(format: "%.10g", frac).dropFirst(2))
            return .string(whole + "จุด" + digits.compactMap { $0.wholeNumberValue }.map { Thai.digits[$0] }.joined())
        }
        r.scalar("THAISTRINGLENGTH", min: 1, max: 1) { s in
            // Counts base characters (combining vowels/tone marks do not add length).
            .number(Double(try s.str(0).count))
        }
        r.num("ROUNDBAHTDOWN", min: 1, max: 1) { s in floor(try s.num(0) * 4) / 4 }
        r.num("ROUNDBAHTUP", min: 1, max: 1) { s in ceil(try s.num(0) * 4) / 4 }
    }

    static func valueText(_ v: SheetValue, strict: Bool) -> String {
        switch v {
        case .string(let s): return strict ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        case .empty: return ""
        default: return v.text
        }
    }

    static func textAround(_ a: Args, before: Bool) throws -> SheetValue {
        guard a.count >= 2, a.count <= 6 else { throw XLError.value }
        let delims = a.flat(from: 1, to: 2).map(\.text)
        let instance = try a.int(2, 1)
        let insensitive = try a.int(3, 0) == 1
        let matchEnd = try a.int(4, 0) == 1
        let notFound: SheetValue? = a.has(5) ? a.value(5) : nil
        guard instance != 0 else { throw XLError.value }
        return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
            let t = try s.str(0)
            guard abs(instance) <= max(1, t.count) || delims.allSatisfy({ $0.isEmpty }) else { throw XLError.value }
            // All delimiter occurrences in order (leftmost-first, longest wins at the same spot).
            var hits: [Range<String.Index>] = []
            if delims.allSatisfy({ $0.isEmpty }) {
                hits = [t.startIndex..<t.startIndex]
            } else {
                var i = t.startIndex
                while i < t.endIndex {
                    var best: Range<String.Index>?
                    for d in delims where !d.isEmpty {
                        if let r = t.range(of: d, options: insensitive ? [.caseInsensitive, .anchored] : [.anchored], range: i..<t.endIndex),
                           best == nil || r.upperBound > best!.upperBound { best = r }
                    }
                    if let b = best { hits.append(b); i = b.upperBound } else { i = t.index(after: i) }
                }
            }
            if matchEnd {
                if instance > 0 { hits.append(t.endIndex..<t.endIndex) } else { hits.insert(t.startIndex..<t.startIndex, at: 0) }
            }
            let idx = instance > 0 ? instance - 1 : hits.count + instance
            guard idx >= 0, idx < hits.count else {
                if let notFound { return notFound }
                throw XLError.na
            }
            let h = hits[idx]
            return .string(before ? String(t[..<h.lowerBound]) : String(t[h.upperBound...]))
        }
    }

    static func textSplit(_ a: Args) throws -> SheetValue {
        let t = try a.str(0)
        let colDelims = a.has(1) ? a.flat(from: 1, to: 2).map(\.text).filter { !$0.isEmpty } : []
        let rowDelims = a.has(2) ? a.flat(from: 2, to: 3).map(\.text).filter { !$0.isEmpty } : []
        guard !colDelims.isEmpty || !rowDelims.isEmpty else { throw XLError.value }
        let ignoreEmpty = try a.bool(3, false)
        let insensitive = try a.int(4, 0) == 1
        let pad: SheetValue = a.has(5) ? a.value(5) : .error("#N/A")
        func split(_ s: String, by delims: [String]) -> [String] {
            guard !delims.isEmpty else { return [s] }
            var out: [String] = [], cur = ""
            var i = s.startIndex
            while i < s.endIndex {
                var matched: Range<String.Index>?
                for d in delims {
                    if let r = s.range(of: d, options: insensitive ? [.caseInsensitive, .anchored] : [.anchored], range: i..<s.endIndex),
                       matched == nil || r.upperBound > matched!.upperBound { matched = r }
                }
                if let m = matched { out.append(cur); cur = ""; i = m.upperBound } else { cur.append(s[i]); i = s.index(after: i) }
            }
            out.append(cur)
            return ignoreEmpty ? out.filter { !$0.isEmpty } : out
        }
        let rows = split(t, by: rowDelims).map { split($0, by: colDelims) }
        let width = rows.map(\.count).max() ?? 0
        guard !rows.isEmpty, width > 0 else { throw XLError.calc }
        var m = Matrix(rows: rows.count, cols: width, fill: pad)
        for (r, row) in rows.enumerated() { for (c, v) in row.enumerated() { m[r, c] = .string(v) } }
        return .array(m)
    }
}

enum Thai {
    static let digits = ["ศูนย์", "หนึ่ง", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด", "เก้า"]
    static let places = ["", "สิบ", "ร้อย", "พัน", "หมื่น", "แสน"]

    /// Words for a non-negative integer below one million, Thai rules
    /// (เอ็ด for trailing one, ยี่สิบ for twenty, สิบ without หนึ่ง).
    private static func chunk(_ n: Int) -> String {
        var out = ""
        let s = Array(String(n))
        for (i, ch) in s.enumerated() {
            let d = ch.wholeNumberValue!
            let place = s.count - i - 1
            if d == 0 { continue }
            if place == 1 && d == 1 { out += "สิบ"; continue }
            if place == 1 && d == 2 { out += "ยี่สิบ"; continue }
            if place == 0 && d == 1 && s.count > 1 { out += "เอ็ด"; continue }
            out += digits[d] + places[place]
        }
        return out
    }

    static func words(_ v: Double) -> String {
        if v == 0 { return digits[0] }
        var n = abs(v)
        var groups: [Int] = []
        while n >= 1 { groups.append(Int(n.truncatingRemainder(dividingBy: 1_000_000))); n = floor(n / 1_000_000) }
        var out = ""
        for (i, g) in groups.enumerated().reversed() {
            if g > 0 || i == 0 { out += g > 0 ? chunk(g) : "" }
            if i > 0 { out += "ล้าน" }
        }
        return (v < 0 ? "ลบ" : "") + out
    }

    static func bahtText(_ v: Double) -> String {
        let r = Num.round(abs(v), 2)
        let baht = floor(r), satang = Int(((r - baht) * 100).rounded())
        var out = v < 0 ? "ลบ" : ""
        if baht > 0 { out += words(baht) + "บาท" }
        if satang > 0 { out += words(Double(satang)) + "สตางค์" }
        else { out += (baht == 0 ? "ศูนย์บาท" : "") + "ถ้วน" }
        return out
    }
}
