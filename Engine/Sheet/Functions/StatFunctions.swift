import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Descriptive statistics shared by the statistical, SUBTOTAL and AGGREGATE functions.
enum Stats {
    static func mean(_ x: [Double]) throws -> Double {
        guard !x.isEmpty else { throw XLError.div0 }
        return x.reduce(0, +) / Double(x.count)
    }
    static func devsq(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let m = x.reduce(0, +) / Double(x.count)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) }
    }
    static func varS(_ x: [Double]) throws -> Double {
        guard x.count > 1 else { throw XLError.div0 }
        return devsq(x) / Double(x.count - 1)
    }
    static func varP(_ x: [Double]) throws -> Double {
        guard !x.isEmpty else { throw XLError.div0 }
        return devsq(x) / Double(x.count)
    }
    static func median(_ x: [Double]) throws -> Double {
        guard !x.isEmpty else { throw XLError.num }
        let s = x.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    /// Modes in order of first appearance (only values occurring > 1 time).
    static func modes(_ x: [Double]) throws -> [Double] {
        var counts: [Double: Int] = [:]
        for v in x { counts[v, default: 0] += 1 }
        guard let best = counts.values.max(), best > 1 else { throw XLError.na }
        var seen = Set<Double>(), out: [Double] = []
        for v in x where counts[v] == best && !seen.contains(v) { seen.insert(v); out.append(v) }
        return out
    }
    static func large(_ x: [Double], _ k: Double) throws -> Double {
        let kk = Int(ceil(Num.approxInt(k)))
        guard kk >= 1, kk <= x.count else { throw XLError.num }
        return x.sorted(by: >)[kk - 1]
    }
    static func small(_ x: [Double], _ k: Double) throws -> Double {
        let kk = Int(ceil(Num.approxInt(k)))
        guard kk >= 1, kk <= x.count else { throw XLError.num }
        return x.sorted()[kk - 1]
    }
    static func percentileInc(_ x: [Double], _ p: Double) throws -> Double {
        guard !x.isEmpty, p >= 0, p <= 1 else { throw XLError.num }
        let s = x.sorted()
        let rank = p * Double(s.count - 1)
        let lo = Int(floor(rank)), frac = rank - floor(rank)
        return lo + 1 < s.count ? s[lo] + frac * (s[lo + 1] - s[lo]) : s[lo]
    }
    static func percentileExc(_ x: [Double], _ p: Double) throws -> Double {
        let n = Double(x.count)
        guard !x.isEmpty, p > 0, p < 1 else { throw XLError.num }
        let rank = p * (n + 1)
        guard rank >= 1, rank <= n else { throw XLError.num }
        let s = x.sorted()
        let lo = Int(floor(rank)) - 1, frac = rank - floor(rank)
        return lo + 1 < s.count ? s[lo] + frac * (s[lo + 1] - s[lo]) : s[lo]
    }
    static func quartileInc(_ x: [Double], _ q: Double) throws -> Double {
        let qq = q.rounded(.towardZero)
        guard (0...4).contains(qq) else { throw XLError.num }
        return try percentileInc(x, qq / 4)
    }
    static func quartileExc(_ x: [Double], _ q: Double) throws -> Double {
        let qq = q.rounded(.towardZero)
        guard (1...3).contains(qq) else { throw XLError.num }
        return try percentileExc(x, qq / 4)
    }
    static func percentRank(_ x: [Double], _ v: Double, sig: Int, exclusive: Bool) throws -> Double {
        guard !x.isEmpty, sig >= 1 else { throw XLError.num }
        let s = x.sorted(), n = Double(s.count)
        guard v >= s.first!, v <= s.last! else { throw XLError.na }
        func rankOf(_ value: Double) -> Double {
            let less = Double(s.filter { $0 < value }.count)
            return exclusive ? (less + 1) / (n + 1) : (n == 1 ? 1 : less / (n - 1))
        }
        var r: Double
        if s.contains(v) { r = rankOf(v) }
        else {
            let lo = s.last { $0 < v }!, hi = s.first { $0 > v }!
            let rl = rankOf(lo), rh = rankOf(hi)
            r = rl + (v - lo) / (hi - lo) * (rh - rl)
        }
        let f = pow(10, Double(sig))
        return floor(r * f + 1e-9) / f
    }
    static func kurt(_ x: [Double]) throws -> Double {
        let n = Double(x.count)
        guard n >= 4 else { throw XLError.div0 }
        let m = try mean(x), s = try varS(x).squareRoot()
        guard s > 0 else { throw XLError.div0 }
        let sum4 = x.reduce(0) { $0 + pow(($1 - m) / s, 4) }
        return n * (n + 1) / ((n - 1) * (n - 2) * (n - 3)) * sum4 - 3 * (n - 1) * (n - 1) / ((n - 2) * (n - 3))
    }
    static func skew(_ x: [Double]) throws -> Double {
        let n = Double(x.count)
        guard n >= 3 else { throw XLError.div0 }
        let m = try mean(x), s = try varS(x).squareRoot()
        guard s > 0 else { throw XLError.div0 }
        return n / ((n - 1) * (n - 2)) * x.reduce(0) { $0 + pow(($1 - m) / s, 3) }
    }
    static func skewP(_ x: [Double]) throws -> Double {
        let n = Double(x.count)
        guard n >= 1 else { throw XLError.div0 }
        let m = try mean(x), s = try varP(x).squareRoot()
        guard s > 0 else { throw XLError.div0 }
        return x.reduce(0) { $0 + pow(($1 - m) / s, 3) } / n
    }
    static func product(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(1, *) }
}

