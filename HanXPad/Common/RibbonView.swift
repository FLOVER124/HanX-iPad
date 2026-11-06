import UIKit

/// Ribbon shared by every editor, drawn like the macOS OfficeRibbon: an
/// underlined tab strip, borderless icon-over-title buttons that highlight on
/// press, bordered pop-up and value boxes, captioned groups with separators.
/// Tabs, groups and command ids are the same as on macOS.
final class RibbonView: UIView {
    struct Item {
        enum Kind { case button, menu([String]), field([String]), toggle }
        let id: String
        let title: String
        var symbol: String?
        var kind: Kind = .button

        static func button(_ id: String, _ title: String, _ symbol: String? = nil) -> Item { Item(id: id, title: title, symbol: symbol) }
        static func toggle(_ id: String, _ title: String, _ symbol: String? = nil) -> Item { Item(id: id, title: title, symbol: symbol, kind: .toggle) }
        static func menu(_ id: String, _ title: String, _ options: [String], symbol: String? = nil) -> Item { Item(id: id, title: title, symbol: symbol, kind: .menu(options)) }
        static func field(_ id: String, _ title: String, _ options: [String]) -> Item { Item(id: id, title: title, kind: .field(options)) }
    }
    struct Group { let title: String; let items: [Item] }
    struct Tab { let title: String; let groups: [Group] }

    static let colorMenu = Palette.names + [Palette.custom]
    static let height: CGFloat = 116

    /// (command id, chosen value, index of the chosen option or -1 for typed values)
    var onCommand: ((String, String, Int) -> Void)?
    /// Toggle states (bold, ruler…) and field values (font, size…).
    var isOn: ((String) -> Bool)?
    var currentValue: ((String) -> String?)?
    var isEnabled: ((String) -> Bool)?
    /// Called before a field's "직접 입력…" prompt; return true to handle it yourself.
    var customField: ((String, UIView) -> Bool)?
    weak var host: UIViewController?

    private let tabs: [Tab]
    private let tabBar = RibbonTabBar()
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var controls: [String: UIView] = [:]
    private var items: [String: Item] = [:]
    /// Pop-ups show the option chosen last, as NSPopUpButton does.
    private var chosen: [String: String] = [:]
    private(set) var selectedTab = 0

