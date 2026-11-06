import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum MathFunctions {
    static func register(_ r: inout Registry) {
        r.raw("SUM") { a in try X.check(try a.numbers().reduce(0, +)) }
        r.raw("PRODUCT") { a in
            let n = try a.numbers()
            return try X.check(n.isEmpty ? 0 : n.reduce(1, *))
        }
        r.raw("SUMSQ") { a in try X.check(try a.numbers().reduce(0) { $0 + $1 * $1 }) }

        r.num("ABS", min: 1, max: 1) { abs(try $0.num(0)) }
        r.num("INT", min: 1, max: 1) { floor(try $0.num(0)) }
        r.num("SIGN", min: 1, max: 1) { let x = try $0.num(0); return x > 0 ? 1 : x < 0 ? -1 : 0 }
        r.num("SQRT", min: 1, max: 1) { let x = try $0.num(0); guard x >= 0 else { throw XLError.num }; return x.squareRoot() }
        r.num("SQRTPI", min: 1, max: 1) { let x = try $0.num(0); guard x >= 0 else { throw XLError.num }; return (x * Double.pi).squareRoot() }
        r.num("EXP", min: 1, max: 1) { exp(try $0.num(0)) }
        r.num("LN", min: 1, max: 1) { let x = try $0.num(0); guard x > 0 else { throw XLError.num }; return log(x) }
        r.num("LOG10", min: 1, max: 1) { let x = try $0.num(0); guard x > 0 else { throw XLError.num }; return log10(x) }
        r.num("LOG", min: 1, max: 2) { s in
            let x = try s.num(0), b = try s.num(1, 10)
            guard x > 0, b > 0 else { throw XLError.num }
            guard b != 1 else { throw XLError.div0 }
            return log(x) / log(b)
        }
        r.num("PI", min: 0, max: 0) { _ in Double.pi }
        r.num("POWER", min: 2, max: 2) { s in
            let x = try s.num(0), y = try s.num(1)
            if x == 0 && y == 0 { throw XLError.num }
            if x == 0 && y < 0 { throw XLError.div0 }
            return pow(x, y)
        }
        r.num("RADIANS", min: 1, max: 1) { try $0.num(0) * Double.pi / 180 }
        r.num("DEGREES", min: 1, max: 1) { try $0.num(0) * 180 / Double.pi }

        // Trigonometry
        r.num("SIN", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) < 134217728 else { throw XLError.num }; return sin(x) }
        r.num("COS", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) < 134217728 else { throw XLError.num }; return cos(x) }
        r.num("TAN", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) < 134217728 else { throw XLError.num }; return tan(x) }
        r.num("ASIN", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) <= 1 else { throw XLError.num }; return asin(x) }
        r.num("ACOS", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) <= 1 else { throw XLError.num }; return acos(x) }
        r.num("ATAN", min: 1, max: 1) { atan(try $0.num(0)) }
        r.num("ATAN2", min: 2, max: 2) { s in
            let x = try s.num(0), y = try s.num(1)
            guard x != 0 || y != 0 else { throw XLError.div0 }
            return atan2(y, x)
        }
        r.num("SINH", min: 1, max: 1) { sinh(try $0.num(0)) }
        r.num("COSH", min: 1, max: 1) { cosh(try $0.num(0)) }
        r.num("TANH", min: 1, max: 1) { tanh(try $0.num(0)) }
        r.num("ASINH", min: 1, max: 1) { asinh(try $0.num(0)) }
        r.num("ACOSH", min: 1, max: 1) { let x = try $0.num(0); guard x >= 1 else { throw XLError.num }; return acosh(x) }
        r.num("ATANH", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) < 1 else { throw XLError.num }; return atanh(x) }
        r.num("COT", min: 1, max: 1) { let x = try $0.num(0); guard x != 0 else { throw XLError.div0 }; guard abs(x) < 134217728 else { throw XLError.num }; return 1 / tan(x) }
        r.num("CSC", min: 1, max: 1) { let x = try $0.num(0); guard x != 0 else { throw XLError.div0 }; guard abs(x) < 134217728 else { throw XLError.num }; return 1 / sin(x) }
        r.num("SEC", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) < 134217728 else { throw XLError.num }; return 1 / cos(x) }
        r.num("COTH", min: 1, max: 1) { let x = try $0.num(0); guard x != 0 else { throw XLError.div0 }; return 1 / tanh(x) }
        r.num("CSCH", min: 1, max: 1) { let x = try $0.num(0); guard x != 0 else { throw XLError.div0 }; return 1 / sinh(x) }
        r.num("SECH", min: 1, max: 1) { 1 / cosh(try $0.num(0)) }
        r.num("ACOT", min: 1, max: 1) { Double.pi / 2 - atan(try $0.num(0)) }
        r.num("ACOTH", min: 1, max: 1) { let x = try $0.num(0); guard abs(x) > 1 else { throw XLError.num }; return 0.5 * log((x + 1) / (x - 1)) }

        // Rounding
        r.num("ROUND", min: 2, max: 2) { Num.round(try $0.num(0), try $0.int(1)) }
        r.num("ROUNDUP", min: 2, max: 2) { Num.roundUp(try $0.num(0), try $0.int(1)) }
        r.num("ROUNDDOWN", min: 2, max: 2) { Num.roundDown(try $0.num(0), try $0.int(1)) }
        r.num("TRUNC", min: 1, max: 2) { Num.roundDown(try $0.num(0), try $0.int(1, 0)) }
        r.num("EVEN", min: 1, max: 1) { s in
            let x = try s.num(0)
            let v = ceil(abs(x) / 2) * 2
            return x < 0 ? -v : v
        }
        r.num("ODD", min: 1, max: 1) { s in
            let x = try s.num(0)
            var v = ceil(abs(x))
            if v.truncatingRemainder(dividingBy: 2) == 0 { v += 1 }
            return x < 0 ? -v : v
        }
        r.num("MROUND", min: 2, max: 2) { s in
            let n = try s.num(0), m = try s.num(1)
            if m == 0 { return 0 }
            guard n * m >= 0 else { throw XLError.num }
            return Num.round(Num.approxInt(n / m), 0) * m
        }
        r.num("FLOOR", min: 2, max: 2) { s in
            let x = try s.num(0), sig = try s.num(1)
            if x == 0 { return 0 }
            guard sig != 0 else { throw XLError.div0 }
            guard !(x > 0 && sig < 0) else { throw XLError.num }
            return floor(Num.approxInt(x / sig)) * sig
        }
        r.num("CEILING", min: 2, max: 2) { s in
            let x = try s.num(0), sig = try s.num(1)
            if x == 0 || sig == 0 { return 0 }
            guard !(x > 0 && sig < 0) else { throw XLError.num }
            return ceil(Num.approxInt(x / sig)) * sig
        }
        r.num("CEILING.PRECISE", "ISO.CEILING", min: 1, max: 2) { s in
            let x = try s.num(0), sig = abs(try s.num(1, 1))
            if sig == 0 { return 0 }
            return ceil(Num.approxInt(x / sig)) * sig
        }
        r.num("FLOOR.PRECISE", min: 1, max: 2) { s in
            let x = try s.num(0), sig = abs(try s.num(1, 1))
            if sig == 0 { return 0 }
            return floor(Num.approxInt(x / sig)) * sig
        }
        r.num("CEILING.MATH", "ECMA.CEILING", min: 1, max: 3) { s in
            let x = try s.num(0), sig = abs(try s.num(1, 1)), mode = try s.num(2, 0)
            if sig == 0 { return 0 }
            let q = Num.approxInt(x / sig)
            return (x < 0 && mode != 0 ? floor(q) : ceil(q)) * sig
        }
        r.num("FLOOR.MATH", min: 1, max: 3) { s in
            let x = try s.num(0), sig = abs(try s.num(1, 1)), mode = try s.num(2, 0)
            if sig == 0 { return 0 }
            let q = Num.approxInt(x / sig)
            return (x < 0 && mode != 0 ? ceil(q) : floor(q)) * sig
        }

        r.num("MOD", min: 2, max: 2) { s in
            let x = try s.num(0), y = try s.num(1)
            guard y != 0 else { throw XLError.div0 }
            let m = x - y * floor(Num.approxInt(x / y))
            return abs(m) < 1e-15 * abs(y) ? 0 : m
        }
        r.num("QUOTIENT", min: 2, max: 2) { s in
            let x = try s.num(0), y = try s.num(1)
            guard y != 0 else { throw XLError.div0 }
            return (x / y).rounded(.towardZero)
        }

        // Combinatorics
        r.num("FACT", min: 1, max: 1) { s in
            let n = try s.num(0)
            guard n >= 0 else { throw XLError.num }
            return Num.fact(Int(n))
        }
        r.num("FACTDOUBLE", min: 1, max: 1) { s in
            let n = Int(try s.num(0))
            guard n >= -1 else { throw XLError.num }
            var r = 1.0, k = n
            while k > 1 { r *= Double(k); k -= 2 }
            return r
        }
        r.num("COMBIN", min: 2, max: 2) { s in
            let n = try s.num(0).rounded(.towardZero), k = try s.num(1).rounded(.towardZero)
            guard n >= 0, k >= 0, n >= k else { throw XLError.num }
            return Num.combin(n, k)
        }
        r.num("COMBINA", min: 2, max: 2) { s in
            let n = try s.num(0).rounded(.towardZero), k = try s.num(1).rounded(.towardZero)
            guard n >= 0, k >= 0, n >= k || n > 0 || k == 0 else { throw XLError.num }
            if n == 0 && k == 0 { return 1 }
            return Num.combin(n + k - 1, k)
        }
        r.num("PERMUT", min: 2, max: 2) { s in
            let n = try s.num(0).rounded(.towardZero), k = try s.num(1).rounded(.towardZero)
            guard n > 0 || (n == 0 && k == 0), k >= 0, n >= k else { throw XLError.num }
            var r = 1.0
            var i = 0.0
            while i < k { r *= n - i; i += 1 }
            return r
        }
        r.num("PERMUTATIONA", min: 2, max: 2) { s in
            let n = try s.num(0).rounded(.towardZero), k = try s.num(1).rounded(.towardZero)
            guard n >= 0, k >= 0 else { throw XLError.num }
            return pow(n, k)
        }
        r.raw("GCD", min: 1) { a in
            let n = try a.numbers().map { $0.rounded(.towardZero) }
            guard n.allSatisfy({ $0 >= 0 && $0 < 9.007199254740992e15 }) else { throw XLError.num }
            return .number(n.reduce(0) { Num.gcd($0, $1) })
        }
        r.raw("LCM", min: 1) { a in
            let n = try a.numbers().map { $0.rounded(.towardZero) }
            guard n.allSatisfy({ $0 >= 0 }) else { throw XLError.num }
            if n.contains(0) { return .number(0) }
            return try X.check(n.reduce(1) { $0 / Num.gcd($0, $1) * $1 })
        }
        r.raw("MULTINOMIAL", min: 1) { a in
            let n = try a.numbers().map { $0.rounded(.towardZero) }
            guard n.allSatisfy({ $0 >= 0 }) else { throw XLError.num }
            var lr = Special.lnGamma(n.reduce(0, +) + 1)
            for x in n { lr -= Special.lnGamma(x + 1) }
            return try X.check(exp(lr).rounded())
        }

        // Random
        r.raw("RAND", max: 0) { _ in .number(Double.random(in: 0..<1)) }
        r.num("RANDBETWEEN", min: 2, max: 2) { s in
            let lo = ceil(try s.num(0)), hi = floor(try s.num(1))
            guard lo <= hi else { throw XLError.num }
            return Double(Int64.random(in: Int64(lo)...Int64(hi)))
        }
        r.raw("RANDARRAY", max: 5) { a in
            let rows = try a.int(0, 1), cols = try a.int(1, 1)
            let lo = try a.num(2, 0), hi = try a.num(3, 1), integer = try a.bool(4, false)
            guard rows >= 1, cols >= 1 else { throw rows == 0 || cols == 0 ? XLError.calc : XLError.value }
            guard lo <= hi, !integer || (lo == lo.rounded() && hi == hi.rounded()) else { throw XLError.value }
            var m = Matrix(rows: rows, cols: cols)
            for i in 0..<m.data.count {
                m.data[i] = .number(integer ? Double(Int64.random(in: Int64(lo)...Int64(hi))) : lo + (hi - lo) * Double.random(in: 0..<1))
            }
            return .array(m)
        }
        r.raw("SEQUENCE", min: 1, max: 4) { a in
            let rows = try a.int(0, 1), cols = try a.int(1, 1)
            let start = try a.num(2, 1), step = try a.num(3, 1)
            guard rows >= 0, cols >= 0 else { throw XLError.value }
            guard rows > 0, cols > 0 else { throw XLError.calc }
            guard rows * cols <= 1_048_576 * 16 else { throw XLError.num }
            var m = Matrix(rows: rows, cols: cols)
            for i in 0..<(rows * cols) { m.data[i] = .number(start + Double(i) * step) }
            return .array(m)
        }

        // Sums of arrays
        r.raw("SUMPRODUCT", min: 1) { a in
            let ms = try (0..<a.count).map { try a.matrix($0) }
            guard let first = ms.first else { throw XLError.value }
            guard ms.allSatisfy({ $0.rows == first.rows && $0.cols == first.cols }) else { throw XLError.value }
            var total = 0.0
            for i in 0..<first.data.count {
                var p = 1.0
                for m in ms {
                    switch m.data[i] {
                    case .number(let d): p *= d
                    case .error(let e): throw XLError(e)
                    default: p = 0
                    }
                }
                total += p
            }
            return try X.check(total)
        }
        func pairs(_ a: Args) throws -> [(Double, Double)] {
            let x = try a.matrix(0), y = try a.matrix(1)
            guard x.data.count == y.data.count else { throw XLError.na }
            var out: [(Double, Double)] = []
            for i in 0..<x.data.count {
                if case .error(let e) = x.data[i] { throw XLError(e) }
                if case .error(let e) = y.data[i] { throw XLError(e) }
                if case .number(let p) = x.data[i], case .number(let q) = y.data[i] { out.append((p, q)) }
            }
            return out
        }
        r.raw("SUMX2MY2", min: 2, max: 2) { a in try X.check(try pairs(a).reduce(0) { $0 + $1.0 * $1.0 - $1.1 * $1.1 }) }
        r.raw("SUMX2PY2", min: 2, max: 2) { a in try X.check(try pairs(a).reduce(0) { $0 + $1.0 * $1.0 + $1.1 * $1.1 }) }
        r.raw("SUMXMY2", min: 2, max: 2) { a in try X.check(try pairs(a).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }) }
        r.raw("SERIESSUM", min: 4, max: 4) { a in
            let x = try a.num(0), n = try a.num(1), m = try a.num(2)
            let coef = try a.matrix(3).data.map { v -> Double in
                guard case .number(let d) = v else { throw XLError.value }
                return d
            }
            var s = 0.0
            for (i, c) in coef.enumerated() { s += c * pow(x, n + Double(i) * m) }
            return try X.check(s)
        }

        // Conditional sums
        r.raw("SUMIF", min: 2, max: 3) { a in
            let range = a.grid(0)
            let sumRange: Matrix
            if a.has(2) {
                if let ref = a.ref(2) {
                    // Excel resizes sum_range to the criteria range's shape from its top-left.
                    let s = ref.range.start
                    sumRange = Matrix((0..<range.rows).map { r in (0..<range.cols).map { c in
                        a.engine.value(ref.sheet, CellRef(row: s.row + r, col: s.col + c)) } })
                } else { sumRange = a.grid(2) }
            } else { sumRange = range }
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(1))]), lifted: nil) { s in
                let crit = Criteria(s.raw(0))
                var total = 0.0
                for r in 0..<range.rows { for c in 0..<range.cols where crit.test(range[r, c]) {
                    guard r < sumRange.rows, c < sumRange.cols else { continue }
                    switch sumRange[r, c] {
                    case .number(let d): total += d
                    case .error(let e): throw XLError(e)
                    default: break
                    }
                } }
                return .number(total)
            }
        }
        r.raw("SUMIFS", min: 3) { a in
            try Conditional.aggregate(a, valuesAt: 0, pairsFrom: 1) { vals in .number(vals.reduce(0, +)) }
        }

        // Matrices
        r.raw("MMULT", min: 2, max: 2) { a in
            let x = try Matrix.numeric(a.matrix(0)), y = try Matrix.numeric(a.matrix(1))
            guard x.cols == y.rows else { throw XLError.value }
            var m = Matrix(rows: x.rows, cols: y.cols)
            for i in 0..<x.rows { for j in 0..<y.cols {
                var s = 0.0
                for k in 0..<x.cols { s += x.d[i * x.cols + k] * y.d[k * y.cols + j] }
                m[i, j] = .number(s)
            } }
            return .array(m)
        }
        r.raw("MDETERM", min: 1, max: 1) { a in
            let x = try Matrix.numeric(a.matrix(0))
            guard x.rows == x.cols else { throw XLError.value }
            return try X.check(LinearAlgebra.determinant(x.d, x.rows))
        }
        r.raw("MINVERSE", min: 1, max: 1) { a in
            let x = try Matrix.numeric(a.matrix(0))
            guard x.rows == x.cols else { throw XLError.value }
            guard let inv = LinearAlgebra.inverse(x.d, x.rows) else { throw XLError.num }
            var m = Matrix(rows: x.rows, cols: x.cols)
            m.data = inv.map { .number(abs($0) < 1e-16 ? 0 : $0) }
            return .array(m)
        }
        r.raw("MUNIT", min: 1, max: 1) { a in
            let n = try a.int(0)
            guard n >= 1 else { throw XLError.value }
            var m = Matrix(rows: n, cols: n, fill: .number(0))
            for i in 0..<n { m[i, i] = .number(1) }
            return .array(m)
        }

        // Numerals
        r.scalar("ROMAN", min: 1, max: 2) { s in
            let n = try s.num(0)
            var form = 0
            if s.has(1) {
                if case .bool(let b) = s.raw(1) { form = b ? 0 : 4 } else { form = try s.int(1) }
            }
            guard n >= 0, n < 4000, (0...4).contains(form) else { throw XLError.value }
            return .string(Numerals.roman(Int(n), form))
        }
        r.scalar("ARABIC", min: 1, max: 1) { s in
            guard let v = Numerals.arabic(try s.str(0)) else { throw XLError.value }
            return .number(v)
        }
        r.scalar("BASE", min: 2, max: 3) { s in
            let n = try s.num(0).rounded(.towardZero), radix = try s.int(1), minLen = try s.int(2, 0)
            guard n >= 0, n < 9007199254740992, (2...36).contains(radix), (0...255).contains(minLen) else { throw XLError.num }
            var str = String(UInt64(n), radix: radix).uppercased()
            if str.count < minLen { str = String(repeating: "0", count: minLen - str.count) + str }
            return .string(str)
        }
        r.scalar("DECIMAL", min: 2, max: 2) { s in
            var t = try s.str(0).trimmingCharacters(in: .whitespaces)
            let radix = try s.int(1)
            guard (2...36).contains(radix), t.count <= 255 else { throw XLError.num }
            if radix == 16, t.lowercased().hasPrefix("0x") { t.removeFirst(2) }
            if radix == 16, t.lowercased().hasSuffix("h") { t.removeLast() }
            if radix == 2, t.lowercased().hasSuffix("b") { t.removeLast() }
            var v = 0.0
            for ch in t {
                guard let d = ch.hexDigitValue ?? (ch.isLetter ? Int(ch.uppercased().unicodeScalars.first!.value) - 55 : nil), d < radix else { throw XLError.num }
                v = v * Double(radix) + Double(d)
            }
            return .number(v)
        }

        // Subtotals
        r.raw("SUBTOTAL", min: 2) { a in
            let fn = try a.int(0)
            let code = fn > 100 ? fn - 100 : fn
            guard (1...11).contains(code) else { throw XLError.value }
            var values: [SheetValue] = []
            for i in 1..<a.count {
                if let ref = a.ref(i) {
                    for cell in ref.range.cells {
                        if let input = ref.sheet.cells[cell]?.input.uppercased(), input.hasPrefix("="),
                           input.contains("SUBTOTAL(") || input.contains("AGGREGATE(") { continue }
                        values.append(a.engine.value(ref.sheet, cell))
                    }
                } else {
                    values += a.flat(from: i, to: i + 1)
                }
            }
            return try Aggregates.apply(subtotal: code, values)
        }
        r.raw("AGGREGATE", min: 3) { a in
            let fn = try a.int(0), options = try a.int(1, 0)
            guard (1...19).contains(fn), (0...7).contains(options) else { throw XLError.value }
            let skipErrors = [2, 3, 6, 7].contains(options)
            let skipNested = options <= 3
            var values: [SheetValue] = []
            let lastData = fn >= 14 ? 3 : a.count
            for i in 2..<lastData {
                if let ref = a.ref(i) {
                    for cell in ref.range.cells {
                        if skipNested, let input = ref.sheet.cells[cell]?.input.uppercased(), input.hasPrefix("="),
                           input.contains("SUBTOTAL(") || input.contains("AGGREGATE(") { continue }
                        values.append(a.engine.value(ref.sheet, cell))
                    }
                } else {
                    values += a.flat(from: i, to: i + 1)
                }
            }
            if skipErrors { values = values.filter { !$0.isError } }
            if fn >= 14 {
                guard a.count >= 4 else { throw XLError.value }
                return try Aggregates.apply(aggregate: fn, values, k: try a.num(3))
            }
            return try Aggregates.apply(aggregate: fn, values, k: nil)
        }

        r.raw("PERCENTOF", min: 2, max: 2) { a in
            let part = try a.numbers(from: 0, to: 1).reduce(0, +)
            let all = try a.numbers(from: 1, to: 2).reduce(0, +)
            guard all != 0 else { throw XLError.div0 }
            return try X.check(part / all)
        }
    }
}

