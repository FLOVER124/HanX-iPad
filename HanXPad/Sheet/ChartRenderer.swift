import UIKit

/// Draws a SheetChart (column, bar, line, area, pie) into a rect in the
/// current UIKit context, with the Office default palette (as on macOS).
enum ChartRenderer {
    static let palette: [UIColor] = [
        (68, 114, 196), (237, 125, 49), (165, 165, 165), (255, 192, 0), (91, 155, 213), (112, 173, 71),
        (38, 68, 120), (158, 72, 14), (99, 99, 99), (153, 115, 0),
    ].map { UIColor(red: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }

    private static func label(_ s: String, size: CGFloat = 10, color: UIColor = UIColor(white: 0.35, alpha: 1), bold: Bool = false) -> NSAttributedString {
        let font = FontResolver.shared.font(name: "Apple SD Gothic Neo", size: Double(size), bold: bold, italic: false).font
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    static func niceStep(_ range: Double) -> Double {
        guard range > 0 else { return 1 }
        let raw = range / 5
        let mag = pow(10, floor(log10(raw)))
        let f = raw / mag
        return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag
    }

    static func draw(_ chart: SheetChart, ws: Worksheet, engine: FormulaEngine, in rect: CGRect, selected: Bool) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let (cats, series) = chart.resolve(ws, engine)
        let frame = UIBezierPath(roundedRect: rect, cornerRadius: 4)
        UIColor.white.setFill(); frame.fill()
        (selected ? UIColor.systemBlue : UIColor(white: 0.8, alpha: 1)).setStroke()
        frame.lineWidth = selected ? 2 : 0.75
        frame.stroke()

        var area = rect.insetBy(dx: 12, dy: 10)
        if !chart.title.isEmpty {
            let t = label(chart.title, size: 14, color: UIColor(white: 0.2, alpha: 1), bold: true)
            let sz = t.size()
            t.draw(at: CGPoint(x: area.midX - sz.width / 2, y: area.minY))
            area.origin.y += sz.height + 6; area.size.height -= sz.height + 6
        }
        guard !series.isEmpty, !cats.isEmpty else {
            label("데이터 없음").draw(at: CGPoint(x: area.midX - 24, y: area.midY))
            return
        }
        let legend: [(String, UIColor)] = chart.kind == .pie
            ? cats.enumerated().map { ($0.element, palette[$0.offset % palette.count]) }
            : series.enumerated().map { ($0.element.name, palette[$0.offset % palette.count]) }
        if chart.kind == .pie {
            let w: CGFloat = min(120, area.width * 0.32)
            var y = area.minY + 4
            for (name, color) in legend.prefix(12) {
                color.setFill(); UIRectFill(CGRect(x: area.maxX - w, y: y + 3, width: 9, height: 9))
                label(name).draw(at: CGPoint(x: area.maxX - w + 14, y: y))
                y += 16
            }
            area.size.width -= w + 8
            drawPie(series[0].values, in: area)
            return
        }
        var widths: CGFloat = 0
        for (name, _) in legend { widths += label(name).size().width + 26 }
        var lx = area.midX - widths / 2
        let ly = area.maxY - 14
        for (name, color) in legend {
            color.setFill(); UIRectFill(CGRect(x: lx, y: ly + 3, width: 9, height: 9))
            let l = label(name); l.draw(at: CGPoint(x: lx + 13, y: ly)); lx += l.size().width + 26
        }
        area.size.height -= 20

        let all = series.flatMap(\.values)
        var lo = min(0, all.min() ?? 0), hi = max(0, all.max() ?? 1)
        if lo == hi { hi = lo + 1 }
        let step = niceStep(hi - lo)
        lo = floor(lo / step) * step; hi = ceil(hi / step) * step
        let horizontal = chart.kind == .bar
        let values = stride(from: lo, through: hi + step / 2, by: step).map { $0 }
        let labelW = (values.map { label(SheetValue.general($0)).size().width }.max() ?? 20) + 6
        let catH: CGFloat = 16
        var p: CGRect = horizontal
            ? CGRect(x: area.minX + min(90, (cats.map { label($0).size().width }.max() ?? 30) + 6), y: area.minY, width: 0, height: area.height - catH)
            : CGRect(x: area.minX + labelW, y: area.minY + 4, width: area.width - labelW, height: area.height - catH - 4)
        if horizontal { p.size.width = area.maxX - p.minX }
        func pos(_ v: Double) -> CGFloat {
            let t = CGFloat((v - lo) / (hi - lo))
            return horizontal ? p.minX + t * p.width : p.maxY - t * p.height
        }
        g.setLineWidth(1)
        for v in values {
            let l = label(SheetValue.general(v))
            g.setStrokeColor(UIColor(white: 0.9, alpha: 1).cgColor)
            if horizontal {
                g.move(to: CGPoint(x: pos(v), y: p.minY)); g.addLine(to: CGPoint(x: pos(v), y: p.maxY)); g.strokePath()
                l.draw(at: CGPoint(x: pos(v) - l.size().width / 2, y: p.maxY + 2))
            } else {
                g.move(to: CGPoint(x: p.minX, y: pos(v))); g.addLine(to: CGPoint(x: p.maxX, y: pos(v))); g.strokePath()
                l.draw(at: CGPoint(x: p.minX - l.size().width - 4, y: pos(v) - 7))
            }
        }
        g.setStrokeColor(UIColor(white: 0.55, alpha: 1).cgColor)
        if horizontal { g.move(to: CGPoint(x: pos(0), y: p.minY)); g.addLine(to: CGPoint(x: pos(0), y: p.maxY)) }
        else { g.move(to: CGPoint(x: p.minX, y: pos(0))); g.addLine(to: CGPoint(x: p.maxX, y: pos(0))) }
        g.strokePath()

        let n = cats.count
        let slot = (horizontal ? p.height : p.width) / CGFloat(n)
        for (i, c) in cats.enumerated() {
            let l = label(c)
            if horizontal { l.draw(at: CGPoint(x: p.minX - l.size().width - 4, y: p.minY + slot * (CGFloat(i) + 0.5) - 7)) }
            else if l.size().width < slot + 10 || i % max(1, Int(ceil(l.size().width / slot))) == 0 {
                l.draw(at: CGPoint(x: p.minX + slot * (CGFloat(i) + 0.5) - l.size().width / 2, y: p.maxY + 2))
            }
        }
        switch chart.kind {
        case .column, .bar:
            let group = slot * 0.7, bw = group / CGFloat(series.count)
            for (si, s) in series.enumerated() {
                palette[si % palette.count].setFill()
                for (i, v) in s.values.enumerated() {
                    let start = slot * CGFloat(i) + (slot - group) / 2 + bw * CGFloat(si)
                    let a = pos(0), b = pos(v)
                    let r = horizontal
                        ? CGRect(x: min(a, b), y: p.minY + start, width: abs(b - a), height: bw * 0.92)
                        : CGRect(x: p.minX + start, y: min(a, b), width: bw * 0.92, height: abs(b - a))
                    UIRectFill(r)
                }
            }
        case .line, .area:
            for (si, s) in series.enumerated() {
                let color = palette[si % palette.count]
                let pts = s.values.enumerated().map { CGPoint(x: p.minX + slot * (CGFloat($0.offset) + 0.5), y: pos($0.element)) }
                guard let first = pts.first, let last = pts.last else { continue }
                let path = UIBezierPath()
                path.move(to: first)
                pts.dropFirst().forEach { path.addLine(to: $0) }
                if chart.kind == .area {
                    let fill = path.copy() as! UIBezierPath
                    fill.addLine(to: CGPoint(x: last.x, y: pos(0)))
                    fill.addLine(to: CGPoint(x: first.x, y: pos(0)))
                    fill.close()
                    color.withAlphaComponent(0.55).setFill()
                    fill.fill()
                }
                color.setStroke()
                path.lineWidth = 2.25
                path.lineJoinStyle = .round
                path.stroke()
                if chart.kind == .line {
                    color.setFill()
                    for pt in pts { UIBezierPath(ovalIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)).fill() }
                }
            }
        case .pie: break
        }
    }

    private static func drawPie(_ values: [Double], in area: CGRect) {
        let total = values.map { max(0, $0) }.reduce(0, +)
        guard total > 0 else { return }
        let d = min(area.width, area.height) * 0.9
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle: CGFloat = -.pi / 2
        for (i, v) in values.enumerated() where v > 0 {
            let sweep = CGFloat(v / total) * 2 * .pi
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: d / 2, startAngle: angle, endAngle: angle + sweep, clockwise: true)
            path.close()
            palette[i % palette.count].setFill()
            path.fill()
            UIColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
            let mid = angle + sweep / 2
            let pct = label("\(Int((v / total * 100).rounded()))%", size: 10, color: .white, bold: true)
            if sweep > 0.25 {
                pct.draw(at: CGPoint(x: center.x + cos(mid) * d * 0.32 - pct.size().width / 2, y: center.y + sin(mid) * d * 0.32 - 7))
            }
            angle += sweep
        }
    }
}
