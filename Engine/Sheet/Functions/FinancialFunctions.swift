import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Time-value-of-money primitives (Excel sign conventions).
enum TVM {
    static func fv(_ r: Double, _ n: Double, _ pmt: Double, _ pv: Double, _ type: Double) -> Double {
        if r == 0 { return -(pv + pmt * n) }
        let f = pow(1 + r, n)
        return -(pv * f + pmt * (1 + r * type) * (f - 1) / r)
    }
    static func pv(_ r: Double, _ n: Double, _ pmt: Double, _ fv: Double, _ type: Double) -> Double {
        if r == 0 { return -(fv + pmt * n) }
        let f = pow(1 + r, n)
        return -(fv + pmt * (1 + r * type) * (f - 1) / r) / f
    }
    static func pmt(_ r: Double, _ n: Double, _ pv: Double, _ fv: Double, _ type: Double) -> Double {
        if r == 0 { return -(pv + fv) / n }
        let f = pow(1 + r, n)
        return -(r * (pv * f + fv)) / ((1 + r * type) * (f - 1))
    }
    static func ipmt(_ r: Double, _ per: Double, _ n: Double, _ pv: Double, _ fv: Double, _ type: Double) -> Double {
        let p = pmt(r, n, pv, fv, type)
        var i: Double
        if per == 1 { i = type == 1 ? 0 : -pv }
        else { i = type == 1 ? self.fv(r, per - 2, p, pv, 1) - p : self.fv(r, per - 1, p, pv, 0) }
        return i * r
    }

    /// Newton–Raphson with numeric derivative; nil when it fails to converge.
    static func solve(_ guess: Double, _ f: (Double) -> Double) -> Double? {
        var x = guess
        for _ in 0..<200 {
            let y = f(x)
            if !y.isFinite { return nil }
            if abs(y) < 1e-10 { return x }
            let h = max(1e-7, abs(x) * 1e-7)
            let d = (f(x + h) - f(x - h)) / (2 * h)
            if d == 0 || !d.isFinite { return nil }
            let nx = x - y / d
            if abs(nx - x) < 1e-12 { return nx }
            x = nx
        }
        return abs(f(x)) < 1e-6 ? x : nil
    }
}

/// Coupon schedule helpers for bond functions.
enum Coupon {
    static func validate(_ settle: Double, _ mat: Double, _ freq: Int, _ basis: Int) throws {
        guard [1, 2, 4].contains(freq), (0...4).contains(basis), settle < mat else { throw XLError.num }
    }

    /// Adds months keeping month-end alignment when the anchor is a month end.
    static func shift(_ anchor: Double, months: Int) -> Double {
        let (y, m, d) = DateSerial.ymd(anchor)
        let eom = d == DayCount.daysInMonth(y, m)
        let idx = y * 12 + (m - 1) + months
        let ny = idx / 12, nm = idx % 12 + 1
        let nd = eom ? DayCount.daysInMonth(ny, nm) : min(d, DayCount.daysInMonth(ny, nm))
        return DayCount.serial(ny, nm, nd)
    }

    static func pcd(_ settle: Double, _ mat: Double, _ freq: Int) -> Double {
        let step = 12 / freq
        var k = 0
        var d = mat
        while d > settle { k += 1; d = shift(mat, months: -k * step) }
        return d
    }
    static func ncd(_ settle: Double, _ mat: Double, _ freq: Int) -> Double {
        let step = 12 / freq
        var k = 0
        var d = mat
        while shift(mat, months: -(k + 1) * step) > settle { k += 1 }
        d = shift(mat, months: -k * step)
        return d
    }
    static func num(_ settle: Double, _ mat: Double, _ freq: Int) -> Double {
        let step = 12 / freq
        var k = 0
        while shift(mat, months: -(k + 1) * step) > settle { k += 1 }
        return Double(k + 1)
    }
    static func diff(_ a: Double, _ b: Double, _ basis: Int) -> Double {
        switch basis {
        case 0: return DayCount.days360(a, b, european: false)
        case 4: return DayCount.days360(a, b, european: true)
        default: return b - a
        }
    }
    static func days(_ settle: Double, _ mat: Double, _ freq: Int, _ basis: Int) -> Double {
        switch basis {
        case 1:
            let p = pcd(settle, mat, freq)
            return shift(p, months: 12 / freq) - p
        case 3: return 365 / Double(freq)
        default: return 360 / Double(freq)
        }
    }
    static func daybs(_ settle: Double, _ mat: Double, _ freq: Int, _ basis: Int) -> Double {
        diff(pcd(settle, mat, freq), settle, basis)
    }
    static func daysnc(_ settle: Double, _ mat: Double, _ freq: Int, _ basis: Int) -> Double {
        if basis != 0 && basis != 4 { return ncd(settle, mat, freq) - settle }
        return days(settle, mat, freq, basis) - daybs(settle, mat, freq, basis)
    }