/// SUBTOTAL / AGGREGATE dispatch over raw cell values.
enum Aggregates {
    static func numbers(_ values: [SheetValue], propagate: Bool = true) throws -> [Double] {
        var out: [Double] = []
        for v in values {
            switch v {
            case .number(let d): out.append(d)
            case .error(let e): if propagate { throw XLError(e) }
            default: break
            }
        }
        return out
    }

    static func apply(subtotal code: Int, _ values: [SheetValue]) throws -> SheetValue {
        switch code {
        case 2: return .number(Double(values.filter(\.isNumber).count))
        case 3: return .number(Double(values.filter { if case .empty = $0 { return false }; return true }.count))
        default:
            let map = [1: 1, 4: 4, 5: 5, 6: 6, 7: 7, 8: 8, 9: 9, 10: 10, 11: 11]
            return try apply(aggregate: map[code]!, values, k: nil)
        }
    }

    static func apply(aggregate fn: Int, _ values: [SheetValue], k: Double?) throws -> SheetValue {
        if fn == 2 { return .number(Double(values.filter(\.isNumber).count)) }
        if fn == 3 { return .number(Double(values.filter { if case .empty = $0 { return false }; return true }.count)) }
        let x = try numbers(values)
        let r: Double
        switch fn {
        case 1: r = try Stats.mean(x)
        case 4: r = x.max() ?? 0
        case 5: r = x.min() ?? 0
        case 6: r = Stats.product(x)
        case 7: r = try Stats.varS(x).squareRoot()
        case 8: r = try Stats.varP(x).squareRoot()
        case 9: r = x.reduce(0, +)
        case 10: r = try Stats.varS(x)
        case 11: r = try Stats.varP(x)
        case 12: r = try Stats.median(x)
        case 13: r = try Stats.modes(x)[0]
        case 14: r = try Stats.large(x, k ?? 1)
        case 15: r = try Stats.small(x, k ?? 1)
        case 16: r = try Stats.percentileInc(x, k ?? 0)
        case 17: r = try Stats.quartileInc(x, k ?? 0)
        case 18: r = try Stats.percentileExc(x, k ?? 0)
        case 19: r = try Stats.quartileExc(x, k ?? 0)
        default: throw XLError.value
        }
        return try X.check(r)
    }
}

/// *IFS-style evaluation: (range, criteria) pairs select positions.
enum Conditional {
    static func aggregate(_ a: Args, valuesAt: Int?, pairsFrom: Int, _ f: @escaping ([Double]) throws -> SheetValue) throws -> SheetValue {
        guard (a.count - pairsFrom) % 2 == 0, a.count > pairsFrom else { throw XLError.value }
        let ranges = stride(from: pairsFrom, to: a.count, by: 2).map { a.grid($0) }
        let values = valuesAt.map { a.grid($0) }
        let shape = ranges[0]
        guard ranges.allSatisfy({ $0.rows == shape.rows && $0.cols == shape.cols }) else { throw XLError.value }
        if let values, values.rows != shape.rows || values.cols != shape.cols { throw XLError.value }
        let crits = stride(from: pairsFrom + 1, to: a.count, by: 2).map { Expr.value(a.value($0)) }
        return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: crits), lifted: nil) { s in
            let tests = (0..<s.count).map { Criteria(s.raw($0)) }
            var picked: [Double] = []
            var count = 0
            for i in 0..<shape.data.count {
                var ok = true
                for (j, t) in tests.enumerated() where !t.test(ranges[j].data[i]) { ok = false; break }
                guard ok else { continue }
                count += 1
                if let values {
                    switch values.data[i] {
                    case .number(let d): picked.append(d)
                    case .error(let e): throw XLError(e)
                    default: break
                    }
                }
            }
            return valuesAt == nil ? .number(Double(count)) : try f(picked)
        }
    }
}

/// Paired numeric data for regression-style functions (both values numeric).
enum Paired {
    static func data(_ a: Args, _ yi: Int, _ xi: Int) throws -> (y: [Double], x: [Double]) {
        let ym = try a.matrix(yi), xm = try a.matrix(xi)
        guard ym.data.count == xm.data.count else { throw XLError.na }
        var y: [Double] = [], x: [Double] = []
        for i in 0..<ym.data.count {
            if case .error(let e) = ym.data[i] { throw XLError(e) }
            if case .error(let e) = xm.data[i] { throw XLError(e) }
            if case .number(let p) = ym.data[i], case .number(let q) = xm.data[i] { y.append(p); x.append(q) }
        }
        return (y, x)
    }

