import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Excel number-format engine used for cell display and TEXT():
/// up to four sections with [conditions], colours/locales, literals and
/// escapes, digit placeholders (0 # ?), grouping and thousands scaling,
/// percent, scientific, fractions, dates/times (incl. elapsed [h]:mm and
/// Korean 요일/오전·오후) and the text section (@).
enum NumberFormatter2 {
    enum Token {
        case literal(String)
        case digit(Character)          // 0 # ?
        case point
        case comma
        case percent
        case exponent(String)          // E+ / E- / e+ / e-
        case slash
        case date(String)              // y, m, d, h, s, a (Korean weekday) codes, lower-cased
        case elapsed(Character)        // [h] [m] [s]
        case ampm(String)              // AM/PM, A/P
        case subSecond(Int)            // .0, .00, .000 after seconds
        case text                      // @
    }

    struct Section {
        var tokens: [Token] = []
        var condition: (op: String, value: Double)?
        var korean = false
        var isDate: Bool { tokens.contains { if case .date = $0 { return true }; if case .elapsed = $0 { return true }; if case .ampm = $0 { return true }; return false } }
        var hasDigits: Bool { tokens.contains { if case .digit = $0 { return true }; return false } }
        var hasText: Bool { tokens.contains { if case .text = $0 { return true }; return false } }
    }

    private static var cache: [String: [Section]] = [:]

    static func sections(_ fmt: String) -> [Section] {
        if let s = cache[fmt] { return s }
        var out: [Section] = []
        var cur = Section()
        let c = Array(fmt)
        var i = 0
        func lit(_ s: String) {
            if case .literal(let p)? = cur.tokens.last { cur.tokens[cur.tokens.count - 1] = .literal(p + s) } else { cur.tokens.append(.literal(s)) }
        }
        while i < c.count {
            let ch = c[i]
            let lower = Character(ch.lowercased())
            switch ch {
            case ";": out.append(cur); cur = Section(); i += 1; continue
            case "\"":
                var j = i + 1, s = ""
                while j < c.count && c[j] != "\"" { s.append(c[j]); j += 1 }
                lit(s); i = j + 1; continue
            case "\\": if i + 1 < c.count { lit(String(c[i + 1])) }; i += 2; continue
            case "_": lit(" "); i += 2; continue
            case "*": i += 2; continue
            case "[":
                var j = i + 1, inner = ""
                while j < c.count && c[j] != "]" { inner.append(c[j]); j += 1 }
                i = j + 1
                let li = inner.lowercased()
                if li == "h" || li == "hh" { cur.tokens.append(.elapsed("h")) }
                else if li == "m" || li == "mm" { cur.tokens.append(.elapsed("m")) }
                else if li == "s" || li == "ss" { cur.tokens.append(.elapsed("s")) }
                else if inner.hasPrefix("$") {
                    let body = inner.dropFirst()
                    let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    if let sym = parts.first, !sym.isEmpty { lit(String(sym)) }
                    if parts.count > 1, parts[1].uppercased().hasSuffix("412") { cur.korean = true }
                } else if let m = inner.range(of: #"^(<=|>=|<>|<|>|=)\s*(-?[0-9.]+)$"#, options: .regularExpression) {
                    let cond = String(inner[m])
                    let op = String(cond.prefix { "<>=".contains($0) })
                    cur.condition = (op, Double(cond.dropFirst(op.count).trimmingCharacters(in: .whitespaces)) ?? 0)
                }
                continue
            case "0", "#", "?": cur.tokens.append(.digit(ch)); i += 1; continue
            case ".":
                // Sub-second precision after seconds (ss.00)
                if let last = cur.tokens.last, case .date(let d) = last, d.hasPrefix("s"), i + 1 < c.count, c[i + 1] == "0" {
                    var j = i + 1
                    while j < c.count && c[j] == "0" { j += 1 }
                    cur.tokens.append(.subSecond(j - i - 1)); i = j; continue
                }
                cur.tokens.append(.point); i += 1; continue
            case ",": cur.tokens.append(.comma); i += 1; continue
            case "%": cur.tokens.append(.percent); i += 1; continue
            case "/": cur.tokens.append(.slash); i += 1; continue
            case "@": cur.tokens.append(.text); i += 1; continue
            default: break
            }
            if (lower == "e") && i + 1 < c.count && (c[i + 1] == "+" || c[i + 1] == "-") {
                cur.tokens.append(.exponent(String([ch, c[i + 1]]))); i += 2; continue
            }
            let rest = String(c[i...]).uppercased()
            if rest.hasPrefix("AM/PM") { cur.tokens.append(.ampm("AM/PM")); i += 5; continue }
            if rest.hasPrefix("A/P") { cur.tokens.append(.ampm(String(c[i..<(i + 3)]))); i += 3; continue }
            if rest.hasPrefix("오전/오후") { cur.tokens.append(.ampm("오전/오후")); i += 5; continue }
            if "ymdhsa".contains(lower) || lower == "e" || lower == "g" || lower == "b" {
                var j = i
                while j < c.count && Character(c[j].lowercased()) == lower { j += 1 }
                let code = String(repeating: lower, count: j - i)
                if lower == "e" { cur.tokens.append(.date("yyyy")) }        // e = year in Japanese era; use Gregorian year
                else if lower == "g" || lower == "b" { /* era names unsupported: skip */ }
                else if lower == "a" && j - i < 3 { lit(String(c[i..<j])) }
                else { cur.tokens.append(.date(code)) }
                i = j; continue
            }
            if lower == "g", rest.hasPrefix("GENERAL") { cur.tokens.append(.literal("\u{1}GENERAL")); i += 7; continue }
            lit(String(ch)); i += 1
        }
        out.append(cur)
        // "General" inside a section
        cache[fmt] = out
        return out
    }

