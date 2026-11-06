import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// D-functions: database range with a header row, a field (header text or
/// 1-based index) and a criteria range (rows are OR-ed, columns AND-ed).
enum DatabaseFunctions {
    static func select(_ a: Args, fieldOptional: Bool = false) throws -> [SheetValue] {
        let db = a.grid(0), crit = a.grid(2)
        guard db.rows >= 1, crit.rows >= 1 else { throw XLError.value }
        let headers = db.rowValues(0).map { $0.text.lowercased() }
        var field: Int?
        if a.has(1) {
            switch a.value(1).scalar {
            case .number(let d):
                let i = Int(d)
                guard i >= 1, i <= db.cols else { throw XLError.value }
                field = i - 1
            case .error(let e): throw XLError(e)
            default:
                guard let i = headers.firstIndex(of: a.value(1).text.lowercased()) else { throw XLError.value }
                field = i
            }
        } else if !fieldOptional { throw XLError.value }

        // Criteria: map each criteria column to a database column.
        let critCols = crit.rowValues(0).map { h in headers.firstIndex(of: h.text.lowercased()) }
        var conditions: [[(Int, Criteria)]] = []
        for r in 1..<max(1, crit.rows) {
            var row: [(Int, Criteria)] = []
            for (c, col) in critCols.enumerated() {
                guard let col else { continue }
                var v = crit[r, c]
                if case .empty = v { continue }
                // Plain text criteria match by prefix (Advanced Filter semantics).
                if case .string(let s) = v, !s.isEmpty, !["<", ">", "="].contains(s.first!) { v = .string(s + "*") }
                row.append((col, Criteria(v)))
            }
            conditions.append(row)
        }
        if crit.rows == 1 { conditions = [[]] }
        var out: [SheetValue] = []
        for r in 1..<max(1, db.rows) {
            let record = db.rowValues(r)
            let ok = conditions.contains { cond in cond.allSatisfy { $0.1.test(record[$0.0]) } }
            if ok { out.append(field.map { record[$0] } ?? .number(1)) }
        }
        return out
    }

    static func numbers(_ v: [SheetValue]) throws -> [Double] { try Aggregates.numbers(v) }

    static func register(_ r: inout Registry) {
        r.raw("DSUM", min: 3, max: 3) { a in .number(try numbers(select(a)).reduce(0, +)) }
        r.raw("DAVERAGE", min: 3, max: 3) { a in try X.check(try Stats.mean(numbers(select(a)))) }
        r.raw("DCOUNT", min: 3, max: 3) { a in
            let vals = try select(a, fieldOptional: true)
            return .number(Double(a.has(1) ? vals.filter(\.isNumber).count : vals.count))
        }
        r.raw("DCOUNTA", min: 3, max: 3) { a in
            let vals = try select(a, fieldOptional: true)
            return .number(Double(vals.filter { if case .empty = $0 { return false }; return true }.count))
        }
        r.raw("DMAX", min: 3, max: 3) { a in .number(try numbers(select(a)).max() ?? 0) }
        r.raw("DMIN", min: 3, max: 3) { a in .number(try numbers(select(a)).min() ?? 0) }
        r.raw("DPRODUCT", min: 3, max: 3) { a in .number(Stats.product(try numbers(select(a)))) }
        r.raw("DSTDEV", min: 3, max: 3) { a in try X.check(try Stats.varS(numbers(select(a))).squareRoot()) }
        r.raw("DSTDEVP", min: 3, max: 3) { a in try X.check(try Stats.varP(numbers(select(a))).squareRoot()) }
        r.raw("DVAR", min: 3, max: 3) { a in try X.check(try Stats.varS(numbers(select(a)))) }
        r.raw("DVARP", min: 3, max: 3) { a in try X.check(try Stats.varP(numbers(select(a)))) }
        r.raw("DGET", min: 3, max: 3) { a in
            let vals = try select(a)
            guard !vals.isEmpty else { throw XLError.value }
            guard vals.count == 1 else { throw XLError.num }
            return vals[0]
        }
    }
}