    static func price(_ settle: Double, _ mat: Double, _ rate: Double, _ yld: Double, _ red: Double, _ freq: Int, _ basis: Int) -> Double {
        let f = Double(freq)
        let e = days(settle, mat, freq, basis), a = daybs(settle, mat, freq, basis)
        let dsc = daysnc(settle, mat, freq, basis), n = num(settle, mat, freq)
        let coupon = 100 * rate / f
        if n == 1 {
            return (red + coupon) / (1 + dsc / e * yld / f) - coupon * a / e
        }
        var p = red / pow(1 + yld / f, n - 1 + dsc / e)
        var k = 1.0
        while k <= n { p += coupon / pow(1 + yld / f, k - 1 + dsc / e); k += 1 }
        return p - coupon * a / e
    }

    /// Macaulay duration in years, measured in coupon periods from settlement.
    static func duration(_ settle: Double, _ mat: Double, _ coup: Double, _ yld: Double, _ freq: Int, _ basis: Int) throws -> Double {
        let f = Double(freq)
        let n = num(settle, mat, freq)
        let first = daysnc(settle, mat, freq, basis) / days(settle, mat, freq, basis)
        let c = coup * 100 / f, y = 1 + yld / f
        var weighted = 0.0, price = 0.0
        var k = 1.0
        while k <= n {
            let t = k - 1 + first
            let cf = c + (k == n ? 100 : 0)
            let pv = cf / pow(y, t)
            weighted += t * pv; price += pv
            k += 1
        }
        return weighted / price / f
    }
}

enum FinancialFunctions {
    static func date(_ s: Scalars, _ i: Int) throws -> Double {
        let d = try s.num(i)
        guard d >= 0, d < 2958466 else { throw XLError.num }
        return floor(d)
    }
    static func basis(_ s: Scalars, _ i: Int) throws -> Int {
        let b = try s.int(i, 0)
        guard (0...4).contains(b) else { throw XLError.num }
        return b
    }