    static func sums(_ y: [Double], _ x: [Double]) throws -> (n: Double, mx: Double, my: Double, sxx: Double, syy: Double, sxy: Double) {
        let n = Double(y.count)
        guard n > 0 else { throw XLError.div0 }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<y.count {
            sxx += (x[i] - mx) * (x[i] - mx); syy += (y[i] - my) * (y[i] - my); sxy += (x[i] - mx) * (y[i] - my)
        }
        return (n, mx, my, sxx, syy, sxy)
    }
}

enum StatFunctions {
    static func register(_ r: inout Registry) {
        r.raw("AVERAGE", min: 1) { a in try X.check(try Stats.mean(a.numbers())) }
        r.raw("AVERAGEA", min: 1) { a in try X.check(try Stats.mean(a.numbers(allValues: true))) }
        r.raw("MAX", min: 1) { a in .number(try a.numbers().max() ?? 0) }
        r.raw("MIN", min: 1) { a in .number(try a.numbers().min() ?? 0) }
        r.raw("MAXA", min: 1) { a in .number(try a.numbers(allValues: true).max() ?? 0) }
        r.raw("MINA", min: 1) { a in .number(try a.numbers(allValues: true).min() ?? 0) }
        r.raw("COUNT") { a in
            var n = 0
            for i in 0..<a.count {
                let v = a.value(i)
                if case .array(let m) = v { n += m.data.filter(\.isNumber).count }
                else if a.isRef(i) { if v.isNumber { n += 1 } }
                else if !a.has(i) { n += 1 }
                else if (try? X.num(v)) != nil, !v.isError { n += 1 }
            }
            return .number(Double(n))
        }
        r.raw("COUNTA") { a in
            var n = 0
            for i in 0..<a.count {
                let v = a.value(i)
                if case .array(let m) = v { n += m.data.filter { if case .empty = $0 { return false }; return true }.count }
                else if a.isRef(i) { if case .empty = v {} else { n += 1 } }
                else { n += 1 }
            }
            return .number(Double(n))
        }
        r.raw("COUNTBLANK", min: 1, max: 1) { a in
            let m = a.grid(0)
            return .number(Double(m.data.filter { v in
                if case .empty = v { return true }
                if case .string(let s) = v { return s.isEmpty }
                return false
            }.count))
        }
        r.raw("COUNTIF", min: 2, max: 2) { a in
            let range = a.grid(0)
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(1))]), lifted: nil) { s in
                let c = Criteria(s.raw(0))
                return .number(Double(range.data.filter { c.test($0) }.count))
            }
        }
        r.raw("COUNTIFS", min: 2) { a in try Conditional.aggregate(a, valuesAt: nil, pairsFrom: 0) { _ in .empty } }
        r.raw("AVERAGEIF", min: 2, max: 3) { a in
            let range = a.grid(0)
            var avgRange = range
            if a.has(2) {
                if let ref = a.ref(2) {
                    let s = ref.range.start
                    avgRange = Matrix((0..<range.rows).map { r in (0..<range.cols).map { c in
                        a.engine.value(ref.sheet, CellRef(row: s.row + r, col: s.col + c)) } })
                } else { avgRange = a.grid(2) }
            }
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(1))]), lifted: nil) { s in
                let c = Criteria(s.raw(0))
                var vals: [Double] = []
                for r in 0..<range.rows { for col in 0..<range.cols where c.test(range[r, col]) {
                    guard r < avgRange.rows, col < avgRange.cols else { continue }
                    if case .number(let d) = avgRange[r, col] { vals.append(d) }
                    if case .error(let e) = avgRange[r, col] { throw XLError(e) }
                } }
                return .number(try Stats.mean(vals))
            }
        }
        r.raw("AVERAGEIFS", min: 3) { a in try Conditional.aggregate(a, valuesAt: 0, pairsFrom: 1) { .number(try Stats.mean($0)) } }
        r.raw("MAXIFS", min: 3) { a in try Conditional.aggregate(a, valuesAt: 0, pairsFrom: 1) { .number($0.max() ?? 0) } }
        r.raw("MINIFS", min: 3) { a in try Conditional.aggregate(a, valuesAt: 0, pairsFrom: 1) { .number($0.min() ?? 0) } }
        r.raw("AVERAGE.WEIGHTED", min: 2, max: 2) { a in
            let v = try a.matrix(0), w = try a.matrix(1)
            guard v.data.count == w.data.count else { throw XLError.value }
            var num = 0.0, den = 0.0
            for i in 0..<v.data.count {
                if case .error(let e) = v.data[i] { throw XLError(e) }
                if case .error(let e) = w.data[i] { throw XLError(e) }
                guard case .number(let x) = v.data[i], case .number(let y) = w.data[i] else { continue }
                guard y >= 0 else { throw XLError.num }
                num += x * y; den += y
            }
            guard den != 0 else { throw XLError.div0 }
            return try X.check(num / den)
        }

        // Dispersion
        r.raw("STDEV", "STDEV.S", min: 1) { a in try X.check(try Stats.varS(a.numbers()).squareRoot()) }
        r.raw("STDEVP", "STDEV.P", min: 1) { a in try X.check(try Stats.varP(a.numbers()).squareRoot()) }
        r.raw("STDEVA", min: 1) { a in try X.check(try Stats.varS(a.numbers(allValues: true)).squareRoot()) }
        r.raw("STDEVPA", min: 1) { a in try X.check(try Stats.varP(a.numbers(allValues: true)).squareRoot()) }
        r.raw("VAR", "VAR.S", min: 1) { a in try X.check(try Stats.varS(a.numbers())) }
        r.raw("VARP", "VAR.P", min: 1) { a in try X.check(try Stats.varP(a.numbers())) }
        r.raw("VARA", min: 1) { a in try X.check(try Stats.varS(a.numbers(allValues: true))) }
        r.raw("VARPA", min: 1) { a in try X.check(try Stats.varP(a.numbers(allValues: true))) }
        r.raw("DEVSQ", min: 1) { a in
            let x = try a.numbers()
            guard !x.isEmpty else { throw XLError.num }
            return try X.check(Stats.devsq(x))
        }
        r.raw("AVEDEV", min: 1) { a in
            let x = try a.numbers()
            guard !x.isEmpty else { throw XLError.num }
            let m = try Stats.mean(x)
            return try X.check(x.reduce(0) { $0 + abs($1 - m) } / Double(x.count))
        }
        r.raw("KURT", min: 1) { a in try X.check(try Stats.kurt(a.numbers())) }
        r.raw("SKEW", min: 1) { a in try X.check(try Stats.skew(a.numbers())) }
        r.raw("SKEW.P", min: 1) { a in try X.check(try Stats.skewP(a.numbers())) }
        r.raw("GEOMEAN", min: 1) { a in
            let x = try a.numbers()
            guard !x.isEmpty, x.allSatisfy({ $0 > 0 }) else { throw XLError.num }
            return try X.check(exp(x.reduce(0) { $0 + log($1) } / Double(x.count)))
        }
        r.raw("HARMEAN", min: 1) { a in
            let x = try a.numbers()
            guard !x.isEmpty, x.allSatisfy({ $0 > 0 }) else { throw XLError.num }
            return try X.check(Double(x.count) / x.reduce(0) { $0 + 1 / $1 })
        }
        r.raw("TRIMMEAN", min: 2, max: 2) { a in
            let x = try a.numbers(from: 0, to: 1).sorted(), p = try a.num(1)
            guard p >= 0, p < 1, !x.isEmpty else { throw XLError.num }
            let cut = Int(floor(Double(x.count) * p / 2))
            return try X.check(try Stats.mean(Array(x[cut..<(x.count - cut)])))
        }

        // Order statistics
        r.raw("MEDIAN", min: 1) { a in try X.check(try Stats.median(a.numbers())) }
        r.raw("MODE", "MODE.SNGL", min: 1) { a in .number(try Stats.modes(a.numbers())[0]) }
        r.raw("MODE.MULT", min: 1) { a in .array(.column(try Stats.modes(a.numbers()).map { .number($0) })) }
        func kth(_ name: String, _ f: @escaping ([Double], Double) throws -> Double) {
            r.raw(name, min: 2, max: 2) { a in
                let x = try a.numbers(from: 0, to: 1)
                return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(1))]), lifted: nil) { s in
                    try X.check(try f(x, try s.num(0)))
                }
            }
        }
        kth("LARGE", Stats.large)
        kth("SMALL", Stats.small)
        kth("PERCENTILE", Stats.percentileInc)
        kth("PERCENTILE.INC", Stats.percentileInc)
        kth("PERCENTILE.EXC", Stats.percentileExc)
        kth("QUARTILE", Stats.quartileInc)
        kth("QUARTILE.INC", Stats.quartileInc)
        kth("QUARTILE.EXC", Stats.quartileExc)
        for (name, exclusive) in [("PERCENTRANK", false), ("PERCENTRANK.INC", false), ("PERCENTRANK.EXC", true)] {
            r.raw(name, min: 2, max: 3) { a in
                let x = try a.numbers(from: 0, to: 1)
                return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(1)), .value(a.has(2) ? a.value(2) : .number(3))]), lifted: nil) { s in
                    try X.check(try Stats.percentRank(x, try s.num(0), sig: try s.int(1), exclusive: exclusive))
                }
            }
        }
        for (name, avg) in [("RANK", false), ("RANK.EQ", false), ("RANK.AVG", true)] {
            r.raw(name, min: 2, max: 3) { a in
                guard a.isRef(1) || { if case .array = a.value(1) { return true }; return false }() else { throw XLError.value }
                let x = try Aggregates.numbers(a.grid(1).data, propagate: false)
                let desc = try a.num(2, 0) == 0
                return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
                    let v = try s.num(0)
                    guard x.contains(v) else { throw XLError.na }
                    let better = Double(x.filter { desc ? $0 > v : $0 < v }.count)
                    let ties = Double(x.filter { $0 == v }.count)
                    return .number(avg ? better + (ties + 1) / 2 : better + 1)
                }
            }
        }
        r.raw("FREQUENCY", min: 2, max: 2) { a in
            let data = try Aggregates.numbers(a.grid(0).data)
            let bins = try Aggregates.numbers(a.grid(1).data)
            let order = bins.indices.sorted { bins[$0] < bins[$1] }
            var counts = [Double](repeating: 0, count: bins.count + 1)
            for d in data {
                if let k = order.first(where: { d <= bins[$0] }) { counts[k] += 1 } else { counts[bins.count] += 1 }
            }
            return .array(.column(counts.map { .number($0) }))
        }
        r.raw("PROB", min: 3, max: 4) { a in
            let xs = try a.matrix(0), ps = try a.matrix(1)
            guard xs.data.count == ps.data.count else { throw XLError.na }
            let lo = try a.num(2), hi = a.has(3) ? try a.num(3) : lo
            var total = 0.0, sum = 0.0
            for i in 0..<xs.data.count {
                guard case .number(let x) = xs.data[i], case .number(let p) = ps.data[i] else { continue }
                guard p >= 0, p <= 1 else { throw XLError.num }
                total += p
                if x >= lo && x <= hi { sum += p }
            }
            guard abs(total - 1) < 1e-7 else { throw XLError.num }
            return .number(sum)
        }
        r.num("STANDARDIZE", min: 3, max: 3) { s in
            let sd = try s.num(2)
            guard sd > 0 else { throw XLError.num }
            return (try s.num(0) - s.num(1)) / sd
        }
        r.num("FISHER", min: 1, max: 1) { s in
            let x = try s.num(0)
            guard abs(x) < 1 else { throw XLError.num }
            return 0.5 * log((1 + x) / (1 - x))
        }
        r.num("FISHERINV", min: 1, max: 1) { s in tanh(try s.num(0)) }

        // Correlation and regression
        r.raw("CORREL", "PEARSON", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            guard s.sxx > 0, s.syy > 0 else { throw XLError.div0 }
            return try X.check(s.sxy / (s.sxx * s.syy).squareRoot())
        }
        r.raw("RSQ", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            guard s.sxx > 0, s.syy > 0 else { throw XLError.div0 }
            return try X.check(s.sxy * s.sxy / (s.sxx * s.syy))
        }
        r.raw("SLOPE", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            guard s.sxx > 0 else { throw XLError.div0 }
            return try X.check(s.sxy / s.sxx)
        }
        r.raw("INTERCEPT", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            guard s.sxx > 0 else { throw XLError.div0 }
            return try X.check(s.my - s.sxy / s.sxx * s.mx)
        }
        r.raw("STEYX", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            guard s.n > 2, s.sxx > 0 else { throw XLError.div0 }
            return try X.check(((s.syy - s.sxy * s.sxy / s.sxx) / (s.n - 2)).squareRoot())
        }
        r.raw("COVAR", "COVARIANCE.P", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            return try X.check(s.sxy / s.n)
        }
        r.raw("COVARIANCE.S", min: 2, max: 2) { a in
            let (y, x) = try Paired.data(a, 0, 1)
            let s = try Paired.sums(y, x)
            guard s.n > 1 else { throw XLError.div0 }
            return try X.check(s.sxy / (s.n - 1))
        }
        r.raw("FORECAST", "FORECAST.LINEAR", min: 3, max: 3) { a in
            let (y, x) = try Paired.data(a, 1, 2)
            let s = try Paired.sums(y, x)
            guard s.sxx > 0 else { throw XLError.div0 }
            let b = s.sxy / s.sxx, c = s.my - b * s.mx
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { sc in
                try X.check(c + b * (try sc.num(0)))
            }
        }
        r.raw("LINEST", min: 1, max: 4) { a in try Regression.linest(a, log: false) }
        r.raw("LOGEST", min: 1, max: 4) { a in try Regression.linest(a, log: true) }
        r.raw("TREND", min: 1, max: 4) { a in try Regression.trend(a, log: false) }
        r.raw("GROWTH", min: 1, max: 4) { a in try Regression.trend(a, log: true) }

        r.raw("FORECAST.ETS", min: 3, max: 6) { a in try ETS.forecast(a) }
        r.raw("FORECAST.ETS.CONFINT", min: 3, max: 7) { a in try ETS.confint(a) }
        r.raw("FORECAST.ETS.SEASONALITY", min: 2, max: 4) { a in try ETS.seasonality(a) }
        r.raw("FORECAST.ETS.STAT", min: 3, max: 6) { a in try ETS.stat(a) }
    }
}

