import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Values

/// Rectangular block of values (array constants, ranges, spilled results).
struct Matrix: Equatable {
    var rows: Int
    var cols: Int
    var data: [SheetValue]

    init(rows: Int, cols: Int, fill: SheetValue = .empty) {
        self.rows = max(0, rows); self.cols = max(0, cols)
        data = Array(repeating: fill, count: self.rows * self.cols)
    }

    init(_ grid: [[SheetValue]]) {
        let width = grid.map(\.count).max() ?? 0
        rows = grid.count
        cols = width
        data = grid.flatMap { r in r + Array(repeating: SheetValue.error("#N/A"), count: width - r.count) }
    }

    static func column(_ v: [SheetValue]) -> Matrix { var m = Matrix(rows: v.count, cols: 1); m.data = v; return m }
    static func row(_ v: [SheetValue]) -> Matrix { var m = Matrix(rows: 1, cols: v.count); m.data = v; return m }

    subscript(r: Int, c: Int) -> SheetValue {
        get { data[r * cols + c] }
        set { data[r * cols + c] = newValue }
    }

    func rowValues(_ r: Int) -> [SheetValue] { Array(data[(r * cols)..<((r + 1) * cols)]) }
    func colValues(_ c: Int) -> [SheetValue] { (0..<rows).map { self[$0, c] } }
    var grid: [[SheetValue]] { (0..<rows).map(rowValues) }
    var isEmpty: Bool { rows == 0 || cols == 0 }

    func map(_ f: (SheetValue) -> SheetValue) -> Matrix { var m = self; m.data = data.map(f); return m }
    var transposed: Matrix {
        var m = Matrix(rows: cols, cols: rows)
        for r in 0..<rows { for c in 0..<cols { m[c, r] = self[r, c] } }
        return m
    }
}

/// A LAMBDA value: parameters, body and captured LET/LAMBDA bindings, or a
/// built-in function used by name (eta lambda, e.g. BYROW(A1:C3, SUM)).
final class LambdaValue {
    let params: [String]
    let body: Expr
    let ctx: EvalContext
    let builtin: String?
    init(params: [String], body: Expr, ctx: EvalContext, builtin: String? = nil) {
        self.params = params; self.body = body; self.ctx = ctx; self.builtin = builtin
    }
}

indirect enum SheetValue: Equatable {
    case empty
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(String)
    case array(Matrix)
    case lambda(LambdaValue)

    static func == (a: SheetValue, b: SheetValue) -> Bool {
        switch (a, b) {
        case (.empty, .empty): return true
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.error(let x), .error(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.lambda(let x), .lambda(let y)): return x === y
        default: return false
        }
    }

    /// Top-left element for arrays (implicit intersection of a single cell).
    var scalar: SheetValue {
        if case .array(let m) = self { return m.isEmpty ? .error("#CALC!") : m.data[0].scalar }
        return self
    }

    var number: Double? {
        switch scalar {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .string(let s): return SheetValue.parseNumber(s)
        default: return nil
        }
    }

    var text: String {
        switch scalar {
        case .empty: return ""
        case .number(let d): return SheetValue.general(d)
        case .string(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .lambda: return "#CALC!"
        case .array: return ""
        }
    }

    var truthy: Bool? {
        switch scalar {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .empty: return false
        case .string(let s): return s.uppercased() == "TRUE" ? true : s.uppercased() == "FALSE" ? false : nil
        default: return nil
        }
    }

    var isError: Bool { if case .error = scalar { return true }; return false }
    var isText: Bool { if case .string = self { return true }; return false }
    var isNumber: Bool { if case .number = self { return true }; return false }

    static func general(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "#NUM!" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        let a = abs(d)
        if a >= 1e11 || a < 1e-9 {
            var s = String(format: "%.5E", d)
            // Excel shows e.g. 1.23457E+11
            if let e = s.range(of: "E") {
                var mant = String(s[..<e.lowerBound]); let exp = String(s[e.upperBound...])
                while mant.hasSuffix("0") { mant.removeLast() }
                if mant.hasSuffix(".") { mant.removeLast() }
                let n = Int(exp) ?? 0
                s = mant + "E" + (n < 0 ? "-" : "+") + String(format: "%02d", abs(n))
            }
            return s
        }
        // Excel displays up to 10 significant digits in General (11 chars).
        let digits = max(0, 10 - Int(floor(log10(a))) - 1)
        var s = String(format: "%.\(min(15, digits))f", d)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }

    /// Excel's text → number coercion: plain numbers, thousands separators,
    /// percents, currency, and date/time strings.
    static func parseNumber(_ raw: String) -> Double? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        var sign = 1.0
        if t.hasPrefix("(") && t.hasSuffix(")") { sign = -1; t = String(t.dropFirst().dropLast()) }
        var percent = false
        if t.hasSuffix("%") { percent = true; t.removeLast() }
        for sym in ["$", "₩", "€", "£", "¥"] where t.hasPrefix(sym) { t.removeFirst(sym.count) }
        if t.hasPrefix("-"), let first = t.dropFirst().first, first.isNumber || first == "." { sign *= -1; t.removeFirst() }
        let plain = t.replacingOccurrences(of: ",", with: "")
        if let d = Double(plain), !plain.lowercased().contains("n") && !plain.lowercased().hasPrefix("inf") {
            return sign * (percent ? d / 100 : d)
        }
        if !percent, sign == 1, let serial = DateSerial.parse(t) { return serial }
        return nil
    }

    /// Interprets typed cell input as Excel does: numbers, percents, booleans, errors.
    static func literal(_ s: String) -> SheetValue {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        if s.hasPrefix("'") { return .string(String(s.dropFirst())) }
        if let d = Double(t.replacingOccurrences(of: ",", with: "")), !t.hasPrefix("+") || t.count > 1,
           !t.lowercased().contains("n") { return .number(d) }
        if t.hasSuffix("%"), let d = Double(t.dropLast().trimmingCharacters(in: .whitespaces)) { return .number(d / 100) }
        if t.uppercased() == "TRUE" { return .bool(true) }
        if t.uppercased() == "FALSE" { return .bool(false) }
        if XLError.all.contains(t.uppercased()) { return .error(t.uppercased()) }
        return .string(s)
    }
}