    static func register(_ r: inout Registry) {
        r.num("PV", min: 3, max: 5) { s in TVM.pv(try s.num(0), try s.num(1), try s.num(2), try s.num(3, 0), try s.num(4, 0) != 0 ? 1 : 0) }
        r.num("FV", min: 3, max: 5) { s in TVM.fv(try s.num(0), try s.num(1), try s.num(2), try s.num(3, 0), try s.num(4, 0) != 0 ? 1 : 0) }
        r.num("PMT", min: 3, max: 5) { s in
            let n = try s.num(1)
            guard n != 0 else { throw XLError.num }
            return TVM.pmt(try s.num(0), n, try s.num(2), try s.num(3, 0), try s.num(4, 0) != 0 ? 1 : 0)
        }
        r.num("NPER", min: 3, max: 5) { s in
            let rate = try s.num(0), pmt = try s.num(1), pv = try s.num(2), fv = try s.num(3, 0), t = try s.num(4, 0) != 0 ? 1.0 : 0
            if rate == 0 {
                guard pmt != 0 else { throw XLError.num }
                return -(pv + fv) / pmt
            }
            let num = pmt * (1 + rate * t) - fv * rate, den = pmt * (1 + rate * t) + pv * rate
            guard num / den > 0 else { throw XLError.num }
            return log(num / den) / log(1 + rate)
        }
        r.num("RATE", min: 3, max: 6) { s in
            let n = try s.num(0), pmt = try s.num(1), pv = try s.num(2), fv = try s.num(3, 0)
            let t = try s.num(4, 0) != 0 ? 1.0 : 0, guess = try s.num(5, 0.1)
            guard n > 0 else { throw XLError.num }
            guard let r = TVM.solve(guess, { r in
                abs(r) < 1e-12 ? pv + pmt * n + fv : pv * pow(1 + r, n) + pmt * (1 + r * t) * (pow(1 + r, n) - 1) / r + fv
            }) else { throw XLError.num }
            return r
        }
        r.num("IPMT", min: 4, max: 6) { s in
            let rate = try s.num(0), per = try s.num(1), n = try s.num(2)
            guard per >= 1, per <= n else { throw XLError.num }
            return TVM.ipmt(rate, per, n, try s.num(3), try s.num(4, 0), try s.num(5, 0) != 0 ? 1 : 0)
        }
        r.num("PPMT", min: 4, max: 6) { s in
            let rate = try s.num(0), per = try s.num(1), n = try s.num(2), pv = try s.num(3), fv = try s.num(4, 0)
            let t = try s.num(5, 0) != 0 ? 1.0 : 0
            guard per >= 1, per <= n else { throw XLError.num }
            return TVM.pmt(rate, n, pv, fv, t) - TVM.ipmt(rate, per, n, pv, fv, t)
        }
        func cumulative(_ s: Scalars, principal: Bool) throws -> Double {
            let rate = try s.num(0), n = try s.num(1), pv = try s.num(2)
            let start = try s.num(3).rounded(.up), end = try s.num(4).rounded(.down), t = try s.num(5)
            guard rate > 0, n > 0, pv > 0, start >= 1, end >= start, end <= n, t == 0 || t == 1 else { throw XLError.num }
            let p = TVM.pmt(rate, n, pv, 0, t)
            var total = 0.0
            var k = start
            while k <= end {
                let i = TVM.ipmt(rate, k, n, pv, 0, t)
                total += principal ? p - i : i
                k += 1
            }
            return total
        }
        r.num("CUMIPMT", min: 6, max: 6) { try cumulative($0, principal: false) }
        r.num("CUMPRINC", min: 6, max: 6) { try cumulative($0, principal: true) }
        r.num("ISPMT", min: 4, max: 4) { s in
            let n = try s.num(2)
            guard n != 0 else { throw XLError.div0 }
            return try s.num(3) * s.num(0) * (try s.num(1) / n - 1)
        }
        r.raw("NPV", min: 2) { a in
            let rate = try a.num(0)
            guard rate != -1 else { throw XLError.div0 }
            let v = try a.numbers(from: 1)
            return try X.check(v.enumerated().reduce(0) { $0 + $1.element / pow(1 + rate, Double($1.offset + 1)) })
        }
        r.raw("IRR", min: 1, max: 2) { a in
            let v = try Aggregates.numbers(a.grid(0).data)
            guard v.contains(where: { $0 > 0 }), v.contains(where: { $0 < 0 }) else { throw XLError.num }
            let guess = try a.num(1, 0.1)
            guard let r = TVM.solve(guess, { r in v.enumerated().reduce(0) { $0 + $1.element / pow(1 + r, Double($1.offset)) } }) else { throw XLError.num }
            return .number(r)
        }
        r.raw("XNPV", min: 3, max: 3) { a in
            let rate = try a.num(0)
            let (v, d) = try dated(a, valuesAt: 1, datesAt: 2)
            guard rate > -1 else { throw XLError.num }
            return try X.check(zip(v, d).reduce(0) { $0 + $1.0 / pow(1 + rate, ($1.1 - d[0]) / 365) })
        }
        r.raw("XIRR", min: 2, max: 3) { a in
            let (v, d) = try dated(a, valuesAt: 0, datesAt: 1)
            guard v.contains(where: { $0 > 0 }), v.contains(where: { $0 < 0 }) else { throw XLError.num }
            let guess = try a.num(2, 0.1)
            let f = { (r: Double) in zip(v, d).reduce(0) { $0 + $1.0 / pow(1 + r, ($1.1 - d[0]) / 365) } }
            guard let r = TVM.solve(guess, f) ?? TVM.solve(-0.5, f) ?? TVM.solve(1, f), r > -1 else { throw XLError.num }
            return .number(r)
        }
        r.raw("MIRR", min: 3, max: 3) { a in
            let v = try Aggregates.numbers(a.grid(0).data)
            let fr = try a.num(1), rr = try a.num(2)
            let n = Double(v.count)
            var pos = 0.0, neg = 0.0
            for (i, x) in v.enumerated() {
                if x > 0 { pos += x * pow(1 + rr, n - Double(i) - 1) } else { neg += x / pow(1 + fr, Double(i)) }
            }
            guard neg != 0, pos != 0 else { throw XLError.div0 }
            return try X.check(pow(-pos / neg, 1 / (n - 1)) - 1)
        }
        r.num("EFFECT", min: 2, max: 2) { s in
            let nom = try s.num(0), p = try s.num(1).rounded(.towardZero)
            guard nom > 0, p >= 1 else { throw XLError.num }
            return pow(1 + nom / p, p) - 1
        }
        r.num("NOMINAL", min: 2, max: 2) { s in
            let eff = try s.num(0), p = try s.num(1).rounded(.towardZero)
            guard eff > 0, p >= 1 else { throw XLError.num }
            return (pow(eff + 1, 1 / p) - 1) * p
        }
        r.raw("FVSCHEDULE", min: 2, max: 2) { a in
            var p = try a.num(0)
            for v in a.grid(1).data {
                switch v {
                case .number(let d): p *= 1 + d
                case .empty: break
                case .error(let e): throw XLError(e)
                default: throw XLError.value
                }
            }
            return try X.check(p)
        }
        r.num("PDURATION", min: 3, max: 3) { s in
            let rate = try s.num(0), pv = try s.num(1), fv = try s.num(2)
            guard rate > 0, pv > 0, fv > 0 else { throw XLError.num }
            return (log(fv) - log(pv)) / log(1 + rate)
        }
        r.num("RRI", min: 3, max: 3) { s in
            let n = try s.num(0), pv = try s.num(1), fv = try s.num(2)
            guard n > 0, pv != 0 else { throw XLError.num }
            return pow(fv / pv, 1 / n) - 1
        }

        // Depreciation
        r.num("SLN", min: 3, max: 3) { s in
            let life = try s.num(2)
            guard life != 0 else { throw XLError.div0 }
            return (try s.num(0) - s.num(1)) / life
        }
        r.num("SYD", min: 4, max: 4) { s in
            let cost = try s.num(0), salvage = try s.num(1), life = try s.num(2), per = try s.num(3)
            guard life > 0, per > 0, per <= life else { throw XLError.num }
            return (cost - salvage) * (life - per + 1) * 2 / (life * (life + 1))
        }
        r.num("DDB", min: 4, max: 5) { s in
            let cost = try s.num(0), salvage = try s.num(1), life = try s.num(2), per = try s.num(3), factor = try s.num(4, 2)
            guard cost >= 0, salvage >= 0, life > 0, per > 0, per <= life, factor > 0 else { throw XLError.num }
            return Depreciation.ddb(cost, salvage, life, per, factor)
        }
        r.num("DB", min: 4, max: 5) { s in
            let cost = try s.num(0), salvage = try s.num(1), life = try s.num(2), per = try s.num(3).rounded(.towardZero)
            let month = try s.num(4, 12).rounded(.towardZero)
            guard cost >= 0, salvage >= 0, life > 0, per >= 1, month >= 1, month <= 12, per <= life + (month < 12 ? 1 : 0) else { throw XLError.num }
            if cost == 0 { return 0 }
            let rate = Num.round(1 - pow(salvage / cost, 1 / life), 3)
            var total = 0.0, dep = 0.0
            var p = 1.0
            while p <= per {
                if p == 1 { dep = cost * rate * month / 12 }
                else if p == floor(life) + 1 { dep = (cost - total) * rate * (12 - month) / 12 }
                else { dep = (cost - total) * rate }
                total += dep
                p += 1
            }
            return dep
        }
        r.num("VDB", min: 5, max: 7) { s in
            let cost = try s.num(0), salvage = try s.num(1), life = try s.num(2)
            let start = try s.num(3), end = try s.num(4), factor = try s.num(5, 2), noSwitch = try s.bool(6, false)
            guard start >= 0, end >= start, end <= life, cost >= 0, salvage <= cost, factor > 0, life > 0 else { throw XLError.num }
            return Depreciation.vdb(cost, salvage, life, start, end, factor, noSwitch)
        }
        r.num("AMORLINC", min: 6, max: 7) { s in
            let cost = try s.num(0), purchased = try date(s, 1), first = try date(s, 2), salvage = try s.num(3)
            let per = try s.num(4), rate = try s.num(5), b = try basis(s, 6)
            guard cost > 0, salvage >= 0, salvage <= cost, rate > 0, per >= 0, b != 2, purchased <= first else { throw XLError.num }
            return Depreciation.amorlinc(cost, purchased, first, salvage, per, rate, b)
        }
        r.num("AMORDEGRC", min: 6, max: 7) { s in
            let cost = try s.num(0), purchased = try date(s, 1), first = try date(s, 2), salvage = try s.num(3)
            let per = try s.num(4), rate = try s.num(5), b = try basis(s, 6)
            guard cost > 0, salvage >= 0, salvage <= cost, rate > 0, per >= 0, b != 2, purchased <= first else { throw XLError.num }
            return try Depreciation.amordegrc(cost, purchased, first, salvage, per, rate, b)
        }

        // Discount securities
        func yf(_ s: Scalars, _ a: Int, _ b: Int, _ basisAt: Int) throws -> Double {
            let d1 = try date(s, a), d2 = try date(s, b), bs = try basis(s, basisAt)
            guard d1 < d2 else { throw XLError.num }
            return try DayCount.yearFrac(d1, d2, bs)
        }
        r.num("DISC", min: 4, max: 5) { s in
            let pr = try s.num(2), red = try s.num(3)
            guard pr > 0, red > 0 else { throw XLError.num }
            return (red - pr) / red / (try yf(s, 0, 1, 4))
        }
        r.num("INTRATE", min: 4, max: 5) { s in
            let inv = try s.num(2), red = try s.num(3)
            guard inv > 0, red > 0 else { throw XLError.num }
            return (red - inv) / inv / (try yf(s, 0, 1, 4))
        }
        r.num("RECEIVED", min: 4, max: 5) { s in
            let inv = try s.num(2), disc = try s.num(3)
            guard inv > 0, disc > 0 else { throw XLError.num }
            let d = 1 - disc * (try yf(s, 0, 1, 4))
            guard d > 0 else { throw XLError.num }
            return inv / d
        }
        r.num("PRICEDISC", min: 4, max: 5) { s in
            let disc = try s.num(2), red = try s.num(3)
            guard disc > 0, red > 0 else { throw XLError.num }
            return red * (1 - disc * (try yf(s, 0, 1, 4)))
        }
        r.num("YIELDDISC", min: 4, max: 5) { s in
            let pr = try s.num(2), red = try s.num(3)
            guard pr > 0, red > 0 else { throw XLError.num }
            return (red / pr - 1) / (try yf(s, 0, 1, 4))
        }
        r.num("PRICEMAT", min: 5, max: 6) { s in
            let settle = try date(s, 0), mat = try date(s, 1), issue = try date(s, 2), rate = try s.num(3), yld = try s.num(4), b = try basis(s, 5)
            guard settle < mat, rate >= 0, yld >= 0 else { throw XLError.num }
            let im = try DayCount.yearFrac(issue, mat, b), iS = try DayCount.yearFrac(issue, settle, b), sm = try DayCount.yearFrac(settle, mat, b)
            return ((1 + im * rate) / (1 + sm * yld) - iS * rate) * 100
        }
        r.num("YIELDMAT", min: 5, max: 6) { s in
            let settle = try date(s, 0), mat = try date(s, 1), issue = try date(s, 2), rate = try s.num(3), pr = try s.num(4), b = try basis(s, 5)
            guard settle < mat, rate >= 0, pr > 0 else { throw XLError.num }
            let im = try DayCount.yearFrac(issue, mat, b), iS = try DayCount.yearFrac(issue, settle, b), sm = try DayCount.yearFrac(settle, mat, b)
            return ((1 + im * rate) / (pr / 100 + iS * rate) - 1) / sm
        }
        func dsm(_ s: Scalars) throws -> Double {
            let settle = try date(s, 0), mat = try date(s, 1)
            guard settle < mat, mat - settle <= 365 || DayCount.addMonths(settle, 12).map({ mat <= $0 }) == true else { throw XLError.num }
            return mat - settle
        }
        r.num("TBILLPRICE", min: 3, max: 3) { s in
            let d = try dsm(s), disc = try s.num(2)
            guard disc > 0 else { throw XLError.num }
            let p = 100 * (1 - disc * d / 360)
            guard p > 0 else { throw XLError.num }
            return p
        }
        r.num("TBILLYIELD", min: 3, max: 3) { s in
            let d = try dsm(s), pr = try s.num(2)
            guard pr > 0 else { throw XLError.num }
            return (100 - pr) / pr * 360 / d
        }
        r.num("TBILLEQ", min: 3, max: 3) { s in
            let d = try dsm(s), disc = try s.num(2)
            guard disc > 0 else { throw XLError.num }
            if d <= 182 { return 365 * disc / (360 - disc * d) }
            let price = 100 * (1 - disc * d / 360)
            let t = d / 365
            return (-2 * t + 2 * (t * t - (2 * t - 1) * (1 - 100 / price)).squareRoot()) / (2 * t - 1)
        }
        r.num("DOLLARDE", min: 2, max: 2) { s in
            let v = try s.num(0), f = try s.num(1).rounded(.towardZero)
            guard f >= 0 else { throw XLError.num }
            guard f != 0 else { throw XLError.div0 }
            let ip = v.rounded(.towardZero)
            return ip + (v - ip) * pow(10, ceil(log10(f))) / f
        }
        r.num("DOLLARFR", min: 2, max: 2) { s in
            let v = try s.num(0), f = try s.num(1).rounded(.towardZero)
            guard f >= 0 else { throw XLError.num }
            guard f != 0 else { throw XLError.div0 }
            let ip = v.rounded(.towardZero)
            return ip + (v - ip) * f / pow(10, ceil(log10(f)))
        }

        // Coupon bonds
        func bond(_ s: Scalars, freqAt: Int, basisAt: Int) throws -> (Double, Double, Int, Int) {
            let settle = try date(s, 0), mat = try date(s, 1), f = try s.int(freqAt), b = try basis(s, basisAt)
            try Coupon.validate(settle, mat, f, b)
            return (settle, mat, f, b)
        }
        r.num("COUPPCD", min: 3, max: 4) { s in let (a, m, f, _) = try bond(s, freqAt: 2, basisAt: 3); return Coupon.pcd(a, m, f) }
        r.num("COUPNCD", min: 3, max: 4) { s in let (a, m, f, _) = try bond(s, freqAt: 2, basisAt: 3); return Coupon.ncd(a, m, f) }
        r.num("COUPNUM", min: 3, max: 4) { s in let (a, m, f, _) = try bond(s, freqAt: 2, basisAt: 3); return Coupon.num(a, m, f) }
        r.num("COUPDAYS", min: 3, max: 4) { s in let (a, m, f, b) = try bond(s, freqAt: 2, basisAt: 3); return Coupon.days(a, m, f, b) }
        r.num("COUPDAYBS", min: 3, max: 4) { s in let (a, m, f, b) = try bond(s, freqAt: 2, basisAt: 3); return Coupon.daybs(a, m, f, b) }
        r.num("COUPDAYSNC", min: 3, max: 4) { s in let (a, m, f, b) = try bond(s, freqAt: 2, basisAt: 3); return Coupon.daysnc(a, m, f, b) }
        r.num("PRICE", min: 6, max: 7) { s in
            let (a, m, f, b) = try bond(s, freqAt: 5, basisAt: 6)
            let rate = try s.num(2), yld = try s.num(3), red = try s.num(4)
            guard rate >= 0, yld >= 0, red > 0 else { throw XLError.num }
            return Coupon.price(a, m, rate, yld, red, f, b)
        }
        r.num("YIELD", min: 6, max: 7) { s in
            let (a, m, f, b) = try bond(s, freqAt: 5, basisAt: 6)
            let rate = try s.num(2), pr = try s.num(3), red = try s.num(4)
            guard rate >= 0, pr > 0, red > 0 else { throw XLError.num }
            let n = Coupon.num(a, m, f)
            let ff = Double(f)
            if n <= 1 {
                let e = Coupon.days(a, m, f, b), aa = Coupon.daybs(a, m, f, b), dsr = e - aa
                let num = (red / 100 + rate / ff) - (pr / 100 + aa / e * rate / ff)
                let den = pr / 100 + aa / e * rate / ff
                return num / den * ff * e / dsr
            }
            guard let y = TVM.solve(rate == 0 ? 0.05 : rate, { Coupon.price(a, m, rate, $0, red, f, b) - pr }) else { throw XLError.num }
            return y
        }
        r.num("DURATION", min: 5, max: 6) { s in
            let (a, m, f, b) = try bond(s, freqAt: 4, basisAt: 5)
            let c = try s.num(2), y = try s.num(3)
            guard c >= 0, y >= 0 else { throw XLError.num }
            return try Coupon.duration(a, m, c, y, f, b)
        }
        r.num("MDURATION", min: 5, max: 6) { s in
            let (a, m, f, b) = try bond(s, freqAt: 4, basisAt: 5)
            let c = try s.num(2), y = try s.num(3)
            guard c >= 0, y >= 0 else { throw XLError.num }
            return try Coupon.duration(a, m, c, y, f, b) / (1 + y / Double(f))
        }
        r.num("ACCRINT", min: 6, max: 8) { s in
            let issue = try date(s, 0), settle = try date(s, 2), rate = try s.num(3), par = try s.num(4, 1000)
            let f = try s.int(5), b = try basis(s, 6)
            guard rate > 0, par > 0, [1, 2, 4].contains(f), issue < settle else { throw XLError.num }
            return par * rate * (try DayCount.yearFrac(issue, settle, b))
        }
        r.num("ACCRINTM", min: 3, max: 5) { s in
            let issue = try date(s, 0), settle = try date(s, 1), rate = try s.num(2), par = try s.num(3, 1000), b = try basis(s, 4)
            guard rate > 0, par > 0, issue < settle else { throw XLError.num }
            return par * rate * (try DayCount.yearFrac(issue, settle, b))
        }
        r.num("ODDLPRICE", min: 7, max: 8) { s in
            let settle = try date(s, 0), mat = try date(s, 1), last = try date(s, 2)
            let rate = try s.num(3), yld = try s.num(4), red = try s.num(5), f = Double(try s.int(6)), b = try basis(s, 7)
            guard [1.0, 2, 4].contains(f), rate >= 0, yld >= 0, red > 0, last < settle, settle < mat else { throw XLError.num }
            let dci = try DayCount.yearFrac(last, mat, b) * f, dsci = try DayCount.yearFrac(settle, mat, b) * f
            let ai = try DayCount.yearFrac(last, settle, b) * f
            return (red + dci * 100 * rate / f) / (dsci * yld / f + 1) - ai * 100 * rate / f
        }
        r.num("ODDLYIELD", min: 7, max: 8) { s in
            let settle = try date(s, 0), mat = try date(s, 1), last = try date(s, 2)
            let rate = try s.num(3), pr = try s.num(4), red = try s.num(5), f = Double(try s.int(6)), b = try basis(s, 7)
            guard [1.0, 2, 4].contains(f), rate >= 0, pr > 0, red > 0, last < settle, settle < mat else { throw XLError.num }
            let dci = try DayCount.yearFrac(last, mat, b) * f, dsci = try DayCount.yearFrac(settle, mat, b) * f
            let ai = try DayCount.yearFrac(last, settle, b) * f
            return ((red + dci * 100 * rate / f) / (pr + ai * 100 * rate / f) - 1) * f / dsci
        }
        func oddfPrice(_ settle: Double, _ mat: Double, _ issue: Double, _ first: Double, _ rate: Double, _ yld: Double,
                       _ red: Double, _ freq: Int, _ b: Int) -> Double {
            let f = Double(freq)
            let prev = Coupon.shift(first, months: -12 / freq)
            let e = b == 1 ? first - prev : (b == 3 ? 365 / f : 360 / f)
            let dfc = Coupon.diff(issue, first, b), a = Coupon.diff(issue, settle, b), dsc = Coupon.diff(settle, first, b)
            let n = Coupon.num(first, mat, freq) + 1
            let coupon = 100 * rate / f
            var p = red / pow(1 + yld / f, n - 1 + dsc / e)
            p += coupon * dfc / e / pow(1 + yld / f, dsc / e)
            var k = 2.0
            while k <= n { p += coupon / pow(1 + yld / f, k - 1 + dsc / e); k += 1 }
            return p - coupon * a / e
        }
        r.num("ODDFPRICE", min: 8, max: 9) { s in
            let settle = try date(s, 0), mat = try date(s, 1), issue = try date(s, 2), first = try date(s, 3)
            let rate = try s.num(4), yld = try s.num(5), red = try s.num(6), f = try s.int(7), b = try basis(s, 8)
            guard [1, 2, 4].contains(f), rate >= 0, yld >= 0, red > 0, issue < settle, settle < first, first < mat else { throw XLError.num }
            return oddfPrice(settle, mat, issue, first, rate, yld, red, f, b)
        }
        r.num("ODDFYIELD", min: 8, max: 9) { s in
            let settle = try date(s, 0), mat = try date(s, 1), issue = try date(s, 2), first = try date(s, 3)
            let rate = try s.num(4), pr = try s.num(5), red = try s.num(6), f = try s.int(7), b = try basis(s, 8)
            guard [1, 2, 4].contains(f), rate >= 0, pr > 0, red > 0, issue < settle, settle < first, first < mat else { throw XLError.num }
            guard let y = TVM.solve(max(rate, 0.05), { oddfPrice(settle, mat, issue, first, rate, $0, red, f, b) - pr }) else { throw XLError.num }
            return y
        }

        r.raw("STOCKHISTORY", min: 2) { _ in throw XLError.connect }
    }

