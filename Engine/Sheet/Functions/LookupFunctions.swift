import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum Lookup {
    /// Exact equality for lookups: text is case-insensitive (optionally with
    /// wildcards), numbers/booleans compare by value, types never mix.
    static func equal(_ key: SheetValue, _ v: SheetValue, wildcard: Bool) -> Bool {
        switch (key, v) {
        case (.string(let a), .string(let b)):
            if wildcard, let rx = Criteria.wildcard(a) { return b.range(of: rx, options: [.regularExpression, .caseInsensitive]) != nil }
            return a.caseInsensitiveCompare(b) == .orderedSame
        case (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.empty, .empty): return true
        case (.string(let a), .empty): return a.isEmpty
        default: return false
        }
    }

    static func sameType(_ a: SheetValue, _ b: SheetValue) -> Bool {
        switch (a, b) {
        case (.number, .number), (.string, .string), (.bool, .bool): return true
        default: return false
        }
    }

    /// Approximate match on ascending data (largest value <= key).
    static func approxAscending(_ key: SheetValue, _ vals: [SheetValue]) -> Int? {
        // Binary search like Excel, considering only same-typed entries.
        var lo = 0, hi = vals.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            var m = mid
            while m >= lo && !sameType(vals[m], key) { m -= 1 }
            if m < lo {
                lo = mid + 1; continue
            }
            if Coerce.compare(vals[m], key) <= 0 { found = m; lo = mid + 1 } else { hi = m - 1 }
        }
        // Prefer the last of equal runs.
        if let f = found {
            var k = f
            while k + 1 < vals.count && sameType(vals[k + 1], key) && Coerce.compare(vals[k + 1], key) == 0 { k += 1 }
            return k
        }
        return nil
    }

    static func approxDescending(_ key: SheetValue, _ vals: [SheetValue]) -> Int? {
        var found: Int?
        for (i, v) in vals.enumerated() where sameType(v, key) {
            if Coerce.compare(v, key) >= 0 { found = i } else { break }
        }
        return found
    }

    static func exact(_ key: SheetValue, _ vals: [SheetValue], wildcard: Bool = true, reverse: Bool = false) -> Int? {
        let idx = reverse ? Array(vals.indices.reversed()) : Array(vals.indices)
        return idx.first { equal(key, vals[$0], wildcard: wildcard) }
    }

    /// XMATCH/XLOOKUP core.
    static func xmatch(_ key: SheetValue, _ vals: [SheetValue], mode: Int, search: Int) throws -> Int? {
        guard [-1, 0, 1, 2, 3].contains(mode), [-2, -1, 1, 2].contains(search) else { throw XLError.value }
        if case .error(let e) = key { throw XLError(e) }
        if mode == 3 {
            let rx = try? NSRegularExpression(pattern: key.text)
            guard let rx else { throw XLError.value }
            let order = search < 0 ? Array(vals.indices.reversed()) : Array(vals.indices)
            return order.first { i in
                let t = vals[i].text
                return rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
            }
        }
        if abs(search) == 2 {
            // Binary search on sorted data.
            var lo = 0, hi = vals.count - 1, best: Int?
            let asc = search == 2
            while lo <= hi {
                let mid = (lo + hi) / 2
                let c = Coerce.compare(vals[mid], key) * (asc ? 1 : -1)
                if c == 0 && sameType(vals[mid], key) { return mid }
                if c < 0 {
                    if mode == -1 && asc || mode == 1 && !asc { best = mid }
                    lo = mid + 1
                } else {
                    if mode == 1 && asc || mode == -1 && !asc { best = mid }
                    hi = mid - 1
                }
            }
            return mode == 0 ? nil : best
        }
        let order = search == -1 ? Array(vals.indices.reversed()) : Array(vals.indices)
        if let i = order.first(where: { equal(key, vals[$0], wildcard: mode == 2) }) { return i }
        guard mode == -1 || mode == 1 else { return nil }
        var best: Int?
        for i in order where sameType(vals[i], key) {
            let c = Coerce.compare(vals[i], key)
            if mode == -1 && c < 0 && (best == nil || Coerce.compare(vals[i], vals[best!]) > 0) { best = i }
            if mode == 1 && c > 0 && (best == nil || Coerce.compare(vals[i], vals[best!]) < 0) { best = i }
        }
        return best
    }
}

