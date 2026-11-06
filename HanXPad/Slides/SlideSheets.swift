import UIKit
import Vision

// MARK: - Form helpers

private func formRow(_ title: String, _ control: UIView) -> UIStackView {
    let l = UILabel()
    l.text = title
    l.font = .systemFont(ofSize: 15)
    l.setContentHuggingPriority(.required, for: .horizontal)
    let s = UIStackView(arrangedSubviews: [l, UIView(), control])
    s.spacing = 10
    s.alignment = .center
    return s
}

private func numberField(_ value: Double) -> UITextField {
    let f = UITextField()
    f.text = SheetValue.general((value * 10).rounded() / 10)
    f.keyboardType = .decimalPad
    f.borderStyle = .roundedRect
    f.textAlignment = .right
    f.widthAnchor.constraint(equalToConstant: 100).isActive = true
    return f
}

private func number(_ f: UITextField) -> Double? {
    Double((f.text ?? "").replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
}

private func formStack(_ rows: [UIView], in view: UIView) {
    let stack = UIStackView(arrangedSubviews: rows)
    stack.axis = .vertical
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.keyboardDismissMode = .interactive
    scroll.addSubview(stack)
    view.addSubview(scroll)
    NSLayoutConstraint.activate([
        scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
        stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -18),
        stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 18),
        stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -18),
    ])
}

// MARK: - 크기 위치 (shape inspector)

final class ShapeInspectorViewController: UIViewController {
    private var shape: SlideShape
    private let completion: (SlideShape) -> Void
    private let x: UITextField, y: UITextField, w: UITextField, h: UITextField, rotation: UITextField
    private let name = UITextField()
    private let aspect = UISwitch()
    private let wrap = UISwitch()
    private let anchor = UISegmentedControl(items: ["위", "가운데", "아래"])
    private let kindButton = UIButton(type: .system)
    private var kind: ShapeKind

    init(shape: SlideShape, completion: @escaping (SlideShape) -> Void) {
        self.shape = shape
        self.completion = completion
        kind = shape.kind
        x = numberField(shape.frame.x); y = numberField(shape.frame.y)
        w = numberField(shape.frame.w); h = numberField(shape.frame.h)
        rotation = numberField(shape.rotation)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "크기와 위치"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })
        name.text = shape.name
        name.borderStyle = .roundedRect
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        aspect.isOn = shape.lockAspect
        wrap.isOn = shape.wrap
        anchor.selectedSegmentIndex = shape.anchor == .top ? 0 : shape.anchor == .center ? 1 : 2
        var c = UIButton.Configuration.bordered()
        c.title = kind.title
        kindButton.configuration = c
        kindButton.showsMenuAsPrimaryAction = true
        let kinds = ShapeKind.allCases.filter { ![.image, .table, .line].contains($0) }
        kindButton.menu = UIMenu(children: kinds.map { k in UIAction(title: k.title) { [weak self] _ in self?.kind = k; self?.kindButton.configuration?.title = k.title } })
        var rows: [UIView] = [formRow("이름", name), formRow("X (pt)", x), formRow("Y (pt)", y), formRow("너비 (pt)", w), formRow("높이 (pt)", h),
                              formRow("회전 (°)", rotation), formRow("비율 고정", aspect)]
        if ![.image, .table, .line].contains(shape.kind) {
            rows += [formRow("모양", kindButton), formRow("텍스트 세로 정렬", anchor), formRow("자동 줄 바꿈", wrap)]
        }
        formStack(rows, in: view)
    }

    private func finish() {
        guard let xv = number(x), let yv = number(y), let wv = number(w), let hv = number(h), let rv = number(rotation), wv >= 1, hv >= 0 else {
            presentMessage("값을 확인하세요", "너비는 1pt 이상이어야 합니다."); return
        }
        shape.frame = Frame(x: xv, y: yv, w: wv, h: hv)
        shape.rotation = (rv.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        shape.lockAspect = aspect.isOn
        shape.name = name.text ?? shape.name
        if ![.image, .table, .line].contains(shape.kind) {
            shape.kind = kind
            shape.wrap = wrap.isOn
            shape.anchor = [CellVAlign.top, .center, .bottom][max(0, anchor.selectedSegmentIndex)]
        }
        completion(shape)
        dismiss(animated: true)
    }
}

