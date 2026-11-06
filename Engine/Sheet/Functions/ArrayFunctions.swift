import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ArrayFunctions {
    /// Sort comparison: numbers < text < logicals < errors; blanks always last.
    static func sortCompare(_ a: SheetValue, _ b: SheetValue) -> Int {
        let ea: Bool = { if case .empty = a { return true }; return false }()
        let eb: Bool = { if case .empty = b { return true }; return false }()
        if ea || eb { return ea == eb ? 0 : (ea ? 1 : -1) }
        return Coerce.compare(a, b)
    }

    static func rowsEqual(_ a: [SheetValue], _ b: [SheetValue]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            if case .string(let s) = x, case .string(let t) = y { return s.caseInsensitiveCompare(t) == .orderedSame }
            return x == y
        }
    }

    static func register(_ r: inout Registry) {
        r.raw("FILTER", min: 2, max: 3) { a in
            let m = a.grid(0), inc = a.grid(1)
            var keep: [Bool]
            let byRows: Bool
            if inc.cols == 1 && inc.rows == m.rows { byRows = true }
            else if inc.rows == 1 && inc.cols == m.cols { byRows = false }
            else { throw XLError.value }
            keep = try inc.data.map { v in
                if case .error(let e) = v { throw XLError(e) }
                guard let b = v.truthy else { throw XLError.value }
                return b
            }
            guard keep.contains(true) else {
                if a.has(2) { return a.value(2) }
                throw XLError.calc
            }
            let out = byRows ? Matrix((0..<m.rows).filter { keep[$0] }.map(m.rowValues))
                             : Matrix((0..<m.rows).map { r in (0..<m.cols).filter { keep[$0] }.map { m[r, $0] } })
            return .array(out)
        }
        r.raw("SORT", min: 1, max: 4) { a in
            let m = a.grid(0)
            let byCol = try a.bool(3, false)
            let idx = a.has(1) ? try a.matrix(1).data.map { try X.int($0) } : [1]
            let ord = a.has(2) ? try a.matrix(2).data.map { try X.int($0) } : [1]
            guard ord.allSatisfy({ $0 == 1 || $0 == -1 }) else { throw XLError.value }
            let work = byCol ? m.transposed : m
            guard idx.allSatisfy({ $0 >= 1 && $0 <= work.cols }) else { throw XLError.value }
            let keys = idx.enumerated().map { ($0.element - 1, ord.count == 1 ? ord[0] : (ord[safe: $0.offset] ?? 1)) }
            let sorted = (0..<work.rows).sorted { x, y in
                for (k, o) in keys {
                    let c = sortCompare(work[x, k], work[y, k])
                    if c != 0 { return c * o < 0 }
                }
                return x < y
            }
            let out = Matrix(sorted.map(work.rowValues))
            return .array(byCol ? out.transposed : out)
        }
        r.raw("SORTBY", min: 2) { a in
            let m = a.grid(0)
            var keys: [(Matrix, Int)] = []
            var i = 1
            while i < a.count {
                let k = a.grid(i)
                let o = i + 1 < a.count && a.has(i + 1) ? try X.int(a.value(i + 1)) : 1
                guard o == 1 || o == -1 else { throw XLError.value }
                keys.append((k, o)); i += 2
            }
            guard let first = keys.first?.0 else { throw XLError.value }
            let byRows = first.cols == 1 && first.rows == m.rows
            guard byRows || (first.rows == 1 && first.cols == m.cols) else { throw XLError.value }
            for (k, _) in keys where !(byRows ? (k.cols == 1 && k.rows == m.rows) : (k.rows == 1 && k.cols == m.cols)) { throw XLError.value }
            let n = byRows ? m.rows : m.cols
            let order = (0..<n).sorted { x, y in
                for (k, o) in keys {
                    let c = sortCompare(k.data[x], k.data[y])
                    if c != 0 { return c * o < 0 }
                }
                return x < y
            }
            if byRows { return .array(Matrix(order.map(m.rowValues))) }
            return .array(Matrix((0..<m.rows).map { r in order.map { m[r, $0] } }))
        }
        r.raw("UNIQUE", min: 1, max: 3) { a in
            let m = a.grid(0)
            let byCol = try a.bool(1, false), once = try a.bool(2, false)
            let work = byCol ? m.transposed : m
            var groups: [([SheetValue], Int)] = []
            for r in 0..<work.rows {
                let row = work.rowValues(r)
                if let i = groups.firstIndex(where: { rowsEqual($0.0, row) }) { groups[i].1 += 1 } else { groups.append((row, 1)) }
            }
            let picked = groups.filter { !once || $0.1 == 1 }.map(\.0)
            guard !picked.isEmpty else { throw XLError.calc }
            let out = Matrix(picked)
            return .array(byCol ? out.transposed : out)
        }
        r.raw("TAKE", min: 2, max: 3) { a in
            let m = a.grid(0)
            let rows = a.has(1) ? try a.int(1) : m.rows, cols = a.has(2) ? try a.int(2) : m.cols
            guard rows != 0, cols != 0 else { throw XLError.calc }
            let rr = rows > 0 ? Array(0..<min(rows, m.rows)) : Array(max(0, m.rows + rows)..<m.rows)
            let cc = cols > 0 ? Array(0..<min(cols, m.cols)) : Array(max(0, m.cols + cols)..<m.cols)
            return .array(Matrix(rr.map { r in cc.map { m[r, $0] } }))
        }
        r.raw("DROP", min: 2, max: 3) { a in
            let m = a.grid(0)
            let rows = try a.int(1, 0), cols = try a.int(2, 0)
            let rr = rows >= 0 ? Array(min(rows, m.rows)..<m.rows) : Array(0..<max(0, m.rows + rows))
            let cc = cols >= 0 ? Array(min(cols, m.cols)..<m.cols) : Array(0..<max(0, m.cols + cols))
            guard !rr.isEmpty, !cc.isEmpty else { throw XLError.calc }
            return .array(Matrix(rr.map { r in cc.map { m[r, $0] } }))
        }
        r.raw("EXPAND", min: 2, max: 4) { a in
            let m = a.grid(0)
            let rows = a.has(1) ? try a.int(1) : m.rows, cols = a.has(2) ? try a.int(2) : m.cols
            guard rows >= m.rows, cols >= m.cols else { throw XLError.value }
            let pad: SheetValue = a.has(3) ? a.value(3).scalar : .error("#N/A")
            var out = Matrix(rows: rows, cols: cols, fill: pad)
            for r in 0..<m.rows { for c in 0..<m.cols { out[r, c] = m[r, c] } }
            return .array(out)
        }
        r.raw("CHOOSEROWS", min: 2) { a in
            let m = a.grid(0)
            var rows: [Int] = []
            for v in a.flat(from: 1) {
                let n = try X.int(v)
                guard n != 0, abs(n) <= m.rows else { throw XLError.value }
                rows.append(n > 0 ? n - 1 : m.rows + n)
            }
            return .array(Matrix(rows.map(m.rowValues)))
        }
        r.raw("CHOOSECOLS", min: 2) { a in
            let m = a.grid(0)
            var cols: [Int] = []
            for v in a.flat(from: 1) {
                let n = try X.int(v)
                guard n != 0, abs(n) <= m.cols else { throw XLError.value }
                cols.append(n > 0 ? n - 1 : m.cols + n)
            }
            return .array(Matrix((0..<m.rows).map { r in cols.map { m[r, $0] } }))
        }
        r.raw("VSTACK", min: 1) { a in
            let ms = (0..<a.count).map { a.grid($0) }
            let width = ms.map(\.cols).max() ?? 0
            var rows: [[SheetValue]] = []
            for m in ms { for r in 0..<m.rows { rows.append(m.rowValues(r) + Array(repeating: .error("#N/A"), count: width - m.cols)) } }
            return .array(Matrix(rows))
        }
        r.raw("HSTACK", min: 1) { a in
            let ms = (0..<a.count).map { a.grid($0) }
            let height = ms.map(\.rows).max() ?? 0
            var rows = [[SheetValue]](repeating: [], count: height)
            for m in ms {
                for r in 0..<height { rows[r] += r < m.rows ? m.rowValues(r) : Array(repeating: .error("#N/A"), count: m.cols) }
            }
            return .array(Matrix(rows))
        }
        func flatten(_ a: Args, column: Bool) throws -> SheetValue {
            let m = a.grid(0)
            let ignore = try a.int(1, 0), byCol = try a.bool(2, false)
            guard (0...3).contains(ignore) else { throw XLError.value }
            var vals: [SheetValue] = []
            let order: [(Int, Int)] = byCol ? (0..<m.cols).flatMap { c in (0..<m.rows).map { ($0, c) } }
                                            : (0..<m.rows).flatMap { r in (0..<m.cols).map { (r, $0) } }
            for (r, c) in order {
                let v = m[r, c]
                if ignore & 1 != 0, case .empty = v { continue }
                if ignore & 2 != 0, v.isError { continue }
                vals.append(v)
            }
            guard !vals.isEmpty else { throw XLError.calc }
            return .array(column ? .column(vals) : .row(vals))
        }
        r.raw("TOCOL", min: 1, max: 3) { a in try flatten(a, column: true) }
        r.raw("TOROW", min: 1, max: 3) { a in try flatten(a, column: false) }
        func wrap(_ a: Args, rowsFirst: Bool) throws -> SheetValue {
            let m = a.grid(0)
            guard m.rows == 1 || m.cols == 1 else { throw XLError.value }
            let n = try a.int(1)
            guard n >= 1 else { throw XLError.num }
            let pad: SheetValue = a.has(2) ? a.value(2).scalar : .error("#N/A")
            let count = (m.data.count + n - 1) / n
            var out = rowsFirst ? Matrix(rows: count, cols: n, fill: pad) : Matrix(rows: n, cols: count, fill: pad)
            for (i, v) in m.data.enumerated() {
                if rowsFirst { out[i / n, i % n] = v } else { out[i % n, i / n] = v }
            }
            return .array(out)
        }
        r.raw("WRAPROWS", min: 2, max: 3) { a in try wrap(a, rowsFirst: true) }
        r.raw("WRAPCOLS", min: 2, max: 3) { a in try wrap(a, rowsFirst: false) }
        r.raw("GROUPBY", min: 3, max: 8) { a in try Pivot.groupBy(a) }
        r.raw("PIVOTBY", min: 4, max: 11) { a in try Pivot.pivotBy(a) }
    }
}