    /// Picks the section and sign handling for a number.
    private static func pick(_ d: Double, _ secs: [Section]) -> (Section, Double, Bool)? {
        let numeric = secs.count > 3 ? Array(secs.prefix(3)) : secs.filter { !$0.hasText || $0.hasDigits || $0.isDate }.isEmpty ? secs : secs
        let conditional = numeric.contains { $0.condition != nil }
        if conditional {
            for (i, s) in numeric.prefix(2).enumerated() {
                guard let c = s.condition else { continue }
                let ok: Bool
                switch c.op {
                case "<": ok = d < c.value
                case "<=": ok = d <= c.value
                case ">": ok = d > c.value
                case ">=": ok = d >= c.value
                case "<>": ok = d != c.value
                default: ok = d == c.value
                }
                // A second section matching a negative bound shows the magnitude.
                if ok { return (s, i == 1 && d < 0 && c.value <= 0 ? abs(d) : d, false) }
            }
            if numeric.count >= 3 { return (numeric[2], d, false) }
            if numeric.count == 2, numeric[1].condition == nil { return (numeric[1], d < 0 ? abs(d) : d, d < 0) }
            return nil
        }
        if d < 0 && numeric.count >= 2 { return (numeric[1], -d, false) }
        if d == 0 && numeric.count >= 3 { return (numeric[2], 0, false) }
        return (numeric[0], abs(d), d < 0)
    }

    static func format(_ d: Double, _ fmt: String) -> String {
        if fmt.isEmpty || fmt.caseInsensitiveCompare("General") == .orderedSame { return SheetValue.general(d) }
        let secs = sections(fmt)
        guard let (sec, value, minus) = pick(d, secs) else { return String(repeating: "#", count: 8) }
        var text: String
        if sec.isDate {
            guard d >= 0, d < 2958466 else { return String(repeating: "#", count: 8) }
            text = date(d, sec)
            return text
        } else if sec.hasDigits {
            text = number(value, sec)
        } else {
            text = ""
            for t in sec.tokens {
                switch t {
                case .literal(let s): text += s == "\u{1}GENERAL" ? SheetValue.general(value) : s
                case .percent: text += "%"
                case .text: text += SheetValue.general(d)
                case .comma: text += ","
                case .point: text += "."
                case .slash: text += "/"
                default: break
                }
            }
            if sec.tokens.contains(where: { if case .literal(let s) = $0 { return s == "\u{1}GENERAL" }; return false }) {
                return (minus ? "-" : "") + text
            }
            return text
        }
        if minus && text.contains(where: { $0.isNumber && $0 != "0" }) { text = "-" + text }
        return text
    }

    /// TEXT()/display of a string through a format's text section.
    static func formatText(_ s: String, _ fmt: String) -> String {
        let secs = sections(fmt)
        let sec: Section
        if secs.count >= 4 { sec = secs[3] }
        else if let t = secs.first(where: { $0.hasText }) { sec = t }
        else { return s }
        var out = ""
        for t in sec.tokens {
            switch t {
            case .literal(let l): out += l
            case .text: out += s
            default: break
            }
        }
        return out
    }

