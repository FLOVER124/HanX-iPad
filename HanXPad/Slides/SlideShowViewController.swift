import UIKit
import AVFoundation

/// Plays slide transitions between two rendered slides inside `stage`.
enum TransitionPlayer {
    static func run(_ t: SlideTransition, from: UIImage, to: UIImage, in stage: UIView, completion: @escaping () -> Void) {
        let bounds = stage.bounds
        let old = UIImageView(image: from), new = UIImageView(image: to)
        for v in [old, new] { v.frame = bounds; v.contentMode = .scaleToFill; stage.addSubview(v) }
        let d = max(0.05, t.duration)
        func finish() { old.removeFromSuperview(); new.removeFromSuperview(); completion() }
        let dx: CGFloat, dy: CGFloat
        switch t.direction {
        case .left: dx = -1; dy = 0
        case .right: dx = 1; dy = 0
        case .top: dx = 0; dy = -1
        case .bottom: dx = 0; dy = 1
        }
        // "From the right" means the new slide enters from the right edge.
        let enter = CGAffineTransform(translationX: dx * bounds.width, y: dy * bounds.height)
        let exit = CGAffineTransform(translationX: -dx * bounds.width, y: -dy * bounds.height)
        switch t.kind {
        case .none, .cut:
            old.isHidden = true
            DispatchQueue.main.async(execute: finish)
        case .fade, .dissolve:
            new.alpha = 0
            UIView.animate(withDuration: d, animations: { new.alpha = 1 }, completion: { _ in finish() })
        case .push:
            new.transform = enter
            UIView.animate(withDuration: d, delay: 0, options: .curveEaseInOut, animations: { new.transform = .identity; old.transform = exit }, completion: { _ in finish() })
        case .cover:
            new.transform = enter
            UIView.animate(withDuration: d, delay: 0, options: .curveEaseOut, animations: { new.transform = .identity }, completion: { _ in finish() })
        case .pull:
            stage.bringSubviewToFront(old)
            UIView.animate(withDuration: d, delay: 0, options: .curveEaseIn, animations: { old.transform = exit }, completion: { _ in finish() })
        case .zoom:
            new.transform = t.inward ? CGAffineTransform(scaleX: 1.6, y: 1.6) : CGAffineTransform(scaleX: 0.2, y: 0.2)
            new.alpha = 0
            UIView.animate(withDuration: d, delay: 0, options: .curveEaseOut, animations: { new.transform = .identity; new.alpha = 1 }, completion: { _ in finish() })
        case .newsflash:
            new.transform = CGAffineTransform(rotationAngle: .pi).scaledBy(x: 0.05, y: 0.05)
            UIView.animate(withDuration: d, delay: 0, options: .curveEaseOut, animations: { new.transform = .identity }, completion: { _ in finish() })
        default:
            maskTransition(t, new: new, bounds: bounds, duration: d, completion: finish)
        }
    }

