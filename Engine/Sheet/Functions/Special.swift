import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Special functions behind the statistical distributions (Lanczos gamma,
/// continued-fraction incomplete gamma/beta, AS241 normal quantile).
enum Special {
    static func lnGamma(_ x: Double) -> Double {
        if x <= 0 && x == x.rounded() { return .infinity }
        if x < 0.5 { return log(Double.pi / abs(sin(Double.pi * x))) - lnGamma(1 - x) }
        let g = 7.0
        let c: [Double] = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
                           -176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7]
        let xx = x - 1
        var a = c[0]
        let t = xx + g + 0.5
        for i in 1..<9 { a += c[i] / (xx + Double(i)) }
        return 0.5 * log(2 * Double.pi) + (xx + 0.5) * log(t) - t + log(a)
    }

    static func gamma(_ x: Double) -> Double {
        if x == x.rounded() && x <= 0 { return .nan }
        if x == x.rounded() && x < 171 { return Num.fact(Int(x) - 1) }
        if x < 0.5 { return Double.pi / (sin(Double.pi * x) * gamma(1 - x)) }
        return exp(lnGamma(x))
    }

    static func lnBeta(_ a: Double, _ b: Double) -> Double { lnGamma(a) + lnGamma(b) - lnGamma(a + b) }

    /// Regularised lower incomplete gamma P(a, x).
    static func gammaP(_ a: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x < a + 1 {
            var sum = 1 / a, del = sum, ap = a
            for _ in 0..<10000 {
                ap += 1; del *= x / ap; sum += del
                if abs(del) < abs(sum) * 1e-16 { break }
            }
            return min(1, sum * exp(-x + a * log(x) - lnGamma(a)))
        }
        return 1 - gammaQcf(a, x)
    }

    static func gammaQ(_ a: Double, _ x: Double) -> Double {
        if x <= 0 { return 1 }
        if x < a + 1 { return 1 - gammaP(a, x) }
        return gammaQcf(a, x)
    }

    private static func gammaQcf(_ a: Double, _ x: Double) -> Double {
        let tiny = 1e-300
        var b = x + 1 - a, c = 1 / tiny, d = 1 / b, h = d
        for i in 1..<10000 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b; if abs(d) < tiny { d = tiny }
            c = b + an / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-16 { break }
        }
        return exp(-x + a * log(x) - lnGamma(a)) * h
    }

    /// Regularised incomplete beta I_x(a, b).
    static func betaI(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let bt = exp(a * log(x) + b * log(1 - x) - lnBeta(a, b))
        if x < (a + 1) / (a + b + 2) { return bt * betacf(x, a, b) / a }
        return 1 - bt * betacf(1 - x, b, a) / b
    }

    private static func betacf(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-300
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0, d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1..<10000 {
            let mm = Double(m), m2 = 2 * mm
            var aa = mm * (b - mm) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d; h *= d * c
            aa = -(a + mm) * (qab + mm) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-16 { break }
        }
        return h
    }

    static func erf(_ x: Double) -> Double { Foundation.erf(x) }
    static func erfc(_ x: Double) -> Double { Foundation.erfc(x) }

    static func normCDF(_ z: Double) -> Double { 0.5 * erfc(-z / 2.0.squareRoot()) }
    static func normPDF(_ z: Double) -> Double { exp(-z * z / 2) / (2 * Double.pi).squareRoot() }

    /// Horner evaluation with coefficients from highest to lowest degree.
    static func poly(_ x: Double, _ c: [Double]) -> Double { c.reduce(0) { $0 * x + $1 } }

    /// Wichura AS241 (PPND16), accurate to ~1e-16.
    static func normInv(_ p: Double) -> Double {
        if p <= 0 { return -.infinity }
        if p >= 1 { return .infinity }
        let q = p - 0.5
        if abs(q) <= 0.425 {
            let r = 0.180625 - q * q
            let num = poly(r, [2509.0809287301226727, 33430.575583588128105, 67265.770927008700853, 45921.953931549871457,
                               13731.693765509461125, 1971.5909503065514427, 133.14166789178437745, 3.387132872796366608])
            let den = poly(r, [5226.495278852545925, 28729.085735721942674, 39307.89580009271061, 21213.794301586595867,
                               5394.1960214247511077, 687.1870074920579083, 42.313330701600911252, 1])
            return q * num / den
        }
        var r = q < 0 ? p : 1 - p
        r = (-log(r)).squareRoot()
        var val: Double
        if r <= 5 {
            r -= 1.6
            val = poly(r, [7.7454501427834140764e-4, 0.0227238449892691845833, 0.24178072517745061177, 1.27045825245236838258,
                           3.64784832476320460504, 5.7694972214606914055, 4.6303378461565452959, 1.42343711074968357734])
                / poly(r, [1.05075007164441684324e-9, 5.475938084995344946e-4, 0.0151986665636164571966, 0.14810397642748007459,
                           0.68976733498510000455, 1.6763848301838038494, 2.05319162663775882187, 1])
        } else {
            r -= 5
            val = poly(r, [2.01033439929228813265e-7, 2.71155556874348757815e-5, 0.0012426609473880784386, 0.026532189526576123093,
                           0.29656057182850489123, 1.7848265399172913358, 5.4637849111641143699, 6.6579046435011037772])
                / poly(r, [2.04426310338993978564e-15, 1.4215117583164458887e-7, 1.8463183175100546818e-5, 7.868691311456132591e-4,
                           0.0148753612908506148525, 0.13692988092273580531, 0.59983220655588793769, 1])
        }
        return q < 0 ? -val : val
    }

    /// Inverts a monotonically increasing CDF on [lo, hi] by bisection+secant.
    static func invert(_ cdf: (Double) -> Double, _ p: Double, lo: Double, hi: Double) -> Double {
        var a = lo, b = hi
        // Expand upper bound if needed.
        var guardCount = 0
        while cdf(b) < p && guardCount < 200 { a = b; b *= 2; guardCount += 1 }
        for _ in 0..<300 {
            let m = (a + b) / 2
            if cdf(m) < p { a = m } else { b = m }
            if abs(b - a) <= 1e-15 * max(1, abs(m)) { break }
        }
        return (a + b) / 2
    }

    // Distributions
    static func tCDF(_ t: Double, _ df: Double) -> Double {
        let x = df / (df + t * t)
        let tail = 0.5 * betaI(x, df / 2, 0.5)
        return t > 0 ? 1 - tail : tail
    }
    static func tPDF(_ t: Double, _ df: Double) -> Double {
        exp(lnGamma((df + 1) / 2) - lnGamma(df / 2)) / (df * Double.pi).squareRoot() * pow(1 + t * t / df, -(df + 1) / 2)
    }
    static func tInv(_ p: Double, _ df: Double) -> Double {
        if p == 0.5 { return 0 }
        if p < 0.5 { return -tInv(1 - p, df) }
        return invert({ tCDF($0, df) }, p, lo: 0, hi: 10)
    }
    static func chiCDF(_ x: Double, _ df: Double) -> Double { gammaP(df / 2, x / 2) }
    static func chiPDF(_ x: Double, _ df: Double) -> Double {
        if x < 0 { return 0 }
        if x == 0 { return df == 2 ? 0.5 : df < 2 ? .infinity : 0 }
        return exp((df / 2 - 1) * log(x) - x / 2 - (df / 2) * log(2) - lnGamma(df / 2))
    }
    static func fCDF(_ x: Double, _ d1: Double, _ d2: Double) -> Double {
        if x <= 0 { return 0 }
        return betaI(d1 * x / (d1 * x + d2), d1 / 2, d2 / 2)
    }
    static func fPDF(_ x: Double, _ d1: Double, _ d2: Double) -> Double {
        if x < 0 { return 0 }
        if x == 0 { return d1 == 2 ? 1 : d1 < 2 ? .infinity : 0 }
        return exp(0.5 * (d1 * log(d1 * x) + d2 * log(d2) - (d1 + d2) * log(d1 * x + d2)) - log(x) - lnBeta(d1 / 2, d2 / 2))
    }
    static func gammaCDF(_ x: Double, _ a: Double, _ b: Double) -> Double { gammaP(a, x / b) }
    static func gammaPDF(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x < 0 { return 0 }
        if x == 0 { return a == 1 ? 1 / b : a < 1 ? .infinity : 0 }
        return exp((a - 1) * log(x) - x / b - lnGamma(a) - a * log(b))
    }
    static func betaPDF(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x < 0 || x > 1 { return 0 }
        if x == 0 { return a == 1 ? 1 / exp(lnBeta(a, b)) : a < 1 ? .infinity : 0 }
        if x == 1 { return b == 1 ? 1 / exp(lnBeta(a, b)) : b < 1 ? .infinity : 0 }
        return exp((a - 1) * log(x) + (b - 1) * log(1 - x) - lnBeta(a, b))
    }

    static func binomPMF(_ k: Double, _ n: Double, _ p: Double) -> Double {
        if p == 0 { return k == 0 ? 1 : 0 }
        if p == 1 { return k == n ? 1 : 0 }
        return exp(lnGamma(n + 1) - lnGamma(k + 1) - lnGamma(n - k + 1) + k * log(p) + (n - k) * log(1 - p))
    }
    static func binomCDF(_ k: Double, _ n: Double, _ p: Double) -> Double {
        if k >= n { return 1 }
        if k < 0 { return 0 }
        return 1 - betaI(p, k + 1, n - k)
    }
    static func poissonPMF(_ k: Double, _ m: Double) -> Double {
        if m == 0 { return k == 0 ? 1 : 0 }
        return exp(k * log(m) - m - lnGamma(k + 1))
    }
    static func hypgeomPMF(_ k: Double, _ n: Double, _ K: Double, _ N: Double) -> Double {
        exp(lnC(K, k) + lnC(N - K, n - k) - lnC(N, n))
    }
    static func lnC(_ n: Double, _ k: Double) -> Double { lnGamma(n + 1) - lnGamma(k + 1) - lnGamma(n - k + 1) }

    // Bessel functions (integer order), Numerical Recipes style.
    static func besselJ(_ x: Double, _ n: Int) -> Double {
        if n == 0 { return j0(x) }
        if n == 1 { return j1(x) }
        let ax = abs(x)
        if ax == 0 { return 0 }
        var ans: Double
        if ax > Double(n) {
            var bjm = j0(ax), bj = j1(ax)
            for j in 1..<n { let bjp = Double(j) * 2 / ax * bj - bjm; bjm = bj; bj = bjp }
            ans = bj
        } else {
            let acc = 160.0, bigno = 1e10, bigni = 1e-10
            let m = 2 * ((n + Int((acc * Double(n)).squareRoot())) / 2)
            var jsum = false
            var bjp = 0.0, sum = 0.0, bj = 1.0
            ans = 0
            var j = m
            while j > 0 {
                let bjm = Double(j) * 2 / ax * bj - bjp
                bjp = bj; bj = bjm
                if abs(bj) > bigno { bj *= bigni; bjp *= bigni; ans *= bigni; sum *= bigni }
                if jsum { sum += bj }
                jsum.toggle()
                if j == n { ans = bjp }
                j -= 1
            }
            sum = 2 * sum - bj
            ans /= sum
        }
        return x < 0 && n % 2 == 1 ? -ans : ans
    }
    static func besselY(_ x: Double, _ n: Int) -> Double {
        if n == 0 { return y0(x) }
        if n == 1 { return y1(x) }
        var bym = y0(x), by = y1(x)
        for j in 1..<n { let byp = Double(j) * 2 / x * by - bym; bym = by; by = byp }
        return by
    }
    static func besselI(_ x: Double, _ n: Int) -> Double {
        // Power series: I_n(x) = Σ (x/2)^(2k+n) / (k! (k+n)!)
        var sum = 0.0, term = pow(x / 2, Double(n)) / Num.fact(n)
        var k = 0
        while k < 500 {
            sum += term
            k += 1
            term *= (x / 2) * (x / 2) / (Double(k) * Double(k + n))
            if abs(term) < abs(sum) * 1e-17 { break }
        }
        return sum
    }
    static func besselK(_ x: Double, _ n: Int) -> Double {
        func k0(_ x: Double) -> Double {
            if x <= 2 {
                let y = x * x / 4
                return -log(x / 2) * besselI(x, 0) + poly(y, [0.74e-5, 0.10750e-3, 0.262698e-2, 0.3488590e-1, 0.23069756, 0.42278420, -0.57721566])
            }
            let y = 2 / x
            return exp(-x) / x.squareRoot() * poly(y, [0.53208e-3, -0.251540e-2, 0.587872e-2, -0.1062446e-1, 0.2189568e-1, -0.7832358e-1, 1.25331414])
        }
        func k1(_ x: Double) -> Double {
            if x <= 2 {
                let y = x * x / 4
                return log(x / 2) * besselI(x, 1) + (1 / x) * poly(y, [-0.4686e-4, -0.110404e-2, -0.1919402e-1, -0.18156897, -0.67278579, 0.15443144, 1])
            }
            let y = 2 / x
            return exp(-x) / x.squareRoot() * poly(y, [-0.68245e-3, 0.325614e-2, -0.780353e-2, 0.1504268e-1, -0.3655620e-1, 0.23498619, 1.25331414])
        }
        if n == 0 { return k0(x) }
        if n == 1 { return k1(x) }
        var bkm = k0(x), bk = k1(x)
        for j in 1..<n { let bkp = bkm + Double(j) * 2 / x * bk; bkm = bk; bk = bkp }
        return bk
    }
}