enum LookupFunctions {
    static func register(_ r: inout Registry) {
        r.raw("ROW", max: 1) { a in
            if !a.has(0) { return .number(Double((a.ctx.cell?.row ?? 0) + 1)) }
            guard let ref = a.ref(0) else { throw XLError.value }
            let rows = (ref.range.start.row...ref.range.end.row).map { SheetValue.number(Double($0 + 1)) }
            return rows.count == 1 ? rows[0] : .array(.column(rows))
        }
        r.raw("COLUMN", max: 1) { a in
            if !a.has(0) { return .number(Double((a.ctx.cell?.col ?? 0) + 1)) }
            guard let ref = a.ref(0) else { throw XLError.value }
            let cols = (ref.range.start.col...ref.range.end.col).map { SheetValue.number(Double($0 + 1)) }
            return cols.count == 1 ? cols[0] : .array(.row(cols))
        }
        r.raw("ROWS", min: 1, max: 1) { a in
            if let ref = a.ref(0) { return .number(Double(ref.range.end.row - ref.range.start.row + 1)) }
            return .number(Double(try a.matrix(0).rows))
        }
        r.raw("COLUMNS", min: 1, max: 1) { a in
            if let ref = a.ref(0) { return .number(Double(ref.range.end.col - ref.range.start.col + 1)) }
            return .number(Double(try a.matrix(0).cols))
        }
        r.raw("AREAS", min: 1, max: 1) { a in
            guard a.ref(0) != nil else { throw XLError.value }
            return .number(1)
        }
        r.scalar("ADDRESS", min: 2, max: 5) { s in
            let row = try s.int(0), col = try s.int(1), abs = try s.int(2, 1), a1 = try s.bool(3, true)
            guard row >= 1, row <= 1_048_576, col >= 1, col <= 16384, (1...4).contains(abs) else { throw XLError.value }
            var text: String
            if a1 {
                let c = (abs == 1 || abs == 3 ? "$" : "") + CellRef.columnName(col - 1)
                let rr = (abs == 1 || abs == 2 ? "$" : "") + String(row)
                text = c + rr
            } else {
                let rr = abs == 1 || abs == 2 ? "R\(row)" : "R[\(row)]"
                let cc = abs == 1 || abs == 3 ? "C\(col)" : "C[\(col)]"
                text = rr + cc
            }
            if s.has(4) {
                let sheet = try s.str(4)
                let needsQuote = sheet.contains { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
                text = (needsQuote ? "'" + sheet.replacingOccurrences(of: "'", with: "''") + "'" : sheet) + "!" + text
            }
            return .string(text)
        }
        r.raw("CHOOSE", min: 2) { a in
            let idx = a.value(0)
            if case .array(let m) = idx {
                return .array(m.map { v in
                    guard let i = try? X.int(v), i >= 1, i < a.count else { return .error("#VALUE!") }
                    return a.value(i).scalar
                })
            }
            let i = try X.int(idx)
            guard i >= 1, i < a.count else { throw XLError.value }
            return a.has(i) ? a.value(i) : .number(0)
        }
        r.table["VLOOKUP"] = { a in try vhlookup(a, vertical: true) }
        r.table["HLOOKUP"] = { a in try vhlookup(a, vertical: false) }
        r.raw("LOOKUP", min: 2, max: 3) { a in
            var keys: [SheetValue], results: [SheetValue]
            let lm = try a.matrix(1)
            if a.has(2) {
                keys = lm.data
                results = try a.matrix(2).data
            } else if lm.cols > lm.rows {
                keys = lm.rowValues(0); results = lm.rowValues(lm.rows - 1)
            } else {
                keys = lm.colValues(0); results = lm.colValues(lm.cols - 1)
            }
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
                let key = s.raw(0)
                if case .error(let e) = key { throw XLError(e) }
                guard let i = Lookup.approxAscending(key, keys) else { throw XLError.na }
                guard i < results.count else { throw XLError.na }
                return results[i]
            }
        }
        r.raw("MATCH", min: 2, max: 3) { a in
            let m = try a.matrix(1)
            guard m.rows == 1 || m.cols == 1 else { throw XLError.na }
            let vals = m.data
            let type = try a.int(2, 1)
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
                let key = s.raw(0)
                if case .error(let e) = key { throw XLError(e) }
                let i: Int?
                if type == 0 { i = Lookup.exact(key, vals) }
                else if type > 0 { i = Lookup.approxAscending(key, vals) }
                else { i = Lookup.approxDescending(key, vals) }
                guard let i else { throw XLError.na }
                return .number(Double(i + 1))
            }
        }
        r.raw("XMATCH", min: 2, max: 4) { a in
            let m = try a.matrix(1)
            guard m.rows == 1 || m.cols == 1 else { throw XLError.value }
            let mode = try a.int(2, 0), search = try a.int(3, 1)
            return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0))]), lifted: nil) { s in
                guard let i = try Lookup.xmatch(s.raw(0), m.data, mode: mode, search: search) else { throw XLError.na }
                return .number(Double(i + 1))
            }
        }
        r.raw("XLOOKUP", min: 3, max: 6) { a in try xlookup(a) }
        r.raw("INDEX", min: 1, max: 4) { a in
            if let ref = indexRef(a) { return a.engine.rangeValue(ref) }
            let m = try a.matrix(0)
            let row = try a.int(1, 0), col = try a.int(2, 0)
            guard row >= 0, col >= 0 else { throw XLError.value }
            if !a.has(2) && (m.rows == 1 || m.cols == 1) && a.has(1) && row > 0 {
                guard row <= m.data.count else { throw XLError.ref }
                return m.data[row - 1]
            }
            if row == 0 && col == 0 { return .array(m) }
            if row == 0 { guard col <= m.cols else { throw XLError.ref }; return .array(.column(m.colValues(col - 1))) }
            if col == 0 && m.cols > 1 { guard row <= m.rows else { throw XLError.ref }; return .array(.row(m.rowValues(row - 1))) }
            let c = max(col, 1)
            guard row <= m.rows, c <= m.cols else { throw XLError.ref }
            return m[row - 1, c - 1]
        }
        r.raw("OFFSET", min: 3, max: 5) { a in
            guard let ref = offset(a) else { throw XLError.ref }
            return a.engine.rangeValue(ref)
        }
        r.raw("INDIRECT", min: 1, max: 2) { a in
            guard let ref = indirect(a) else { throw XLError.ref }
            return a.engine.rangeValue(ref)
        }
        r.raw("TRIMRANGE", min: 1, max: 3) { a in
            guard let ref = trimRange(a) else {
                if a.ref(0) != nil { return .error("#REF!") }
                throw XLError.value
            }
            return a.engine.rangeValue(ref)
        }
        r.raw("TRANSPOSE", min: 1, max: 1) { a in .array(a.grid(0).transposed) }
        r.raw("HYPERLINK", min: 1, max: 2) { a in a.has(1) ? a.value(1) : a.value(0) }
        r.raw("GETPIVOTDATA", min: 2) { _ in throw XLError.ref }
        r.raw("RTD", min: 3) { _ in throw XLError.na }
    }

    static func vhlookup(_ a: Args, vertical: Bool) throws -> SheetValue {
        guard a.count >= 3, a.count <= 4 else { throw XLError.value }
        let table = try a.matrix(1)
        let approx = a.has(3) ? try X.bool(a.value(3)) : true
        return Lift.apply(Args(engine: a.engine, ctx: a.ctx, exprs: [.value(a.value(0)), .value(a.value(2))]), lifted: nil) { s in
            let key = s.raw(0)
            if case .error(let e) = key { throw XLError(e) }
            let idx = try s.int(1)
            guard idx >= 1 else { throw XLError.value }
            guard idx <= (vertical ? table.cols : table.rows) else { throw XLError.ref }
            let keys = vertical ? table.colValues(0) : table.rowValues(0)
            let i = approx ? Lookup.approxAscending(key, keys) : Lookup.exact(key, keys)
            guard let i else { throw XLError.na }
            let v = vertical ? table[i, idx - 1] : table[idx - 1, i]
            return v
        }
    }

    static func xlookup(_ a: Args) throws -> SheetValue {
        let look = try a.matrix(1), ret = try a.matrix(2)
        guard look.rows == 1 || look.cols == 1 else { throw XLError.value }
        let vertical = look.cols == 1
        let n = look.data.count
        if vertical { guard ret.rows == n else { throw XLError.value } } else { guard ret.cols == n else { throw XLError.value } }
        let mode = try a.int(4, 0), search = try a.int(5, 1)
        let notFound: SheetValue? = a.has(3) ? a.value(3) : nil
        let key = a.value(0)
        func one(_ k: SheetValue) throws -> SheetValue {
            guard let i = try Lookup.xmatch(k, look.data, mode: mode, search: search) else {
                if let notFound { return notFound }
                throw XLError.na
            }
            if vertical { return ret.cols == 1 ? ret[i, 0] : .array(.row(ret.rowValues(i))) }
            return ret.rows == 1 ? ret[0, i] : .array(.column(ret.colValues(i)))
        }
        if case .array(let km) = key {
            return .array(km.map { k in
                do { return LogicalFunctions.cell(try one(k)) } catch let e as XLError { return .error(e.code) } catch { return .error("#VALUE!") }
            })
        }
        return try one(key)
    }

    static func xlookupRef(_ a: Args) -> Ref? {
        if case .array = a.value(0) { return nil }
        guard let retRef = a.ref(2), let look = try? a.matrix(1), look.rows == 1 || look.cols == 1 else { return nil }
        let mode = (try? a.int(4, 0)) ?? 0, search = (try? a.int(5, 1)) ?? 1
        guard let i = (try? Lookup.xmatch(a.value(0), look.data, mode: mode, search: search)) ?? nil else { return nil }
        let s = retRef.range.start, e = retRef.range.end
        if look.cols == 1 {
            return Ref(sheet: retRef.sheet, range: CellRange(CellRef(row: s.row + i, col: s.col), CellRef(row: s.row + i, col: e.col)))
        }
        return Ref(sheet: retRef.sheet, range: CellRange(CellRef(row: s.row, col: s.col + i), CellRef(row: e.row, col: s.col + i)))
    }

    static func indexRef(_ a: Args) -> Ref? {
        guard let base = a.ref(0) else { return nil }
        let rows = base.range.end.row - base.range.start.row + 1, cols = base.range.end.col - base.range.start.col + 1
        guard let row = try? a.int(1, 0), let col = try? a.int(2, 0), row >= 0, col >= 0 else { return nil }
        if case .array = a.value(1) { return nil }
        if a.has(2), case .array = a.value(2) { return nil }
        var r = row, c = col
        if !a.has(2) && rows == 1 && cols > 1 { c = row; r = 0 }
        if !a.has(2) && cols == 1 { c = 1 }
        guard r <= rows, c <= cols else { return nil }
        let s = base.range.start
        let r0 = r == 0 ? s.row : s.row + r - 1, r1 = r == 0 ? base.range.end.row : r0
        let c0 = c == 0 ? s.col : s.col + c - 1, c1 = c == 0 ? base.range.end.col : c0
        return Ref(sheet: base.sheet, range: CellRange(CellRef(row: r0, col: c0), CellRef(row: r1, col: c1)))
    }

    static func offset(_ a: Args) -> Ref? {
        guard let base = a.ref(0), let dr = try? a.int(1), let dc = try? a.int(2) else { return nil }
        let h0 = base.range.end.row - base.range.start.row + 1, w0 = base.range.end.col - base.range.start.col + 1
        guard let h = try? a.int(3, h0), let w = try? a.int(4, w0), h != 0, w != 0 else { return nil }
        let r0 = base.range.start.row + dr, c0 = base.range.start.col + dc
        let rs = h > 0 ? r0 : r0 + h + 1, cs = w > 0 ? c0 : c0 + w + 1
        guard rs >= 0, cs >= 0 else { return nil }
        return Ref(sheet: base.sheet, range: CellRange(CellRef(row: rs, col: cs), CellRef(row: rs + abs(h) - 1, col: cs + abs(w) - 1)))
    }

    static func indirect(_ a: Args) -> Ref? {
        guard let text = try? a.str(0) else { return nil }
        let a1 = (try? a.bool(1, true)) ?? true
        var t = text.trimmingCharacters(in: .whitespaces)
        if !a1 { t = r1c1ToA1(t, a.ctx.cell ?? CellRef(row: 0, col: 0)) ?? t }
        guard let expr = FormulaParser.parse(t) else { return nil }
        switch expr {
        case .ref, .range, .cols, .rows, .name, .binary(":", _, _): return a.engine.evalRef(expr, a.ctx)
        default: return nil
        }
    }

    static func r1c1ToA1(_ s: String, _ base: CellRef) -> String? {
        var sheet = ""
        var body = s
        if let bang = s.lastIndex(of: "!") { sheet = String(s[...bang]); body = String(s[s.index(after: bang)...]) }
        func one(_ part: String) -> String? {
            let rx = try! NSRegularExpression(pattern: #"^R(\[-?\d+\]|\d+)?C(\[-?\d+\]|\d+)?$"#, options: .caseInsensitive)
            let ns = part as NSString
            guard let m = rx.firstMatch(in: part, range: NSRange(location: 0, length: ns.length)) else { return nil }
            func val(_ i: Int, _ cur: Int) -> Int {
                guard m.range(at: i).location != NSNotFound else { return cur }
                let t = ns.substring(with: m.range(at: i))
                if t.hasPrefix("[") { return cur + (Int(t.dropFirst().dropLast()) ?? 0) }
                return (Int(t) ?? 1) - 1
            }
            let r = val(1, base.row), c = val(2, base.col)
            guard r >= 0, c >= 0 else { return nil }
            return CellRef(row: r, col: c).a1
        }
        let parts = body.split(separator: ":").map(String.init)
        let conv = parts.compactMap(one)
        guard conv.count == parts.count else { return nil }
        return sheet + conv.joined(separator: ":")
    }

    static func trimRange(_ a: Args) -> Ref? {
        guard let base = a.ref(0) else { return nil }
        let tr = (try? a.int(1, 3)) ?? 3, tc = (try? a.int(2, 3)) ?? 3
        guard (0...3).contains(tr), (0...3).contains(tc) else { return nil }
        var r = base.range
        // Clamp to the sheet's used extent first (whole-column references).
        func blank(_ ref: CellRef) -> Bool {
            if case .empty = a.engine.value(base.sheet, ref) { return true }
            return false
        }
        func rowBlank(_ row: Int) -> Bool { (r.start.col...r.end.col).allSatisfy { blank(CellRef(row: row, col: $0)) } }
        func colBlank(_ col: Int) -> Bool { (r.start.row...r.end.row).allSatisfy { blank(CellRef(row: $0, col: col)) } }
        if tr & 1 != 0 { while r.start.row < r.end.row && rowBlank(r.start.row) { r.start.row += 1 } }
        if tr & 2 != 0 { while r.end.row > r.start.row && rowBlank(r.end.row) { r.end.row -= 1 } }
        if tc & 1 != 0 { while r.start.col < r.end.col && colBlank(r.start.col) { r.start.col += 1 } }
        if tc & 2 != 0 { while r.end.col > r.start.col && colBlank(r.end.col) { r.end.col -= 1 } }
        return Ref(sheet: base.sheet, range: r)
    }
}