    // MARK: Numbers

    private static func number(_ value: Double, _ sec: Section) -> String {
        var v = value
        let toks = sec.tokens
        let percentCount = toks.filter { if case .percent = $0 { return true }; return false }.count
        for _ in 0..<percentCount { v *= 100 }

        // Scientific
        if let ei = toks.firstIndex(where: { if case .exponent = $0 { return true }; return false }) {
            return scientific(v, Array(toks[..<ei]), toks[ei], Array(toks[(ei + 1)...]))
        }
        // Fractions
        if let si = toks.firstIndex(where: { if case .slash = $0 { return true }; return false }),
           toks[..<si].contains(where: { if case .digit = $0 { return true }; return false }) {
            return fraction(v, toks, slashAt: si)
        }

        // Thousands scaling: commas right after the last integer placeholder.
        let pointAt = toks.firstIndex { if case .point = $0 { return true }; return false }
        let intEnd = pointAt ?? toks.count
        var lastDigit = -1
        for i in 0..<intEnd { if case .digit = toks[i] { lastDigit = i } }
        var scaleCommas = 0
        var j = lastDigit + 1
        while j < intEnd, case .comma = toks[j] { scaleCommas += 1; j += 1 }
        for _ in 0..<scaleCommas { v /= 1000 }
        let grouping = toks[..<max(0, lastDigit)].contains { if case .comma = $0 { return true }; return false }

        let fracPlaces: [Character] = pointAt.map { p in toks[(p + 1)...].compactMap { if case .digit(let c) = $0 { return c }; return nil } } ?? []
        let rounded = Num.round(v, fracPlaces.count)
        let fixed = String(format: "%.\(fracPlaces.count)f", rounded).split(separator: ".", omittingEmptySubsequences: false)
        var intPart = String(fixed[0])
        let fracDigits = fixed.count > 1 ? String(fixed[1]) : ""
        if intPart == "0" { intPart = "" }

        // Integer section: assign digits right-to-left to placeholders.
        var intTokens = Array(toks[..<intEnd])
        if scaleCommas > 0 { intTokens.removeLast(scaleCommas) }
        let intPlaceholders = intTokens.filter { if case .digit = $0 { return true }; return false }.count
        var digits = Array(intPart)
        var pieces: [String] = []
        var placeholdersSeen = 0
        for t in intTokens.reversed() {
            switch t {
            case .digit(let c):
                placeholdersSeen += 1
                if placeholdersSeen == intPlaceholders {
                    // Leftmost placeholder takes all remaining digits.
                    if !digits.isEmpty { pieces.append(String(digits)); digits = [] }
                    else { pieces.append(c == "0" ? "0" : c == "?" ? " " : "") }
                } else if let last = digits.popLast() { pieces.append(String(last)) }
                else { pieces.append(c == "0" ? "0" : c == "?" ? " " : "") }
            case .literal(let s): pieces.append(s)
            case .percent: pieces.append("%")
            case .comma: break
            default: break
            }
        }
        var intText = pieces.reversed().joined()
        if intPlaceholders == 0 { intText = String(digits) + intText }
        if grouping {
            // Insert separators into the digit run.
            intText = group(intText)
        }
        var out = intText
        if let p = pointAt {
            out += "."
            var fd = Array(fracDigits)
            // Trailing optional placeholders drop/blank zeros.
            var k = fracPlaces.count - 1
            while k >= 0 && fd.count > k && fd[k] == "0" && fracPlaces[k] != "0" {
                fd[k] = fracPlaces[k] == "?" ? " " : "\u{0}"
                k -= 1
            }
            var idx = 0
            for t in toks[(p + 1)...] {
                switch t {
                case .digit:
                    if idx < fd.count, fd[idx] != "\u{0}" { out.append(fd[idx]) }
                    idx += 1
                case .literal(let s): out += s
                case .percent: out += "%"
                default: break
                }
            }
            if fracPlaces.allSatisfy({ $0 == "#" }) && fd.allSatisfy({ $0 == "\u{0}" }) && out.hasSuffix(".") == false {
                // keep trailing point like Excel ("0.#" → "5.")
            }
        }
        return out
    }

