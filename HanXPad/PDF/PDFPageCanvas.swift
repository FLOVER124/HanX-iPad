import UIKit
import PDFKit

/// One PDF page in 개체 편집 mode: the rendered page plus object frames,
/// selection handles and live move/resize previews. All geometry is kept in
/// page space and mapped through the page rotation for display.
final class PDFPageCanvas: UIView, UIGestureRecognizerDelegate {
    private(set) var page: PDFPage?
    var objects: [PDFPageObject] = [] { didSet { setNeedsDisplay() } }
    var selection: [Int] = [] { didSet { setNeedsDisplay(); onSelectionChanged?() } }
    var highlights: [CGRect] = [] { didSet { setNeedsDisplay() } }
    var filter: PDFPageObject.Kind? { didSet { setNeedsDisplay() } }
    var onSelectionChanged: (() -> Void)?
    /// Move/resize finished: (old bounds, new bounds) in page space.
    var onTransform: ((CGRect, CGRect) -> Void)?
    var onEditText: ((PDFPageObject) -> Void)?
    var onDelete: (() -> Void)?
    var onNudge: ((CGFloat, CGFloat) -> Void)?
    var onCopy: (() -> Void)?

    private var pageImage: UIImage?
    private var dragOrigin: CGPoint?
    private var dragHandle: Int?
    private var dragStartRect: CGRect?
    private var preview: CGRect?
    private var marquee: CGRect?
    private var marqueeTouchType: UITouch.TouchType = .direct
    private let pan = UIPanGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(tap)
        addGestureRecognizer(double)
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    var panGesture: UIPanGestureRecognizer { pan }

    // MARK: Geometry

