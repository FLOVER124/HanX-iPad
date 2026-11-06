import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Day-count conventions shared by date and securities functions.
enum DayCount {
    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    }
    static func serial(_ y: Int, _ m: Int, _ d: Int) -> Double { DateSerial.serial(y, m, d) ?? 0 }

    /// 30/360. `european` = basis 4; `fracMode` applies YEARFRAC's
    /// both-end-of-February rule.
    static func days360(_ s1: Double, _ s2: Double, european: Bool, fracMode: Bool = false) -> Double {
        let (y1, m1, dd1) = DateSerial.ymd(s1)
        let (y2, m2, dd2) = DateSerial.ymd(s2)
        var d1 = dd1, d2 = dd2
        if european {
            if d1 == 31 { d1 = 30 }
            if d2 == 31 { d2 = 30 }
        } else {
            let feb1 = m1 == 2 && d1 == daysInMonth(y1, 2), feb2 = m2 == 2 && d2 == daysInMonth(y2, 2)
            if fracMode && feb1 && feb2 { d2 = 30 }
            if feb1 { d1 = 30 }
            if d2 == 31 && d1 >= 30 { d2 = 30 }
            if d1 == 31 { d1 = 30 }
        }
        return Double((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1))
    }

    static func yearFrac(_ a: Double, _ b: Double, _ basis: Int) throws -> Double {
        var s1 = floor(a), s2 = floor(b)
        if s1 > s2 { swap(&s1, &s2) }
        switch basis {
        case 0: return days360(s1, s2, european: false, fracMode: true) / 360
        case 1:
            let (y1, m1, d1) = DateSerial.ymd(s1), (y2, m2, d2) = DateSerial.ymd(s2)
            let denom: Double
            if y1 == y2 || (y2 == y1 + 1 && (m1 > m2 || (m1 == m2 && d1 >= d2))) {
                var leap: Bool
                if y1 == y2 { leap = isLeap(y1) }
                else {
                    leap = (isLeap(y1) && s1 <= serial(y1, 2, 29)) || (isLeap(y2) && s2 >= serial(y2, 2, 29))
                }
                denom = leap ? 366 : 365
            } else {
                let years = Double(y2 - y1 + 1)
                denom = (serial(y2 + 1, 1, 1) - serial(y1, 1, 1)) / years
            }
            return (s2 - s1) / denom
        case 2: return (s2 - s1) / 360
        case 3: return (s2 - s1) / 365
        case 4: return days360(s1, s2, european: true) / 360
        default: throw XLError.num
        }
    }

    /// Adds months, clamping the day to the target month's length.
    static func addMonths(_ s: Double, _ n: Int) -> Double? {
        let (y, m, d) = DateSerial.ymd(s)
        let idx = y * 12 + (m - 1) + n
        let ny = idx / 12, nm = idx % 12 + 1
        guard ny >= 1900, ny <= 9999 else { return nil }
        return DateSerial.serial(ny, nm, min(d, daysInMonth(ny, nm)))
    }

    /// Weekend mask (Mon…Sun) from a WORKDAY.INTL/NETWORKDAYS.INTL weekend argument.
    static func weekendMask(_ v: SheetValue) throws -> [Bool] {
        if case .string(let s) = v {
            guard s.count == 7, s.allSatisfy({ $0 == "0" || $0 == "1" }), s != "1111111" else { throw XLError.value }
            return s.map { $0 == "1" }
        }
        if case .empty = v { return [false, false, false, false, false, true, true] }
        let n = try X.int(v)
        var mask = [Bool](repeating: false, count: 7)
        switch n {
        case 1...7:
            // 1 = Sat/Sun, 2 = Sun/Mon … 7 = Fri/Sat
            let first = (n + 4) % 7          // index of first weekend day (Mon=0)
            mask[first] = true; mask[(first + 1) % 7] = true
        case 11...17: mask[(n - 11 + 6) % 7] = true
        default: throw XLError.num
        }
        return mask
    }

    /// Monday-based index (0 = Mon … 6 = Sun).
    static func monIndex(_ s: Double) -> Int { (DateSerial.weekday(s) + 5) % 7 }

    static func holidays(_ a: Args, _ i: Int) throws -> Set<Double> {
        guard a.has(i) else { return [] }
        var out = Set<Double>()
        for v in a.flat(from: i, to: i + 1) {
            switch v {
            case .number(let d): out.insert(floor(d))
            case .empty: break
            case .error(let e): throw XLError(e)
            case .string(let t):
                guard let d = SheetValue.parseNumber(t) else { throw XLError.value }
                out.insert(floor(d))
            default: throw XLError.value
            }
        }
        return out
    }

    static func networkDays(_ s: Double, _ e: Double, _ mask: [Bool], _ hol: Set<Double>) -> Double {
        let a = floor(min(s, e)), b = floor(max(s, e))
        var n = 0.0
        var d = a
        while d <= b {
            if !mask[monIndex(d)] && !hol.contains(d) { n += 1 }
            d += 1
        }
        return s <= e ? n : -n
    }

    static func workday(_ s: Double, _ days: Int, _ mask: [Bool], _ hol: Set<Double>) throws -> Double {
        var d = floor(s), left = abs(days)
        let step = days >= 0 ? 1.0 : -1.0
        while left > 0 {
            d += step
            guard d >= 0, d <= 2958465 else { throw XLError.num }
            if !mask[monIndex(d)] && !hol.contains(d) { left -= 1 }
        }
        return d
    }
}

