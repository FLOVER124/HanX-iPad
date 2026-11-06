import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LogicalFunctions {
    /// Logical values for AND/OR/XOR: references and arrays contribute
    /// booleans and numbers only; direct text must read TRUE/FALSE.
    static func logicals(_ a: Args) throws -> [Bool] {
        var out: [Bool] = []
        for i in 0..<a.count where a.has(i) {
            let v = a.value(i)
            if case .array(let m) = v {
                for x in m.data {
                    switch x {
                    case .bool(let b): out.append(b)
                    case .number(let d): out.append(d != 0)
                    case .error(let e): throw XLError(e)
                    default: break
                    }
                }
            } else if a.isRef(i) {
                switch v {
                case .bool(let b): out.append(b)
                case .number(let d): out.append(d != 0)
                case .error(let e): throw XLError(e)
                default: break
                }
            } else {
                out.append(try X.bool(v))
            }
        }
        guard !out.isEmpty else { throw XLError.value }
        return out
    }

    static func register(_ r: inout Registry) {
        r.raw("TRUE", max: 0) { _ in .bool(true) }
        r.raw("FALSE", max: 0) { _ in .bool(false) }
        r.raw("AND", min: 1) { a in .bool(try logicals(a).allSatisfy { $0 }) }
        r.raw("OR", min: 1) { a in .bool(try logicals(a).contains(true)) }
        r.raw("XOR", min: 1) { a in .bool(try logicals(a).filter { $0 }.count % 2 == 1) }
        r.scalar("NOT", min: 1, max: 1) { s in .bool(!(try s.bool(0))) }

        r.raw("IF", min: 1, max: 3) { a in
            let cond = a.value(0)
            func branch(_ i: Int, _ dflt: SheetValue) -> SheetValue {
                if i < a.count { return a.has(i) ? a.value(i) : .number(0) }
                return dflt
            }
            if case .array(let m) = cond {
                let t = branch(1, .bool(true)), f = branch(2, .bool(false))
                return Broadcast.map2(.array(m), Broadcast.map2(t, f) { x, y in .array(Matrix([[x, y]])) }) { c, pair in
                    guard case .array(let p) = pair else { return .error("#VALUE!") }
                    if case .error = c { return c }
                    guard let b = c.truthy else { return .error("#VALUE!") }
                    return b ? p.data[0] : p.data[1]
                }
            }
            if case .error(let e) = cond { throw XLError(e) }
            guard let b = cond.truthy else { throw XLError.value }
            return b ? branch(1, .bool(true)) : branch(2, .bool(false))
        }
        r.raw("IFS", min: 2) { a in
            guard a.count % 2 == 0 else { throw XLError.na }
            for i in stride(from: 0, to: a.count, by: 2) {
                let c = a.value(i)
                if case .error(let e) = c { throw XLError(e) }
                guard let b = c.truthy else { throw XLError.value }
                if b { return a.value(i + 1) }
            }
            throw XLError.na
        }
        r.raw("IFERROR", min: 2, max: 2) { a in
            let v = a.value(0)
            if case .array(let m) = v {
                let alt = a.value(1)
                return .array(m.map { $0.isError ? alt.scalar : $0 })
            }
            return v.isError ? a.value(1) : (v == .empty ? .number(0) : v)
        }
        r.raw("IFNA", min: 2, max: 2) { a in
            let v = a.value(0)
            if case .array(let m) = v {
                let alt = a.value(1)
                return .array(m.map { $0 == .error("#N/A") ? alt.scalar : $0 })
            }
            return v == .error("#N/A") ? a.value(1) : (v == .empty ? .number(0) : v)
        }
        r.raw("SWITCH", min: 3) { a in
            let v = a.value(0)
            if case .error(let e) = v { throw XLError(e) }
            var i = 1
            while i + 1 < a.count {
                let c = a.value(i)
                if Coerce.compare(v, c) == 0 && !(v.isText != c.isText && v != .empty && c != .empty) { return a.value(i + 1) }
                i += 2
            }
            if i < a.count { return a.value(i) }
            throw XLError.na
        }

        // LET and lambda helpers
        r.raw("LET", min: 3) { a in try LambdaFunctions.letValue(a) }
        r.raw("LAMBDA", min: 1) { a in FunctionLibrary.makeLambda(a.exprs, a.ctx) }
        r.raw("ISOMITTED", min: 1, max: 1) { a in
            guard case .name(let n) = a.exprs[0] else { return .bool(false) }
            return .bool(a.ctx.env["__OMITTED__" + FormulaParser.clean(n).uppercased()] != nil)
        }
        r.raw("MAP", min: 2) { a in
            let l = try a.lambda(a.count - 1)
            let arrays = (0..<(a.count - 1)).map { a.grid($0) }
            let rows = arrays.map(\.rows).max()!, cols = arrays.map(\.cols).max()!
            var out = Matrix(rows: rows, cols: cols)
            for r in 0..<rows { for c in 0..<cols {
                let args = arrays.map { Broadcast.pick($0, r, c) ?? .error("#N/A") }
                out[r, c] = cell(a.engine.callLambda(l, args))
            } }
            return .array(out)
        }
        r.raw("REDUCE", min: 3, max: 3) { a in
            var acc = a.value(0)
            let l = try a.lambda(2)
            for v in a.grid(1).data { acc = a.engine.callLambda(l, [acc, v]) }
            return acc
        }
        r.raw("SCAN", min: 3, max: 3) { a in
            var acc = a.value(0)
            let l = try a.lambda(2)
            var m = a.grid(1)
            for i in 0..<m.data.count { acc = a.engine.callLambda(l, [acc, m.data[i]]); m.data[i] = cell(acc) }
            return .array(m)
        }
        r.raw("BYROW", min: 2, max: 2) { a in
            let m = a.grid(0), l = try a.lambda(1)
            return .array(.column((0..<m.rows).map { cell(a.engine.callLambda(l, [.array(.row(m.rowValues($0)))])) }))
        }
        r.raw("BYCOL", min: 2, max: 2) { a in
            let m = a.grid(0), l = try a.lambda(1)
            return .array(.row((0..<m.cols).map { cell(a.engine.callLambda(l, [.array(.column(m.colValues($0)))])) }))
        }
        r.raw("MAKEARRAY", min: 3, max: 3) { a in
            let rows = try a.int(0), cols = try a.int(1), l = try a.lambda(2)
            guard rows >= 1, cols >= 1 else { throw XLError.value }
            var m = Matrix(rows: rows, cols: cols)
            for r in 0..<rows { for c in 0..<cols {
                m[r, c] = cell(a.engine.callLambda(l, [.number(Double(r + 1)), .number(Double(c + 1))]))
            } }
            return .array(m)
        }
    }

    /// A lambda result placed in one cell: 1×1 arrays unwrap, larger → #CALC!.
    static func cell(_ v: SheetValue) -> SheetValue {
        switch v {
        case .array(let m): return m.rows * m.cols == 1 ? m.data[0] : .error("#CALC!")
        case .lambda: return .error("#CALC!")
        default: return v
        }
    }
}