// MARK: - 배경 직접 설정

final class BackgroundEditorViewController: UIViewController {
    private var slide: Slide
    private let completion: (Slide) -> Void
    private let start = UIColorWell(), middle = UIColorWell(), end = UIColorWell()
    private let gradient = UISwitch(), useMiddle = UISwitch()
    private let angle = UISlider(), middlePosition = UISlider()
    private let preview = UIImageView()
    private let removePicture = UIButton(type: .system)

    init(slide: Slide, completion: @escaping (Slide) -> Void) {
        self.slide = slide
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "배경 직접 설정"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.read()
            self.completion(self.slide)
            self.dismiss(animated: true)
        })
        start.selectedColor = (slide.background ?? .white).uiColor
        end.selectedColor = (slide.backgroundEnd ?? RGB(r: 128, g: 180, b: 230)).uiColor
        middle.selectedColor = (slide.backgroundMiddle ?? RGB(r: 200, g: 220, b: 240)).uiColor
        gradient.isOn = slide.backgroundEnd != nil
        useMiddle.isOn = slide.backgroundMiddle != nil
        angle.minimumValue = 0; angle.maximumValue = 360; angle.value = Float(slide.gradientAngle)
        middlePosition.minimumValue = 1; middlePosition.maximumValue = 99; middlePosition.value = Float(slide.backgroundMiddlePosition ?? 50)
        for s in [angle, middlePosition] { s.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        for c in [start, middle, end] as [UIControl] { c.addAction(UIAction { [weak self] _ in self?.updatePreview() }, for: .valueChanged) }
        for c in [gradient, useMiddle, angle, middlePosition] as [UIControl] { c.addAction(UIAction { [weak self] _ in self?.updatePreview() }, for: .valueChanged) }
        preview.contentMode = .scaleAspectFit
        preview.layer.borderColor = HanXTheme.border.cgColor
        preview.layer.borderWidth = 1
        preview.heightAnchor.constraint(equalToConstant: 160).isActive = true
        var rc = UIButton.Configuration.bordered()
        rc.title = "배경 그림 제거"
        removePicture.configuration = rc
        removePicture.isHidden = slide.backgroundImage == nil
        removePicture.addAction(UIAction { [weak self] _ in self?.slide.backgroundImage = nil; self?.removePicture.isHidden = true; self?.updatePreview() }, for: .primaryActionTriggered)
        formStack([preview, formRow("시작 색", start), formRow("그라데이션", gradient), formRow("끝 색", end), formRow("가운데 색 사용", useMiddle),
                   formRow("가운데 색", middle), formRow("가운데 위치", middlePosition), formRow("방향 (각도)", angle), removePicture], in: view)
        updatePreview()
    }

    private func read() {
        slide.background = RGB(start.selectedColor ?? .white)
        slide.backgroundEnd = gradient.isOn ? RGB(end.selectedColor ?? .white) : nil
        slide.backgroundMiddle = gradient.isOn && useMiddle.isOn ? RGB(middle.selectedColor ?? .white) : nil
        slide.backgroundMiddlePosition = gradient.isOn && useMiddle.isOn ? Double(middlePosition.value) : nil
        slide.backgroundAngle = gradient.isOn ? Double(angle.value) : nil
    }

    private func updatePreview() {
        read()
        let p = Presentation()
        var s = slide
        s.shapes = []
        p.slides = [s]
        preview.image = SlideRenderer.thumbnail(s, p, width: 480)
    }
}

