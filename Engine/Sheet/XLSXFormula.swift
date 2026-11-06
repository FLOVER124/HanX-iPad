import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Converts formula text between the UI form and the OOXML storage form:
/// newer functions carry `_xlfn.` (FILTER/SORT also `_xlws.`), LET/LAMBDA
/// parameters `_xlpm.`, and the spill operator A1# is ANCHORARRAY(A1).
enum XLSXFormula {
    /// Worksheet functions at BIFF index ≥ 0x1E5 (from Excel's function table).
    static let future: Set<String> = Set("ACOT ACOTH AGGREGATE ARABIC ARRAYTOTEXT AVERAGE.WEIGHTED BASE BETA.DIST BETA.INV BINOM.DIST BINOM.DIST.RANGE BINOM.INV BITAND BITLSHIFT BITOR BITRSHIFT BITXOR BYCOL BYROW CEILING.MATH CEILING.PRECISE CHISQ.DIST CHISQ.DIST.RT CHISQ.INV CHISQ.INV.RT CHISQ.TEST CHOOSECOLS CHOOSEROWS COMBINA CONCAT CONFIDENCE.NORM CONFIDENCE.T COPILOT COT COTH COVARIANCE.P COVARIANCE.S CSC CSCH DAYS DECIMAL DETECTLANGUAGE DROP ECMA.CEILING ENCODEURL ERF.PRECISE ERFC.PRECISE EXPAND EXPON.DIST F.DIST F.DIST.RT F.INV F.INV.RT F.TEST FILTER FILTERXML FLOOR.MATH FLOOR.PRECISE FORECAST.ETS FORECAST.ETS.CONFINT FORECAST.ETS.SEASONALITY FORECAST.ETS.STAT FORECAST.LINEAR FORMATTEDNUMBER FORMULATEXT GAMMA GAMMA.DIST GAMMA.INV GAMMALN.PRECISE GAUSS GROUPBY HSTACK HYPGEOM.DIST IFNA IFS IMAGE IMCOSH IMCOT IMCSC IMCSCH IMPORTCSV IMPORTTEXT IMSEC IMSECH IMSINH IMTAN ISFORMULA ISO.CEILING ISOMITTED ISOWEEKNUM LAMBDA LET LOGNORM.DIST LOGNORM.INV MAKEARRAY MAP MAXIFS MINIFS MODE.MULT MODE.SNGL MUNIT NEGBINOM.DIST NETWORKDAYS.INTL NORM.DIST NORM.INV NORM.S.DIST NORM.S.INV NUMBERVALUE PDURATION PERCENTILE.EXC PERCENTILE.INC PERCENTOF PERCENTRANK.EXC PERCENTRANK.INC PERMUTATIONA PHI PIVOTBY POISSON.DIST PY QUARTILE.EXC QUARTILE.INC RANDARRAY RANK.AVG RANK.EQ REDUCE REGEXEXTRACT REGEXREPLACE REGEXTEST RRI SCAN SEC SECH SEQUENCE SHEET SHEETS SKEW.P SORT SORTBY STDEV.P STDEV.S STOCKHISTORY SWITCH T.DIST T.DIST.2T T.DIST.RT T.INV T.INV.2T T.TEST TAKE TEXTAFTER TEXTBEFORE TEXTJOIN TEXTSPLIT TOCOL TOROW TRANSLATE TRIMRANGE UNICHAR UNICODE UNIQUE UNIT VALUETOTEXT VAR.P VAR.S VSTACK WEBSERVICE WEIBULL.DIST WORKDAY.INTL WRAPCOLS WRAPROWS XLOOKUP XMATCH XOR Z.TEST".split(separator: " ").map(String.init))
    static let worksheetPrefixed: Set<String> = ["FILTER", "SORT"]