enum InfoFunctions {
    static let errorNumbers: [String: Double] = [
        "#NULL!": 1, "#DIV/0!": 2, "#VALUE!": 3, "#REF!": 4, "#NAME?": 5, "#NUM!": 6, "#N/A": 7, "#GETTING_DATA": 8,
        "#SPILL!": 9, "#CONNECT!": 10, "#BLOCKED!": 11, "#UNKNOWN!": 12, "#FIELD!": 13, "#CALC!": 14,
    ]

    static func register(_ r: inout Registry) {
        func isFn(_ name: String, _ f: @escaping (SheetValue) -> Bool) {
            r.raw(name, min: 1, max: 1) { a in
                let v = a.value(0)
                if case .array(let m) = v { return .array(m.map { .bool(f($0)) }) }
                return .bool(f(v))
            }
        }
        isFn("ISBLANK") { if case .empty = $0 { return true }; return false }
        isFn("ISERR") { if case .error(let e) = $0 { return e != "#N/A" }; return false }
        isFn("ISERROR") { $0.isError }
        isFn("ISNA") { $0 == .error("#N/A") }
        isFn("ISLOGICAL") { if case .bool = $0 { return true }; return false }
        isFn("ISNUMBER") { $0.isNumber }
        isFn("ISTEXT") { $0.isText }
        isFn("ISNONTEXT") { !$0.isText }
        r.scalar("ISEVEN", min: 1, max: 1) { s in
            if case .bool = s.raw(0) { throw XLError.value }
            return .bool(Int(try s.num(0).rounded(.towardZero)) % 2 == 0)
        }
        r.scalar("ISODD", min: 1, max: 1) { s in
            if case .bool = s.raw(0) { throw XLError.value }
            return .bool(abs(Int(try s.num(0).rounded(.towardZero))) % 2 == 1)
        }
        r.raw("ISREF", min: 1, max: 1) { a in .bool(a.isRef(0)) }
        r.raw("ISFORMULA", min: 1, max: 1) { a in
            guard let ref = a.ref(0) else { throw XLError.value }
            return .bool(ref.sheet.cells[ref.range.start]?.isFormula ?? false)
        }
        r.raw("FORMULATEXT", min: 1, max: 1) { a in
            guard let ref = a.ref(0) else { throw XLError.value }
            guard let c = ref.sheet.cells[ref.range.start], c.isFormula else { throw XLError.na }
            return .string(c.input)
        }
        r.raw("NA", max: 0) { _ in throw XLError.na }
        r.raw("ERROR.TYPE", min: 1, max: 1) { a in
            if case .error(let e) = a.value(0).scalar, let n = errorNumbers[e] { return .number(n) }
            throw XLError.na
        }
        r.raw("TYPE", min: 1, max: 1) { a in
            switch a.value(0) {
            case .number, .empty: return .number(1)
            case .string: return .number(2)
            case .bool: return .number(4)
            case .error: return .number(16)
            case .array(let m): return .number(m.rows * m.cols == 1 && a.isRef(0) ? 1 : 64)
            case .lambda: return .number(128)
            }
        }
        r.scalar("N", min: 1, max: 1) { s in
            switch s.raw(0) {
            case .number(let d): return .number(d)
            case .bool(let b): return .number(b ? 1 : 0)
            case .error(let e): throw XLError(e)
            default: return .number(0)
            }
        }
        r.scalar("T", min: 1, max: 1) { s in
            switch s.raw(0) {
            case .string(let t): return .string(t)
            case .error(let e): throw XLError(e)
            default: return .string("")
            }
        }
        r.raw("SHEET", max: 1) { a in
            let book = a.engine.book
            if !a.has(0) { return .number(Double((book.sheets.firstIndex { $0 === a.ctx.sheet } ?? 0) + 1)) }
            if let ref = a.ref(0) { return .number(Double((book.sheets.firstIndex { $0 === ref.sheet } ?? 0) + 1)) }
            let name = try a.str(0)
            guard let i = book.sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw XLError.na }
            return .number(Double(i + 1))
        }
        r.raw("SHEETS", max: 1) { a in
            if a.has(0) { guard a.ref(0) != nil else { throw XLError.value }; return .number(1) }
            return .number(Double(a.engine.book.sheets.count))
        }
        r.raw("CELL", min: 1, max: 2) { a in
            let kind = try a.str(0).lowercased()
            let ref: Ref
            if a.has(1) { guard let r = a.ref(1) else { throw XLError.value }; ref = r }
            else { ref = Ref(sheet: a.ctx.sheet, range: CellRange(a.ctx.cell ?? CellRef(row: 0, col: 0), a.ctx.cell ?? CellRef(row: 0, col: 0))) }
            let c = ref.range.start
            let cell = ref.sheet.cells[c]
            let v = a.engine.value(ref.sheet, c)
            switch kind {
            case "address": return .string("$" + CellRef.columnName(c.col) + "$" + String(c.row + 1))
            case "col": return .number(Double(c.col + 1))
            case "row": return .number(Double(c.row + 1))
            case "contents": return v
            case "filename": return .string(ref.sheet.name)
            case "type":
                if case .empty = v { return .string("b") }
                return .string(v.isText ? "l" : "v")
            case "prefix":
                guard v.isText, let style = cell?.style else { return .string("") }
                switch style.align { case .left: return .string("'"); case .right: return .string("\""); case .center: return .string("^"); default: return .string("'") }
            case "width": return .number((ref.sheet.width(c.col) / 7).rounded(.down))
            case "format":
                let f = cell?.style.numberFormat ?? "General"
                if f == "General" { return .string("G") }
                if f.contains("%") { return .string("P" + String(f.split(separator: ".").last?.filter { $0 == "0" }.count ?? 0)) }
                if f.lowercased().contains("y") || f.lowercased().contains("d") { return .string("D1") }
                let dec = f.contains(".") ? f.split(separator: ".").last!.filter { $0 == "0" }.count : 0
                return .string((f.contains(",") ? "," : "F") + String(dec))
            case "color": return .number(0)
            case "parentheses": return .number(0)
            case "protect": return .number(1)
            default: throw XLError.value
            }
        }
        r.raw("INFO", min: 1, max: 1) { a in
            switch try a.str(0).lowercased() {
            case "directory": return .string(FileManager.default.currentDirectoryPath + "/")
            case "numfile": return .number(Double(a.engine.book.sheets.count))
            case "origin": return .string("$A:$A$1")
            case "osversion": return .string("Macintosh " + ProcessInfo.processInfo.operatingSystemVersionString)
            case "recalc": return .string("Automatic")
            case "release": return .string("16.0")
            case "system": return .string("mac")
            default: throw XLError.value
            }
        }
    }
}