struct XLError: Error {
    let code: String
    init(_ c: String) { code = c }
    static let value = XLError("#VALUE!"), div0 = XLError("#DIV/0!"), na = XLError("#N/A"), name = XLError("#NAME?")
    static let num = XLError("#NUM!"), ref = XLError("#REF!"), null = XLError("#NULL!"), calc = XLError("#CALC!")
    static let spill = XLError("#SPILL!"), connect = XLError("#CONNECT!"), blocked = XLError("#BLOCKED!")
    static let all: Set<String> = ["#VALUE!", "#DIV/0!", "#N/A", "#NAME?", "#NUM!", "#REF!", "#NULL!", "#CALC!", "#SPILL!",
                                   "#GETTING_DATA", "#CONNECT!", "#BLOCKED!", "#FIELD!", "#UNKNOWN!", "#BUSY!", "#PYTHON!"]
}

// MARK: - Expressions & parser

indirect enum Expr {
    case value(SheetValue)
    case ref(String?, CellRef)
    case range(String?, CellRange)
    case cols(String?, Int, Int)          // A:C
    case rows(String?, Int, Int)          // 1:3
    case name(String)
    case array([[Expr]])
    case unary(Character, Expr)
    case percent(Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
    case invoke(Expr, [Expr])
    case spill(Expr)                      // A1#
    case implicit(Expr)                   // @A1:A9
    case omitted                          // missing optional argument
}

struct FormulaParser {
    enum Token: Equatable {
        case num(Double), str(String), ident(String), err(String), op(String)
        case lparen, rparen, lbrace, rbrace, comma, semicolon, hash, at, end
    }

    private var tokens: [Token] = []
    private var i = 0

    static func parse(_ formula: String, observe: ((Token, Range<Int>) -> Void)? = nil) -> Expr? {
        guard let toks = tokenize(formula, observe: observe) else { return nil }
        var p = FormulaParser()
        p.tokens = toks
        guard let e = p.comparison(), p.peek == .end else { return nil }
        return e
    }

    /// Strips the storage prefixes Excel writes for newer functions/params.
    static func clean(_ name: String) -> String {
        var n = name
        for prefix in ["_xlfn.", "_xlws.", "_xlpm.", "_xludf."] {
            while n.lowercased().hasPrefix(prefix) { n.removeFirst(prefix.count) }
        }
        return n
    }

    static func tokenize(_ s: String, observe: ((Token, Range<Int>) -> Void)? = nil) -> [Token]? {
        var out: [Token] = []
        let c = Array(s)
        var i = 0
        func isIdentChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "$" || ch == "\\" }
        while i < c.count {
            let start = i, previousCount = out.count
            defer { if out.count > previousCount, let token = out.last { observe?(token, start..<i) } }
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            // Row range like 1:3 or $1:$3 starts with a digit or $digit.
            if ch.isNumber || (ch == "$" && i + 1 < c.count && c[i + 1].isNumber) {
                var j = i
                while j < c.count && (c[j].isNumber || c[j] == "$") { j += 1 }
                if j < c.count && c[j] == ":" && j + 1 < c.count && (c[j + 1].isNumber || c[j + 1] == "$"), ch != "." {
                    var k = j + 1
                    while k < c.count && (c[k].isNumber || c[k] == "$") { k += 1 }
                    if k == c.count || !(c[k].isLetter) {
                        out.append(.ident(String(c[i..<k]))); i = k; continue
                    }
                }
            }
            if ch.isNumber || (ch == "." && i + 1 < c.count && c[i + 1].isNumber) {
                var j = i
                while j < c.count && (c[j].isNumber || c[j] == ".") { j += 1 }
                if j < c.count && (c[j] == "e" || c[j] == "E"), j + 1 < c.count, c[j + 1].isNumber || ((c[j + 1] == "-" || c[j + 1] == "+") && j + 2 < c.count && c[j + 2].isNumber) {
                    j += 2
                    while j < c.count && c[j].isNumber { j += 1 }
                }
                // A number glued to letters is a cell/name token (e.g. 1E is not valid; A1 starts with letter)
                guard let d = Double(String(c[i..<j])) else { return nil }
                out.append(.num(d)); i = j; continue
            }
            if ch == "\"" {
                var j = i + 1, str = ""
                while j < c.count {
                    if c[j] == "\"" { if j + 1 < c.count && c[j + 1] == "\"" { str.append("\""); j += 2; continue }; break }
                    str.append(c[j]); j += 1
                }
                guard j < c.count else { return nil }
                out.append(.str(str)); i = j + 1; continue
            }
            if ch == "#" {
                // Error literal (#N/A, #DIV/0! …) or spill operator after a reference.
                if let last = out.last, case .ident = last, i + 1 >= c.count || !c[i + 1].isLetter && c[i + 1] != "N" {
                    out.append(.hash); i += 1; continue
                }
                if let last = out.last, case .rparen = last { out.append(.hash); i += 1; continue }
                var j = i + 1
                while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "/" || c[j] == "!" || c[j] == "?" || c[j] == "_") {
                    j += 1
                    if c[j - 1] == "!" || c[j - 1] == "?" { break }
                }
                let e = String(c[i..<j]).uppercased()
                if XLError.all.contains(e) { out.append(.err(e)); i = j; continue }
                out.append(.hash); i += 1; continue
            }
            if ch == "'" {
                // Quoted sheet name: 'My Sheet'!A1
                var j = i + 1, name = ""
                while j < c.count {
                    if c[j] == "'" { if j + 1 < c.count && c[j + 1] == "'" { name.append("'"); j += 2; continue }; break }
                    name.append(c[j]); j += 1
                }
                j += 1
                guard j < c.count, c[j] == "!" else { return nil }
                var k = j + 1
                while k < c.count && (isIdentChar(c[k]) || c[k] == ":") { k += 1 }
                out.append(.ident("'" + name.replacingOccurrences(of: "'", with: "''") + "'!" + String(c[(j + 1)..<k])))
                i = k; continue
            }
            if ch.isLetter || ch == "_" || ch == "$" || ch == "\\" {
                var j = i
                while j < c.count {
                    if isIdentChar(c[j]) || c[j] == "!" { j += 1; continue }
                    // A ':' joins a range only when the right side is a plain reference, not a function call.
                    if c[j] == ":" && j + 1 < c.count && isIdentChar(c[j + 1]) {
                        var k = j + 1
                        while k < c.count && isIdentChar(c[k]) { k += 1 }
                        if k < c.count && c[k] == "(" { break }
                        j += 1; continue
                    }
                    break
                }
                out.append(.ident(String(c[i..<j]))); i = j; continue
            }
            switch ch {
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case "{": out.append(.lbrace)
            case "}": out.append(.rbrace)
            case ",": out.append(.comma)
            case ";": out.append(.semicolon)
            case "@": out.append(.at)
            case "<", ">":
                if i + 1 < c.count && (c[i + 1] == "=" || (ch == "<" && c[i + 1] == ">")) { out.append(.op(String([ch, c[i + 1]]))); i += 2; continue }
                out.append(.op(String(ch)))
            case "+", "-", "*", "/", "^", "&", "=", "%", ":": out.append(.op(String(ch)))
            default: return nil
            }
            i += 1
        }
        out.append(.end)
        return out
    }

    private var peek: Token { i < tokens.count ? tokens[i] : .end }
    private mutating func next() -> Token { defer { i += 1 }; return peek }

    private mutating func comparison() -> Expr? {
        guard var l = concat() else { return nil }
        while case .op(let o) = peek, ["=", "<>", "<", ">", "<=", ">="].contains(o) {
            _ = next(); guard let r = concat() else { return nil }; l = .binary(o, l, r)
        }
        return l
    }
    private mutating func concat() -> Expr? {
        guard var l = additive() else { return nil }
        while peek == .op("&") { _ = next(); guard let r = additive() else { return nil }; l = .binary("&", l, r) }
        return l
    }
    private mutating func additive() -> Expr? {
        guard var l = term() else { return nil }
        while case .op(let o) = peek, o == "+" || o == "-" { _ = next(); guard let r = term() else { return nil }; l = .binary(o, l, r) }
        return l
    }
    private mutating func term() -> Expr? {
        guard var l = power() else { return nil }
        while case .op(let o) = peek, o == "*" || o == "/" { _ = next(); guard let r = power() else { return nil }; l = .binary(o, l, r) }
        return l
    }
    private mutating func power() -> Expr? {
        guard var l = unary() else { return nil }
        while peek == .op("^") { _ = next(); guard let r = unary() else { return nil }; l = .binary("^", l, r) }
        return l
    }
    private mutating func unary() -> Expr? {
        if case .op(let o) = peek, o == "-" || o == "+" {
            _ = next(); guard let e = unary() else { return nil }
            return o == "-" ? .unary("-", e) : .unary("+", e)
        }
        if peek == .at { _ = next(); guard let e = unary() else { return nil }; return .implicit(e) }
        guard var e = postfix() else { return nil }
        while peek == .op("%") { _ = next(); e = .percent(e) }
        return e
    }
    private mutating func postfix() -> Expr? {
        guard var e = rangeOp() else { return nil }
        while true {
            if peek == .hash { _ = next(); e = .spill(e); continue }
            if peek == .lparen, case .name = e { guard let args = argList() else { return nil }; e = .invoke(e, args); continue }
            if peek == .lparen, case .invoke = e { guard let args = argList() else { return nil }; e = .invoke(e, args); continue }
            if peek == .lparen, case .call(let n, _) = e, n == "LAMBDA" { guard let args = argList() else { return nil }; e = .invoke(e, args); continue }
            break
        }
        return e
    }
    /// The ':' range operator between reference-valued expressions.
    private mutating func rangeOp() -> Expr? {
        guard var l = primary() else { return nil }
        while peek == .op(":") { _ = next(); guard let r = primary() else { return nil }; l = .binary(":", l, r) }
        return l
    }
    private mutating func argList() -> [Expr]? {
        guard next() == .lparen else { return nil }
        var args: [Expr] = []
        if peek == .rparen { _ = next(); return args }
        while true {
            if peek == .comma { args.append(.omitted); _ = next(); continue }
            if peek == .rparen { args.append(.omitted); _ = next(); return args }
            guard let a = comparison() else { return nil }
            args.append(a)
            if peek == .comma { _ = next(); if peek == .rparen { args.append(.omitted); _ = next(); return args }; continue }
            if next() == .rparen { return args } else { return nil }
        }
    }
    private mutating func primary() -> Expr? {
        switch peek {
        case .num(let d): _ = next(); return .value(.number(d))
        case .str(let s): _ = next(); return .value(.string(s))
        case .err(let e): _ = next(); return .value(.error(e))
        case .lparen:
            _ = next()
            guard let e = comparison(), next() == .rparen else { return nil }
            return e
        case .lbrace:
            _ = next()
            var rows: [[Expr]] = [[]]
            while true {
                guard let v = arrayElement() else { return nil }
                rows[rows.count - 1].append(v)
                switch next() {
                case .comma: continue
                case .semicolon: rows.append([])
                case .rbrace: return .array(rows)
                default: return nil
                }
            }
        case .ident(let raw):
            _ = next()
            let name = FormulaParser.clean(raw)
            if peek == .lparen {
                guard let args = argList() else { return nil }
                return .call(name.uppercased(), args)
            }
            let up = name.uppercased()
            if up == "TRUE" { return .value(.bool(true)) }
            if up == "FALSE" { return .value(.bool(false)) }
            return FormulaParser.reference(name)
        default: return nil
        }
    }
    private mutating func arrayElement() -> Expr? {
        var sign = 1.0
        if case .op(let o) = peek, o == "-" || o == "+" { _ = next(); if o == "-" { sign = -1 } }
        switch next() {
        case .num(let d): return .value(.number(sign * d))
        case .str(let s): return .value(.string(s))
        case .err(let e): return .value(.error(e))
        case .ident(let n):
            if n.uppercased() == "TRUE" { return .value(.bool(true)) }
            if n.uppercased() == "FALSE" { return .value(.bool(false)) }
            return nil
        default: return nil
        }
    }

    static func reference(_ raw: String) -> Expr {
        var sheet: String?
        var body = raw
        if let bang = raw.lastIndex(of: "!") {
            var s = String(raw[..<bang])
            if s.hasPrefix("'") && s.hasSuffix("'") { s = String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            sheet = s
            body = String(raw[raw.index(after: bang)...])
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "$", with: "") }
        if parts.count == 2 {
            if let a = CellRef.columnIndex(parts[0]), let b = CellRef.columnIndex(parts[1]), parts[0].allSatisfy(\.isLetter), parts[1].allSatisfy(\.isLetter) {
                return .cols(sheet, min(a, b), max(a, b))
            }
            if let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b >= 1 { return .rows(sheet, min(a, b) - 1, max(a, b) - 1) }
            if let a = CellRef(a1: parts[0]), let b = CellRef(a1: parts[1]) { return .range(sheet, CellRange(a, b)) }
            return .value(.error("#NAME?"))
        }
        if parts.count == 1, let r = CellRef(a1: parts[0]), parts[0].first?.isLetter == true,
           parts[0].drop(while: \.isLetter).allSatisfy(\.isNumber), parts[0].prefix(while: \.isLetter).count <= 3 {
            return .ref(sheet, r)
        }
        return .name(sheet.map { $0 + "!" + body } ?? body)
    }
}