    static func dated(_ a: Args, valuesAt: Int, datesAt: Int) throws -> ([Double], [Double]) {
        let vm = try a.matrix(valuesAt), dm = try a.matrix(datesAt)
        guard vm.data.count == dm.data.count, !vm.data.isEmpty else { throw XLError.num }
        let v = try vm.data.map { x -> Double in guard case .number(let d) = x else { throw XLError.value }; return d }
        let d = try dm.data.map { x -> Double in guard case .number(let d) = x else { throw XLError.value }; return floor(d) }
        guard d.allSatisfy({ $0 >= d[0] }) else { throw XLError.num }
        return (v, d)
    }
}

enum Depreciation {
    static func ddb(_ cost: Double, _ salvage: Double, _ life: Double, _ period: Double, _ factor: Double) -> Double {
        var rate = factor / life
        var old: Double
        if rate >= 1 { rate = 1; old = period == 1 ? cost : 0 }
        else { old = cost * pow(1 - rate, period - 1) }
        let new = cost * pow(1 - rate, period)
        let d = new < salvage ? old - salvage : old - new
        return max(d, 0)
    }

    static func interVDB(_ cost: Double, _ salvage: Double, _ life: Double, _ life1: Double, _ period: Double, _ factor: Double) -> Double {
        var vdb = 0.0
        let intEnd = ceil(Num.approxInt(period))
        let loopEnd = Int(intEnd)
        var sln = 0.0, salvageValue = cost - salvage, nowSln = false
        if loopEnd < 1 { return 0 }
        for i in 1...loopEnd {
            var term: Double
            if !nowSln {
                let d = ddb(cost, salvage, life, Double(i), factor)
                sln = salvageValue / (life1 - Double(i - 1))
                if sln > d { term = sln; nowSln = true } else { term = d; salvageValue -= d }
            } else { term = sln }
            if i == loopEnd { term *= period + 1 - intEnd }
            vdb += term
        }
        return vdb
    }