    /// Reveal effects built from an animated mask on the incoming slide.
    private static func maskTransition(_ t: SlideTransition, new: UIView, bounds: CGRect, duration d: Double, completion: @escaping () -> Void) {
        let mask = CAShapeLayer()
        mask.frame = bounds
        new.layer.mask = mask
        let w = bounds.width, h = bounds.height
        let diagonal = hypot(w, h)
        func rects(_ progress: CGFloat) -> CGPath {
            let p = CGMutablePath()
            switch t.kind {
            case .wipe:
                switch t.direction {
                case .right: p.addRect(CGRect(x: w * (1 - progress), y: 0, width: w * progress, height: h))
                case .left: p.addRect(CGRect(x: 0, y: 0, width: w * progress, height: h))
                case .top: p.addRect(CGRect(x: 0, y: 0, width: w, height: h * progress))
                case .bottom: p.addRect(CGRect(x: 0, y: h * (1 - progress), width: w, height: h * progress))
                }
            case .split:
                if t.vertical { p.addRect(CGRect(x: w / 2 * (1 - progress), y: 0, width: w * progress, height: h)) }
                else { p.addRect(CGRect(x: 0, y: h / 2 * (1 - progress), width: w, height: h * progress)) }
            case .blinds, .comb, .strips, .randomBar:
                let n = t.kind == .randomBar ? 24 : 10
                for i in 0..<n {
                    if t.vertical {
                        let band = w / CGFloat(n)
                        p.addRect(CGRect(x: CGFloat(i) * band, y: 0, width: band * progress, height: h))
                    } else {
                        let band = h / CGFloat(n)
                        p.addRect(CGRect(x: 0, y: CGFloat(i) * band, width: w, height: band * progress))
                    }
                }
            case .checker:
                let n = 8, cw = w / CGFloat(n), ch = h / CGFloat(n)
                for r in 0..<n { for c in 0..<n {
                    let offset = (r + c) % 2 == 0 ? 0 : 0.5
                    let local = max(0, min(1, (progress - CGFloat(offset) * 0.5) * 2))
                    p.addRect(CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch, width: cw * local, height: ch))
                } }
            case .circle:
                let rr = diagonal / 2 * progress
                p.addEllipse(in: CGRect(x: w / 2 - rr, y: h / 2 - rr, width: rr * 2, height: rr * 2))
            case .diamond:
                let rr = diagonal * progress
                p.move(to: CGPoint(x: w / 2, y: h / 2 - rr)); p.addLine(to: CGPoint(x: w / 2 + rr, y: h / 2))
                p.addLine(to: CGPoint(x: w / 2, y: h / 2 + rr)); p.addLine(to: CGPoint(x: w / 2 - rr, y: h / 2)); p.closeSubpath()
            case .plus:
                p.addRect(CGRect(x: w / 2 - w / 2 * progress, y: 0, width: w * progress, height: h).insetBy(dx: 0, dy: h / 2 * (1 - progress)))
                p.addRect(CGRect(x: 0, y: h / 2 - h / 2 * progress, width: w, height: h * progress).insetBy(dx: w / 2 * (1 - progress), dy: 0))
                p.addRect(CGRect(x: w / 2 - w * progress / 4, y: 0, width: w * progress / 2, height: h))
                p.addRect(CGRect(x: 0, y: h / 2 - h * progress / 4, width: w, height: h * progress / 2))
            case .wedge, .wheel:
                let spokes = t.kind == .wheel ? 4 : 1
                let c = CGPoint(x: w / 2, y: h / 2)
                for s in 0..<spokes {
                    let start = -CGFloat.pi / 2 + CGFloat(s) * 2 * .pi / CGFloat(spokes)
                    let sweep = 2 * .pi / CGFloat(spokes) * progress
                    p.move(to: c)
                    if t.kind == .wedge {
                        p.addArc(center: c, radius: diagonal, startAngle: start - sweep / 2 * CGFloat(spokes), endAngle: start + sweep / 2 * CGFloat(spokes), clockwise: false)
                    } else {
                        p.addArc(center: c, radius: diagonal, startAngle: start, endAngle: start + sweep, clockwise: false)
                    }
                    p.closeSubpath()
                }
            default:
                p.addRect(CGRect(x: 0, y: 0, width: w * progress, height: h))
            }
            return p
        }
        let steps = max(2, Int(d * 60))
        var frame = 0
        mask.path = rects(0.001)
        let link = DisplayLinkTarget { link in
            frame += 1
            let progress = min(1, CGFloat(frame) / CGFloat(steps))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.path = rects(progress)
            CATransaction.commit()
            if progress >= 1 {
                link.invalidate()
                new.layer.mask = nil
                completion()
            }
        }
        link.start()
    }
}

/// CADisplayLink with a closure (keeps itself alive until invalidated).
final class DisplayLinkTarget: NSObject {
    private var link: CADisplayLink?
    private let tick: (DisplayLinkTarget) -> Void
    private var retainSelf: DisplayLinkTarget?

    init(_ tick: @escaping (DisplayLinkTarget) -> Void) { self.tick = tick }