// MARK: - Engine

struct Ref {
    let sheet: Worksheet
    var range: CellRange
}

struct EvalContext {
    var sheet: Worksheet
    var cell: CellRef?
    var env: [String: SheetValue] = [:]
}

/// Evaluates formulas with memoisation, cycle detection, dynamic-array
/// spilling and LAMBDA/LET scoping. Call `invalidate()` after any edit.
final class FormulaEngine {
    let book: Workbook
    private var cache: [ObjectIdentifier: [CellRef: SheetValue]] = [:]
    private var arrays: [ObjectIdentifier: [CellRef: Matrix]] = [:]   // spilled results by anchor
    private var visiting: Set<String> = []
    private var probing: Set<String> = []
    private var candidates: [ObjectIdentifier: [CellRef]] = [:]
    private var parsed: [String: Expr] = [:]
    private var depth = 0
    var now = Date()

    let allowExternalIO: Bool
    init(book: Workbook, allowExternalIO: Bool = true) { self.book = book; self.allowExternalIO = allowExternalIO }

    func invalidate() { cache = [:]; arrays = [:]; candidates = [:]; now = Date() }

    func parse(_ formula: String) -> Expr? {
        if let e = parsed[formula] { return e }
        let e = FormulaParser.parse(formula)
        if let e { parsed[formula] = e }
        return e
    }