/// LINEST/LOGEST/TREND/GROWTH: multiple linear regression.
enum Regression {
    struct Fit {
        var coef: [Double]       // intercept first (0 when no constant), then one per x variable
        var x: [[Double]]
        var y: [Double]
        var const: Bool
    }

    /// Reads known_y / known_x into observation rows.
    static func data(_ a: Args, yi: Int, xi: Int, log useLog: Bool) throws -> (y: [Double], x: [[Double]], byRow: Bool, ym: Matrix) {
        let ym = try a.matrix(yi)
        var y = try ym.data.map { v -> Double in
            guard case .number(let d) = v else { throw XLError.value }
            return d
        }
        if useLog {
            guard y.allSatisfy({ $0 > 0 }) else { throw XLError.num }
            y = y.map { Foundation.log($0) }
        }
        let n = y.count
        var x: [[Double]]
        var byRow = false
        if a.has(xi) {
            let xm = try a.matrix(xi)
            let d = try xm.data.map { v -> Double in
                guard case .number(let v) = v else { throw XLError.value }
                return v
            }
            if xm.rows * xm.cols == n && (ym.rows == 1 || ym.cols == 1) && (xm.rows == 1 || xm.cols == 1) {
                x = d.map { [$0] }
            } else if ym.cols == 1 && xm.rows == n {
                x = (0..<n).map { r in (0..<xm.cols).map { d[r * xm.cols + $0] } }
            } else if ym.rows == 1 && xm.cols == n {
                byRow = true
                x = (0..<n).map { c in (0..<xm.rows).map { d[$0 * xm.cols + c] } }
            } else { throw XLError.ref }
        } else {
            x = (1...max(1, n)).map { [Double($0)] }
        }
        return (y, x, byRow, ym)
    }