    private static func group(_ s: String) -> String {
        // Finds the longest run of digits (first one) and groups it.
        guard let start = s.firstIndex(where: \.isNumber) else { return s }
        var end = start
        while end < s.endIndex && s[end].isNumber { end = s.index(after: end) }
        let run = Array(s[start..<end])
        var g = ""
        for (i, ch) in run.enumerated() {
            if i > 0 && (run.count - i) % 3 == 0 { g.append(",") }
            g.append(ch)
        }
        return String(s[..<start]) + g + String(s[end...])
    }

    private static func scientific(_ v: Double, _ mant: [Token], _ e: Token, _ expo: [Token]) -> String {
        guard case .exponent(let sign) = e else { return "" }
        let intDigits = max(1, mant.prefix { if case .point = $0 { return false }; return true }.filter { if case .digit = $0 { return true }; return false }.count)
        let fracCount = mant.drop { if case .point = $0 { return false }; return true }.dropFirst().filter { if case .digit = $0 { return true }; return false }.count
        var exp = v == 0 ? 0 : Int(floor(log10(abs(v))))
        // Engineering-style grouping when several integer placeholders (##0.0E+0).
        if intDigits > 1 { exp = Int(floor(Double(exp) / Double(intDigits))) * intDigits }
        var mantissa = v / pow(10, Double(exp))
        mantissa = Num.round(mantissa, fracCount)
        if abs(mantissa) >= pow(10, Double(intDigits)) { exp += intDigits; mantissa = Num.round(v / pow(10, Double(exp)), fracCount) }
        let m = String(format: "%.\(fracCount)f", mantissa)
        let expDigits = max(1, expo.filter { if case .digit = $0 { return true }; return false }.count)
        let es = String(format: "%0\(expDigits)d", abs(exp))
        let signText = exp < 0 ? "-" : (sign.hasSuffix("+") ? "+" : "")
        let prefix = mant.compactMap { if case .literal(let s) = $0 { return s }; return nil }.joined()
        return prefix + m + String(sign.prefix(1)) + signText + es
    }

    private static func fraction(_ v: Double, _ toks: [Token], slashAt si: Int) -> String {
        let denomTokens = Array(toks[(si + 1)...])
        let fixedDenom = Int(denomTokens.compactMap { if case .literal(let s) = $0 { return s }; return nil }.joined().trimmingCharacters(in: .whitespaces))
        let denPlaces = denomTokens.filter { if case .digit = $0 { return true }; return false }.count
        // Whole-number part exists if there is a literal/space separating two digit groups before the slash.
        let before = Array(toks[..<si])
        var groups: [[Token]] = [[]]
        for t in before {
            if case .digit = t { groups[groups.count - 1].append(t) } else if !(groups.last?.isEmpty ?? true) { groups.append([]) }
        }
        groups = groups.filter { !$0.isEmpty }
        let hasWhole = groups.count >= 2
        var whole = hasWhole ? floor(v) : 0
        let frac = v - whole
        var num = 0, den = 1
        if let fd = fixedDenom, fd > 0 {
            den = fd; num = Int((frac * Double(fd)).rounded())
        } else {
            let maxDen = Int(pow(10, Double(max(1, denPlaces)))) - 1
            var best = (0, 1, Double.infinity)
            for d in 1...max(1, maxDen) {
                let n = (frac * Double(d)).rounded()
                let err = abs(frac - n / Double(d))
                if err < best.2 - 1e-12 { best = (Int(n), d, err) }
                if err == 0 { break }
            }
            num = best.0; den = best.1
        }
        if num == den && hasWhole { whole += 1; num = 0 }
        let pad = { (s: String, n: Int) in String(repeating: " ", count: max(0, n - s.count)) + s }
        let numPlaces = groups.last?.count ?? 1
        if num == 0 && hasWhole {
            return pad(String(Int(whole)), groups.first?.count ?? 1) + String(repeating: " ", count: numPlaces + 1 + max(denPlaces, String(den).count) + 1)
        }
        let wholeText = hasWhole ? (whole == 0 ? "" : String(Int(whole))) + " " : ""
        let numText = hasWhole ? String(num) : String(Int((v * Double(den)).rounded()))
        return wholeText + pad(numText, numPlaces) + "/" + (fixedDenom != nil ? String(den) : String(den) + String(repeating: " ", count: max(0, denPlaces - String(den).count)))
    }

    // MARK: Dates

    static let monthsEN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let daysEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let daysKO = ["일", "월", "화", "수", "목", "금", "토"]

    /// Formats a serial with a plain format string (used by TEXT and others).
    static func date(_ serial: Double, _ fmt: String) -> String {
        guard let sec = sections(fmt).first else { return "" }
        return date(serial, sec)
    }