    /// Value shown in a cell (the top-left element for a spilling formula).
    func value(_ sheet: Worksheet, _ ref: CellRef) -> SheetValue {
        let sid = ObjectIdentifier(sheet)
        if let v = cache[sid]?[ref] { return v }
        let v: SheetValue
        if let cell = sheet.cells[ref], !cell.input.isEmpty {
            if cell.isFormula {
                let key = sheet.name + "!" + ref.a1
                if visiting.contains(key) { return .error("#CYCLE!") }
                visiting.insert(key)
                var result: SheetValue
                if sheet.legacyFormulas.contains(ref), let expr = parse(String(cell.input.dropFirst())) {
                    result = eval(.implicit(expr), EvalContext(sheet: sheet, cell: ref))
                } else {
                    result = evaluateFormula(String(cell.input.dropFirst()), sheet: sheet, cell: ref)
                }
                visiting.remove(key)
                if case .array(let m) = result {
                    if m.rows * m.cols == 1 { result = m.data[0] }
                    else if blocked(sheet, ref, m) { result = .error("#SPILL!") }
                    else { arrays[sid, default: [:]][ref] = m; result = m.data[0] }
                }
                if case .lambda = result { result = .error("#CALC!") }
                v = result
            } else {
                v = SheetValue.literal(cell.input)
            }
        } else {
            v = spilled(sheet, ref) ?? .empty
        }
        cache[sid, default: [:]][ref] = v
        return v
    }

    /// Full spilled array of an anchor cell, if it spills.
    func spillArray(_ sheet: Worksheet, _ anchor: CellRef) -> Matrix? {
        _ = value(sheet, anchor)
        return arrays[ObjectIdentifier(sheet)]?[anchor]
    }

    /// Range covered by the spill that contains `ref` (anchor included).
    func spillRange(_ sheet: Worksheet, _ ref: CellRef) -> CellRange? {
        _ = value(sheet, ref)
        for (anchor, m) in arrays[ObjectIdentifier(sheet)] ?? [:] {
            let r = CellRange(anchor, CellRef(row: anchor.row + m.rows - 1, col: anchor.col + m.cols - 1))
            if r.contains(ref) { return r }
        }
        return nil
    }

    /// True when the cell shows part of another cell's spill.
    func isSpillTarget(_ sheet: Worksheet, _ ref: CellRef) -> Bool {
        if let c = sheet.cells[ref], !c.input.isEmpty { return false }
        return spilled(sheet, ref) != nil
    }

    private func blocked(_ sheet: Worksheet, _ anchor: CellRef, _ m: Matrix) -> Bool {
        for r in 0..<m.rows { for c in 0..<m.cols where r > 0 || c > 0 {
            if let cell = sheet.cells[CellRef(row: anchor.row + r, col: anchor.col + c)], !cell.input.isEmpty { return true }
        } }
        return false
    }