    static func fit(_ y: [Double], _ x: [[Double]], const: Bool) throws -> [Double] {
        let design = x.map { (const ? [1.0] : []) + $0 }
        guard let c = LinearAlgebra.leastSquares(design, y) else { throw XLError.value }
        return const ? c : [0] + c
    }

    static func linest(_ a: Args, log useLog: Bool) throws -> SheetValue {
        let (y, x, _, _) = try data(a, yi: 0, xi: 1, log: useLog)
        let const = try a.bool(2, true), stats = try a.bool(3, false)
        let p = x.first?.count ?? 0, n = y.count
        let c = try fit(y, x, const: const)
        // Output order: m_p … m_1, b
        var row1: [Double] = c.dropFirst().reversed() + [c[0]]
        if useLog { row1 = row1.map { exp($0) } }
        guard stats else { return .array(.row(row1.map { .number($0) })) }
        let predicted = x.map { xi in c[0] + zip(xi, c.dropFirst()).reduce(0) { $0 + $1.0 * $1.1 } }
        let my = y.reduce(0, +) / Double(n)
        let ssresid = zip(y, predicted).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        let sstotal = const ? y.reduce(0) { $0 + ($1 - my) * ($1 - my) } : y.reduce(0) { $0 + $1 * $1 }
        let ssreg = sstotal - ssresid
        let df = n - p - (const ? 1 : 0)
        let r2 = sstotal == 0 ? 1 : ssreg / sstotal
        let sey = df > 0 ? (ssresid / Double(df)).squareRoot() : 0
        let f = df > 0 && ssresid > 0 ? (ssreg / Double(p)) / (ssresid / Double(df)) : .infinity
        // Standard errors from (X'X)^-1.
        let design = x.map { (const ? [1.0] : []) + $0 }
        let k = design[0].count
        var xtx = [Double](repeating: 0, count: k * k)
        for row in design { for i in 0..<k { for j in 0..<k { xtx[i * k + j] += row[i] * row[j] } } }
        let inv = LinearAlgebra.inverse(xtx, k) ?? [Double](repeating: 0, count: k * k)
        let se = (0..<k).map { (max(0, inv[$0 * k + $0]) * sey * sey).squareRoot() }
        let seCoef: [Double] = const ? Array(se.dropFirst()).reversed() + [se[0]] : se.reversed() + [0]
        let cols = p + 1
        var m = Matrix(rows: 5, cols: cols, fill: .error("#N/A"))
        for j in 0..<cols {
            m[0, j] = .number(row1[j])
            m[1, j] = const || j < p ? .number(seCoef[j]) : .error("#N/A")
        }
        m[2, 0] = .number(r2); m[2, 1 < cols ? 1 : 0] = .number(sey)
        m[3, 0] = f.isFinite ? .number(f) : .error("#NUM!"); if cols > 1 { m[3, 1] = .number(Double(df)) }
        m[4, 0] = .number(ssreg); if cols > 1 { m[4, 1] = .number(ssresid) }
        return .array(m)
    }

