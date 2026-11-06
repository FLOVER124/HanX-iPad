import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum DistributionFunctions {
    static func register(_ r: inout Registry) {
        // Normal family
        func normDist(_ s: Scalars) throws -> Double {
            let x = try s.num(0), m = try s.num(1), sd = try s.num(2), cum = try s.bool(3)
            guard sd > 0 else { throw XLError.num }
            let z = (x - m) / sd
            return cum ? Special.normCDF(z) : Special.normPDF(z) / sd
        }
        r.num("NORM.DIST", "NORMDIST", min: 4, max: 4, normDist)
        r.num("NORM.INV", "NORMINV", min: 3, max: 3) { s in
            let p = try s.num(0), m = try s.num(1), sd = try s.num(2)
            guard p > 0, p < 1, sd > 0 else { throw XLError.num }
            return m + sd * Special.normInv(p)
        }
        r.num("NORM.S.DIST", min: 2, max: 2) { s in
            let z = try s.num(0)
            return try s.bool(1) ? Special.normCDF(z) : Special.normPDF(z)
        }
        r.num("NORMSDIST", min: 1, max: 1) { Special.normCDF(try $0.num(0)) }
        r.num("NORM.S.INV", "NORMSINV", min: 1, max: 1) { s in
            let p = try s.num(0)
            guard p > 0, p < 1 else { throw XLError.num }
            return Special.normInv(p)
        }
        r.num("GAUSS", min: 1, max: 1) { Special.normCDF(try $0.num(0)) - 0.5 }
        r.num("PHI", min: 1, max: 1) { Special.normPDF(try $0.num(0)) }
        r.num("LOGNORM.DIST", min: 4, max: 4) { s in
            let x = try s.num(0), m = try s.num(1), sd = try s.num(2), cum = try s.bool(3)
            guard x > 0, sd > 0 else { throw XLError.num }
            let z = (log(x) - m) / sd
            return cum ? Special.normCDF(z) : Special.normPDF(z) / (x * sd)
        }
        r.num("LOGNORMDIST", min: 3, max: 3) { s in
            let x = try s.num(0), m = try s.num(1), sd = try s.num(2)
            guard x > 0, sd > 0 else { throw XLError.num }
            return Special.normCDF((log(x) - m) / sd)
        }
        r.num("LOGNORM.INV", "LOGINV", min: 3, max: 3) { s in
            let p = try s.num(0), m = try s.num(1), sd = try s.num(2)
            guard p > 0, p < 1, sd > 0 else { throw XLError.num }
            return exp(m + sd * Special.normInv(p))
        }
        r.num("CONFIDENCE", "CONFIDENCE.NORM", min: 3, max: 3) { s in
            let alpha = try s.num(0), sd = try s.num(1), n = try s.num(2).rounded(.towardZero)
            guard alpha > 0, alpha < 1, sd > 0, n >= 1 else { throw XLError.num }
            return Special.normInv(1 - alpha / 2) * sd / n.squareRoot()
        }
        r.num("CONFIDENCE.T", min: 3, max: 3) { s in
            let alpha = try s.num(0), sd = try s.num(1), n = try s.num(2).rounded(.towardZero)
            guard alpha > 0, alpha < 1, sd > 0, n >= 1 else { throw XLError.num }
            guard n > 1 else { throw XLError.div0 }
            return Special.tInv(1 - alpha / 2, n - 1) * sd / n.squareRoot()
        }
        r.raw("Z.TEST", "ZTEST", min: 2, max: 3) { a in
            let x = try a.numbers(from: 0, to: 1)
            guard !x.isEmpty else { throw XLError.na }
            let mu = try a.num(1)
            let sigma = a.has(2) ? try a.num(2) : try Stats.varS(x).squareRoot()
            guard sigma > 0 else { throw XLError.div0 }
            let z = (try Stats.mean(x) - mu) / (sigma / Double(x.count).squareRoot())
            return try X.check(1 - Special.normCDF(z))
        }

        // Discrete
        func binom(_ s: Scalars) throws -> Double {
            let k = try s.num(0).rounded(.towardZero), n = try s.num(1).rounded(.towardZero), p = try s.num(2)
            let cum = try s.bool(3)
            guard k >= 0, k <= n, p >= 0, p <= 1 else { throw XLError.num }
            if !cum { return Special.binomPMF(k, n, p) }
            var t = 0.0
            var i = 0.0
            while i <= k { t += Special.binomPMF(i, n, p); i += 1 }
            return min(1, t)
        }
        r.num("BINOM.DIST", "BINOMDIST", min: 4, max: 4, binom)
        r.num("BINOM.DIST.RANGE", min: 3, max: 4) { s in
            let n = try s.num(0).rounded(.towardZero), p = try s.num(1)
            let lo = try s.num(2).rounded(.towardZero), hi = s.has(3) ? try s.num(3).rounded(.towardZero) : lo
            guard n >= 0, p >= 0, p <= 1, lo >= 0, lo <= n, hi >= lo, hi <= n else { throw XLError.num }
            var t = 0.0
            var i = lo
            while i <= hi { t += Special.binomPMF(i, n, p); i += 1 }
            return t
        }
        r.num("BINOM.INV", "CRITBINOM", min: 3, max: 3) { s in
            let n = try s.num(0).rounded(.towardZero), p = try s.num(1), alpha = try s.num(2)
            guard n >= 0, p >= 0, p <= 1, alpha > 0, alpha < 1 else { throw XLError.num }
            var c = 0.0, k = 0.0
            while k <= n {
                c += Special.binomPMF(k, n, p)
                if c >= alpha - 1e-15 { return k }
                k += 1
            }
            return n
        }
        r.num("NEGBINOM.DIST", min: 4, max: 4) { s in
            let f = try s.num(0).rounded(.towardZero), k = try s.num(1).rounded(.towardZero), p = try s.num(2)
            guard f >= 0, k >= 1, p >= 0, p <= 1 else { throw XLError.num }
            if try s.bool(3) { return Special.betaI(p, k, f + 1) }
            return exp(Special.lnC(f + k - 1, k - 1) + k * log(p) + f * log(1 - p))
        }
        r.num("NEGBINOMDIST", min: 3, max: 3) { s in
            let f = try s.num(0).rounded(.towardZero), k = try s.num(1).rounded(.towardZero), p = try s.num(2)
            guard f >= 0, k >= 1, p >= 0, p <= 1 else { throw XLError.num }
            return exp(Special.lnC(f + k - 1, k - 1) + k * log(p) + f * log(1 - p))
        }
        func hyp(_ s: Scalars, cum: Bool) throws -> Double {
            let k = try s.num(0).rounded(.towardZero), n = try s.num(1).rounded(.towardZero)
            let K = try s.num(2).rounded(.towardZero), N = try s.num(3).rounded(.towardZero)
            guard k >= 0, n >= 0, K >= 0, N >= 0, n <= N, K <= N, k <= n, k <= K, k >= max(0, n - N + K) else { throw XLError.num }
            if !cum { return Special.hypgeomPMF(k, n, K, N) }
            var t = 0.0
            var i = max(0, n - N + K)
            while i <= k { t += Special.hypgeomPMF(i, n, K, N); i += 1 }
            return min(1, t)
        }
        r.num("HYPGEOM.DIST", min: 5, max: 5) { s in try hyp(s, cum: try s.bool(4)) }
        r.num("HYPGEOMDIST", min: 4, max: 4) { s in try hyp(s, cum: false) }
        r.num("POISSON.DIST", "POISSON", min: 3, max: 3) { s in
            let k = try s.num(0).rounded(.towardZero), m = try s.num(1)
            guard k >= 0, m >= 0 else { throw XLError.num }
            return try s.bool(2) ? Special.gammaQ(k + 1, m) : Special.poissonPMF(k, m)
        }

        // Continuous
        r.num("EXPON.DIST", "EXPONDIST", min: 3, max: 3) { s in
            let x = try s.num(0), l = try s.num(1)
            guard x >= 0, l > 0 else { throw XLError.num }
            return try s.bool(2) ? 1 - exp(-l * x) : l * exp(-l * x)
        }
        r.num("WEIBULL", "WEIBULL.DIST", min: 4, max: 4) { s in
            let x = try s.num(0), a = try s.num(1), b = try s.num(2)
            guard x >= 0, a > 0, b > 0 else { throw XLError.num }
            return try s.bool(3) ? 1 - exp(-pow(x / b, a)) : a / pow(b, a) * pow(x, a - 1) * exp(-pow(x / b, a))
        }
        r.num("GAMMA.DIST", "GAMMADIST", min: 4, max: 4) { s in
            let x = try s.num(0), a = try s.num(1), b = try s.num(2)
            guard x >= 0, a > 0, b > 0 else { throw XLError.num }
            return try s.bool(3) ? Special.gammaCDF(x, a, b) : Special.gammaPDF(x, a, b)
        }
        r.num("GAMMA.INV", "GAMMAINV", min: 3, max: 3) { s in
            let p = try s.num(0), a = try s.num(1), b = try s.num(2)
            guard p >= 0, p < 1, a > 0, b > 0 else { throw XLError.num }
            if p == 0 { return 0 }
            return Special.invert({ Special.gammaCDF($0, a, b) }, p, lo: 0, hi: max(1, a * b * 4))
        }
        r.num("GAMMA", min: 1, max: 1) { s in
            let x = try s.num(0)
            guard !(x <= 0 && x == x.rounded()) else { throw XLError.num }
            return Special.gamma(x)
        }
        r.num("GAMMALN", "GAMMALN.PRECISE", min: 1, max: 1) { s in
            let x = try s.num(0)
            guard x > 0 else { throw XLError.num }
            return Special.lnGamma(x)
        }
        r.num("BETA.DIST", min: 4, max: 6) { s in
            let x = try s.num(0), a = try s.num(1), b = try s.num(2), cum = try s.bool(3)
            let lo = try s.num(4, 0), hi = try s.num(5, 1)
            guard a > 0, b > 0, lo < hi, x >= lo, x <= hi else { throw XLError.num }
            let t = (x - lo) / (hi - lo)
            return cum ? Special.betaI(t, a, b) : Special.betaPDF(t, a, b) / (hi - lo)
        }
        r.num("BETADIST", min: 3, max: 5) { s in
            let x = try s.num(0), a = try s.num(1), b = try s.num(2)
            let lo = try s.num(3, 0), hi = try s.num(4, 1)
            guard a > 0, b > 0, lo < hi, x >= lo, x <= hi else { throw XLError.num }
            return Special.betaI((x - lo) / (hi - lo), a, b)
        }
        r.num("BETA.INV", "BETAINV", min: 3, max: 5) { s in
            let p = try s.num(0), a = try s.num(1), b = try s.num(2)
            let lo = try s.num(3, 0), hi = try s.num(4, 1)
            guard p > 0, p <= 1, a > 0, b > 0, lo < hi else { throw XLError.num }
            if p == 1 { return hi }
            return lo + (hi - lo) * Special.invert({ Special.betaI($0, a, b) }, p, lo: 0, hi: 1)
        }

        // Chi-squared
        func df(_ s: Scalars, _ i: Int) throws -> Double {
            let d = try s.num(i).rounded(.towardZero)
            guard d >= 1, d <= 1e10 else { throw XLError.num }
            return d
        }
        r.num("CHISQ.DIST", min: 3, max: 3) { s in
            let x = try s.num(0), k = try df(s, 1)
            guard x >= 0 else { throw XLError.num }
            return try s.bool(2) ? Special.chiCDF(x, k) : Special.chiPDF(x, k)
        }
        r.num("CHISQ.DIST.RT", "CHIDIST", min: 2, max: 2) { s in
            let x = try s.num(0), k = try df(s, 1)
            guard x >= 0 else { throw XLError.num }
            return Special.gammaQ(k / 2, x / 2)
        }
        r.num("CHISQ.INV", min: 2, max: 2) { s in
            let p = try s.num(0), k = try df(s, 1)
            guard p >= 0, p < 1 else { throw XLError.num }
            if p == 0 { return 0 }
            return Special.invert({ Special.chiCDF($0, k) }, p, lo: 0, hi: max(1, k * 4))
        }
        r.num("CHISQ.INV.RT", "CHIINV", min: 2, max: 2) { s in
            let p = try s.num(0), k = try df(s, 1)
            guard p > 0, p <= 1 else { throw XLError.num }
            if p == 1 { return 0 }
            return Special.invert({ 1 - Special.gammaQ(k / 2, $0 / 2) }, 1 - p, lo: 0, hi: max(1, k * 4))
        }
        r.raw("CHISQ.TEST", "CHITEST", min: 2, max: 2) { a in
            let obs = try a.matrix(0), exp = try a.matrix(1)
            guard obs.rows == exp.rows, obs.cols == exp.cols, obs.data.count > 1 else { throw XLError.na }
            var chi = 0.0
            for i in 0..<obs.data.count {
                guard case .number(let o) = obs.data[i], case .number(let e) = exp.data[i] else { continue }
                guard e != 0 else { throw XLError.div0 }
                chi += (o - e) * (o - e) / e
            }
            let dof = obs.rows > 1 && obs.cols > 1 ? Double((obs.rows - 1) * (obs.cols - 1)) : Double(obs.data.count - 1)
            return try X.check(Special.gammaQ(dof / 2, chi / 2))
        }

        // F
        r.num("F.DIST", min: 4, max: 4) { s in
            let x = try s.num(0), d1 = try df(s, 1), d2 = try df(s, 2)
            guard x >= 0 else { throw XLError.num }
            return try s.bool(3) ? Special.fCDF(x, d1, d2) : Special.fPDF(x, d1, d2)
        }
        r.num("F.DIST.RT", "FDIST", min: 3, max: 3) { s in
            let x = try s.num(0), d1 = try df(s, 1), d2 = try df(s, 2)
            guard x >= 0 else { throw XLError.num }
            return x == 0 ? 1 : Special.betaI(d2 / (d2 + d1 * x), d2 / 2, d1 / 2)
        }
        r.num("F.INV", min: 3, max: 3) { s in
            let p = try s.num(0), d1 = try df(s, 1), d2 = try df(s, 2)
            guard p >= 0, p <= 1 else { throw XLError.num }
            if p == 0 { return 0 }
            return Special.invert({ Special.fCDF($0, d1, d2) }, p, lo: 0, hi: 10)
        }
        r.num("F.INV.RT", "FINV", min: 3, max: 3) { s in
            let p = try s.num(0), d1 = try df(s, 1), d2 = try df(s, 2)
            guard p > 0, p <= 1 else { throw XLError.num }
            if p == 1 { return 0 }
            return Special.invert({ Special.fCDF($0, d1, d2) }, 1 - p, lo: 0, hi: 10)
        }
        r.raw("F.TEST", "FTEST", min: 2, max: 2) { a in
            let x = try Aggregates.numbers(a.grid(0).data), y = try Aggregates.numbers(a.grid(1).data)
            guard x.count > 1, y.count > 1 else { throw XLError.div0 }
            let v1 = try Stats.varS(x), v2 = try Stats.varS(y)
            guard v1 > 0, v2 > 0 else { throw XLError.div0 }
            let f = v1 / v2
            let c = Special.fCDF(f, Double(x.count - 1), Double(y.count - 1))
            return try X.check(2 * min(c, 1 - c))
        }

        // Student t
        r.num("T.DIST", min: 3, max: 3) { s in
            let x = try s.num(0), k = try df(s, 1)
            return try s.bool(2) ? Special.tCDF(x, k) : Special.tPDF(x, k)
        }
        r.num("T.DIST.2T", min: 2, max: 2) { s in
            let x = try s.num(0), k = try df(s, 1)
            guard x >= 0 else { throw XLError.num }
            return 2 * (1 - Special.tCDF(x, k))
        }
        r.num("T.DIST.RT", min: 2, max: 2) { s in
            let x = try s.num(0), k = try df(s, 1)
            return 1 - Special.tCDF(x, k)
        }
        r.num("TDIST", min: 3, max: 3) { s in
            let x = try s.num(0), k = try df(s, 1), tails = try s.int(2)
            guard x >= 0, tails == 1 || tails == 2 else { throw XLError.num }
            return Double(tails) * (1 - Special.tCDF(x, k))
        }
        r.num("T.INV", min: 2, max: 2) { s in
            let p = try s.num(0), k = try df(s, 1)
            guard p > 0, p < 1 else { throw XLError.num }
            return Special.tInv(p, k)
        }
        r.num("T.INV.2T", "TINV", min: 2, max: 2) { s in
            let p = try s.num(0), k = try df(s, 1)
            guard p > 0, p <= 1 else { throw XLError.num }
            return abs(Special.tInv(1 - p / 2, k))
        }
        r.raw("T.TEST", "TTEST", min: 4, max: 4) { a in
            let tails = try a.int(2), type = try a.int(3)
            guard tails == 1 || tails == 2, (1...3).contains(type) else { throw XLError.num }
            let t: Double, dof: Double
            if type == 1 {
                let x = try a.matrix(0), y = try a.matrix(1)
                guard x.data.count == y.data.count else { throw XLError.na }
                var d: [Double] = []
                for i in 0..<x.data.count {
                    if case .number(let p) = x.data[i], case .number(let q) = y.data[i] { d.append(p - q) }
                }
                guard d.count > 1 else { throw XLError.div0 }
                let sd = try Stats.varS(d).squareRoot()
                guard sd > 0 else { throw XLError.div0 }
                t = try Stats.mean(d) / (sd / Double(d.count).squareRoot())
                dof = Double(d.count - 1)
            } else {
                let x = try Aggregates.numbers(a.grid(0).data), y = try Aggregates.numbers(a.grid(1).data)
                guard x.count > 1, y.count > 1 else { throw XLError.div0 }
                let n1 = Double(x.count), n2 = Double(y.count)
                let v1 = try Stats.varS(x), v2 = try Stats.varS(y)
                let diff = try Stats.mean(x) - Stats.mean(y)
                if type == 2 {
                    let sp = ((n1 - 1) * v1 + (n2 - 1) * v2) / (n1 + n2 - 2)
                    guard sp > 0 else { throw XLError.div0 }
                    t = diff / (sp * (1 / n1 + 1 / n2)).squareRoot()
                    dof = n1 + n2 - 2
                } else {
                    let se = v1 / n1 + v2 / n2
                    guard se > 0 else { throw XLError.div0 }
                    t = diff / se.squareRoot()
                    dof = se * se / (pow(v1 / n1, 2) / (n1 - 1) + pow(v2 / n2, 2) / (n2 - 1))
                }
            }
            return try X.check(Double(tails) * (1 - Special.tCDF(abs(t), dof)))
        }
    }
}
