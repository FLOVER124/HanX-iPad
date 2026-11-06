import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Complex numbers in Excel's text form ("3+4i", "-2.5j").
struct Complex {
    var re: Double, im: Double, suffix: Character = "i"

    static func parse(_ v: SheetValue) throws -> Complex {
        switch v.scalar {
        case .number(let d): return Complex(re: d, im: 0)
        case .empty: return Complex(re: 0, im: 0)
        case .bool: throw XLError.value
        case .error(let e): throw XLError(e)
        default: break
        }
        var s = v.text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return Complex(re: 0, im: 0) }
        var suffix: Character = "i"
        if s.hasSuffix("i") || s.hasSuffix("j") {
            suffix = s.last!
            s.removeLast()
            // Split at the last +/- that is not an exponent sign or the leading sign.
            let chars = Array(s)
            var split = -1
            for k in stride(from: chars.count - 1, to: 0, by: -1) where chars[k] == "+" || chars[k] == "-" {
                if chars[k - 1] == "e" || chars[k - 1] == "E" { continue }
                split = k; break
            }
            let reText = split > 0 ? String(chars[..<split]) : ""
            var imText = split > 0 ? String(chars[split...]) : s
            if imText.isEmpty || imText == "+" { imText += "1" } else if imText == "-" { imText = "-1" }
            guard let im = Double(imText), reText.isEmpty || Double(reText) != nil else { throw XLError.num }
            return Complex(re: Double(reText) ?? 0, im: im, suffix: suffix)
        }
        guard let d = Double(s) else { throw XLError.num }
        return Complex(re: d, im: 0)
    }

    var text: String {
        func num(_ d: Double) -> String {
            var t = String(format: "%.15g", d)
            if t.contains("e") {
                let parts = t.split(separator: "e")
                let exp = Int(parts[1]) ?? 0
                t = String(parts[0]) + "E" + (exp < 0 ? "-" : "+") + String(format: "%02d", Swift.abs(exp))
            }
            return t
        }
        let r = Swift.abs(re) < 1e-300 ? 0 : re, i = Swift.abs(im) < 1e-300 ? 0 : im
        if i == 0 { return num(r) }
        let imPart = i == 1 ? "" : i == -1 ? "-" : num(i)
        if r == 0 { return imPart + String(suffix) }
        return num(r) + (i > 0 ? "+" : "") + imPart + String(suffix)
    }

    var magnitude: Double { hypot(re, im) }
    var arg: Double { atan2(im, re) }
    static func + (a: Complex, b: Complex) -> Complex { Complex(re: a.re + b.re, im: a.im + b.im, suffix: a.suffix) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(re: a.re - b.re, im: a.im - b.im, suffix: a.suffix) }
    static func * (a: Complex, b: Complex) -> Complex {
        Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re, suffix: a.suffix)
    }
    static func / (a: Complex, b: Complex) throws -> Complex {
        let d = b.re * b.re + b.im * b.im
        guard d != 0 else { throw XLError.num }
        return Complex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d, suffix: a.suffix)
    }
    func cexp() -> Complex { let e = Foundation.exp(re); return Complex(re: e * Foundation.cos(im), im: e * Foundation.sin(im), suffix: suffix) }
    func cln() throws -> Complex {
        guard re != 0 || im != 0 else { throw XLError.num }
        return Complex(re: log(magnitude), im: arg, suffix: suffix)
    }
    func csin() -> Complex { Complex(re: Foundation.sin(re) * Foundation.cosh(im), im: Foundation.cos(re) * Foundation.sinh(im), suffix: suffix) }
    func ccos() -> Complex { Complex(re: Foundation.cos(re) * Foundation.cosh(im), im: -Foundation.sin(re) * Foundation.sinh(im), suffix: suffix) }
    func csinh() -> Complex { Complex(re: Foundation.sinh(re) * Foundation.cos(im), im: Foundation.cosh(re) * Foundation.sin(im), suffix: suffix) }
    func ccosh() -> Complex { Complex(re: Foundation.cosh(re) * Foundation.cos(im), im: Foundation.sinh(re) * Foundation.sin(im), suffix: suffix) }
    func cpow(_ n: Double) throws -> Complex {
        if re == 0 && im == 0 {
            guard n > 0 else { throw XLError.num }
            return Complex(re: 0, im: 0, suffix: suffix)
        }
        if n == n.rounded(), Swift.abs(n) <= 64 {
            var out = Complex(re: 1, im: 0, suffix: suffix)
            for _ in 0..<Int(Swift.abs(n)) { out = out * self }
            return n < 0 ? try Complex(re: 1, im: 0, suffix: suffix) / out : out
        }
        let r = Foundation.pow(magnitude, n), t = arg * n
        return Complex(re: r * Foundation.cos(t), im: r * Foundation.sin(t), suffix: suffix)
    }
    static let one = Complex(re: 1, im: 0)
}