// MARK: - 효과 넘김 설정

final class TransitionOptionsViewController: UIViewController {
    private var transition: SlideTransition
    private let completion: (SlideTransition) -> Void
    private let kindButton = UIButton(type: .system)
    private let duration: UITextField
    private let direction = UISegmentedControl(items: AnimDirection.allCases.map(\.title))
    private let vertical = UISwitch(), inward = UISwitch(), onClick = UISwitch(), automatic = UISwitch()
    private let after: UITextField

    init(transition: SlideTransition, completion: @escaping (SlideTransition) -> Void) {
        self.transition = transition
        self.completion = completion
        duration = numberField(transition.duration)
        after = numberField(transition.advanceAfter ?? 5)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "화면 전환 설정"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })
        var c = UIButton.Configuration.bordered()
        c.title = transition.kind.title
        kindButton.configuration = c
        kindButton.showsMenuAsPrimaryAction = true
        kindButton.menu = UIMenu(children: TransitionKind.allCases.map { k in
            UIAction(title: k.title) { [weak self] _ in self?.transition.kind = k; self?.kindButton.configuration?.title = k.title }
        })
        direction.selectedSegmentIndex = AnimDirection.allCases.firstIndex(of: transition.direction) ?? 0
        vertical.isOn = transition.vertical
        inward.isOn = transition.inward
        onClick.isOn = transition.advanceOnClick
        automatic.isOn = transition.advanceAfter != nil
        formStack([formRow("전환 효과", kindButton), formRow("전환 시간 (초)", duration), formRow("방향", direction),
                   formRow("세로 방향", vertical), formRow("안쪽으로", inward), formRow("클릭할 때 넘기기", onClick),
                   formRow("자동으로 넘기기", automatic), formRow("넘기기까지 (초)", after)], in: view)
    }

    private func finish() {
        guard let d = number(duration), d > 0, d <= 60 else { presentMessage("전환 시간을 확인하세요", "0초보다 크고 60초 이하로 입력하세요."); return }
        transition.duration = d
        transition.direction = AnimDirection.allCases[max(0, direction.selectedSegmentIndex)]
        transition.vertical = vertical.isOn
        transition.inward = inward.isOn
        transition.advanceOnClick = onClick.isOn
        transition.advanceAfter = automatic.isOn ? max(0, number(after) ?? 5) : nil
        completion(transition)
        dismiss(animated: true)
    }
}

// MARK: - 애니메이션 창

final class AnimationPaneViewController: UITableViewController {
    private var slide: Slide
    private let selected: [Int]
    private let onChange: ([SlideAnimation]) -> Void
    private let onPlay: () -> Void