    /// Storage → UI.
    static func decode(_ f: String) -> String {
        var out = ""
        scan(f) { piece, isCode in
            guard isCode else { out += piece; return }
            var p = piece
            for prefix in ["_xlfn._xlws.", "_xlfn.", "_xlws.", "_xlpm.", "_xludf."] {
                p = p.replacingOccurrences(of: prefix, with: "", options: .caseInsensitive)
            }
            // ANCHORARRAY(ref) → ref#
            p = p.replacingOccurrences(of: #"ANCHORARRAY\(([^()]+)\)"#, with: "$1#", options: [.regularExpression, .caseInsensitive])
            p = p.replacingOccurrences(of: #"SINGLE\("#, with: "@(", options: [.regularExpression, .caseInsensitive])
            out += p
        }
        return out
    }

    /// UI → storage.
    static func encode(_ f: String) -> String {
        let params = lambdaParams(f)
        var out = ""
        scan(f) { piece, isCode in
            guard isCode else { out += piece; return }
            let c = Array(piece)
            var i = 0
            while i < c.count {
                let ch = c[i]
                if ch.isLetter || ch == "_" || ch == "\\" {
                    var j = i
                    while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "." || c[j] == "\\") { j += 1 }
                    let word = String(c[i..<j])
                    var k = j
                    while k < c.count && c[k] == " " { k += 1 }
                    let call = k < c.count && c[k] == "("
                    let prev = i > 0 ? c[i - 1] : " "
                    let up = word.uppercased()
                    if prev == "!" || prev == "$" || prev == ":" && !call {
                        out += word
                    } else if params.contains(up) && (j >= c.count || c[j] != "!") {
                        out += "_xlpm." + word
                    } else if call && worksheetPrefixed.contains(up) {
                        out += "_xlfn._xlws." + word
                    } else if call && future.contains(up) {
                        out += "_xlfn." + word
                    } else if j < c.count && c[j] == "#" && CellRef(a1: word) != nil {
                        out += "_xlfn.ANCHORARRAY(" + word + ")"
                        j += 1
                    } else {
                        out += word
                    }
                    i = j
                    continue
                }
                if ch == "@" { i += 1; continue }
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    /// Calls `body` with alternating code and literal pieces ("…" strings, '…' sheet names).
    static func scan(_ f: String, _ body: (String, Bool) -> Void) {
        var code = "", i = f.startIndex
        while i < f.endIndex {
            let ch = f[i]
            if ch == "\"" || ch == "'" {
                if !code.isEmpty { body(code, true); code = "" }
                var lit = String(ch)
                var j = f.index(after: i)
                while j < f.endIndex {
                    lit.append(f[j])
                    if f[j] == ch {
                        let n = f.index(after: j)
                        if n < f.endIndex && f[n] == ch { lit.append(ch); j = f.index(after: n); continue }
                        j = n; break
                    }
                    j = f.index(after: j)
                }
                body(lit, false)
                i = j
                continue
            }
            code.append(ch)
            i = f.index(after: i)
        }
        if !code.isEmpty { body(code, true) }
    }

    /// Names bound by LET or used as LAMBDA parameters anywhere in the formula.
    static func lambdaParams(_ f: String) -> Set<String> {
        guard let e = FormulaParser.parse(f.hasPrefix("=") ? String(f.dropFirst()) : f) else { return [] }
        var out = Set<String>()
        func walk(_ e: Expr) {
            switch e {
            case .call(let name, let args):
                if name == "LET" {
                    for (i, a) in args.enumerated() where i % 2 == 0 && i < args.count - 1 {
                        if case .name(let n) = a { out.insert(n.uppercased()) }
                    }
                }
                if name == "LAMBDA" {
                    for a in args.dropLast() { if case .name(let n) = a { out.insert(n.uppercased()) } }
                }
                args.forEach(walk)
            case .invoke(let t, let args): walk(t); args.forEach(walk)
            case .unary(_, let x), .percent(let x), .spill(let x), .implicit(let x): walk(x)
            case .binary(_, let a, let b): walk(a); walk(b)
            case .array(let rows): rows.flatMap { $0 }.forEach(walk)
            default: break
            }
        }
        walk(e)
        return out
    }
}