enum DateFunctions {
    static func serialArg(_ s: Scalars, _ i: Int) throws -> Double {
        let d = try s.num(i)
        guard d >= 0, d < 2958466 else { throw XLError.num }
        return d
    }

    static func register(_ r: inout Registry) {
        r.num("DATE", min: 3, max: 3) { s in
            let y = try s.num(0).rounded(.towardZero), m = try s.num(1).rounded(.towardZero), d = try s.num(2).rounded(.towardZero)
            guard y >= 0, y < 10000, abs(m) < 1e7, abs(d) < 1e9 else { throw XLError.num }
            guard let v = DateSerial.serial(Int(y), Int(m), Int(d)) else { throw XLError.num }
            return v
        }
        r.num("TIME", min: 3, max: 3) { s in
            let h = try s.num(0).rounded(.towardZero), m = try s.num(1).rounded(.towardZero), sec = try s.num(2).rounded(.towardZero)
            let total = h * 3600 + m * 60 + sec
            guard total >= 0, h < 32768, m < 32768, sec < 32768 else { throw XLError.num }
            return total.truncatingRemainder(dividingBy: 86400) / 86400
        }
        r.num("YEAR", min: 1, max: 1) { s in Double(DateSerial.ymd(try serialArg(s, 0)).0) }
        r.num("MONTH", min: 1, max: 1) { s in Double(DateSerial.ymd(try serialArg(s, 0)).1) }
        r.num("DAY", min: 1, max: 1) { s in Double(DateSerial.ymd(try serialArg(s, 0)).2) }
        r.num("HOUR", min: 1, max: 1) { s in Double(DateSerial.time(try serialArg(s, 0)).0) }
        r.num("MINUTE", min: 1, max: 1) { s in Double(DateSerial.time(try serialArg(s, 0)).1) }
        r.num("SECOND", min: 1, max: 1) { s in Double(DateSerial.time(try serialArg(s, 0)).2) }
        r.num("WEEKDAY", min: 1, max: 2) { s in
            let d = try serialArg(s, 0), type = try s.int(1, 1)
            let sun1 = DateSerial.weekday(d)           // 1 = Sun
            let mon0 = (sun1 + 5) % 7                  // 0 = Mon
            switch type {
            case 1, 17: return Double(sun1)
            case 2, 11: return Double(mon0 + 1)
            case 3: return Double(mon0)
            case 12...16: return Double((mon0 - (type - 11) + 7) % 7 + 1)
            default: throw XLError.num
            }
        }
        r.raw("NOW", max: 0) { a in .number(DateSerial.fromDate(a.engine.now)) }
        r.raw("TODAY", max: 0) { a in .number(floor(DateSerial.fromDate(a.engine.now))) }
        r.scalar("DATEVALUE", min: 1, max: 1) { s in
            guard case .string(let t) = s.raw(0) else {
                if case .error(let e) = s.raw(0) { throw XLError(e) }
                throw XLError.value
            }
            guard let v = DateSerial.parse(t), v >= 1 || t.contains(where: { $0 == "/" || $0 == "-" }) else { throw XLError.value }
            return .number(floor(v))
        }
        r.scalar("TIMEVALUE", min: 1, max: 1) { s in
            guard case .string(let t) = s.raw(0) else {
                if case .error(let e) = s.raw(0) { throw XLError(e) }
                throw XLError.value
            }
            guard let v = DateSerial.parse(t) else { throw XLError.value }
            return .number(v - floor(v))
        }
        r.num("DAYS", min: 2, max: 2) { s in floor(try serialArg(s, 0)) - floor(try serialArg(s, 1)) }
        r.num("DAYS360", min: 2, max: 3) { s in
            DayCount.days360(floor(try serialArg(s, 0)), floor(try serialArg(s, 1)), european: try s.bool(2, false))
        }
        r.num("EDATE", min: 2, max: 2) { s in
            guard let v = DayCount.addMonths(floor(try serialArg(s, 0)), try s.int(1)) else { throw XLError.num }
            return v
        }
        r.num("EOMONTH", min: 2, max: 2) { s in
            guard let v = DayCount.addMonths(floor(try serialArg(s, 0)), try s.int(1)) else { throw XLError.num }
            let (y, m, _) = DateSerial.ymd(v)
            return DayCount.serial(y, m, DayCount.daysInMonth(y, m))
        }
        r.num("DATEDIF", min: 3, max: 3) { s in
            let a = floor(try serialArg(s, 0)), b = floor(try serialArg(s, 1))
            guard a <= b else { throw XLError.num }
            let (y1, m1, d1) = DateSerial.ymd(a), (y2, m2, d2) = DateSerial.ymd(b)
            var months = (y2 - y1) * 12 + (m2 - m1)
            if d2 < d1 { months -= 1 }
            switch try s.str(2).uppercased() {
            case "Y": return Double(months / 12)
            case "M": return Double(months)
            case "D": return b - a
            case "YM": return Double(months % 12)
            case "MD":
                if d2 >= d1 { return Double(d2 - d1) }
                let pm = m2 == 1 ? 12 : m2 - 1, py = m2 == 1 ? y2 - 1 : y2
                return Double(DayCount.daysInMonth(py, pm) - d1 + d2)
            case "YD":
                var start = DateSerial.serial(y2, m1, min(d1, DayCount.daysInMonth(y2, m1))) ?? a
                if start > b { start = DateSerial.serial(y2 - 1, m1, min(d1, DayCount.daysInMonth(y2 - 1, m1))) ?? a }
                return b - start
            default: throw XLError.num
            }
        }
        r.num("WEEKNUM", min: 1, max: 2) { s in
            let d = floor(try serialArg(s, 0)), type = try s.int(1, 1)
            if type == 21 { return Double(isoWeek(d)) }
            let startDay: Int  // Monday-based index of week start
            switch type {
            case 1, 17: startDay = 6
            case 2, 11: startDay = 0
            case 12...16: startDay = type - 11
            default: throw XLError.num
            }
            let (y, _, _) = DateSerial.ymd(d)
            let jan1 = DayCount.serial(y, 1, 1)
            let offset = (DayCount.monIndex(jan1) - startDay + 7) % 7
            return floor((d - jan1 + Double(offset)) / 7) + 1
        }
        r.num("ISOWEEKNUM", min: 1, max: 1) { s in Double(isoWeek(floor(try serialArg(s, 0)))) }
        r.num("YEARFRAC", min: 2, max: 3) { s in
            try DayCount.yearFrac(try serialArg(s, 0), try serialArg(s, 1), try s.int(2, 0))
        }

        r.raw("NETWORKDAYS", min: 2, max: 3) { a in
            let hol = try DayCount.holidays(a, 2)
            let mask = [false, false, false, false, false, true, true]
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0)), .value(a.value(1))]), lifted: nil) { s in
                .number(DayCount.networkDays(try serialArg(s, 0), try serialArg(s, 1), mask, hol))
            }
        }
        r.raw("NETWORKDAYS.INTL", min: 2, max: 4) { a in
            let hol = try DayCount.holidays(a, 3)
            let mask = try DayCount.weekendMask(a.has(2) ? a.value(2) : .empty)
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0)), .value(a.value(1))]), lifted: nil) { s in
                .number(DayCount.networkDays(try serialArg(s, 0), try serialArg(s, 1), mask, hol))
            }
        }
        r.raw("WORKDAY", min: 2, max: 3) { a in
            let hol = try DayCount.holidays(a, 2)
            let mask = [false, false, false, false, false, true, true]
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0)), .value(a.value(1))]), lifted: nil) { s in
                .number(try DayCount.workday(try serialArg(s, 0), try s.int(1), mask, hol))
            }
        }
        r.raw("WORKDAY.INTL", min: 2, max: 4) { a in
            let hol = try DayCount.holidays(a, 3)
            let mask = try DayCount.weekendMask(a.has(2) ? a.value(2) : .empty)
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0)), .value(a.value(1))]), lifted: nil) { s in
                .number(try DayCount.workday(try serialArg(s, 0), try s.int(1), mask, hol))
            }
        }

        // Thai calendar
        let thaiDays = ["อาทิตย์", "จันทร์", "อังคาร", "พุธ", "พฤหัสบดี", "ศุกร์", "เสาร์"]
        let thaiMonths = ["มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม", "มิถุนายน", "กรกฎาคม", "สิงหาคม", "กันยายน", "ตุลาคม", "พฤศจิกายน", "ธันวาคม"]
        r.scalar("THAIDAYOFWEEK", min: 1, max: 1) { s in .string(thaiDays[DateSerial.weekday(try serialArg(s, 0)) - 1]) }
        r.scalar("THAIMONTHOFYEAR", min: 1, max: 1) { s in .string(thaiMonths[DateSerial.ymd(try serialArg(s, 0)).1 - 1]) }
        r.num("THAIYEAR", min: 1, max: 1) { s in Double(DateSerial.ymd(try serialArg(s, 0)).0 + 543) }
    }

    static func isoWeek(_ d: Double) -> Int {
        // Thursday of the same ISO week decides the year.
        let thursday = d - Double(DayCount.monIndex(d)) + 3
        let (y, _, _) = DateSerial.ymd(thursday)
        let jan1 = DayCount.serial(y, 1, 1)
        return Int((thursday - jan1) / 7) + 1
    }
}