    init(slide: Slide, selected: [Int], onChange: @escaping ([SlideAnimation]) -> Void, onPlay: @escaping () -> Void) {
        self.slide = slide
        self.selected = selected
        self.onChange = onChange
        self.onPlay = onPlay
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "애니메이션"
        let menu = UIMenu(children: AnimClass.allCases.map { cls in
            UIMenu(title: cls == .entrance ? "나타내기" : cls == .emphasis ? "강조" : "끝내기", children: AnimEffect.allCases.filter { $0.animClass == cls }.map { e in
                UIAction(title: e.title) { [weak self] _ in self?.add(e) }
            })
        })
        let addItem = UIBarButtonItem(title: "효과 추가", image: UIImage(systemName: "plus"), menu: menu)
        addItem.isEnabled = !selected.isEmpty
        navigationItem.rightBarButtonItems = [addItem, editButtonItem]
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "재생", image: UIImage(systemName: "play.fill"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.onPlay() }
        })
    }

    private func name(_ id: Int) -> String {
        guard let s = slide.shapes.first(where: { $0.id == id }) else { return "개체 \(id)" }
        let text = s.paragraphs.map(\.plainText).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? (s.name.isEmpty ? s.kind.title : s.name) : String(text.prefix(24))
    }

    private func add(_ effect: AnimEffect) {
        for id in selected {
            var a = SlideAnimation(shapeID: id, effect: effect)
            a.duration = effect.defaultDuration
            a.trigger = slide.animations.isEmpty ? .onClick : .afterPrevious
            slide.animations.append(a)
        }
        changed()
    }

    private func changed() {
        onChange(slide.animations)
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, slide.animations.count) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        selected.isEmpty ? "캔버스에서 개체를 선택한 뒤 효과를 추가하세요." : "선택한 개체 \(selected.count)개에 효과를 추가합니다."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var c = cell.defaultContentConfiguration()
        if slide.animations.isEmpty {
            c.text = "효과 없음"
            c.textProperties.color = .secondaryLabel
        } else {
            let a = slide.animations[indexPath.row]
            c.text = "\(indexPath.row + 1). \(a.effect.title) — \(name(a.shapeID))"
            c.secondaryText = "\(a.trigger.title) · \(SheetValue.general(a.duration))초" + (a.delay > 0 ? " · 지연 \(SheetValue.general(a.delay))초" : "")
            c.image = UIImage(systemName: a.effect.animClass == .entrance ? "arrow.down.right.circle" : a.effect.animClass == .emphasis ? "star.circle" : "arrow.up.right.circle")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = c
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !slide.animations.isEmpty }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { !slide.animations.isEmpty }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, slide.animations.indices.contains(indexPath.row) else { return }
        slide.animations.remove(at: indexPath.row)
        changed()
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let a = slide.animations.remove(at: sourceIndexPath.row)
        slide.animations.insert(a, at: destinationIndexPath.row)
        onChange(slide.animations)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard slide.animations.indices.contains(indexPath.row) else { return }
        let i = indexPath.row
        let detail = AnimationDetailViewController(animation: slide.animations[i]) { [weak self] a in
            self?.slide.animations[i] = a
            self?.changed()
        }
        navigationController?.pushViewController(detail, animated: true)
    }
}

final class AnimationDetailViewController: UIViewController {
    private var animation: SlideAnimation
    private let completion: (SlideAnimation) -> Void
    private let effectButton = UIButton(type: .system)
    private let trigger = UISegmentedControl(items: AnimTrigger.allCases.map(\.title))
    private let direction = UISegmentedControl(items: AnimDirection.allCases.map(\.title))
    private let duration: UITextField, delay: UITextField

    init(animation: SlideAnimation, completion: @escaping (SlideAnimation) -> Void) {
        self.animation = animation
        self.completion = completion
        duration = numberField(animation.duration)
        delay = numberField(animation.delay)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "효과 옵션"
        view.backgroundColor = .systemGroupedBackground
        var c = UIButton.Configuration.bordered()
        c.title = animation.effect.title
        effectButton.configuration = c
        effectButton.showsMenuAsPrimaryAction = true
        effectButton.menu = UIMenu(children: AnimEffect.allCases.filter { $0.animClass == animation.effect.animClass }.map { e in
            UIAction(title: e.title) { [weak self] _ in self?.animation.effect = e; self?.effectButton.configuration?.title = e.title }
        })
        trigger.selectedSegmentIndex = AnimTrigger.allCases.firstIndex(of: animation.trigger) ?? 0
        direction.selectedSegmentIndex = AnimDirection.allCases.firstIndex(of: animation.direction) ?? 0
        formStack([formRow("효과", effectButton), formRow("시작", trigger), formRow("방향", direction),
                   formRow("재생 시간 (초)", duration), formRow("지연 (초)", delay)], in: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        animation.trigger = AnimTrigger.allCases[max(0, trigger.selectedSegmentIndex)]
        animation.direction = AnimDirection.allCases[max(0, direction.selectedSegmentIndex)]
        animation.duration = max(0, min(60, number(duration) ?? animation.duration))
        animation.delay = max(0, min(60, number(delay) ?? animation.delay))
        completion(animation)
    }
}

// MARK: - Picture tools

private func decodeBitmap(_ data: Data, preview: Bool) throws -> SolidBackgroundRemoval.Bitmap {
    try SolidBackgroundRemoval.decode(data, maximumDimension: preview ? 900 : nil)
}

private func image(_ bitmap: SolidBackgroundRemoval.Bitmap) -> UIImage? {
    (try? bitmap.cgImage()).map { UIImage(cgImage: $0) }
}

/// 자르기: drag the corners of the crop rectangle.
final class ImageCropViewController: UIViewController {
    private let data: Data
    private let completion: (Data, CGRect) -> Void
    private let imageView = UIImageView()
    private let overlay = CropOverlayView()