    /// Formula cells that could produce an array (legacy formulas never spill).
    private func spillCandidates(_ sheet: Worksheet) -> [CellRef] {
        let sid = ObjectIdentifier(sheet)
        if let c = candidates[sid] { return c }
        let c = sheet.cells.filter { ref, cell in
            guard cell.isFormula, !sheet.legacyFormulas.contains(ref) else { return false }
            // Plain arithmetic on single cells/numbers cannot return an array.
            if cell.input.contains(where: { ":({#".contains($0) }) { return true }
            let words = cell.input.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") })
            return words.contains { w in w.first?.isLetter == true && CellRef(a1: String(w)) == nil }
        }.keys.sorted()
        candidates[sid] = c
        return c
    }

    private func spilled(_ sheet: Worksheet, _ ref: CellRef) -> SheetValue? {
        for anchor in spillCandidates(sheet) where anchor.row <= ref.row && anchor.col <= ref.col && anchor != ref {
            let key = sheet.name + "!" + anchor.a1
            if visiting.contains(key) || probing.contains(key) { continue }
            if cache[ObjectIdentifier(sheet)]?[anchor] == nil {
                // Probe with a fresh cycle stack so cells of the caller's chain
                // are not mistaken for cycles.
                probing.insert(key)
                let saved = visiting
                visiting = []
                _ = value(sheet, anchor)
                visiting = saved
                probing.remove(key)
            }
            if let m = arrays[ObjectIdentifier(sheet)]?[anchor], ref.row - anchor.row < m.rows, ref.col - anchor.col < m.cols {
                return m[ref.row - anchor.row, ref.col - anchor.col]
            }
        }
        return nil
    }

    func evaluateFormula(_ src: String, sheet: Worksheet, cell: CellRef?) -> SheetValue {
        guard let expr = parse(src) else { return .error("#NAME?") }
        return eval(expr, EvalContext(sheet: sheet, cell: cell))
    }

    func sheet(named name: String?, _ ctx: EvalContext) -> Worksheet? {
        guard let name else { return ctx.sheet }
        return book.sheet(named: name)
    }

    /// Bounding box used for whole-row/column references.
    private func extent(_ ws: Worksheet) -> CellRef {
        let used = ws.usedRange?.end ?? CellRef(row: 0, col: 0)
        var end = used
        for (a, _) in arrays[ObjectIdentifier(ws)] ?? [:] { end = CellRef(row: max(end.row, a.row), col: max(end.col, a.col)) }
        return end
    }

    // MARK: References

    func evalRef(_ e: Expr, _ ctx: EvalContext) -> Ref? {
        switch e {
        case .ref(let s, let r): return sheet(named: s, ctx).map { Ref(sheet: $0, range: CellRange(r, r)) }
        case .range(let s, let r): return sheet(named: s, ctx).map { Ref(sheet: $0, range: r) }
        case .cols(let s, let a, let b):
            guard let ws = sheet(named: s, ctx) else { return nil }
            return Ref(sheet: ws, range: CellRange(CellRef(row: 0, col: a), CellRef(row: max(0, extent(ws).row), col: b)))
        case .rows(let s, let a, let b):
            guard let ws = sheet(named: s, ctx) else { return nil }
            return Ref(sheet: ws, range: CellRange(CellRef(row: a, col: 0), CellRef(row: b, col: max(0, extent(ws).col))))
        case .spill(let inner):
            guard let base = evalRef(inner, ctx), let m = spillArray(base.sheet, base.range.start) else { return nil }
            let s = base.range.start
            return Ref(sheet: base.sheet, range: CellRange(s, CellRef(row: s.row + m.rows - 1, col: s.col + m.cols - 1)))
        case .binary(":", let a, let b):
            guard let x = evalRef(a, ctx), let y = evalRef(b, ctx), x.sheet === y.sheet else { return nil }
            let r = CellRange(CellRef(row: min(x.range.start.row, y.range.start.row), col: min(x.range.start.col, y.range.start.col)),
                              CellRef(row: max(x.range.end.row, y.range.end.row), col: max(x.range.end.col, y.range.end.col)))
            return Ref(sheet: x.sheet, range: r)
        case .name(let n):
            if ctx.env[n.uppercased()] != nil { return nil }
            if let def = book.definedNames[n.uppercased()], let ex = parse(def) { return evalRef(ex, ctx) }
            return nil
        case .call(let f, let args):
            return FunctionLibrary.refFunction(f, Args(engine: self, ctx: ctx, exprs: args))
        case .implicit(let inner): return evalRef(inner, ctx)
        default: return nil
        }
    }

    func rangeValue(_ ref: Ref) -> SheetValue {
        let r = ref.range
        if r.start == r.end { return value(ref.sheet, r.start) }
        var m = Matrix(rows: r.end.row - r.start.row + 1, cols: r.end.col - r.start.col + 1)
        for row in 0..<m.rows { for col in 0..<m.cols {
            m[row, col] = value(ref.sheet, CellRef(row: r.start.row + row, col: r.start.col + col))
        } }
        return .array(m)
    }

    // MARK: Evaluation