/// Functions that depend on external services, add-ins or data connections.
/// Offline they return the same errors Excel shows without the service.
enum ExternalFunctions {
    nonisolated(unsafe) static var webCache: [String: SheetValue] = [:]

    static func register(_ r: inout Registry) {
        for name in ["CUBEVALUE", "CUBEMEMBER", "CUBEMEMBERPROPERTY", "CUBERANKEDMEMBER", "CUBEKPIMEMBER", "CUBESET", "CUBESETCOUNT"] {
            r.raw(name, min: 1) { _ in throw XLError.name }
        }
        for name in ["CALL", "REGISTER.ID", "EXEC"] { r.raw(name, min: 1) { _ in throw XLError.blocked } }
        r.raw("PY", min: 0) { _ in throw XLError.blocked }
        r.raw("COPILOT", min: 1) { _ in throw XLError.connect }
        r.raw("UNIT", min: 1, max: 2) { a in a.value(0) }
        r.raw("IMAGE", min: 1, max: 5) { a in .string(a.has(1) ? try a.str(1) : try a.str(0)) }

        r.scalar("WEBSERVICE", min: 1, max: 1) { s in
            guard s.args.engine.allowExternalIO else { throw XLError.blocked }
            let urlText = try s.str(0)
            guard urlText.count <= 2048, let url = URL(string: urlText), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw XLError.value }
            if let cached = webCache[urlText] { return cached }
            var result: SheetValue = .error("#VALUE!")
            let sem = DispatchSemaphore(value: 0)
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            URLSession.shared.dataTask(with: req) { data, response, _ in
                if let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    let text = String(decoding: data, as: UTF8.self)
                    result = text.count <= TextFunctions.maxLength ? .string(text) : .error("#VALUE!")
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
            webCache[urlText] = result
            return result
        }
        r.raw("FILTERXML", min: 2, max: 2) { a in
            let xml = try a.str(0), path = try a.str(1)
            guard let doc = try? XMLDocument(xmlString: xml, options: []), let nodes = try? doc.nodes(forXPath: path), !nodes.isEmpty else {
                throw XLError.value
            }
            let vals = nodes.map { n -> SheetValue in
                let t = n.stringValue ?? ""
                if let d = Double(t.trimmingCharacters(in: .whitespaces)) { return .number(d) }
                return .string(t)
            }
            return vals.count == 1 ? vals[0] : .array(.column(vals))
        }
        r.raw("IMPORTCSV", min: 1, max: 4) { a in
            guard a.engine.allowExternalIO else { throw XLError.blocked }
            return try importText(path: try a.str(0), delimiter: ",", skip: try a.int(1, 0), take: a.has(2) ? try a.int(2) : nil)
        }
        r.raw("IMPORTTEXT", min: 1, max: 6) { a in
            guard a.engine.allowExternalIO else { throw XLError.blocked }
            let d = a.has(1) ? try a.str(1) : "\t"
            return try importText(path: try a.str(0), delimiter: d.first ?? "\t", skip: try a.int(2, 0), take: a.has(3) ? try a.int(3) : nil)
        }
    }

    static func importText(path: String, delimiter: Character, skip: Int, take: Int?) throws -> SheetValue {
        let url: URL
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") { throw XLError.connect }
        if path.lowercased().hasPrefix("file://"), let u = URL(string: path) { url = u } else { url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        guard let data = try? Data(contentsOf: url) else { throw XLError.value }
        let ws = DelimitedText.parse(DelimitedText.decode(data), separator: delimiter)
        guard let used = ws.usedRange else { throw XLError.calc }
        var rows: [[SheetValue]] = []
        for r in 0...used.end.row {
            rows.append((0...used.end.col).map { c in SheetValue.literal(ws.cells[CellRef(row: r, col: c)]?.input ?? "") })
        }
        if skip > 0 { rows = Array(rows.dropFirst(skip)) } else if skip < 0 { rows = Array(rows.dropLast(-skip)) }
        if let take { rows = take >= 0 ? Array(rows.prefix(take)) : Array(rows.suffix(-take)) }
        guard !rows.isEmpty else { throw XLError.calc }
        return .array(Matrix(rows))
    }
}