    init(data: Data, completion: @escaping (Data, CGRect) -> Void) {
        self.data = data
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "그림 자르기"
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "자르기", style: .done, target: self, action: #selector(apply)),
            UIBarButtonItem(title: "초기화", style: .plain, target: self, action: #selector(reset)),
        ]
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(data: data)?.normalizedOrientation()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        view.addSubview(overlay)
        for v in [imageView, overlay] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
                v.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            ])
        }
        overlay.imageSize = imageView.image?.size ?? .zero
    }

    @objc private func reset() { overlay.selection = SlideImageCrop.full }

    @objc private func apply() {
        do {
            let bitmap = try decodeBitmap(data, preview: false)
            let (png, region) = try SlideImageCrop.crop(bitmap, selection: overlay.selection)
            dismiss(animated: true) { self.completion(png, region) }
        } catch { presentError(error) }
    }
}

final class CropOverlayView: UIView {
    var imageSize: CGSize = .zero { didSet { setNeedsDisplay() } }
    var selection = SlideImageCrop.full { didSet { setNeedsDisplay() } }
    private var handle: Int?
    private var start: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var imageRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let k = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * k, h = imageSize.height * k
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private var cropRect: CGRect {
        let r = imageRect
        return CGRect(x: r.minX + selection.minX * r.width, y: r.minY + selection.minY * r.height, width: selection.width * r.width, height: selection.height * r.height)
    }

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let c = cropRect
        g.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        g.addRect(imageRect); g.addRect(c)
        g.fillPath(using: .evenOdd)
        g.setStrokeColor(UIColor.white.cgColor)
        g.setLineWidth(2)
        g.stroke(c)
        g.setLineWidth(0.5)
        for i in 1...2 {
            let x = c.minX + c.width * CGFloat(i) / 3, y = c.minY + c.height * CGFloat(i) / 3
            g.move(to: CGPoint(x: x, y: c.minY)); g.addLine(to: CGPoint(x: x, y: c.maxY))
            g.move(to: CGPoint(x: c.minX, y: y)); g.addLine(to: CGPoint(x: c.maxX, y: y))
        }
        g.strokePath()
        g.setFillColor(UIColor.white.cgColor)
        for p in corners(c) { g.fill(CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)) }
    }

    private func corners(_ c: CGRect) -> [CGPoint] {
        [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY), CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: c.minX, y: c.maxY)]
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let r = imageRect
        switch g.state {
        case .began:
            start = selection
            handle = corners(cropRect).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 30 } ?? (cropRect.contains(p) ? 4 : nil)
        case .changed:
            guard let h = handle, r.width > 0, r.height > 0 else { return }
            let t = g.translation(in: self)
            let dx = t.x / r.width, dy = t.y / r.height
            var s = start
            switch h {
            case 0: s = CGRect(x: start.minX + dx, y: start.minY + dy, width: start.width - dx, height: start.height - dy)
            case 1: s = CGRect(x: start.minX, y: start.minY + dy, width: start.width + dx, height: start.height - dy)
            case 2: s = CGRect(x: start.minX, y: start.minY, width: start.width + dx, height: start.height + dy)
            case 3: s = CGRect(x: start.minX + dx, y: start.minY, width: start.width - dx, height: start.height + dy)
            default: s = start.offsetBy(dx: dx, dy: dy)
                s.origin.x = max(0, min(1 - s.width, s.minX)); s.origin.y = max(0, min(1 - s.height, s.minY))
            }
            s = s.standardized.intersection(SlideImageCrop.full)
            if s.width > 0.02 && s.height > 0.02 { selection = s }
        default: handle = nil
        }
    }
}