enum EngineeringFunctions {
    // MARK: Base conversion

    static func fromBase(_ s: Scalars, radix: Int, bits: Int) throws -> Double {
        var t: String
        switch s.raw(0) {
        case .number(let d): t = String(Int64(d))
        case .error(let e): throw XLError(e)
        case .bool: throw XLError.value
        default: t = try s.str(0)
        }
        t = t.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.count <= 10 else { throw XLError.num }
        if t.isEmpty { return 0 }
        guard let v = Int64(t, radix: radix), v >= 0 else { throw XLError.num }
        let limit = Int64(1) << Int64(bits)
        return Double(v >= limit / 2 ? v - limit : v)
    }

    static func toBase(_ value: Double, radix: Int, bits: Int, places: Int?) throws -> String {
        let v = Int64(value.rounded(.towardZero))
        let limit = Int64(1) << Int64(bits)
        guard v >= -limit / 2, v < limit / 2 else { throw XLError.num }
        if v < 0 { return String(limit + v, radix: radix).uppercased() }
        let t = String(v, radix: radix).uppercased()
        if let places {
            guard places >= 0, places <= 10, t.count <= places else { throw XLError.num }
            return String(repeating: "0", count: places - t.count) + t
        }
        return t
    }

    static func register(_ r: inout Registry) {
        let systems: [(String, Int, Int)] = [("BIN", 2, 10), ("OCT", 8, 30), ("DEC", 10, 0), ("HEX", 16, 40)]
        for (fromName, fromRadix, fromBits) in systems {
            for (toName, toRadix, toBits) in systems where fromName != toName {
                let name = fromName + "2" + toName
                if toName == "DEC" {
                    r.num(name, min: 1, max: 1) { s in try fromBase(s, radix: fromRadix, bits: fromBits) }
                } else {
                    r.scalar(name, min: 1, max: 2) { s in
                        let v: Double
                        if fromName == "DEC" { v = try s.num(0) } else { v = try fromBase(s, radix: fromRadix, bits: fromBits) }
                        let places: Int? = s.has(1) ? try s.int(1) : nil
                        return .string(try toBase(v, radix: toRadix, bits: toBits, places: places))
                    }
                }
            }
        }

        // Bitwise
        func bitArg(_ s: Scalars, _ i: Int) throws -> UInt64 {
            let d = try s.num(i)
            guard d >= 0, d < 281474976710656, d == d.rounded() else { throw XLError.num }
            return UInt64(d)
        }
        r.num("BITAND", min: 2, max: 2) { s in Double(try bitArg(s, 0) & bitArg(s, 1)) }
        r.num("BITOR", min: 2, max: 2) { s in Double(try bitArg(s, 0) | bitArg(s, 1)) }
        r.num("BITXOR", min: 2, max: 2) { s in Double(try bitArg(s, 0) ^ bitArg(s, 1)) }
        func shift(_ s: Scalars, left: Bool) throws -> Double {
            let v = try bitArg(s, 0), n = try s.int(1)
            guard abs(n) <= 53 else { throw XLError.num }
            let k = left ? n : -n
            let out = k >= 0 ? Double(v) * pow(2, Double(k)) : Double(v >> UInt64(-k))
            guard out < 281474976710656 else { throw XLError.num }
            return out
        }
        r.num("BITLSHIFT", min: 2, max: 2) { try shift($0, left: true) }
        r.num("BITRSHIFT", min: 2, max: 2) { try shift($0, left: false) }

        r.num("DELTA", min: 1, max: 2) { s in try s.num(0) == s.num(1, 0) ? 1 : 0 }
        r.num("GESTEP", min: 1, max: 2) { s in try s.num(0) >= s.num(1, 0) ? 1 : 0 }
        r.num("ERF", min: 1, max: 2) { s in
            let a = try s.num(0)
            if s.has(1) { return Special.erf(try s.num(1)) - Special.erf(a) }
            return Special.erf(a)
        }
        r.num("ERF.PRECISE", min: 1, max: 1) { Special.erf(try $0.num(0)) }
        r.num("ERFC", "ERFC.PRECISE", min: 1, max: 1) { Special.erfc(try $0.num(0)) }
        r.num("BESSELJ", min: 2, max: 2) { s in
            let n = try s.num(1).rounded(.towardZero)
            guard n >= 0 else { throw XLError.num }
            return Special.besselJ(try s.num(0), Int(n))
        }
        r.num("BESSELY", min: 2, max: 2) { s in
            let x = try s.num(0), n = try s.num(1).rounded(.towardZero)
            guard n >= 0, x > 0 else { throw XLError.num }
            return Special.besselY(x, Int(n))
        }
        r.num("BESSELI", min: 2, max: 2) { s in
            let n = try s.num(1).rounded(.towardZero)
            guard n >= 0 else { throw XLError.num }
            return Special.besselI(try s.num(0), Int(n))
        }
        r.num("BESSELK", min: 2, max: 2) { s in
            let x = try s.num(0), n = try s.num(1).rounded(.towardZero)
            guard n >= 0, x > 0 else { throw XLError.num }
            return Special.besselK(x, Int(n))
        }

        // Complex numbers
        r.scalar("COMPLEX", min: 2, max: 3) { s in
            let suffix = try s.str(2, "i")
            guard suffix == "i" || suffix == "j" || suffix.isEmpty else { throw XLError.value }
            return .string(Complex(re: try s.num(0), im: try s.num(1), suffix: suffix.isEmpty ? "i" : Character(suffix)).text)
        }
        func c1(_ name: String, _ f: @escaping (Complex) throws -> Complex) {
            r.scalar(name, min: 1, max: 1) { s in .string(try f(try Complex.parse(s.raw(0))).text) }
        }
        func n1(_ name: String, _ f: @escaping (Complex) throws -> Double) {
            r.num(name, min: 1, max: 1) { s in try f(try Complex.parse(s.raw(0))) }
        }
        n1("IMABS") { $0.magnitude }
        n1("IMREAL") { $0.re }
        n1("IMAGINARY") { $0.im }
        n1("IMARGUMENT") { c in
            guard c.re != 0 || c.im != 0 else { throw XLError.div0 }
            return c.arg
        }
        c1("IMCONJUGATE") { Complex(re: $0.re, im: -$0.im, suffix: $0.suffix) }
        c1("IMEXP") { $0.cexp() }
        c1("IMLN") { try $0.cln() }
        c1("IMLOG10") { c in let l = try c.cln(); return Complex(re: l.re / log(10), im: l.im / log(10), suffix: c.suffix) }
        c1("IMLOG2") { c in let l = try c.cln(); return Complex(re: l.re / log(2), im: l.im / log(2), suffix: c.suffix) }
        c1("IMSQRT") { try $0.cpow(0.5) }
        c1("IMSIN") { $0.csin() }
        c1("IMCOS") { $0.ccos() }
        c1("IMTAN") { c in try c.csin() / c.ccos() }
        c1("IMCOT") { c in try c.ccos() / c.csin() }
        c1("IMSEC") { c in try Complex(re: 1, im: 0, suffix: c.suffix) / c.ccos() }
        c1("IMCSC") { c in try Complex(re: 1, im: 0, suffix: c.suffix) / c.csin() }
        c1("IMSINH") { $0.csinh() }
        c1("IMCOSH") { $0.ccosh() }
        c1("IMSECH") { c in try Complex(re: 1, im: 0, suffix: c.suffix) / c.ccosh() }
        c1("IMCSCH") { c in try Complex(re: 1, im: 0, suffix: c.suffix) / c.csinh() }
        r.scalar("IMPOWER", min: 2, max: 2) { s in .string(try Complex.parse(s.raw(0)).cpow(try s.num(1)).text) }
        r.scalar("IMDIV", min: 2, max: 2) { s in .string(try (Complex.parse(s.raw(0)) / Complex.parse(s.raw(1))).text) }
        r.scalar("IMSUB", min: 2, max: 2) { s in .string((try Complex.parse(s.raw(0)) - Complex.parse(s.raw(1))).text) }
        func fold(_ a: Args, _ start: Complex, _ op: (Complex, Complex) -> Complex) throws -> SheetValue {
            var acc: Complex?
            for v in a.flat() {
                if case .empty = v { continue }
                let c = try Complex.parse(v)
                acc = acc.map { op($0, c) } ?? c
            }
            return .string((acc ?? start).text)
        }
        r.raw("IMSUM", min: 1) { a in try fold(a, Complex(re: 0, im: 0), +) }
        r.raw("IMPRODUCT", min: 1) { a in try fold(a, .one, *) }

        r.scalar("CONVERT", min: 3, max: 3) { s in
            .number(try ConvertUnits.convert(try s.num(0), try s.str(1), try s.str(2)))
        }
    }
}