    static func vdb(_ costIn: Double, _ salvage: Double, _ life: Double, _ start: Double, _ end: Double, _ factor: Double, _ noSwitch: Bool) -> Double {
        var cost = costIn
        let intStart = floor(Num.approxInt(start)), intEnd = ceil(Num.approxInt(end))
        if noSwitch {
            var v = 0.0
            let ls = Int(intStart), le = Int(intEnd)
            if ls + 1 > le { return 0 }
            for i in (ls + 1)...le {
                var term = ddb(cost, salvage, life, Double(i), factor)
                if i == ls + 1 { term *= min(end, intStart + 1) - start }
                else if i == le { term *= end + 1 - intEnd }
                v += term
            }
            return v
        }
        var part = 0.0
        if start != intStart {
            let tv = cost - interVDB(cost, salvage, life, life, intStart, factor)
            part += (start - intStart) * interVDB(tv, salvage, life, life - intStart, 1, factor)
        }
        if end != intEnd {
            let ts = intEnd - 1
            let tv = cost - interVDB(cost, salvage, life, life, ts, factor)
            part += (intEnd - end) * interVDB(tv, salvage, life, life - ts, intEnd - ts, factor)
        }
        cost -= interVDB(cost, salvage, life, life, intStart, factor)
        return interVDB(cost, salvage, life, life - intStart, intEnd - intStart, factor) - part
    }