    func start() {
        retainSelf = self
        let l = CADisplayLink(target: self, selector: #selector(fire))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func fire() { tick(self) }

    func invalidate() {
        link?.invalidate()
        link = nil
        retainSelf = nil
    }
}

/// Full-screen slide show: transitions, click / with / after animations,
/// automatic advance, embedded movies. Tap or swipe, Space/arrows on a
/// keyboard, or a presenter remote (arrow keys) to advance.
final class SlideShowViewController: UIViewController {
    private let pres: Presentation
    private var index: Int
    private let stage = UIView()
    private var baseView = UIImageView()
    private var shapeLayers: [Int: UIImageView] = [:]
    private var steps: [[SlideAnimation]] = []
    private var step = 0
    private var busy = false
    private var advanceTimer: Timer?
    private var players: [AVPlayerLayer] = []
    private let hint = UILabel()

    init(presentation: Presentation, start: Int) {
        pres = presentation
        index = max(0, min(start, presentation.slides.count - 1))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stage.clipsToBounds = true
        view.addSubview(stage)
        let tap = UITapGestureRecognizer(target: self, action: #selector(next))
        let back = UISwipeGestureRecognizer(target: self, action: #selector(previous)); back.direction = .right
        let forward = UISwipeGestureRecognizer(target: self, action: #selector(next)); forward.direction = .left
        let close = UISwipeGestureRecognizer(target: self, action: #selector(closeShow)); close.direction = .down
        for g in [tap, back, forward, close] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
        hint.text = "탭 또는 → 다음 · 오른쪽으로 쓸기 이전 · 아래로 쓸기 종료"
        hint.textColor = UIColor.white.withAlphaComponent(0.7)
        hint.font = .systemFont(ofSize: 13)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        UIView.animate(withDuration: 0.6, delay: 3, options: []) { self.hint.alpha = 0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if baseView.superview == nil { show(index, transition: false) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let k = min(view.bounds.width / CGFloat(pres.width), view.bounds.height / CGFloat(pres.height))
        let size = CGSize(width: CGFloat(pres.width) * k, height: CGFloat(pres.height) * k)
        let frame = CGRect(x: (view.bounds.width - size.width) / 2, y: (view.bounds.height - size.height) / 2, width: size.width, height: size.height)
        if stage.frame != frame {
            stage.frame = frame
            if baseView.superview != nil { show(index, transition: false, keepStep: true) }
        }
    }

    private var scale: CGFloat { stage.bounds.width / CGFloat(pres.width) }

    private func render(_ slide: Slide, hiding: Set<Int>) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let s = scale
        return UIGraphicsImageRenderer(size: stage.bounds.size, format: format).image { ctx in
            ctx.cgContext.scaleBy(x: s, y: s)
            SlideRenderer.draw(slide, pres, skip: hiding)
        }
    }

    /// Shapes that start hidden: those with an entrance effect.
    private func animatedShapes(_ slide: Slide) -> Set<Int> { Set(slide.animations.map(\.shapeID)) }

    private func show(_ i: Int, transition: Bool, keepStep: Bool = false) {
        guard pres.slides.indices.contains(i) else { return }
        advanceTimer?.invalidate()
        players.forEach { $0.player?.pause(); $0.removeFromSuperlayer() }
        players = []
        let previousImage = transition ? UIGraphicsImageRenderer(bounds: stage.bounds).image { _ in stage.drawHierarchy(in: stage.bounds, afterScreenUpdates: false) } : nil
        index = i
        let slide = pres.slides[i]
        // Animated shapes are drawn as separate layers above a static base.
        let animated = animatedShapes(slide)
        stage.subviews.forEach { $0.removeFromSuperview() }
        shapeLayers = [:]
        baseView = UIImageView(image: render(slide, hiding: animated))
        baseView.frame = stage.bounds
        stage.addSubview(baseView)
        for s in slide.shapes where animated.contains(s.id) {
            let (img, rect) = SlideRenderer.shapeImage(s, pres, scale: scale * traitCollection.displayScale)
            let v = UIImageView(image: img)
            v.frame = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            let entrance = slide.animations.first { $0.shapeID == s.id }?.effect.animClass == .entrance
            v.alpha = entrance ? 0 : 1
            stage.addSubview(v)
            shapeLayers[s.id] = v
        }
        steps = buildSteps(slide.animations)
        if !keepStep { step = 0 }
        startMovies(slide)
        if let previousImage, slide.transition.kind != .none {
            busy = true
            let overlay = UIView(frame: stage.bounds)
            stage.addSubview(overlay)
            TransitionPlayer.run(slide.transition, from: previousImage, to: render(slide, hiding: animated), in: overlay) { [weak self] in
                overlay.removeFromSuperview()
                self?.busy = false
                self?.afterShown()
            }
        } else {
            afterShown()
        }
    }

    private func afterShown() {
        // "With previous"/"after previous" effects at the start play without a click.
        if let first = steps.first, first.first?.trigger != .onClick { playStep() }
        scheduleAdvance()
    }

    private func scheduleAdvance() {
        advanceTimer?.invalidate()
        guard pres.slides.indices.contains(index), let after = pres.slides[index].transition.advanceAfter, step >= steps.count else { return }
        advanceTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, after), repeats: false) { [weak self] _ in self?.next() }
    }

    /// Groups animations into click steps; within a step, "after previous" chains.
    private func buildSteps(_ list: [SlideAnimation]) -> [[SlideAnimation]] {
        var out: [[SlideAnimation]] = []
        for a in list {
            if a.trigger == .onClick || out.isEmpty { out.append([a]) } else { out[out.count - 1].append(a) }
        }
        return out
    }

    private func playStep() {
        guard step < steps.count else { return }
        let group = steps[step]
        step += 1
        busy = true
        var start = 0.0, lastEnd = 0.0, groupEnd = 0.0
        for a in group {
            if a.trigger == .afterPrevious { start = lastEnd }
            let begin = start + a.delay
            animate(a, after: begin)
            lastEnd = begin + max(0.01, a.duration)
            groupEnd = max(groupEnd, lastEnd)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + groupEnd + 0.02) { [weak self] in
            guard let self else { return }
            self.busy = false
            // A following step that starts automatically.
            if self.step < self.steps.count, self.steps[self.step].first?.trigger != .onClick { self.playStep() } else { self.scheduleAdvance() }
        }
    }

    private func animate(_ a: SlideAnimation, after delay: Double) {
        guard let v = shapeLayers[a.shapeID] else { return }
        let d = max(0.01, a.duration)
        let w = stage.bounds.width, h = stage.bounds.height
        var offset: CGAffineTransform {
            switch a.direction {
            case .bottom: return CGAffineTransform(translationX: 0, y: h - v.frame.minY)
            case .top: return CGAffineTransform(translationX: 0, y: -v.frame.maxY)
            case .left: return CGAffineTransform(translationX: -v.frame.maxX, y: 0)
            case .right: return CGAffineTransform(translationX: w - v.frame.minX, y: 0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            switch a.effect {
            case .appear: v.alpha = 1
            case .disappear: v.alpha = 0
            case .fade: UIView.animate(withDuration: d) { v.alpha = 1 }
            case .fadeOut: UIView.animate(withDuration: d) { v.alpha = 0 }
            case .flyIn:
                v.transform = offset; v.alpha = 1
                UIView.animate(withDuration: d, delay: 0, options: .curveEaseOut) { v.transform = .identity }
            case .flyOut:
                UIView.animate(withDuration: d, delay: 0, options: .curveEaseIn, animations: { v.transform = offset }, completion: { _ in v.alpha = 0; v.transform = .identity })
            case .floatIn:
                v.transform = CGAffineTransform(translationX: 0, y: 40); v.alpha = 0
                UIView.animate(withDuration: d, delay: 0, options: .curveEaseOut) { v.transform = .identity; v.alpha = 1 }
            case .floatOut:
                UIView.animate(withDuration: d, animations: { v.transform = CGAffineTransform(translationX: 0, y: -40); v.alpha = 0 }, completion: { _ in v.transform = .identity })
            case .zoom:
                v.transform = CGAffineTransform(scaleX: 0.05, y: 0.05); v.alpha = 1
                UIView.animate(withDuration: d, delay: 0, options: .curveEaseOut) { v.transform = .identity }
            case .zoomOut:
                UIView.animate(withDuration: d, animations: { v.transform = CGAffineTransform(scaleX: 0.05, y: 0.05) }, completion: { _ in v.alpha = 0; v.transform = .identity })
            case .wheel:
                v.transform = CGAffineTransform(rotationAngle: -.pi).scaledBy(x: 0.3, y: 0.3); v.alpha = 0
                UIView.animate(withDuration: d) { v.transform = .identity; v.alpha = 1 }
            case .wipe, .split:
                v.alpha = 1
                self.reveal(v, duration: d, split: a.effect == .split, direction: a.direction, hide: false)
            case .wipeOut, .splitOut:
                self.reveal(v, duration: d, split: a.effect == .splitOut, direction: a.direction, hide: true)
            case .spin:
                let r = CABasicAnimation(keyPath: "transform.rotation.z")
                r.fromValue = 0; r.toValue = 2 * Double.pi; r.duration = d
                v.layer.add(r, forKey: "spin")
            case .growShrink:
                UIView.animate(withDuration: d / 2, animations: { v.transform = CGAffineTransform(scaleX: 1.5, y: 1.5) }, completion: { _ in
                    UIView.animate(withDuration: d / 2) { v.transform = .identity }
                })
            case .transparency:
                UIView.animate(withDuration: d / 2, animations: { v.alpha = 0.5 }, completion: { _ in UIView.animate(withDuration: d / 2) { v.alpha = 1 } })
            case .pulse:
                UIView.animate(withDuration: d / 2, animations: { v.transform = CGAffineTransform(scaleX: 1.08, y: 1.08) }, completion: { _ in
                    UIView.animate(withDuration: d / 2) { v.transform = .identity }
                })
            default: v.alpha = a.effect.animClass == .exit ? 0 : 1
            }
        }
    }

    /// Wipe / split as an animated mask on the shape layer.
    private func reveal(_ v: UIView, duration d: Double, split: Bool, direction: AnimDirection, hide: Bool) {
        let mask = CALayer()
        mask.backgroundColor = UIColor.black.cgColor
        let b = v.bounds
        let full = b
        var empty: CGRect
        if split { empty = CGRect(x: b.midX, y: 0, width: 0, height: b.height) }
        else {
            switch direction {
            case .left: empty = CGRect(x: 0, y: 0, width: 0, height: b.height)
            case .right: empty = CGRect(x: b.maxX, y: 0, width: 0, height: b.height)
            case .top: empty = CGRect(x: 0, y: 0, width: b.width, height: 0)
            case .bottom: empty = CGRect(x: 0, y: b.maxY, width: b.width, height: 0)
            }
        }
        mask.frame = hide ? full : empty
        v.layer.mask = mask
        CATransaction.begin()
        CATransaction.setAnimationDuration(d)
        CATransaction.setCompletionBlock {
            v.layer.mask = nil
            if hide { v.alpha = 0 }
        }
        mask.frame = hide ? empty : full
        CATransaction.commit()
    }

    private func startMovies(_ slide: Slide) {
        for s in slide.shapes {
            guard let vid = s.videoID, let d = pres.images[vid] else { continue }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hanx-movie-\(abs(vid.hashValue)).\((vid as NSString).pathExtension.isEmpty ? "mp4" : (vid as NSString).pathExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { try? d.data.write(to: url) }
            let player = AVPlayer(url: url)
            let layer = AVPlayerLayer(player: player)
            layer.frame = CGRect(x: s.frame.x * Double(scale), y: s.frame.y * Double(scale), width: s.frame.w * Double(scale), height: s.frame.h * Double(scale))
            layer.videoGravity = .resizeAspect
            stage.layer.addSublayer(layer)
            players.append(layer)
            player.play()
        }
    }

    @objc private func next() {
        guard !busy else { return }
        if step < steps.count { playStep(); return }
        if index + 1 < pres.slides.count { show(index + 1, transition: true) } else { closeShow() }
    }

    @objc private func previous() {
        guard !busy else { return }
        if index > 0 { show(index - 1, transition: false) }
    }

    @objc private func closeShow() {
        advanceTimer?.invalidate()
        players.forEach { $0.player?.pause() }
        dismiss(animated: true)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { super.pressesBegan(presses, with: event); return }
        switch key.keyCode {
        case .keyboardRightArrow, .keyboardDownArrow, .keyboardSpacebar, .keyboardReturnOrEnter, .keyboardPageDown: next()
        case .keyboardLeftArrow, .keyboardUpArrow, .keyboardPageUp, .keyboardDeleteOrBackspace: previous()
        case .keyboardEscape: closeShow()
        case .keyboardHome: show(0, transition: false)
        case .keyboardEnd: show(pres.slides.count - 1, transition: false)
        default: super.pressesBegan(presses, with: event)
        }
    }
}