/// CONVERT unit table: factor to the category's base unit.
enum ConvertUnits {
    enum Category { case mass, distance, time, pressure, force, energy, power, magnetism, temperature, volume, area, information, speed }
    struct Unit { let category: Category; let factor: Double; let prefixable: Bool; let power: Int }

    static let table: [String: Unit] = {
        var t: [String: Unit] = [:]
        func add(_ names: [String], _ c: Category, _ f: Double, prefix: Bool = false, power: Int = 1) {
            for n in names { t[n] = Unit(category: c, factor: f, prefixable: prefix, power: power) }
        }
        // Mass (gram)
        add(["g"], .mass, 1, prefix: true)
        add(["sg"], .mass, 14593.9029372064)
        add(["lbm"], .mass, 453.59237)
        add(["u"], .mass, 1.660538782e-24, prefix: true)
        add(["ozm"], .mass, 28.349523125)
        add(["grain"], .mass, 0.06479891)
        add(["cwt", "shweight"], .mass, 45359.237)
        add(["uk_cwt", "lcwt", "hweight"], .mass, 50802.34544)
        add(["stone"], .mass, 6350.29318)
        add(["ton"], .mass, 907184.74)
        add(["uk_ton", "LTON", "brton"], .mass, 1016046.9088)
        // Distance (metre)
        let inch = 0.0254, mile = 1609.344, nmi = 1852.0, ly = 9.4607304725808e15, pica = 0.0254 / 72
        add(["m"], .distance, 1, prefix: true)
        add(["mi"], .distance, mile)
        add(["Nmi"], .distance, nmi)
        add(["in"], .distance, inch)
        add(["ft"], .distance, 0.3048)
        add(["yd"], .distance, 0.9144)
        add(["ang"], .distance, 1e-10, prefix: true)
        add(["ell"], .distance, 1.143)
        add(["ly"], .distance, ly, prefix: true)
        add(["parsec", "pc"], .distance, 3.08567758128155e16, prefix: true)
        add(["Picapt", "Pica"], .distance, pica)
        add(["pica"], .distance, inch / 6)
        add(["survey_mi"], .distance, 1609.34721869444)
        // Time (second)
        add(["yr"], .time, 31557600)
        add(["day", "d"], .time, 86400)
        add(["hr"], .time, 3600)
        add(["mn", "min"], .time, 60)
        add(["sec", "s"], .time, 1, prefix: true)
        // Pressure (pascal)
        add(["Pa", "p"], .pressure, 1, prefix: true)
        add(["atm", "at"], .pressure, 101325, prefix: true)
        add(["mmHg"], .pressure, 133.322368421053, prefix: true)
        add(["psi"], .pressure, 6894.75729316836)
        add(["Torr"], .pressure, 133.322368421053)
        // Force (newton)
        add(["N"], .force, 1, prefix: true)
        add(["dyn", "dy"], .force, 1e-5, prefix: true)
        add(["lbf"], .force, 4.4482216152605)
        add(["pond"], .force, 0.00980665, prefix: true)
        // Energy (joule)
        add(["J"], .energy, 1, prefix: true)
        add(["e"], .energy, 1e-7, prefix: true)
        add(["c"], .energy, 4.184, prefix: true)
        add(["cal"], .energy, 4.1868, prefix: true)
        add(["eV", "ev"], .energy, 1.602176487e-19, prefix: true)
        add(["HPh", "hh"], .energy, 2684519.53769617)
        add(["Wh", "wh"], .energy, 3600, prefix: true)
        add(["flb"], .energy, 1.3558179483314)
        add(["BTU", "btu"], .energy, 1055.05585262)
        // Power (watt)
        add(["HP", "h"], .power, 745.69987158227)
        add(["PS"], .power, 735.49875)
        add(["W", "w"], .power, 1, prefix: true)
        // Magnetism (tesla)
        add(["T"], .magnetism, 1, prefix: true)
        add(["ga"], .magnetism, 1e-4, prefix: true)
        // Temperature (handled specially)
        add(["C", "cel", "F", "fah", "Rank", "Reau"], .temperature, 1)
        add(["K", "kel"], .temperature, 1, prefix: true)
        // Volume (cubic metre)
        add(["tsp"], .volume, 4.92892159375e-6)
        add(["tspm"], .volume, 5e-6)
        add(["tbs"], .volume, 1.478676478125e-5)
        add(["oz"], .volume, 2.95735295625e-5)
        add(["cup"], .volume, 2.365882365e-4)
        add(["pt", "us_pt"], .volume, 4.73176473e-4)
        add(["uk_pt"], .volume, 5.6826125e-4)
        add(["qt"], .volume, 9.46352946e-4)
        add(["uk_qt"], .volume, 1.1365225e-3)
        add(["gal"], .volume, 3.785411784e-3)
        add(["uk_gal"], .volume, 4.54609e-3)
        add(["l", "L", "lt"], .volume, 1e-3, prefix: true)
        add(["ang3", "ang^3"], .volume, 1e-30, prefix: true, power: 3)
        add(["barrel"], .volume, 0.158987294928)
        add(["bushel"], .volume, 0.03523907016688)
        add(["ft3", "ft^3"], .volume, 0.028316846592)
        add(["in3", "in^3"], .volume, inch * inch * inch)
        add(["ly3", "ly^3"], .volume, ly * ly * ly)
        add(["m3", "m^3"], .volume, 1, prefix: true, power: 3)
        add(["mi3", "mi^3"], .volume, mile * mile * mile)
        add(["yd3", "yd^3"], .volume, 0.9144 * 0.9144 * 0.9144)
        add(["Nmi3", "Nmi^3"], .volume, nmi * nmi * nmi)
        add(["Picapt3", "Picapt^3", "Pica3", "Pica^3"], .volume, pica * pica * pica)
        add(["GRT", "regton"], .volume, 2.8316846592)
        add(["MTON"], .volume, 1.13267386368)
        // Area (square metre)
        add(["uk_acre"], .area, 4046.8564224)
        add(["us_acre"], .area, 4046.87260987425)
        add(["ang2", "ang^2"], .area, 1e-20, prefix: true, power: 2)
        add(["ar"], .area, 100, prefix: true)
        add(["ft2", "ft^2"], .area, 0.09290304)
        add(["ha"], .area, 10000)
        add(["in2", "in^2"], .area, inch * inch)
        add(["ly2", "ly^2"], .area, ly * ly)
        add(["m2", "m^2"], .area, 1, prefix: true, power: 2)
        add(["Morgen"], .area, 2500)
        add(["mi2", "mi^2"], .area, mile * mile)
        add(["Nmi2", "Nmi^2"], .area, nmi * nmi)
        add(["Picapt2", "Pica2", "Pica^2", "Picapt^2"], .area, pica * pica)
        add(["yd2", "yd^2"], .area, 0.83612736)
        // Information (bit)
        add(["bit"], .information, 1, prefix: true)
        add(["byte"], .information, 8, prefix: true)
        // Speed (m/s)
        add(["admkn"], .speed, 0.514773333333333)
        add(["kn"], .speed, 0.514444444444444)
        add(["m/h", "m/hr"], .speed, 1.0 / 3600, prefix: true)
        add(["m/s", "m/sec"], .speed, 1, prefix: true)
        add(["mph"], .speed, 0.44704)
        return t
    }()