    func eval(_ e: Expr, _ ctx: EvalContext) -> SheetValue {
        depth += 1
        defer { depth -= 1 }
        if depth > 900 { return .error("#NUM!") }
        switch e {
        case .value(let v): return v
        case .omitted: return .empty
        case .ref, .range, .cols, .rows, .spill:
            guard let r = evalRef(e, ctx) else { return .error("#REF!") }
            return rangeValue(r)
        case .name(let n):
            let key = n.uppercased()
            if let v = ctx.env[key] { return v }
            if let def = book.definedNames[key] {
                guard let ex = parse(def) else { return .error("#NAME?") }
                return eval(ex, EvalContext(sheet: ctx.sheet, cell: ctx.cell))
            }
            let fn = FormulaParser.clean(n).uppercased()
            if FunctionLibrary.table[fn] != nil, fn != "LAMBDA" {
                return .lambda(LambdaValue(params: [], body: .omitted, ctx: ctx, builtin: fn))
            }
            return .error("#NAME?")
        case .array(let rows):
            return .array(Matrix(rows.map { $0.map { eval($0, ctx).scalar } }))
        case .implicit(let inner):
            let v = eval(inner, ctx)
            guard case .array(let m) = v else { return v }
            if let r = evalRef(inner, ctx), let cell = ctx.cell {
                // Implicit intersection with the formula's row/column.
                if r.range.start.col == r.range.end.col, r.range.contains(CellRef(row: cell.row, col: r.range.start.col)) {
                    return value(r.sheet, CellRef(row: cell.row, col: r.range.start.col))
                }
                if r.range.start.row == r.range.end.row, r.range.contains(CellRef(row: r.range.start.row, col: cell.col)) {
                    return value(r.sheet, CellRef(row: r.range.start.row, col: cell.col))
                }
                return .error("#VALUE!")
            }
            return m.data.first ?? .error("#VALUE!")
        case .unary(let op, let x):
            return Broadcast.map1(eval(x, ctx)) { v in
                if case .error = v { return v }
                guard let d = Coerce.arith(v) else { return .error("#VALUE!") }
                return .number(op == "-" ? -d : d)
            }
        case .percent(let x):
            return Broadcast.map1(eval(x, ctx)) { v in
                if case .error = v { return v }
                guard let d = Coerce.arith(v) else { return .error("#VALUE!") }
                return .number(d / 100)
            }
        case .binary(":", _, _):
            guard let r = evalRef(e, ctx) else { return .error("#REF!") }
            return rangeValue(r)
        case .binary(let op, let l, let r):
            return Broadcast.map2(eval(l, ctx), eval(r, ctx)) { Operators.apply(op, $0, $1) }
        case .call(let name, let args):
            if name == "LAMBDA" { return FunctionLibrary.makeLambda(args, ctx) }
            if let fn = FunctionLibrary.table[name] {
                do { return try fn(Args(engine: self, ctx: ctx, exprs: args)) }
                catch let err as XLError { return .error(err.code) }
                catch { return .error("#VALUE!") }
            }
            // A LET/LAMBDA-bound name called like a function.
            if let v = ctx.env[name], case .lambda(let l) = v {
                return callLambda(l, args.map { $0.isOmitted ? .empty : eval($0, ctx) }, omitted: args.map(\.isOmitted))
            }
            if let def = book.definedNames[name], let ex = parse(def), case .lambda(let l) = eval(ex, ctx) {
                return callLambda(l, args.map { eval($0, ctx) })
            }
            return .error("#NAME?")
        case .invoke(let target, let args):
            guard case .lambda(let l) = eval(target, ctx) else { return .error("#VALUE!") }
            return callLambda(l, args.map { $0.isOmitted ? .empty : eval($0, ctx) }, omitted: args.map(\.isOmitted))
        }
    }

    func callLambda(_ l: LambdaValue, _ values: [SheetValue], omitted: [Bool] = []) -> SheetValue {
        if let fn = l.builtin, let f = FunctionLibrary.table[fn] {
            do { return try f(Args(engine: self, ctx: l.ctx, exprs: values.map { .value($0) })) }
            catch let err as XLError { return .error(err.code) }
            catch { return .error("#VALUE!") }
        }
        guard values.count <= l.params.count else { return .error("#VALUE!") }
        var ctx = l.ctx
        for (i, p) in l.params.enumerated() {
            let key = p.uppercased()
            if i < values.count && !(omitted[safe: i] ?? false) {
                ctx.env[key] = values[i]; ctx.env["__OMITTED__" + key] = nil
            } else {
                ctx.env[key] = .empty; ctx.env["__OMITTED__" + key] = .bool(true)
            }
        }
        return eval(l.body, ctx)
    }

    /// Display string for a cell, honouring its number format.
    func display(_ sheet: Worksheet, _ ref: CellRef) -> String {
        let v = value(sheet, ref)
        if case .number(let d) = v {
            let anchorFormat = sheet.cells[ref]?.style.numberFormat
            if let fmt = anchorFormat { return NumberFormatter2.format(d, fmt) }
        }
        return v.text
    }
}

extension Expr {
    var isOmitted: Bool { if case .omitted = self { return true }; return false }
    var isReference: Bool {
        switch self {
        case .ref, .range, .cols, .rows, .spill: return true
        case .binary(":", _, _): return true
        default: return false
        }
    }
}

// MARK: - Coercion, operators, broadcasting

enum Coerce {
    /// Arithmetic coercion: numbers, booleans, numeric text, blanks.
    static func arith(_ v: SheetValue) -> Double? {
        switch v.scalar {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .string(let s): return SheetValue.parseNumber(s)
        default: return nil
        }
    }

    /// Excel's comparison order: numbers < text < logicals; text case-insensitive.
    static func compare(_ a: SheetValue, _ b: SheetValue) -> Int {
        func rank(_ v: SheetValue) -> Int {
            switch v { case .number, .empty: return 0; case .string: return 1; case .bool: return 2; default: return 3 }
        }
        var x = a.scalar, y = b.scalar
        if case .empty = x { if case .string = y { x = .string("") } else if case .bool = y { x = .bool(false) } }
        if case .empty = y { if case .string = x { y = .string("") } else if case .bool = x { y = .bool(false) } }
        let rx = rank(x), ry = rank(y)
        if rx != ry { return rx < ry ? -1 : 1 }
        switch (x, y) {
        case (.string(let s), .string(let t)):
            let r = s.compare(t, options: [.caseInsensitive], locale: Locale(identifier: "ko_KR"))
            return r == .orderedAscending ? -1 : r == .orderedDescending ? 1 : 0
        case (.bool(let p), .bool(let q)): return p == q ? 0 : (!p ? -1 : 1)
        default:
            let p = x.number ?? 0, q = y.number ?? 0
            return p < q ? -1 : p > q ? 1 : 0
        }
    }
}