    static func amorlinc(_ cost: Double, _ date: Double, _ first: Double, _ rest: Double, _ per: Double, _ rate: Double, _ basis: Int) -> Double {
        let n = Int(per)
        let one = cost * rate
        let delta = cost - rest
        let r0 = ((try? DayCount.yearFrac(date, first, basis)) ?? 0) * rate * cost
        let full = Int((cost - rest - r0) / one)
        var result = 0.0
        if n == 0 { result = r0 }
        else if n <= full { result = one }
        else if n == full + 1 { result = delta - one * Double(full) - r0 }
        return max(result, 0)
    }

    static func amordegrc(_ costIn: Double, _ date: Double, _ first: Double, _ rest: Double, _ per: Double, _ rateIn: Double, _ basis: Int) throws -> Double {
        let n = Int(per)
        let usePer = 1 / rateIn
        let coeff: Double = usePer < 3 ? 1 : usePer < 5 ? 1.5 : usePer <= 6 ? 2 : 2.5
        let rate = rateIn * coeff
        var cost = costIn
        var nRate = (try DayCount.yearFrac(date, first, basis) * rate * cost).rounded()
        cost -= nRate
        var restV = cost - rest
        for i in 0..<n {
            nRate = (rate * cost).rounded()
            restV -= nRate
            if restV < 0 {
                switch n - i {
                case 0, 1: return (cost * 0.5).rounded()
                default: return 0
                }
            }
            cost -= nRate
        }
        return nRate
    }
}