    init(tabs: [Tab]) {
        self.tabs = tabs
        super.init(frame: .zero)
        backgroundColor = HanXTheme.paper
        tabBar.titles = tabs.map(\.title)
        tabBar.onSelect = { [weak self] i in self?.showTab(i) }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 3, left: 14, bottom: 6, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        let divider = UIView()
        divider.backgroundColor = HanXTheme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tabBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            tabBar.heightAnchor.constraint(equalToConstant: 31),
            scroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: RibbonView.height),
        ])
        showTab(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTab = index
        tabBar.selected = index
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        controls = [:]
        for (gi, group) in tabs[index].groups.enumerated() {
            let buttons = UIStackView()
            buttons.axis = .horizontal
            buttons.spacing = 4
            buttons.alignment = .center
            for item in group.items {
                let control = makeControl(item)
                items[item.id] = item
                controls[item.id] = control
                buttons.addArrangedSubview(control)
            }
            buttons.heightAnchor.constraint(equalToConstant: 50).isActive = true
            let caption = UILabel()
            caption.text = group.title
            caption.font = .systemFont(ofSize: 10.5)
            caption.textColor = HanXTheme.secondary
            caption.textAlignment = .center
            let stack = UIStackView(arrangedSubviews: [buttons, caption])
            stack.axis = .vertical
            stack.spacing = 3
            stack.alignment = .center
            row.addArrangedSubview(stack)
            if gi < tabs[index].groups.count - 1 {
                let line = UIView()
                line.backgroundColor = HanXTheme.border
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                line.heightAnchor.constraint(equalToConstant: 62).isActive = true
                row.addArrangedSubview(line)
            }
        }
        row.addArrangedSubview(UIView())
        scroll.contentOffset = .zero
        refresh()
    }

    func showTab(titled title: String) {
        if let i = tabs.firstIndex(where: { $0.title == title }) { showTab(i) }
    }

    private func makeControl(_ item: Item) -> UIView {
        switch item.kind {
        case .button, .toggle:
            let b = RibbonButton(title: item.title, symbol: item.symbol)
            b.addAction(UIAction { [weak self] _ in self?.onCommand?(item.id, item.title, 0) }, for: .touchUpInside)
            return b
        case .menu(let options):
            let p = RibbonPopup(width: nil)
            p.title = chosen[item.id] ?? options.first ?? item.title
            p.accessibilityLabel = item.title
            p.menu = UIMenu(title: item.title, children: options.enumerated().map { i, option in
                UIAction(title: option) { [weak self, weak p] _ in
                    // Prompts such as "여백 선택…" and "사용자 지정…" do not stick as the shown value.
                    if !option.hasSuffix("…") { self?.chosen[item.id] = option; p?.title = option }
                    self?.onCommand?(item.id, option, i)
                }
            })
            return p
        case .field(let options):
            let p = RibbonPopup(width: item.id == "font" ? 146 : 64)
            p.title = options.first ?? ""
            p.accessibilityLabel = item.title
            p.menu = fieldMenu(item, options: options, control: p)
            return p
        }
    }

    private func fieldMenu(_ item: Item, options: [String], control: UIView) -> UIMenu {
        let typed = UIAction(title: item.id == "font" ? "글꼴 선택…" : "직접 입력…", image: UIImage(systemName: "keyboard")) { [weak self, weak control] _ in
            guard let self, let control else { return }
            if self.customField?(item.id, control) == true { return }
            let current = self.currentValue?(item.id) ?? ""
            self.host?.promptText(item.title, text: current, keyboard: item.id == "font" ? .default : .decimalPad) { value in
                guard let value, !value.isEmpty else { return }
                self.onCommand?(item.id, value, -1)
            }
        }
        let presets = UIMenu(options: .displayInline, children: options.enumerated().map { i, option in
            UIAction(title: option) { [weak self] _ in self?.onCommand?(item.id, option, i) }
        })
        return UIMenu(title: item.title, children: [typed, presets])
    }

    /// Re-reads toggle states, field values and availability.
    func refresh() {
        for (id, control) in controls {
            guard let item = items[id] else { continue }
            let enabled = isEnabled?(id) ?? true
            if let b = control as? RibbonButton {
                if case .toggle = item.kind { b.isOn = isOn?(id) ?? false }
                b.isEnabled = enabled
            } else if let p = control as? RibbonPopup {
                if case .field = item.kind, let value = currentValue?(id) { p.title = value.isEmpty ? "—" : value }
                p.isEnabled = enabled
            }
        }
    }

    func control(_ id: String) -> UIView? { controls[id] }
}

// MARK: - Controls drawn like HWActionButton / HWPopupButton / HWTabControl

/// Borderless icon-over-title button; pressed or "on" shows the selection fill.
final class RibbonButton: UIControl {
    let title: String
    private let image: UIImage?
    var isOn = false { didSet { if oldValue != isOn { setNeedsDisplay(); accessibilityTraits = isOn ? [.button, .selected] : .button } } }
    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }
    override var isEnabled: Bool { didSet { setNeedsDisplay() } }
    private var hovering = false { didSet { setNeedsDisplay() } }

    init(title: String, symbol: String?) {
        self.title = title
        image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)) }
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        let width = max(44, min(108, (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 11.5)]).width + 16))
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: ceil(width)), heightAnchor.constraint(equalToConstant: 48)])
        addInteraction(UIPointerInteraction(delegate: nil))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func hover(_ g: UIHoverGestureRecognizer) { hovering = g.state == .began || g.state == .changed }

    override func draw(_ rect: CGRect) {
        let active = isOn || isHighlighted
        if active || hovering {
            let p = UIBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 4)
            (active ? HanXTheme.selection : HanXTheme.toolbar).setFill()
            p.fill()
            if active { HanXTheme.border.setStroke(); p.lineWidth = 1; p.stroke() }
        }
        let tint: UIColor = !isEnabled ? HanXTheme.secondary.withAlphaComponent(0.45) : active ? HanXTheme.accent : HanXTheme.ink
        if let image {
            let tinted = image.withTintColor(tint, renderingMode: .alwaysOriginal)
            let s = tinted.size
            let k = min(1, 20 / max(s.width, s.height))
            let w = s.width * k, h = s.height * k
            tinted.draw(in: CGRect(x: bounds.midX - w / 2, y: 6 + (20 - h) / 2, width: w, height: h))
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let font = UIFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
        let y: CGFloat = image == nil ? bounds.midY - 8 : bounds.height - 19
        (title as NSString).draw(in: CGRect(x: 3, y: y, width: bounds.width - 6, height: 16),
                                 withAttributes: [.font: font, .foregroundColor: tint, .paragraphStyle: para])
    }
}