    static func trend(_ a: Args, log useLog: Bool) throws -> SheetValue {
        let (y, x, byRow, ym) = try data(a, yi: 0, xi: 1, log: useLog)
        let const = try a.bool(3, true)
        let c = try fit(y, x, const: const)
        let p = x.first?.count ?? 1
        var newX: [[Double]]
        var shape: (Int, Int)
        if a.has(2) {
            let nm = try a.matrix(2)
            let d = try nm.data.map { v -> Double in guard case .number(let v) = v else { throw XLError.value }; return v }
            if p == 1 { newX = d.map { [$0] }; shape = (nm.rows, nm.cols) }
            else if byRow { newX = (0..<nm.cols).map { c in (0..<nm.rows).map { d[$0 * nm.cols + c] } }; shape = (1, nm.cols) }
            else { newX = (0..<nm.rows).map { r in (0..<nm.cols).map { d[r * nm.cols + $0] } }; shape = (nm.rows, 1) }
        } else {
            newX = x; shape = (ym.rows, ym.cols)
        }
        let out = newX.map { xi -> SheetValue in
            let v = c[0] + zip(xi, c.dropFirst()).reduce(0) { $0 + $1.0 * $1.1 }
            return .number(useLog ? exp(v) : v)
        }
        var m = Matrix(rows: shape.0, cols: shape.1)
        m.data = out
        return .array(m)
    }
}