extension Matrix {
    /// Numeric view; any non-number element is #VALUE!.
    static func numeric(_ m: Matrix) throws -> (rows: Int, cols: Int, d: [Double]) {
        let d = try m.data.map { v -> Double in
            switch v {
            case .number(let x): return x
            case .error(let e): throw XLError(e)
            default: throw XLError.value
            }
        }
        return (m.rows, m.cols, d)
    }
}

enum LinearAlgebra {
    static func determinant(_ a: [Double], _ n: Int) -> Double {
        var m = a, det = 1.0
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(m[r * n + c]) > abs(m[p * n + c]) { p = r }
            if m[p * n + c] == 0 { return 0 }
            if p != c { for k in 0..<n { m.swapAt(p * n + k, c * n + k) }; det = -det }
            det *= m[c * n + c]
            for r in (c + 1)..<max(c + 1, n) {
                let f = m[r * n + c] / m[c * n + c]
                for k in c..<n { m[r * n + k] -= f * m[c * n + k] }
            }
        }
        return det
    }

    static func inverse(_ a: [Double], _ n: Int) -> [Double]? {
        var m = a
        var inv = [Double](repeating: 0, count: n * n)
        for i in 0..<n { inv[i * n + i] = 1 }
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(m[r * n + c]) > abs(m[p * n + c]) { p = r }
            guard abs(m[p * n + c]) > 1e-300 else { return nil }
            if p != c { for k in 0..<n { m.swapAt(p * n + k, c * n + k); inv.swapAt(p * n + k, c * n + k) } }
            let piv = m[c * n + c]
            for k in 0..<n { m[c * n + k] /= piv; inv[c * n + k] /= piv }
            for r in 0..<n where r != c {
                let f = m[r * n + c]
                if f == 0 { continue }
                for k in 0..<n { m[r * n + k] -= f * m[c * n + k]; inv[r * n + k] -= f * inv[c * n + k] }
            }
        }
        return inv
    }

    /// Least squares via normal equations with QR-like Householder solve.
    /// Returns coefficients for columns of x (n×p) predicting y.
    static func leastSquares(_ x: [[Double]], _ y: [Double]) -> [Double]? {
        let n = y.count, p = x.first?.count ?? 0
        guard n > 0, p > 0 else { return nil }
        var a = x, b = y
        var rdiag = [Double](repeating: 0, count: p)
        // Householder QR
        for k in 0..<p {
            var nrm = 0.0
            for i in k..<n { nrm = hypot(nrm, a[i][k]) }
            if nrm != 0 {
                if a[k][k] < 0 { nrm = -nrm }
                for i in k..<n { a[i][k] /= nrm }
                a[k][k] += 1
                for j in (k + 1)..<max(k + 1, p) {
                    var s = 0.0
                    for i in k..<n { s += a[i][k] * a[i][j] }
                    s = -s / a[k][k]
                    for i in k..<n { a[i][j] += s * a[i][k] }
                }
                var s = 0.0
                for i in k..<n { s += a[i][k] * b[i] }
                s = -s / a[k][k]
                for i in k..<n { b[i] += s * a[i][k] }
            }
            rdiag[k] = -nrm
        }
        var coef = [Double](repeating: 0, count: p)
        for k in stride(from: p - 1, through: 0, by: -1) {
            if abs(rdiag[k]) < 1e-12 { coef[k] = 0; continue }   // collinear column
            var s = b[k]
            for j in (k + 1)..<max(k + 1, p) { s -= a[k][j] * coef[j] }
            coef[k] = s / rdiag[k]
        }
        return coef
    }
}