/// Bordered value box with a chevron that opens its menu (pop-up / combo box).
final class RibbonPopup: UIButton {
    var title = "" { didSet { if oldValue != title { setNeedsDisplay(); invalidateIntrinsicContentSize(); accessibilityValue = title } } }
    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }
    override var isEnabled: Bool { didSet { setNeedsDisplay() } }
    private let fixedWidth: CGFloat?

    init(width: CGFloat?) {
        fixedWidth = width
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
        showsMenuAsPrimaryAction = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        else { widthAnchor.constraint(lessThanOrEqualToConstant: 175).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let w = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 12)]).width + 34
        return CGSize(width: fixedWidth ?? max(64, min(175, ceil(w))), height: 30)
    }

    override func draw(_ rect: CGRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = UIBezierPath(roundedRect: r, cornerRadius: 4)
        (isEnabled ? (isHighlighted ? HanXTheme.selection : HanXTheme.paper) : HanXTheme.toolbar).setFill()
        p.fill()
        HanXTheme.border.setStroke()
        p.lineWidth = 1
        p.stroke()
        let color = isEnabled ? HanXTheme.ink : HanXTheme.secondary
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: CGRect(x: 9, y: bounds.midY - 8, width: max(1, bounds.width - 29), height: 17),
                                 withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: para])
        let chevron = UIBezierPath()
        chevron.move(to: CGPoint(x: bounds.maxX - 17, y: bounds.midY - 2))
        chevron.addLine(to: CGPoint(x: bounds.maxX - 13, y: bounds.midY + 2))
        chevron.addLine(to: CGPoint(x: bounds.maxX - 9, y: bounds.midY - 2))
        chevron.lineWidth = 1.2
        HanXTheme.secondary.setStroke()
        chevron.stroke()
    }
}

/// Tab strip: plain labels; the selected tab gets the selection fill, accent
/// semibold text and a 2 pt accent underline.
final class RibbonTabBar: UIView {
    var titles: [String] = [] { didSet { rebuild() } }
    var selected = 0 { didSet { buttons.enumerated().forEach { $0.element.isSelected = $0.offset == selected } } }
    var onSelect: ((Int) -> Void)?
    private var buttons: [TabButton] = []
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { i, t in
            let b = TabButton(title: t)
            b.isSelected = i == selected
            b.addAction(UIAction { [weak self] _ in self?.onSelect?(i) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
            return b
        }
    }

    final class TabButton: UIControl {
        let title: String
        override var isSelected: Bool { didSet { setNeedsDisplay(); accessibilityTraits = isSelected ? [.button, .selected] : .button } }
        override var isHighlighted: Bool { didSet { setNeedsDisplay() } }

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
            backgroundColor = .clear
            contentMode = .redraw
            isAccessibilityElement = true
            accessibilityLabel = title
            let w = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 12.5, weight: .semibold)]).width + 28
            widthAnchor.constraint(equalToConstant: max(64, ceil(w))).isActive = true
            addInteraction(UIPointerInteraction(delegate: nil))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ rect: CGRect) {
            if isSelected || isHighlighted {
                (isSelected ? HanXTheme.selection : HanXTheme.toolbar).setFill()
                UIBezierPath(roundedRect: bounds, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 4, height: 4)).fill()
            }
            let color = isSelected ? HanXTheme.accent : HanXTheme.secondary
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            (title as NSString).draw(in: CGRect(x: 4, y: bounds.midY - 8.5, width: bounds.width - 8, height: 18),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .regular),
                                                      .foregroundColor: color, .paragraphStyle: para])
            if isSelected {
                HanXTheme.accent.setFill()
                UIRectFill(CGRect(x: 8, y: bounds.maxY - 2, width: max(0, bounds.width - 16), height: 2))
            }
        }
    }
}