/// FORECAST.ETS family: additive (AAA) exponential triple smoothing with
/// parameters fitted by minimising one-step squared error.
enum ETS {
    struct Model {
        var alpha = 0.5, beta = 0.1, gamma = 0.1
        var period = 1
        var level = 0.0, trend = 0.0
        var season: [Double] = []
        var sse = 0.0, n = 0
        var residuals: [Double] = []
    }

    static func series(_ a: Args, valuesAt: Int, timelineAt: Int, aggregation: Int) throws -> (t: [Double], y: [Double]) {
        let vm = try a.matrix(valuesAt), tm = try a.matrix(timelineAt)
        guard vm.data.count == tm.data.count, vm.data.count >= 2 else { throw XLError.na }
        var pairs: [(Double, Double?)] = []
        for i in 0..<vm.data.count {
            guard case .number(let t) = tm.data[i] else { throw XLError.value }
            if case .number(let v) = vm.data[i] { pairs.append((t, v)) } else { pairs.append((t, nil)) }
        }
        pairs.sort { $0.0 < $1.0 }
        // Aggregate duplicate timestamps (default AVERAGE).
        var t: [Double] = [], y: [Double?] = []
        var i = 0
        while i < pairs.count {
            var j = i, group: [Double] = []
            while j < pairs.count && pairs[j].0 == pairs[i].0 { if let v = pairs[j].1 { group.append(v) }; j += 1 }
            t.append(pairs[i].0)
            if group.isEmpty { y.append(nil) } else {
                switch aggregation {
                case 2, 3: y.append(Double(group.count))
                case 4: y.append(group.max()!)
                case 5: y.append(try Stats.median(group))
                case 6: y.append(group.min()!)
                case 7: y.append(group.reduce(0, +))
                default: y.append(group.reduce(0, +) / Double(group.count))
                }
            }
            i = j
        }
        guard t.count >= 2 else { throw XLError.na }
        let step = t[1] - t[0]
        guard step > 0 else { throw XLError.num }
        for k in 1..<t.count where abs((t[k] - t[k - 1]) - step) > 1e-9 * max(1, step) { throw XLError.num }
        // Fill missing points by linear interpolation (completion default 1).
        var filled = y
        for k in 0..<filled.count where filled[k] == nil {
            let prev = (0..<k).last { filled[$0] != nil }, next = ((k + 1)..<filled.count).first { y[$0] != nil }
            if let p = prev, let q = next { filled[k] = filled[p]! + (y[q]! - filled[p]!) * Double(k - p) / Double(q - p) }
            else { filled[k] = prev.map { filled[$0]! } ?? next.map { y[$0]! } ?? 0 }
        }
        return (t, filled.map { $0! })
    }

    static func detectSeason(_ y: [Double]) -> Int {
        let n = y.count
        guard n >= 6 else { return 1 }
        let m = y.reduce(0, +) / Double(n)
        let d = y.map { $0 - m }
        let denom = d.reduce(0) { $0 + $1 * $1 }
        guard denom > 0 else { return 1 }
        var best = 1, bestR = 0.0
        for lag in 2...max(2, n / 2) {
            var s = 0.0
            for i in lag..<n { s += d[i] * d[i - lag] }
            let r = s / denom
            if r > bestR + 1e-9 { bestR = r; best = lag }
        }
        return bestR > 0.3 ? best : 1
    }