/// GROUPBY / PIVOTBY aggregation.
enum Pivot {
    struct Key: Hashable {
        let parts: [String]
        let values: [SheetValue]
        static func == (a: Key, b: Key) -> Bool { a.parts == b.parts }
        func hash(into h: inout Hasher) { h.combine(parts) }
    }

    static func key(_ row: [SheetValue]) -> Key {
        Key(parts: row.map { v in
            switch v {
            case .string(let s): return "s" + s.lowercased()
            case .number(let d): return "n" + String(d)
            case .bool(let b): return "b" + (b ? "1" : "0")
            case .error(let e): return "e" + e
            default: return "_"
            }
        }, values: row)
    }

    static func compareKeys(_ a: Key, _ b: Key) -> Int {
        for (x, y) in zip(a.values, b.values) {
            let c = ArrayFunctions.sortCompare(x, y)
            if c != 0 { return c }
        }
        return 0
    }

    /// Splits header row off when requested or auto-detected.
    static func headers(_ mode: Int?, _ fields: Matrix, _ values: Matrix) -> (Bool, Bool) {
        if let mode { return (mode == 1 || mode == 3, mode >= 2) }
        let firstText = values.rows > 1 && values.rowValues(0).allSatisfy(\.isText)
        let secondNumeric = values.rows > 1 && values.rowValues(1).contains(where: \.isNumber)
        let detected = firstText && secondNumeric
        return (detected, detected)
    }

