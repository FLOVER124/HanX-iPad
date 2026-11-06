import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Worksheet function library. Each category file adds its functions to the
/// registry; names are the canonical English names Excel stores in files
/// (without the `_xlfn.` prefix).
typealias XLFunction = (Args) throws -> SheetValue

enum FunctionLibrary {
    static let table: [String: XLFunction] = {
        var r = Registry()
        MathFunctions.register(&r)
        StatFunctions.register(&r)
        DistributionFunctions.register(&r)
        TextFunctions.register(&r)
        DateFunctions.register(&r)
        LogicalFunctions.register(&r)
        InfoFunctions.register(&r)
        LookupFunctions.register(&r)
        ArrayFunctions.register(&r)
        FinancialFunctions.register(&r)
        EngineeringFunctions.register(&r)
        DatabaseFunctions.register(&r)
        ExternalFunctions.register(&r)
        return r.table
    }()

    /// Functions that can return references (so OFFSET(...):B9, SUM(INDEX(...)) work).
    static func refFunction(_ name: String, _ a: Args) -> Ref? {
        switch name {
        case "OFFSET": return LookupFunctions.offset(a)
        case "INDIRECT": return LookupFunctions.indirect(a)
        case "INDEX": return LookupFunctions.indexRef(a)
        case "CHOOSE":
            guard let i = try? X.int(a.value(0)), i >= 1, i < a.count else { return nil }
            return a.ref(i)
        case "IF":
            guard let c = a.value(0).truthy else { return nil }
            return c ? a.ref(1) : (a.has(2) ? a.ref(2) : nil)
        case "TRIMRANGE": return LookupFunctions.trimRange(a)
        case "XLOOKUP": return LookupFunctions.xlookupRef(a)
        default: return nil
        }
    }

    static func makeLambda(_ args: [Expr], _ ctx: EvalContext) -> SheetValue {
        guard let body = args.last else { return .error("#VALUE!") }
        var params: [String] = []
        for p in args.dropLast() {
            switch p {
            case .name(let n): params.append(FormulaParser.clean(n))
            case .ref(nil, let r): params.append(r.a1)
            default: return .error("#VALUE!")
            }
        }
        return .lambda(LambdaValue(params: params, body: body, ctx: ctx))
    }
}

struct Registry {
    var table: [String: XLFunction] = [:]

    /// Registers a function that receives its arguments unevaluated.
    mutating func raw(_ names: String..., min: Int = 0, max: Int = 255, _ f: @escaping XLFunction) {
        for n in names {
            table[n] = { a in
                guard a.count >= min, a.count <= max else { throw XLError.value }
                return try f(a)
            }
        }
    }

    /// Registers an elementwise function: array arguments in `lifted` positions
    /// (all positions when nil) are broadcast and the function maps over them.
    mutating func scalar(_ names: String..., min: Int, max: Int, lifted: Set<Int>? = nil,
                         _ f: @escaping (Scalars) throws -> SheetValue) {
        for n in names {
            table[n] = { a in
                guard a.count >= min, a.count <= max else { throw XLError.value }
                return Lift.apply(a, lifted: lifted, f)
            }
        }
    }

    /// Elementwise numeric function: non-finite results become #NUM!.
    mutating func num(_ names: String..., min: Int, max: Int, lifted: Set<Int>? = nil,
                      _ f: @escaping (Scalars) throws -> Double) {
        for n in names {
            table[n] = { a in
                guard a.count >= min, a.count <= max else { throw XLError.value }
                return Lift.apply(a, lifted: lifted) { s in
                    let d = try f(s)
                    guard d.isFinite else { throw XLError.num }
                    return .number(d == 0 ? 0 : d)
                }
            }
        }
    }

    mutating func alias(_ name: String, _ target: String) { table[name] = table[target] }
}

// MARK: - Argument access

final class Args {
    let engine: FormulaEngine
    let ctx: EvalContext
    let exprs: [Expr]
    private var cache: [Int: SheetValue] = [:]

    init(engine: FormulaEngine, ctx: EvalContext, exprs: [Expr]) {
        self.engine = engine; self.ctx = ctx; self.exprs = exprs
    }

    var count: Int { exprs.count }
    func has(_ i: Int) -> Bool { i < exprs.count && !exprs[i].isOmitted }

    func value(_ i: Int) -> SheetValue {
        guard i < exprs.count else { return .empty }
        if let v = cache[i] { return v }
        let v = engine.eval(exprs[i], ctx)
        cache[i] = v
        return v
    }

    func ref(_ i: Int) -> Ref? { i < exprs.count ? engine.evalRef(exprs[i], ctx) : nil }

    /// True when the argument is a reference (its text/logicals are skipped by
    /// aggregate functions, unlike values typed directly as arguments).
    func isRef(_ i: Int) -> Bool {
        guard i < exprs.count else { return false }
        switch exprs[i] {
        case .ref, .range, .cols, .rows, .spill, .binary(":", _, _): return true
        case .name, .call, .implicit: return ref(i) != nil
        default: return false
        }
    }