enum Operators {
    static func apply(_ op: String, _ a: SheetValue, _ b: SheetValue) -> SheetValue {
        if case .error = a { return a }
        if case .error = b { return b }
        switch op {
        case "&": return .string(a.text + b.text)
        case "=", "<>", "<", ">", "<=", ">=":
            let c = Coerce.compare(a, b)
            switch op {
            case "=": return .bool(c == 0)
            case "<>": return .bool(c != 0)
            case "<": return .bool(c < 0)
            case ">": return .bool(c > 0)
            case "<=": return .bool(c <= 0)
            default: return .bool(c >= 0)
            }
        default:
            guard let x = Coerce.arith(a), let y = Coerce.arith(b) else { return .error("#VALUE!") }
            let r: Double
            switch op {
            case "+": r = x + y
            case "-": r = x - y
            case "*": r = x * y
            case "/": if y == 0 { return .error("#DIV/0!") }; r = x / y
            case "^":
                if x == 0 && y == 0 { return .error("#NUM!") }
                if x == 0 && y < 0 { return .error("#DIV/0!") }
                r = pow(x, y)
            default: return .error("#VALUE!")
            }
            return r.isFinite ? .number(r) : .error("#NUM!")
        }
    }
}

enum Broadcast {
    static func map1(_ v: SheetValue, _ f: (SheetValue) -> SheetValue) -> SheetValue {
        if case .array(let m) = v { return .array(m.map { f($0) }) }
        return f(v)
    }

    /// Elementwise with Excel's broadcasting: 1×N, N×1 and 1×1 expand;
    /// out-of-shape positions become #N/A.
    static func map2(_ a: SheetValue, _ b: SheetValue, _ f: (SheetValue, SheetValue) -> SheetValue) -> SheetValue {
        switch (a, b) {
        case (.array(let x), .array(let y)):
            let rows = max(x.rows, y.rows), cols = max(x.cols, y.cols)
            var m = Matrix(rows: rows, cols: cols)
            for r in 0..<rows { for c in 0..<cols {
                guard let p = pick(x, r, c), let q = pick(y, r, c) else { m[r, c] = .error("#N/A"); continue }
                m[r, c] = f(p, q)
            } }
            return .array(m)
        case (.array(let x), _): return .array(x.map { f($0, b) })
        case (_, .array(let y)): return .array(y.map { f(a, $0) })
        default: return f(a, b)
        }
    }

    static func pick(_ m: Matrix, _ r: Int, _ c: Int) -> SheetValue? {
        let rr = m.rows == 1 ? 0 : r, cc = m.cols == 1 ? 0 : c
        guard rr < m.rows, cc < m.cols else { return nil }
        return m[rr, cc]
    }
}

// MARK: - Criteria (COUNTIF, SUMIFS, D-functions …)

struct Criteria {
    let test: (SheetValue) -> Bool

    init(_ crit: SheetValue) {
        var c = crit.scalar
        if case .number(let n) = c {
            test = { v in
                switch v { case .number(let x): return x == n; case .string(let t): return SheetValue.parseNumber(t) == n; default: return false }
            }
            return
        }
        if case .empty = c { test = { if case .number(let x) = $0 { return x == 0 }; return false }; return }
        if case .bool(let b) = c { test = { if case .bool(let x) = $0 { return x == b }; return false }; return }
        if case .error(let e) = c { test = { if case .error(let x) = $0 { return x == e }; return false }; return }
        var s = c.text
        var op = "="
        for o in ["<>", ">=", "<=", ">", "<", "="] where s.hasPrefix(o) { op = o; s = String(s.dropFirst(o.count)); break }
        c = .string(s)
        if let n = SheetValue.parseNumber(s), !s.isEmpty {
            test = { v in
                var value = v.scalar
                if op == "=", case .string(let t) = value, let p = SheetValue.parseNumber(t) { value = .number(p) }
                guard case .number(let x) = value else { return op == "<>" }
                switch op {
                case ">": return x > n
                case "<": return x < n
                case ">=": return x >= n
                case "<=": return x <= n
                case "<>": return x != n
                default: return x == n
                }
            }
            return
        }
        let upper = s.uppercased()
        if upper == "TRUE" || upper == "FALSE" {
            let b = upper == "TRUE"
            test = { v in
                if case .bool(let x) = v { return op == "<>" ? x != b : x == b }
                return op == "<>"
            }
            return
        }
        if s.isEmpty {
            // "" or "=" match blanks; "<>" matches non-blanks.
            test = { v in
                let blank: Bool = { if case .empty = v { return true }; if case .string(let t) = v { return t.isEmpty }; return false }()
                return op == "<>" ? !blank : blank
            }
            return
        }
        if op == "=" || op == "<>" {
            let regex = Criteria.wildcard(s)
            test = { v in
                var match: Bool
                if let regex { match = v.text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil }
                else { match = v.text.caseInsensitiveCompare(s) == .orderedSame && v.isText }
                if case .empty = v { match = false }
                return op == "<>" ? !match : match
            }
            return
        }
        test = { v in
            guard v.isText else { return false }
            let r = Coerce.compare(v, .string(s))
            switch op {
            case ">": return r > 0
            case "<": return r < 0
            case ">=": return r >= 0
            default: return r <= 0
            }
        }
    }