    static func apply(_ a: Args, _ fn: LambdaValue, _ vals: [SheetValue]) -> SheetValue {
        LogicalFunctions.cell(a.engine.callLambda(fn, [.array(.column(vals.isEmpty ? [.empty] : vals))]))
    }

    static func groupBy(_ a: Args) throws -> SheetValue {
        var fields = a.grid(0), values = a.grid(1)
        let fn = try a.lambda(2)
        guard fields.rows == values.rows else { throw XLError.value }
        let (hasHeader, showHeader) = headers(a.has(3) ? try a.int(3) : nil, fields, values)
        var fieldNames: [SheetValue] = [], valueNames: [SheetValue] = []
        if hasHeader {
            fieldNames = fields.rowValues(0); valueNames = values.rowValues(0)
            fields = Matrix((1..<fields.rows).map(fields.rowValues)); values = Matrix((1..<values.rows).map(values.rowValues))
        } else if showHeader {
            fieldNames = (0..<fields.cols).map { .string("Row Field \($0 + 1)") }
            valueNames = (0..<values.cols).map { .string("Value \($0 + 1)") }
        }
        let totalDepth = try a.int(4, 1)
        let sortOrder = a.has(5) ? try a.int(5) : 1
        var keep = [Bool](repeating: true, count: fields.rows)
        if a.has(6) {
            let f = a.grid(6)
            guard f.data.count == fields.rows else { throw XLError.value }
            keep = f.data.map { $0.truthy ?? false }
        }
        var order: [Key] = []
        var bucket: [Key: [Int]] = [:]
        for r in 0..<fields.rows where keep[r] {
            let k = key(fields.rowValues(r))
            if bucket[k] == nil { order.append(k) }
            bucket[k, default: []].append(r)
        }
        // Sort by the chosen column (key columns first, then value columns).
        let sortIdx = abs(sortOrder) - 1
        var rows: [(Key, [SheetValue])] = order.map { k in
            let idx = bucket[k]!
            let aggs = (0..<values.cols).map { c in apply(a, fn, idx.map { values[$0, c] }) }
            return (k, aggs)
        }
        if sortOrder != 0 {
            rows.sort { x, y in
                let c: Int
                if sortIdx < fields.cols { c = ArrayFunctions.sortCompare(x.0.values[sortIdx], y.0.values[sortIdx]) }
                else { c = ArrayFunctions.sortCompare(x.1[safe: sortIdx - fields.cols] ?? .empty, y.1[safe: sortIdx - fields.cols] ?? .empty) }
                if c == 0 { return compareKeys(x.0, y.0) < 0 }
                return sortOrder > 0 ? c < 0 : c > 0
            }
        }
        var out: [[SheetValue]] = []
        if showHeader { out.append(fieldNames + valueNames) }
        var body = rows.map { $0.0.values + $0.1 }
        // Subtotals for the first key level when depth ≥ 2 and multiple key columns.
        if abs(totalDepth) >= 2 && fields.cols > 1 {
            var withSub: [[SheetValue]] = []
            var i = 0
            while i < rows.count {
                let head = rows[i].0.values[0]
                var j = i
                var idx: [Int] = []
                while j < rows.count && key([rows[j].0.values[0]]) == key([head]) { idx += bucket[rows[j].0]!; j += 1 }
                let sub = [head] + Array(repeating: SheetValue.empty, count: fields.cols - 1) + (0..<values.cols).map { c in apply(a, fn, idx.map { values[$0, c] }) }
                if totalDepth < 0 { withSub.append(sub) }
                withSub += rows[i..<j].map { $0.0.values + $0.1 }
                if totalDepth > 0 { withSub.append(sub) }
                i = j
            }
            body = withSub
        }
        let allIdx = order.flatMap { bucket[$0]! }
        let total = [SheetValue.string("Total")] + Array(repeating: SheetValue.empty, count: max(0, fields.cols - 1))
            + (0..<values.cols).map { c in apply(a, fn, allIdx.map { values[$0, c] }) }
        if totalDepth < 0 { out.append(total) }
        out += body
        if totalDepth > 0 { out.append(total) }
        guard !out.isEmpty else { throw XLError.calc }
        return .array(Matrix(out))
    }