    func num(_ i: Int, _ def: Double? = nil) throws -> Double {
        if !has(i) { if let def { return def }; if i < count { return 0 }; throw XLError.value }
        return try X.num(value(i))
    }
    func int(_ i: Int, _ def: Int? = nil) throws -> Int {
        if !has(i), let def { return def }
        return try X.int(has(i) ? value(i) : .number(0))
    }
    func str(_ i: Int, _ def: String? = nil) throws -> String {
        if !has(i) { if let def { return def }; return "" }
        return try X.str(value(i))
    }
    func bool(_ i: Int, _ def: Bool? = nil) throws -> Bool {
        if !has(i) { if let def { return def }; return false }
        return try X.bool(value(i))
    }
    func lambda(_ i: Int) throws -> LambdaValue {
        guard case .lambda(let l) = value(i) else { throw XLError.value }
        return l
    }

    /// The argument as a matrix (scalars become 1×1).
    func matrix(_ i: Int) throws -> Matrix {
        let v = value(i)
        if case .array(let m) = v { return m }
        if case .error(let e) = v { throw XLError(e) }
        if case .lambda = v { throw XLError.calc }
        return Matrix([[v]])
    }

    /// Like `matrix` but errors stay as elements.
    func grid(_ i: Int) -> Matrix {
        let v = value(i)
        if case .array(let m) = v { return m }
        return Matrix([[v]])
    }

    /// Numbers for SUM-style aggregates. References/arrays contribute only
    /// numbers (or, with `allValues`, logicals as 1/0 and text as 0);
    /// direct arguments are coerced. Errors propagate.
    func numbers(from start: Int = 0, to end: Int? = nil, allValues: Bool = false, skipErrors: Bool = false) throws -> [Double] {
        var out: [Double] = []
        for i in start..<min(end ?? count, count) {
            if !has(i) { out.append(0); continue }
            let v = value(i)
            if case .array(let m) = v {
                for x in m.data { try X.collect(x, into: &out, allValues: allValues, skipErrors: skipErrors) }
            } else if isRef(i) {
                try X.collect(v, into: &out, allValues: allValues, skipErrors: skipErrors)
            } else {
                switch v {
                case .error(let e): if !skipErrors { throw XLError(e) }
                case .lambda: throw XLError.calc
                default: out.append(try X.num(v))
                }
            }
        }
        return out
    }

    /// Every value (flattened) from the arguments, keeping blanks as `.empty`.
    func flat(from start: Int = 0, to end: Int? = nil) -> [SheetValue] {
        var out: [SheetValue] = []
        for i in start..<min(end ?? count, count) {
            if case .array(let m) = value(i) { out += m.data } else { out.append(value(i)) }
        }
        return out
    }
}

/// Coercions with Excel's rules; errors are thrown as `XLError`.
enum X {
    static func num(_ v: SheetValue) throws -> Double {
        switch v.scalar {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .string(let s):
            guard let d = SheetValue.parseNumber(s) else { throw XLError.value }
            return d
        case .error(let e): throw XLError(e)
        default: throw XLError.value
        }
    }

    static func int(_ v: SheetValue) throws -> Int {
        let d = try num(v)
        guard abs(d) < 9.0e15 else { throw XLError.num }
        return Int(d.rounded(.towardZero))
    }

    static func str(_ v: SheetValue) throws -> String {
        switch v.scalar {
        case .error(let e): throw XLError(e)
        case .lambda: throw XLError.calc
        default: return v.scalar.text
        }
    }

    static func bool(_ v: SheetValue) throws -> Bool {
        switch v.scalar {
        case .error(let e): throw XLError(e)
        default:
            guard let b = v.scalar.truthy else { throw XLError.value }
            return b
        }
    }

    static func collect(_ x: SheetValue, into out: inout [Double], allValues: Bool, skipErrors: Bool) throws {
        switch x {
        case .number(let d): out.append(d)
        case .error(let e): if !skipErrors { throw XLError(e) }
        case .bool(let b): if allValues { out.append(b ? 1 : 0) }
        case .string: if allValues { out.append(0) }
        default: break
        }
    }

    static func check(_ d: Double) throws -> SheetValue {
        guard d.isFinite else { throw XLError.num }
        return .number(d == 0 ? 0 : d)
    }

    /// Numeric vector from an array argument, keeping positions (non-numbers → nil).
    static func optionalNumbers(_ m: Matrix) throws -> [Double?] {
        try m.data.map { v -> Double? in
            if case .error(let e) = v { throw XLError(e) }
            if case .number(let d) = v { return d }
            return nil
        }
    }
}

/// Scalar argument list for lifted functions.
struct Scalars {
    let values: [SheetValue]
    let omitted: [Bool]
    let args: Args

    var count: Int { values.count }
    func has(_ i: Int) -> Bool { i < values.count && !omitted[i] }
    func raw(_ i: Int) -> SheetValue { i < values.count ? values[i] : .empty }