    private static func date(_ serial: Double, _ sec: Section) -> String {
        let toks = sec.tokens
        let subDigits = toks.compactMap { if case .subSecond(let n) = $0 { return n }; return nil }.first ?? 0
        let hasSeconds = toks.contains { if case .date(let c) = $0 { return c.hasPrefix("s") }; if case .elapsed(let c) = $0 { return c == "s" }; return false }
        // Round to the displayed precision.
        let unit = hasSeconds ? 86400 * pow(10, Double(subDigits)) : 86400
        let totalUnits = (serial * unit).rounded()
        let s2 = totalUnits / unit
        let (y, mo, d) = DateSerial.ymd(s2)
        let dayFrac = s2 - floor(s2)
        let secsOfDay = dayFrac * 86400
        let hour = Int(secsOfDay / 3600), minute = Int(secsOfDay.truncatingRemainder(dividingBy: 3600) / 60)
        let second = Int(secsOfDay.truncatingRemainder(dividingBy: 60))
        let sub = secsOfDay - floor(secsOfDay)
        let weekday = DateSerial.weekday(s2) - 1
        let twelve = toks.contains { if case .ampm = $0 { return true }; return false }

        // Disambiguate m/mm (minutes after h or before s).
        var kinds: [String] = []
        for t in toks { if case .date(let c) = t { kinds.append(c) } else if case .elapsed(let c) = t { kinds.append("[" + String(c)) } }
        var out = ""
        var dateIdx = 0
        for (i, t) in toks.enumerated() {
            switch t {
            case .literal(let s): out += s == "\u{1}GENERAL" ? SheetValue.general(serial) : s
            case .comma: out += ","
            case .point: out += "."
            case .slash: out += "/"
            case .percent: out += "%"
            case .digit(let c): out += c == "0" ? "0" : ""
            case .subSecond(let n): out += "." + String(format: "%0\(n)d", Int((sub * pow(10, Double(n))).rounded(.down)))
            case .ampm(let style):
                let pm = hour >= 12
                if style == "AM/PM" { out += sec.korean ? (pm ? "오후" : "오전") : (pm ? "PM" : "AM") }
                else if style == "오전/오후" { out += pm ? "오후" : "오전" }
                else { let a = pm ? "P" : "A"; out += style.first!.isLowercase ? a.lowercased() : a }
            case .elapsed(let c):
                dateIdx += 1
                let total = serial * 24
                switch c {
                case "h": out += String(Int(floor(total + 1e-9)))
                case "m": out += String(Int(floor(serial * 1440 + 1e-9)))
                default: out += String(Int(floor(serial * 86400 + 1e-6)))
                }
                _ = i
            case .date(let code):
                defer { dateIdx += 1 }
                switch code.first! {
                case "y": out += code.count <= 2 ? String(format: "%02d", y % 100) : String(format: "%04d", y)
                case "m":
                    let prev = kinds[..<dateIdx].last
                    let next = dateIdx + 1 < kinds.count ? kinds[dateIdx + 1] : nil
                    let isMinute = code.count <= 2 && ((prev?.hasPrefix("h") ?? false) || (prev?.hasPrefix("[h") ?? false) || (next?.hasPrefix("s") ?? false))
                    if isMinute { out += code.count == 2 ? String(format: "%02d", minute) : String(minute) }
                    else {
                        switch code.count {
                        case 1: out += String(mo)
                        case 2: out += String(format: "%02d", mo)
                        case 3: out += String(monthsEN[mo - 1].prefix(3))
                        case 5: out += String(monthsEN[mo - 1].prefix(1))
                        default: out += monthsEN[mo - 1]
                        }
                    }
                case "d":
                    switch code.count {
                    case 1: out += String(d)
                    case 2: out += String(format: "%02d", d)
                    case 3: out += sec.korean ? daysKO[weekday] : String(daysEN[weekday].prefix(3))
                    default: out += sec.korean ? daysKO[weekday] + "요일" : daysEN[weekday]
                    }
                case "a": out += code.count == 3 ? daysKO[weekday] : daysKO[weekday] + "요일"
                case "h":
                    var h = hour
                    if twelve { h = h % 12; if h == 0 { h = 12 } }
                    out += code.count >= 2 ? String(format: "%02d", h) : String(h)
                case "s": out += code.count >= 2 ? String(format: "%02d", second) : String(second)
                default: break
                }
            default: break
            }
        }
        return out
    }
}