    var pageBox: CGRect { page?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792) }
    var rotation: Int { ((page?.rotation ?? 0) % 360 + 360) % 360 }
    /// Size of the page as displayed (rotation applied), in PDF units.
    var displaySize: CGSize {
        let b = pageBox
        return rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }
    var scale: CGFloat { bounds.width / max(1, displaySize.width) }

    private func toDisplay(_ p: CGPoint) -> CGPoint {
        let b = pageBox
        switch rotation {
        case 90: return CGPoint(x: p.y - b.minY, y: b.maxX - p.x)
        case 180: return CGPoint(x: b.maxX - p.x, y: b.maxY - p.y)
        case 270: return CGPoint(x: b.maxY - p.y, y: p.x - b.minX)
        default: return CGPoint(x: p.x - b.minX, y: p.y - b.minY)
        }
    }

    private func fromDisplay(_ d: CGPoint) -> CGPoint {
        let b = pageBox
        switch rotation {
        case 90: return CGPoint(x: b.maxX - d.y, y: d.x + b.minY)
        case 180: return CGPoint(x: b.maxX - d.x, y: b.maxY - d.y)
        case 270: return CGPoint(x: d.y + b.minX, y: b.maxY - d.x)
        default: return CGPoint(x: d.x + b.minX, y: d.y + b.minY)
        }
    }

    func viewPoint(_ p: CGPoint) -> CGPoint {
        let d = toDisplay(p)
        return CGPoint(x: d.x * scale, y: (displaySize.height - d.y) * scale)
    }

    func pagePoint(_ v: CGPoint) -> CGPoint {
        fromDisplay(CGPoint(x: v.x / scale, y: displaySize.height - v.y / scale))
    }

    func viewRect(_ r: CGRect) -> CGRect { boundingRect([r.origin, CGPoint(x: r.maxX, y: r.maxY)].map(viewPoint)) }
    func pageRect(_ r: CGRect) -> CGRect { boundingRect([r.origin, CGPoint(x: r.maxX, y: r.maxY)].map(pagePoint)) }

    private func boundingRect(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: Content

    func show(_ page: PDFPage?, width: CGFloat) {
        self.page = page
        let size = displaySize
        frame.size = CGSize(width: width, height: width * size.height / max(1, size.width))
        rerender()
    }

    /// Re-rasterises the page at the current on-screen resolution.
    func rerender(zoom: CGFloat = 1) {
        guard let page else { pageImage = nil; setNeedsDisplay(); return }
        let pixels = bounds.size.applying(CGAffineTransform(scaleX: zoom * traitCollection.displayScale, y: zoom * traitCollection.displayScale))
        let capped = CGSize(width: min(pixels.width, 5000), height: min(pixels.height, 5000 * pixels.height / max(1, pixels.width)))
        pageImage = page.thumbnail(of: capped, for: .mediaBox)
        setNeedsDisplay()
    }

    var selectedObjects: [PDFPageObject] { objects.filter { selection.contains($0.id) } }
    var selectionBounds: CGRect? {
        let s = selectedObjects
        guard let first = s.first else { return nil }
        return s.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    private var visibleObjects: [PDFPageObject] { objects.filter { filter == nil || $0.kind == filter } }

    func object(at viewPoint: CGPoint) -> PDFPageObject? {
        let p = pagePoint(viewPoint)
        let hits = visibleObjects.filter { $0.bounds.insetBy(dx: -3 / scale, dy: -3 / scale).contains(p) }
        // Prefer text, then the smallest object under the finger.
        return hits.min { a, b in
            if (a.kind == .text) != (b.kind == .text) { return a.kind == .text }
            return a.bounds.width * a.bounds.height < b.bounds.width * b.bounds.height
        }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        UIColor.white.setFill()
        g.fill(bounds)
        pageImage?.draw(in: bounds)
        for r in highlights {
            g.setFillColor(UIColor.systemYellow.withAlphaComponent(0.4).cgColor)
            g.fill(viewRect(r))
        }
        for o in visibleObjects where !selection.contains(o.id) {
            let color: UIColor = o.kind == .text ? .systemBlue : o.kind == .image ? .systemGreen : .systemOrange
            g.setStrokeColor(color.withAlphaComponent(0.35).cgColor)
            g.setLineWidth(0.75)
            g.stroke(viewRect(o.bounds).insetBy(dx: -1, dy: -1))
        }
        if let selected = selectionBounds {
            let r = preview ?? viewRect(selected).insetBy(dx: -2, dy: -2)
            g.setStrokeColor(HanXTheme.accent.resolvedColor(with: traitCollection).cgColor)
            g.setLineWidth(1.5)
            if preview != nil { g.setLineDash(phase: 0, lengths: [5, 3]) }
            g.stroke(r)
            g.setLineDash(phase: 0, lengths: [])
            if selection.count == 1 || preview != nil {
                for h in handles(for: r) {
                    g.setFillColor(UIColor.white.cgColor)
                    g.fillEllipse(in: h)
                    g.setStrokeColor(HanXTheme.accent.resolvedColor(with: traitCollection).cgColor)
                    g.strokeEllipse(in: h)
                }
            }
        }
        if let m = marquee {
            g.setFillColor(HanXTheme.accent.withAlphaComponent(0.12).cgColor)
            g.fill(m)
            g.setStrokeColor(HanXTheme.accent.cgColor)
            g.setLineWidth(1)
            g.stroke(m)
        }
    }

    private func handles(for r: CGRect) -> [CGRect] {
        let s: CGFloat = 14
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                   CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        return pts.map { CGRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    // MARK: Gestures

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        becomeFirstResponder()
        let additive = g.modifierFlags.contains(.shift) || g.modifierFlags.contains(.command)
        guard let o = object(at: g.location(in: self)) else { if !additive { selection = [] }; return }
        if additive {
            if let i = selection.firstIndex(of: o.id) { selection.remove(at: i) } else { selection.append(o.id) }
        } else {
            selection = [o.id]
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let o = object(at: g.location(in: self)) else { return }
        selection = [o.id]
        if o.kind == .text { onEditText?(o) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pan { marqueeTouchType = touch.type }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return super.gestureRecognizerShouldBegin(g) }
        let p = pan.location(in: self)
        if let sel = selectionBounds {
            let r = viewRect(sel).insetBy(dx: -2, dy: -2)
            if handles(for: r).contains(where: { $0.insetBy(dx: -8, dy: -8).contains(p) }) { return true }
            if r.insetBy(dx: -6, dy: -6).contains(p) { return true }
        }
        // Rubber-band selection with Apple Pencil or a pointer; fingers scroll.
        return marqueeTouchType == .pencil || marqueeTouchType == .indirectPointer
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dragOrigin = p
            if let sel = selectionBounds {
                let r = viewRect(sel).insetBy(dx: -2, dy: -2)
                dragStartRect = r
                dragHandle = handles(for: r).firstIndex { $0.insetBy(dx: -8, dy: -8).contains(p) }
                if dragHandle == nil && !r.insetBy(dx: -6, dy: -6).contains(p) { dragStartRect = nil; marquee = CGRect(origin: p, size: .zero) }
            } else {
                marquee = CGRect(origin: p, size: .zero)
            }
        case .changed:
            guard let o = dragOrigin else { return }
            let dx = p.x - o.x, dy = p.y - o.y
            if var m = marquee {
                m = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(dx), height: abs(dy))
                marquee = m
                setNeedsDisplay()
                return
            }
            guard var r = dragStartRect else { return }
            if let h = dragHandle {
                if [0, 6, 7].contains(h) { r.origin.x += dx; r.size.width -= dx }
                if [2, 3, 4].contains(h) { r.size.width += dx }
                if [0, 1, 2].contains(h) { r.origin.y += dy; r.size.height -= dy }
                if [4, 5, 6].contains(h) { r.size.height += dy }
                r = r.standardized
                r.size.width = max(4, r.width); r.size.height = max(4, r.height)
            } else {
                r = r.offsetBy(dx: dx, dy: dy)
            }
            preview = r
            setNeedsDisplay()
        case .ended:
            if let m = marquee {
                let area = pageRect(m)
                let hits = visibleObjects.filter { area.intersects($0.bounds) }.map(\.id)
                marquee = nil
                selection = hits
            } else if let r = preview, let start = dragStartRect, let sel = selectionBounds {
                preview = nil
                setNeedsDisplay()
                // Undo the 2pt selection inset before converting back.
                let target = pageRect(r.insetBy(dx: 2, dy: 2))
                if abs(r.minX - start.minX) > 0.5 || abs(r.minY - start.minY) > 0.5 || abs(r.width - start.width) > 0.5 || abs(r.height - start.height) > 0.5 {
                    onTransform?(sel, target)
                }
            }
            dragOrigin = nil; dragStartRect = nil; dragHandle = nil
        default:
            preview = nil; marquee = nil; dragOrigin = nil; dragStartRect = nil; dragHandle = nil
            setNeedsDisplay()
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { super.pressesBegan(presses, with: event); return }
        let step: CGFloat = key.modifierFlags.contains(.shift) ? 10 : 1
        switch key.keyCode {
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward: if !selection.isEmpty { onDelete?() } else { super.pressesBegan(presses, with: event) }
        case .keyboardLeftArrow: onNudge?(-step, 0)
        case .keyboardRightArrow: onNudge?(step, 0)
        case .keyboardUpArrow: onNudge?(0, step)
        case .keyboardDownArrow: onNudge?(0, -step)
        case .keyboardEscape: selection = []
        case .keyboardReturnOrEnter: if let o = selectedObjects.first, o.kind == .text { onEditText?(o) }
        default: super.pressesBegan(presses, with: event)
        }
    }

    override func copy(_ sender: Any?) { onCopy?() }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectedObjects.contains { $0.kind == .text } }
        return super.canPerformAction(action, withSender: sender)
    }
}