enum Numerals {
    static func roman(_ value: Int, _ mode: Int) -> String {
        let chars: [Character] = ["M", "D", "C", "L", "X", "V", "I"]
        let values = [1000, 500, 100, 50, 10, 5, 1]
        let maxIndex = values.count - 1
        var out = ""
        var val = value
        for i in 0...(maxIndex / 2) {
            var index = 2 * i
            let digit = val / values[index]
            if digit % 5 == 4 {
                let index2 = digit == 4 ? index - 1 : index - 2
                var steps = 0
                while steps < mode && index < maxIndex {
                    steps += 1
                    if values[index2] - values[index + 1] <= val { index += 1 } else { steps = mode }
                }
                out.append(chars[index]); out.append(chars[index2])
                val = val + values[index] - values[index2]
            } else {
                if digit > 4 { out.append(chars[index - 1]) }
                out += String(repeating: chars[index], count: digit % 5)
                val %= values[index]
            }
        }
        return out
    }

    static func arabic(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.count <= 255 else { return nil }
        var sign = 1.0
        if s.hasPrefix("-") { sign = -1; s.removeFirst() }
        if s.isEmpty { return 0 }
        let map: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0, prev = 0
        for ch in s.reversed() {
            guard let v = map[ch] else { return nil }
            if v < prev { total -= v } else { total += v; prev = v }
        }
        return sign * Double(total)
    }
}