    static func pivotBy(_ a: Args) throws -> SheetValue {
        var rf = a.grid(0), cf = a.grid(1), values = a.grid(2)
        let fn = try a.lambda(3)
        guard rf.rows == values.rows, cf.rows == values.rows else { throw XLError.value }
        let (hasHeader, _) = headers(a.has(4) ? try a.int(4) : nil, rf, values)
        if hasHeader {
            rf = Matrix((1..<rf.rows).map(rf.rowValues)); cf = Matrix((1..<cf.rows).map(cf.rowValues))
            values = Matrix((1..<values.rows).map(values.rowValues))
        }
        let rowTotal = try a.int(5, 1), rowSort = a.has(6) ? try a.int(6) : 1
        let colTotal = try a.int(7, 1), colSort = a.has(8) ? try a.int(8) : 1
        var keep = [Bool](repeating: true, count: rf.rows)
        if a.has(9) { keep = a.grid(9).data.map { $0.truthy ?? false } }
        var rowKeys: [Key] = [], colKeys: [Key] = []
        var cellsIdx: [Key: [Key: [Int]]] = [:]
        for r in 0..<rf.rows where keep[safe: r] ?? true {
            let rk = key(rf.rowValues(r)), ck = key(cf.rowValues(r))
            if !rowKeys.contains(rk) { rowKeys.append(rk) }
            if !colKeys.contains(ck) { colKeys.append(ck) }
            cellsIdx[rk, default: [:]][ck, default: []].append(r)
        }
        if rowSort != 0 { rowKeys.sort { rowSort > 0 ? compareKeys($0, $1) < 0 : compareKeys($0, $1) > 0 } }
        if colSort != 0 { colKeys.sort { colSort > 0 ? compareKeys($0, $1) < 0 : compareKeys($0, $1) > 0 } }
        let vcols = values.cols
        func agg(_ idx: [Int]) -> [SheetValue] { (0..<vcols).map { c in apply(a, fn, idx.map { values[$0, c] }) } }
        let rowLevels = rf.cols, colLevels = cf.cols
        var out: [[SheetValue]] = []
        // Header rows: one per column-key level.
        for level in 0..<colLevels {
            var line = Array(repeating: SheetValue.empty, count: rowLevels)
            for ck in colKeys { line += [ck.values[level]] + Array(repeating: .empty, count: vcols - 1) }
            if colTotal != 0 { line += [level == 0 ? .string("Total") : .empty] + Array(repeating: .empty, count: vcols - 1) }
            out.append(line)
        }
        var bodyRows: [[SheetValue]] = []
        for rk in rowKeys {
            var line = rk.values
            var all: [Int] = []
            for ck in colKeys {
                let idx = cellsIdx[rk]?[ck] ?? []
                all += idx
                line += idx.isEmpty ? Array(repeating: .empty, count: vcols) : agg(idx)
            }
            if colTotal != 0 { line += agg(all) }
            bodyRows.append(line)
        }
        var totalLine = [SheetValue.string("Total")] + Array(repeating: .empty, count: rowLevels - 1)
        var everything: [Int] = []
        for ck in colKeys {
            let idx = rowKeys.flatMap { cellsIdx[$0]?[ck] ?? [] }
            everything += idx
            totalLine += agg(idx)
        }
        if colTotal != 0 { totalLine += agg(everything) }
        if rowTotal < 0 { out.append(totalLine) }
        out += bodyRows
        if rowTotal > 0 { out.append(totalLine) }
        return .array(Matrix(out))
    }
}