    static let prefixes: [(String, Double)] = [
        ("da", 1e1), ("Y", 1e24), ("Z", 1e21), ("E", 1e18), ("P", 1e15), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("k", 1e3),
        ("h", 1e2), ("e", 1e1), ("d", 1e-1), ("c", 1e-2), ("m", 1e-3), ("u", 1e-6), ("n", 1e-9), ("p", 1e-12),
        ("f", 1e-15), ("a", 1e-18), ("z", 1e-21), ("y", 1e-24),
    ]
    static let binaryPrefixes: [(String, Double)] = [
        ("ki", 1024), ("Mi", 1048576), ("Gi", 1073741824), ("Ti", 1099511627776), ("Pi", 1125899906842624),
        ("Ei", 1152921504606846976), ("Zi", 1180591620717411303424), ("Yi", 1208925819614629174706176),
    ]

    static func lookup(_ name: String) -> (Unit, Double, String)? {
        if let u = table[name] { return (u, 1, name) }
        for (p, f) in binaryPrefixes + prefixes where name.hasPrefix(p) {
            let rest = String(name.dropFirst(p.count))
            if let u = table[rest], u.prefixable {
                if binaryPrefixes.contains(where: { $0.0 == p }) && u.category != .information { continue }
                return (u, pow(f, Double(u.power)), rest)
            }
        }
        return nil
    }

    static func convert(_ v: Double, _ from: String, _ to: String) throws -> Double {
        guard let (a, fa, baseA) = lookup(from), let (b, fb, baseB) = lookup(to), a.category == b.category else { throw XLError.na }
        if a.category == .temperature {
            let kelvin = toKelvin(v * fa, baseA)
            return fromKelvin(kelvin, baseB) / fb
        }
        return v * a.factor * fa / (b.factor * fb)
    }

    static func toKelvin(_ v: Double, _ u: String) -> Double {
        switch u {
        case "C", "cel": return v + 273.15
        case "F", "fah": return (v - 32) * 5 / 9 + 273.15
        case "Rank": return v * 5 / 9
        case "Reau": return v * 1.25 + 273.15
        default: return v
        }
    }
    static func fromKelvin(_ k: Double, _ u: String) -> Double {
        switch u {
        case "C", "cel": return k - 273.15
        case "F", "fah": return (k - 273.15) * 9 / 5 + 32
        case "Rank": return k * 9 / 5
        case "Reau": return (k - 273.15) * 0.8
        default: return k
        }
    }
}