/// 그림 보정: opacity, brightness, contrast, saturation, skew, perspective, filter.
final class ImageAdjustmentsViewController: UIViewController {
    private let data: Data
    private let completion: (Data) -> Void
    private let imageView = UIImageView()
    private var previewBitmap: SolidBackgroundRemoval.Bitmap?
    private var settings = ImageAdjustments.Settings()
    private var sliders: [String: UISlider] = [:]
    private let filter = UISegmentedControl(items: ["원본", "흑백", "세피아", "반전"])
    private var pending = false

    init(data: Data, completion: @escaping (Data) -> Void) {
        self.data = data
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "그림 보정"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "적용", style: .done, target: self, action: #selector(apply))
        previewBitmap = try? decodeBitmap(data, preview: true)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = UIColor(patternImage: checkerboard())
        imageView.heightAnchor.constraint(equalToConstant: 280).isActive = true
        func slider(_ key: String, _ range: ClosedRange<Float>, _ value: Float) -> UISlider {
            let s = UISlider()
            s.minimumValue = range.lowerBound; s.maximumValue = range.upperBound; s.value = value
            s.widthAnchor.constraint(equalToConstant: 260).isActive = true
            s.addAction(UIAction { [weak self] _ in self?.changed() }, for: .valueChanged)
            sliders[key] = s
            return s
        }
        filter.selectedSegmentIndex = 0
        filter.addAction(UIAction { [weak self] _ in self?.changed() }, for: .valueChanged)
        formStack([imageView,
                   formRow("투명도 (%)", slider("opacity", 0...100, 100)), formRow("밝기", slider("brightness", -100...100, 0)),
                   formRow("대비", slider("contrast", -100...100, 0)), formRow("채도 (%)", slider("saturation", 0...200, 100)),
                   formRow("가로 기울이기 (°)", slider("skewX", -30...30, 0)), formRow("세로 기울이기 (°)", slider("skewY", -30...30, 0)),
                   formRow("가로 원근", slider("perspectiveX", -75...75, 0)), formRow("세로 원근", slider("perspectiveY", -75...75, 0)),
                   formRow("필터", filter)], in: view)
        render()
    }

    private func read() {
        func v(_ k: String) -> Double { Double(sliders[k]?.value ?? 0).rounded() }
        settings.opacity = v("opacity"); settings.brightness = v("brightness"); settings.contrast = v("contrast"); settings.saturation = v("saturation")
        settings.skewX = v("skewX"); settings.skewY = v("skewY"); settings.perspectiveX = v("perspectiveX"); settings.perspectiveY = v("perspectiveY")
        settings.filter = [ImageAdjustments.Filter.normal, .grayscale, .sepia, .invert][max(0, filter.selectedSegmentIndex)]
    }

    private func changed() {
        read()
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pending = false; self?.render() }
    }

    private func render() {
        guard let b = previewBitmap, let rgba = try? ImageAdjustments.apply(b.rgba, width: b.width, height: b.height, settings: settings) else {
            imageView.image = UIImage(data: data); return
        }
        imageView.image = image(SolidBackgroundRemoval.Bitmap(rgba: rgba, width: b.width, height: b.height))
    }

    @objc private func apply() {
        read()
        do {
            let b = try decodeBitmap(data, preview: false)
            let rgba = try ImageAdjustments.apply(b.rgba, width: b.width, height: b.height, settings: settings)
            let png = try SolidBackgroundRemoval.Bitmap(rgba: rgba, width: b.width, height: b.height).png()
            dismiss(animated: true) { self.completion(png) }
        } catch { presentError(error) }
    }
}