    static func run(_ y: [Double], _ period: Int, _ alpha: Double, _ beta: Double, _ gamma: Double) -> Model {
        var m = Model()
        m.alpha = alpha; m.beta = beta; m.gamma = gamma; m.period = period
        let p = max(1, period)
        let first = Array(y.prefix(p))
        m.level = first.reduce(0, +) / Double(first.count)
        if y.count >= 2 * p && p > 1 {
            m.trend = (y[p..<(2 * p)].reduce(0, +) - first.reduce(0, +)) / Double(p * p)
        } else if y.count >= 2 { m.trend = y[1] - y[0] }
        m.season = p > 1 ? first.map { $0 - m.level } : [0]
        for (i, v) in y.enumerated() {
            let s = m.season[i % p]
            let forecast = m.level + m.trend + (p > 1 ? s : 0)
            if i > 0 { let e = v - forecast; m.sse += e * e; m.residuals.append(e) }
            let prevLevel = m.level
            m.level = alpha * (v - (p > 1 ? s : 0)) + (1 - alpha) * (m.level + m.trend)
            m.trend = beta * (m.level - prevLevel) + (1 - beta) * m.trend
            if p > 1 { m.season[i % p] = gamma * (v - m.level) + (1 - gamma) * s }
        }
        m.n = y.count
        return m
    }

    static func best(_ y: [Double], _ period: Int) -> Model {
        var bestModel = run(y, period, 0.5, 0.1, 0.1)
        let grid = [0.001, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.999]
        for a in grid { for b in [0.001, 0.05, 0.1, 0.2, 0.3, 0.5] { for g in (period > 1 ? [0.001, 0.05, 0.1, 0.3, 0.5, 0.8] : [0.0]) {
            let m = run(y, period, a, b, g)
            if m.sse < bestModel.sse { bestModel = m }
        } } }
        return bestModel
    }

    static func model(_ a: Args, seasonalityAt: Int, aggregationAt: Int) throws -> (Model, [Double]) {
        let (t, y) = try series(a, valuesAt: 1, timelineAt: 2, aggregation: try a.int(aggregationAt, 1))
        var period = try a.int(seasonalityAt, 1)
        guard period >= 0, period <= 8760 else { throw XLError.num }
        if period == 1 { period = detectSeason(y) } else if period == 0 { period = 1 }
        return (best(y, period), t)
    }

    static func horizon(_ target: Double, _ t: [Double]) throws -> Double {
        let step = t[1] - t[0]
        let h = (target - t.last!) / step
        guard target >= t.first! else { throw XLError.num }
        return max(h, 0)
    }

    static func forecast(_ a: Args) throws -> SheetValue {
        let (m, t) = try model(a, seasonalityAt: 3, aggregationAt: 5)
        return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
            let h = try horizon(try s.num(0), t)
            let k = Int(ceil(h))
            let seasonal = m.period > 1 ? m.season[(m.n + max(k, 1) - 1) % m.period] : 0
            return try X.check(m.level + h * m.trend + seasonal)
        }
    }

    static func confint(_ a: Args) throws -> SheetValue {
        let (m, t) = try model(a, seasonalityAt: 4, aggregationAt: 6)
        let conf = try a.num(3, 0.95)
        guard conf > 0, conf < 1 else { throw XLError.num }
        let sigma = (m.sse / Double(max(1, m.residuals.count))).squareRoot()
        let z = Special.normInv(0.5 + conf / 2)
        return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
            let h = max(1, try horizon(try s.num(0), t))
            var v = 1.0
            var j = 1.0
            while j < h { v += pow(m.alpha * (1 + j * m.beta), 2); j += 1 }
            return try X.check(z * sigma * v.squareRoot())
        }
    }

    static func seasonality(_ a: Args) throws -> SheetValue {
        let (_, y) = try series(a, valuesAt: 0, timelineAt: 1, aggregation: try a.int(3, 1))
        return .number(Double(detectSeason(y) == 1 ? 0 : detectSeason(y)))
    }

    static func stat(_ a: Args) throws -> SheetValue {
        let (_, y) = try series(a, valuesAt: 0, timelineAt: 1, aggregation: try a.int(5, 1))
        var period = try a.int(3, 1)
        if period == 1 { period = detectSeason(y) } else if period == 0 { period = 1 }
        let m = best(y, period)
        return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(2))]), lifted: nil) { s in
            let res = m.residuals
            let n = Double(max(1, res.count))
            let mae = res.reduce(0) { $0 + abs($1) } / n
            let rmse = (m.sse / n).squareRoot()
            switch try s.int(0) {
            case 1: return .number(m.alpha)
            case 2: return .number(m.beta)
            case 3: return .number(m.gamma)
            case 4: // MASE
                var naive = 0.0
                for i in 1..<y.count { naive += abs(y[i] - y[i - 1]) }
                naive /= Double(max(1, y.count - 1))
                return naive == 0 ? .error("#DIV/0!") : .number(mae / naive)
            case 5: // SMAPE
                var sm = 0.0
                for (i, e) in res.enumerated() {
                    let actual = y[i + 1], fc = actual - e
                    let d = abs(actual) + abs(fc)
                    if d > 0 { sm += 2 * abs(e) / d }
                }
                return .number(sm / n)
            case 6: return .number(mae)
            case 7: return .number(rmse)
            case 8: return .number(Double(m.period > 1 ? m.period : 0))
            default: throw XLError.num
            }
        }
    }
}