    func num(_ i: Int, _ def: Double? = nil) throws -> Double {
        if !has(i) { if let def { return def }; if i < count { return 0 }; throw XLError.value }
        return try X.num(values[i])
    }
    func int(_ i: Int, _ def: Int? = nil) throws -> Int {
        if !has(i) { if let def { return def }; return 0 }
        return try X.int(values[i])
    }
    func str(_ i: Int, _ def: String? = nil) throws -> String {
        if !has(i) { return def ?? "" }
        return try X.str(values[i])
    }
    func bool(_ i: Int, _ def: Bool? = nil) throws -> Bool {
        if !has(i) { return def ?? false }
        return try X.bool(values[i])
    }
}

enum Lift {
    static func apply(_ a: Args, lifted: Set<Int>?, _ f: (Scalars) throws -> SheetValue) -> SheetValue {
        let vals = (0..<a.count).map { a.has($0) ? a.value($0) : .empty }
        let omitted = (0..<a.count).map { !a.has($0) }
        var rows = 0, cols = 0, any = false
        for (i, v) in vals.enumerated() where lifted?.contains(i) ?? true {
            if case .array(let m) = v { rows = max(rows, m.rows); cols = max(cols, m.cols); any = true }
        }
        func run(_ s: [SheetValue]) -> SheetValue {
            do { return try f(Scalars(values: s, omitted: omitted, args: a)) }
            catch let e as XLError { return .error(e.code) }
            catch { return .error("#VALUE!") }
        }
        guard any else { return run(vals) }
        var out = Matrix(rows: rows, cols: cols)
        for r in 0..<rows { for c in 0..<cols {
            var s = vals
            var bad = false
            for (i, v) in vals.enumerated() where lifted?.contains(i) ?? true {
                if case .array(let m) = v {
                    if let x = Broadcast.pick(m, r, c) { s[i] = x } else { bad = true }
                }
            }
            out[r, c] = bad ? .error("#N/A") : run(s)
        } }
        return .array(out)
    }
}

// MARK: - LET / LAMBDA helpers

enum LambdaFunctions {
    static func letValue(_ a: Args) throws -> SheetValue {
        guard a.count >= 3, a.count % 2 == 1 else { throw XLError.value }
        var ctx = a.ctx
        for i in stride(from: 0, to: a.count - 1, by: 2) {
            guard case .name(let n) = a.exprs[i] else { throw XLError.value }
            let v = a.engine.eval(a.exprs[i + 1], ctx)
            ctx.env[FormulaParser.clean(n).uppercased()] = v
        }
        return a.engine.eval(a.exprs[a.count - 1], ctx)
    }

    static func call(_ a: Args, _ l: LambdaValue, _ values: [SheetValue]) -> SheetValue {
        a.engine.callLambda(l, values)
    }
}

// MARK: - Shared numeric helpers

enum Num {
    /// Round half away from zero at `digits` decimals using the value's
    /// 15-significant-digit form, matching Excel (ROUND(2.675,2) = 2.68).
    static func round(_ x: Double, _ digits: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Double {
        guard x.isFinite, x != 0 else { return x }
        let neg = x < 0
        var dec = Decimal(string: String(format: "%.15g", abs(x))) ?? Decimal(abs(x))
        var out = Decimal()
        let m: NSDecimalNumber.RoundingMode = mode == .plain ? .plain : mode
        NSDecimalRound(&out, &dec, max(-308, min(digits, 300)), m)
        let r = NSDecimalNumber(decimal: out).doubleValue
        return neg ? -r : r
    }

    static func roundUp(_ x: Double, _ digits: Int) -> Double { round(x, digits, mode: .up) }
    static func roundDown(_ x: Double, _ digits: Int) -> Double { round(x, digits, mode: .down) }

    /// Snaps values within 1e-12 relative of an integer (division noise).
    static func approxInt(_ q: Double) -> Double {
        let r = q.rounded()
        return abs(q - r) <= 1e-12 * max(1, abs(q)) ? r : q
    }

    static func fact(_ n: Int) -> Double {
        if n < 0 { return .nan }
        if n > 170 { return .infinity }
        var r = 1.0
        if n > 1 { for i in 2...n { r *= Double(i) } }
        return r
    }

    static func combin(_ n: Double, _ k: Double) -> Double {
        if k < 0 || n < k { return .nan }
        let kk = min(k, n - k)
        if kk == 0 { return 1 }
        if n > 1000 { return (exp(Special.lnGamma(n + 1) - Special.lnGamma(kk + 1) - Special.lnGamma(n - kk + 1))).rounded() }
        var r = 1.0
        for i in 0..<Int(kk) { r = r * (n - Double(i)) / Double(i + 1) }
        return r.rounded()
    }

    static func gcd(_ a: Double, _ b: Double) -> Double {
        var x = a, y = b
        while y > 0.5 { let t = x.truncatingRemainder(dividingBy: y); x = y; y = t }
        return x
    }
}