private func checkerboard() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
        UIColor(white: 0.92, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        UIColor(white: 0.8, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
    }
}

/// 배경 제거: subject detection (Vision) or edge-connected solid colour.
final class BackgroundRemovalViewController: UIViewController {
    private let data: Data
    private let completion: (Data) -> Void
    private let imageView = UIImageView()
    private let mode = UISegmentedControl(items: ["피사체 자동 인식", "단색 배경"])
    private let tolerance = UISlider()
    private let feather = UISlider()
    private let status = UILabel()
    private var preview: SolidBackgroundRemoval.Bitmap?
    private var mask: ImageBackgroundMask?

    init(data: Data, completion: @escaping (Data) -> Void) {
        self.data = data
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "배경 제거"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "적용", style: .done, target: self, action: #selector(apply))
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = UIColor(patternImage: checkerboard())
        imageView.heightAnchor.constraint(equalToConstant: 320).isActive = true
        mode.selectedSegmentIndex = 0
        tolerance.minimumValue = 0; tolerance.maximumValue = 120; tolerance.value = 32
        feather.minimumValue = 0; feather.maximumValue = 12; feather.value = 1
        for s in [tolerance, feather] { s.widthAnchor.constraint(equalToConstant: 240).isActive = true }
        for c in [mode, tolerance, feather] as [UIControl] { c.addAction(UIAction { [weak self] _ in self?.update() }, for: .valueChanged) }
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        formStack([imageView, mode, formRow("색 허용 범위", tolerance), formRow("가장자리 부드럽게", feather), status], in: view)
        preview = try? decodeBitmap(data, preview: true)
        update()
    }

    private func update() {
        guard let preview else { status.text = "그림을 읽을 수 없습니다."; return }
        tolerance.isEnabled = mode.selectedSegmentIndex == 1
        feather.isEnabled = mode.selectedSegmentIndex == 0
        if mode.selectedSegmentIndex == 1 {
            let result = try? preview.removing(color: preview.backgroundColor, tolerance: Double(tolerance.value))
            imageView.image = result.flatMap(image)
            status.text = "그림 가장자리와 이어진 같은 색 영역만 지웁니다."
            return
        }
        if let mask {
            imageView.image = (try? mask.feathered(radius: Int(feather.value)).applying(to: preview)).flatMap(image)
            return
        }
        status.text = "피사체를 찾는 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = try? SubjectBackgroundRemoval.mask(for: preview, request: VNGenerateForegroundInstanceMaskRequest())
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mask = found
                self.status.text = found == nil ? "피사체를 찾지 못했습니다. 단색 배경 모드를 사용해 보세요." : "인물·사물을 남기고 배경을 지웁니다."
                if found != nil { self.update() }
            }
        }
    }

    @objc private func apply() {
        let removeSolid = mode.selectedSegmentIndex == 1
        let tol = Double(tolerance.value), radius = Int(feather.value)
        let data = self.data
        status.text = "처리 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let full = try decodeBitmap(data, preview: false)
                let result: SolidBackgroundRemoval.Bitmap
                if removeSolid {
                    result = try full.removing(color: full.backgroundColor, tolerance: tol)
                } else {
                    let m = try SubjectBackgroundRemoval.mask(for: full, request: VNGenerateForegroundInstanceMaskRequest())
                    result = try m.feathered(radius: radius).applying(to: full)
                }
                let png = try result.png()
                DispatchQueue.main.async { self.dismiss(animated: true) { self.completion(png) } }
            } catch {
                DispatchQueue.main.async { self.status.text = HanXError.describe(error) }
            }
        }
    }
}