    /// Converts Excel wildcards (* ? with ~ escape) to an anchored regex.
    static func wildcard(_ s: String) -> String? {
        guard s.contains("*") || s.contains("?") || s.contains("~") else { return nil }
        var out = "^"
        var escape = false
        for ch in s {
            if escape { out += NSRegularExpression.escapedPattern(for: String(ch)); escape = false; continue }
            switch ch {
            case "~": escape = true
            case "*": out += ".*"
            case "?": out += "."
            default: out += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return out + "$"
    }
}

// MARK: - Dates (1900 system, including Excel's 1900-02-29)

enum DateSerial {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let epoch = DateComponents(year: 1899, month: 12, day: 30)

    /// Serial for a (possibly out-of-range) y/m/d, normalised like DATE().
    static func serial(_ y: Int, _ m: Int, _ d: Int) -> Double? {
        var year = y
        if year < 1900 { year += 1900 }
        guard year >= 1900 && year <= 9999 || (year >= 0 && year < 1900) else { return nil }
        let monthIndex = year * 12 + (m - 1)
        let yy = Int((Double(monthIndex) / 12).rounded(.down)), mm = monthIndex - yy * 12 + 1
        guard let first = calendar.date(from: DateComponents(year: yy, month: mm, day: 1)),
              let date = calendar.date(byAdding: .day, value: d - 1, to: first),
              let base = calendar.date(from: epoch) else { return nil }
        var s = Double(calendar.dateComponents([.day], from: base, to: date).day!)
        if s < 61 { s -= 1 }               // Lotus bug: 1900-02-29 exists in Excel
        if yy == 1900 && mm == 2 && d == 29 { return 60 }
        guard s >= 0, s <= 2958465 else { return nil }
        return s
    }

    static func ymd(_ serial: Double) -> (Int, Int, Int) {
        let s = Int(serial.rounded(.down))
        if s == 60 { return (1900, 2, 29) }
        if s == 0 { return (1900, 1, 0) }
        let days = s < 60 ? s + 1 : s
        let date = calendar.date(byAdding: .day, value: days, to: calendar.date(from: epoch)!)!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    /// 1 = Sunday … 7 = Saturday.
    static func weekday(_ serial: Double) -> Int {
        let s = Int(serial.rounded(.down))
        return ((s - 1) % 7 + 7) % 7 + 1
    }

    static func fromDate(_ d: Date) -> Double {
        d.timeIntervalSince1970 / 86400 + 25569 + Double(TimeZone.current.secondsFromGMT(for: d)) / 86400
    }

    static func time(_ serial: Double) -> (Int, Int, Int) {
        var frac = serial - serial.rounded(.down)
        if frac < 0 { frac += 1 }
        let secs = Int((frac * 86400).rounded())
        return ((secs / 3600) % 24, (secs / 60) % 60, secs % 60)
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// DATEVALUE/TIMEVALUE parsing for common Korean/ISO/US forms.
    static func parse(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 3, s.contains(where: \.isNumber) else { return nil }
        var datePart = s, timePart = ""
        if let r = s.range(of: #"\s+\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\s*([AaPp][Mm])?$"#, options: .regularExpression) {
            datePart = String(s[..<r.lowerBound]); timePart = String(s[r]).trimmingCharacters(in: .whitespaces)
        } else if s.range(of: #"^\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\s*([AaPp][Mm])?$"#, options: .regularExpression) != nil {
            datePart = ""; timePart = s
        } else if s.range(of: #"^(오전|오후)\s*\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
            datePart = ""; timePart = s
        }
        var total = 0.0
        if !datePart.isEmpty {
            let n = datePart.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
            let lower = datePart.lowercased()
            if let mi = monthNames.firstIndex(where: { lower.contains($0) }), let d = n.first {
                let y = n.count > 1 ? n[1] : ymd(fromDate(Date())).0
                guard let v = DateSerial.serial(y < 100 && n.count > 1 ? (y < 30 ? 2000 + y : 1900 + y) : y, mi + 1, d) else { return nil }
                total = v
            } else if n.count == 3 {
                var y: Int, m: Int, d: Int
                if n[0] > 31 || datePart.contains("년") || (n[0] >= 1000) { (y, m, d) = (n[0], n[1], n[2]) }
                else { (m, d, y) = (n[0], n[1], n[2]) }
                if y < 100 { y += y < 30 ? 2000 : 1900 }
                guard (1...12).contains(m), (1...31).contains(d), let v = DateSerial.serial(y, m, d) else { return nil }
                total = v
            } else if n.count == 2, datePart.contains("/") || datePart.contains("-") || datePart.contains("월") {
                guard (1...12).contains(n[0]), (1...31).contains(n[1]), let v = DateSerial.serial(ymd(fromDate(Date())).0, n[0], n[1]) else { return nil }
                total = v
            } else {
                return nil
            }
        }
        if !timePart.isEmpty {
            let pm = timePart.lowercased().hasSuffix("pm") || timePart.hasPrefix("오후")
            let am = timePart.lowercased().hasSuffix("am") || timePart.hasPrefix("오전")
            let nums = timePart.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.compactMap { Double($0) }
            guard nums.count >= 2 else { return nil }
            var h = nums[0]
            if pm && h < 12 { h += 12 }
            if am && h == 12 { h = 0 }
            total += (h * 3600 + nums[1] * 60 + (nums.count > 2 ? nums[2] : 0)) / 86400
        }
        return total
    }
}

extension FormulaEngine {
    /// Rewrites A1 references after rows/columns are inserted (n > 0) or
    /// deleted (n < 0) at index `at`.
    static func shift(_ formula: String, rowAt: Int? = nil, colAt: Int? = nil, by n: Int) -> String {
        guard formula.hasPrefix("=") else { return formula }
        let pattern = #"("[^"]*")|(\$?)([A-Za-z]{1,3})(\$?)([0-9]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return formula }
        let ns = formula as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: formula, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            if m.range(at: 1).location != NSNotFound { out += ns.substring(with: m.range); continue }
            let colAbs = ns.substring(with: m.range(at: 2)), letters = ns.substring(with: m.range(at: 3))
            let rowAbs = ns.substring(with: m.range(at: 4))
            guard var c = CellRef.columnIndex(letters), var r = Int(ns.substring(with: m.range(at: 5))) else { out += ns.substring(with: m.range); continue }
            r -= 1
            if let rowAt, r >= rowAt { r += n; if r < rowAt { out += "#REF!"; continue } }
            if let colAt, c >= colAt { c += n; if c < colAt { out += "#REF!"; continue } }
            out += colAbs + CellRef.columnName(c) + rowAbs + String(r + 1)
        }
        out += ns.substring(from: last)
        return out
    }
}
