import UIKit

protocol SlideCanvasDelegate: AnyObject {
    var canvasSlide: Slide { get }
    var canvasPresentation: Presentation { get }
    func canvasSelectionChanged()
    /// Shapes were moved/resized/rotated interactively; `shapes` is the final state.
    func canvasCommit(_ name: String, shapes: [SlideShape])
    func canvasBeginTextEditing(_ shapeID: Int)
    func canvasEditTable(_ shapeID: Int)
    func canvasDelete()
    func canvasDuplicate()
    func canvasCopy(cut: Bool)
    func canvasPaste()
    func canvasMenu(for shapeID: Int?) -> UIMenu?
}

/// Slide editing surface: selection, 8 resize handles, rotation handle,
/// marquee (Apple Pencil / pointer), two-finger scale & rotate of the
/// selection, centre snapping guides and keyboard nudging.
final class SlideCanvasView: UIView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    weak var delegate: SlideCanvasDelegate?
    var selectedIDs: [Int] = [] { didSet { if oldValue != selectedIDs { setNeedsDisplay(); delegate?.canvasSelectionChanged() } } }
    var hiddenTextID: Int? { didSet { setNeedsDisplay() } }
    /// Shapes being dragged (drawn instead of the stored ones).
    private var live: [Int: SlideShape] = [:]
    private var guides: [(CGPoint, CGPoint)] = []
    private var marquee: CGRect?
    private var dragKind: Drag?
    private var touchType: UITouch.TouchType = .direct
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let rotate = UIRotationGestureRecognizer()

    private enum Drag { case move(CGPoint), resize(Int, CGPoint), rotate, marquee(CGPoint) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pinch.addTarget(self, action: #selector(twoFinger(_:)))
        rotate.addTarget(self, action: #selector(twoFinger(_:)))
        for g in [pan, pinch, rotate] as [UIGestureRecognizer] { g.delegate = self }
        for g in [tap, double, pan, pinch, rotate] as [UIGestureRecognizer] { addGestureRecognizer(g) }
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    var gestures: [UIGestureRecognizer] { [pan, pinch, rotate] }

    // MARK: Geometry

    private var pres: Presentation { delegate?.canvasPresentation ?? Presentation() }
    private var slide: Slide { delegate?.canvasSlide ?? Slide() }

    /// Points per slide unit (the canvas is sized to the slide's aspect ratio).
    var scale: CGFloat { bounds.width / max(1, CGFloat(pres.width)) }
    func slidePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / scale, y: p.y / scale) }
    func viewRect(_ f: Frame) -> CGRect { CGRect(x: f.x * scale, y: f.y * scale, width: f.w * scale, height: f.h * scale) }

    private func shape(_ id: Int) -> SlideShape? { live[id] ?? slide.shapes.first { $0.id == id } }
    var selectedShapes: [SlideShape] { selectedIDs.compactMap(shape) }

    func shapeID(at viewPoint: CGPoint) -> Int? {
        let p = slidePoint(viewPoint)
        for s in slide.shapes.reversed() where !s.locked {
            let local = ShapeGeometry.local(x: Double(p.x), y: Double(p.y), frame: s.frame, rotation: s.rotation)
            let tolerance = 6 / Double(scale)
            var f = s.frame
            if s.kind == .line { f = Frame(x: min(f.x, f.maxX) - tolerance, y: min(f.y, f.maxY) - tolerance, w: abs(f.w) + tolerance * 2, h: abs(f.h) + tolerance * 2) }
            if local.0 >= f.x - tolerance && local.0 <= f.maxX + tolerance && local.1 >= f.y - tolerance && local.1 <= f.maxY + tolerance { return s.id }
        }
        return nil
    }

    /// Corners and edge midpoints of a shape's frame, rotated, in view points.
    private func handlePoints(_ s: SlideShape) -> [CGPoint] {
        let f = s.frame
        let pts = [(f.x, f.y), (f.x + f.w / 2, f.y), (f.maxX, f.y), (f.maxX, f.y + f.h / 2), (f.maxX, f.maxY), (f.x + f.w / 2, f.maxY), (f.x, f.maxY), (f.x, f.y + f.h / 2)]
        return pts.map { p in
            let w = ShapeGeometry.world(x: p.0, y: p.1, frame: f, rotation: s.rotation)
            return CGPoint(x: w.0 * scale, y: w.1 * scale)
        }
    }

    private func rotationHandle(_ s: SlideShape) -> CGPoint {
        let f = s.frame
        let w = ShapeGeometry.world(x: f.x + f.w / 2, y: f.y - Double(28 / scale), frame: f, rotation: s.rotation)
        return CGPoint(x: w.0 * scale, y: w.1 * scale)
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        g.saveGState()
        g.scaleBy(x: scale, y: scale)
        g.clip(to: CGRect(x: 0, y: 0, width: pres.width, height: pres.height))
        var s = slide
        if !live.isEmpty { s.shapes = s.shapes.map { live[$0.id] ?? $0 } }
        SlideRenderer.draw(s, pres, hideTextOf: hiddenTextID)
        g.restoreGState()
        let accent = UIColor.systemBlue
        for shape in selectedShapes {
            let pts = handlePoints(shape)
            let outline = UIBezierPath()
            outline.move(to: pts[0]); outline.addLine(to: pts[2]); outline.addLine(to: pts[4]); outline.addLine(to: pts[6]); outline.close()
            accent.setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
            guard selectedIDs.count == 1 else { continue }
            let rot = rotationHandle(shape)
            let stem = UIBezierPath(); stem.move(to: pts[1]); stem.addLine(to: rot); stem.lineWidth = 1; stem.stroke()
            for p in pts + [rot] {
                let h = UIBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                UIColor.white.setFill(); h.fill()
                accent.setStroke(); h.lineWidth = 1.5; h.stroke()
            }
        }
        if !guides.isEmpty {
            UIColor.systemPink.setStroke()
            for (a, b) in guides {
                let p = UIBezierPath(); p.move(to: a); p.addLine(to: b); p.lineWidth = 1
                p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
            }
        }
        if let m = marquee {
            accent.withAlphaComponent(0.12).setFill(); UIRectFill(m)
            accent.setStroke(); UIBezierPath(rect: m).stroke()
        }
    }

    // MARK: Taps

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        becomeFirstResponder()
        let additive = g.modifierFlags.contains(.shift) || g.modifierFlags.contains(.command)
        guard let id = shapeID(at: g.location(in: self)) else { if !additive { selectedIDs = [] }; return }
        if additive {
            if let i = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: i) } else { selectedIDs.append(id) }
        } else {
            selectedIDs = [id]
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let id = shapeID(at: g.location(in: self)), let s = shape(id) else { return }
        selectedIDs = [id]
        if s.kind == .table { delegate?.canvasEditTable(id) }
        else if s.kind != .image && s.kind != .line { delegate?.canvasBeginTextEditing(id) }
    }

    // MARK: Drag, resize, rotate

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === pan { touchType = touch.type }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        let p = g.location(in: self)
        if g === pinch || g === rotate {
            return !selectedIDs.isEmpty && selectedShapes.contains { viewRect(ShapeGeometry.bounds($0)).insetBy(dx: -30, dy: -30).contains(p) }
        }
        guard g === pan else { return super.gestureRecognizerShouldBegin(g) }
        if let s = selectedShapes.first, selectedIDs.count == 1 {
            if hypot(p.x - rotationHandle(s).x, p.y - rotationHandle(s).y) < 22 { return true }
            if handlePoints(s).contains(where: { hypot(p.x - $0.x, p.y - $0.y) < 22 }) { return true }
        }
        if shapeID(at: p) != nil { return true }
        return touchType == .pencil || touchType == .indirectPointer
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pinch && other === rotate) || (g === rotate && other === pinch)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            if let s = selectedShapes.first, selectedIDs.count == 1 {
                if hypot(p.x - rotationHandle(s).x, p.y - rotationHandle(s).y) < 22 { begin(.rotate); return }
                if let h = handlePoints(s).firstIndex(where: { hypot(p.x - $0.x, p.y - $0.y) < 22 }) { begin(.resize(h, p)); return }
            }
            if let id = shapeID(at: p) {
                if !selectedIDs.contains(id) { selectedIDs = g.modifierFlags.contains(.shift) ? selectedIDs + [id] : [id] }
                begin(.move(p))
            } else {
                begin(.marquee(p))
                marquee = CGRect(origin: p, size: .zero)
            }
        case .changed:
            guard let kind = dragKind else { return }
            switch kind {
            case .move(let start): move(by: CGPoint(x: (p.x - start.x) / scale, y: (p.y - start.y) / scale))
            case .resize(let h, let start): resize(handle: h, by: CGPoint(x: (p.x - start.x) / scale, y: (p.y - start.y) / scale))
            case .rotate: rotateTo(p)
            case .marquee(let start): marquee = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            }
            setNeedsDisplay()
        case .ended:
            if case .marquee = dragKind, let m = marquee {
                let area = CGRect(x: m.minX / scale, y: m.minY / scale, width: m.width / scale, height: m.height / scale)
                selectedIDs = slide.shapes.filter { !$0.locked && area.intersects(SlideRenderer.cg(ShapeGeometry.bounds($0))) }.map(\.id)
                marquee = nil
            } else if let kind = dragKind {
                let name: String
                switch kind { case .move: name = "이동"; case .resize: name = "크기 조절"; case .rotate: name = "회전"; case .marquee: name = "" }
                commitLive(name)
            }
            end()
        default:
            live = [:]; end()
        }
    }

    private var originals: [Int: SlideShape] = [:]

    private func begin(_ kind: Drag) {
        dragKind = kind
        originals = Dictionary(uniqueKeysWithValues: selectedShapes.map { ($0.id, $0) })
    }

    private func end() {
        dragKind = nil
        originals = [:]
        guides = []
        marquee = nil
        setNeedsDisplay()
    }

    private func commitLive(_ name: String) {
        let changed = live.values.filter { s in originals[s.id].map { $0.frame != s.frame || $0.rotation != s.rotation } ?? false }
        live = [:]
        if !changed.isEmpty { delegate?.canvasCommit(name, shapes: Array(changed)) }
    }

    private func move(by d: CGPoint) {
        guides = []
        var dx = Double(d.x), dy = Double(d.y)
        // Snap the selection's centre and edges to the slide's centre lines and edges.
        let boxes = originals.values.map(ShapeGeometry.bounds)
        if let minX = boxes.map(\.x).min(), let minY = boxes.map(\.y).min(), let maxX = boxes.map(\.maxX).max(), let maxY = boxes.map(\.maxY).max() {
            let tol = 6 / Double(scale)
            let cx = (minX + maxX) / 2 + dx, cy = (minY + maxY) / 2 + dy
            if abs(cx - pres.width / 2) < tol { dx += pres.width / 2 - cx; guides.append((CGPoint(x: pres.width / 2 * Double(scale), y: 0), CGPoint(x: pres.width / 2 * Double(scale), y: Double(bounds.height)))) }
            if abs(cy - pres.height / 2) < tol { dy += pres.height / 2 - cy; guides.append((CGPoint(x: 0, y: pres.height / 2 * Double(scale)), CGPoint(x: Double(bounds.width), y: pres.height / 2 * Double(scale)))) }
            if abs(minX + dx) < tol { dx = -minX } else if abs(maxX + dx - pres.width) < tol { dx = pres.width - maxX }
            if abs(minY + dy) < tol { dy = -minY } else if abs(maxY + dy - pres.height) < tol { dy = pres.height - maxY }
        }
        for (id, o) in originals {
            var s = o
            s.frame.x = o.frame.x + dx
            s.frame.y = o.frame.y + dy
            live[id] = s
        }
    }

    private func resize(handle: Int, by d: CGPoint) {
        guard let first = originals.first else { return }
        let id = first.key, o = first.value
        var s = o
        s.frame = ShapeGeometry.resized(o.frame, rotation: o.rotation, handle: handle, dx: Double(d.x), dy: Double(d.y),
                                         preserveAspect: o.lockAspect || o.kind == .image)
        live[id] = s
    }

    private func rotateTo(_ p: CGPoint) {
        guard let first = originals.first else { return }
        let id = first.key, o = first.value
        let c = CGPoint(x: (o.frame.x + o.frame.w / 2) * Double(scale), y: (o.frame.y + o.frame.h / 2) * Double(scale))
        var angle = atan2(Double(p.y - c.y), Double(p.x - c.x)) * 180 / .pi + 90
        // Snap to 15° steps.
        let snapped = (angle / 15).rounded() * 15
        if abs(snapped - angle) < 4 { angle = snapped }
        var s = o
        s.rotation = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        live[id] = s
    }

    @objc private func twoFinger(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            if originals.isEmpty { begin(.move(.zero)) }
        case .changed:
            let k = Double(pinch.scale), turn = Double(rotate.rotation) * 180 / .pi
            for (id, o) in originals {
                var s = o
                let cx = o.frame.x + o.frame.w / 2, cy = o.frame.y + o.frame.h / 2
                s.frame.w = max(4, o.frame.w * k); s.frame.h = max(4, o.frame.h * k)
                s.frame.x = cx - s.frame.w / 2; s.frame.y = cy - s.frame.h / 2
                s.rotation = ((o.rotation + turn).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                live[id] = s
            }
            setNeedsDisplay()
        case .ended, .cancelled:
            if pinch.state != .changed && rotate.state != .changed {
                commitLive("크기 회전")
                end()
            }
        default: break
        }
    }

    // MARK: Context menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let id = shapeID(at: location)
        if let id, !selectedIDs.contains(id) { selectedIDs = [id] }
        guard let menu = delegate?.canvasMenu(for: id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    var onNudge: ((Double, Double) -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { super.pressesBegan(presses, with: event); return }
        let step = key.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch key.keyCode {
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward where !selectedIDs.isEmpty: delegate?.canvasDelete()
        case .keyboardLeftArrow: onNudge?(-step, 0)
        case .keyboardRightArrow: onNudge?(step, 0)
        case .keyboardUpArrow: onNudge?(0, -step)
        case .keyboardDownArrow: onNudge?(0, step)
        case .keyboardEscape: selectedIDs = []
        case .keyboardReturnOrEnter:
            if let s = selectedShapes.first, selectedIDs.count == 1, s.kind != .image, s.kind != .line {
                if s.kind == .table { delegate?.canvasEditTable(s.id) } else { delegate?.canvasBeginTextEditing(s.id) }
            }
        default: super.pressesBegan(presses, with: event)
        }
    }

    override func copy(_ sender: Any?) { delegate?.canvasCopy(cut: false) }
    override func cut(_ sender: Any?) { delegate?.canvasCopy(cut: true) }
    override func paste(_ sender: Any?) { delegate?.canvasPaste() }
    override func selectAll(_ sender: Any?) { selectedIDs = slide.shapes.filter { !$0.locked }.map(\.id) }
    override func delete(_ sender: Any?) { delegate?.canvasDelete() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return !selectedIDs.isEmpty
        case #selector(paste(_:)): return UIPasteboard.general.contains(pasteboardTypes: [SlideEditorViewController.shapePasteboardType]) || UIPasteboard.general.hasImages
        case #selector(selectAll(_:)): return true
        default: return super.canPerformAction(action, withSender: sender)
        }
    }
}
