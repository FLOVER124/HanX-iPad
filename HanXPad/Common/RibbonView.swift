import UIKit

/// Touch-sized ribbon shared by every editor. Tabs and groups match the macOS
/// OfficeRibbon item for item (same command ids), laid out for fingers: 44 pt
/// targets, a horizontally scrolling row, pull-down menus instead of popups.
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
    private let tabControl: UISegmentedControl
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var controls: [String: UIButton] = [:]
    private var items: [String: Item] = [:]
    private(set) var selectedTab = 0

    init(tabs: [Tab]) {
        self.tabs = tabs
        tabControl = UISegmentedControl(items: tabs.map(\.title))
        super.init(frame: .zero)
        backgroundColor = HanXTheme.toolbar
        tabControl.selectedSegmentIndex = 0
        tabControl.addAction(UIAction { [weak self] _ in self?.showTab(self?.tabControl.selectedSegmentIndex ?? 0) }, for: .valueChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabControl)

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        let divider = UIView()
        divider.backgroundColor = HanXTheme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            tabControl.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            tabControl.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 76),
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
        ])
        showTab(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTab = index
        tabControl.selectedSegmentIndex = index
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        controls = [:]
        for (gi, group) in tabs[index].groups.enumerated() {
            let buttons = UIStackView()
            buttons.axis = .horizontal
            buttons.spacing = 2
            buttons.alignment = .center
            for item in group.items {
                let b = makeControl(item)
                items[item.id] = item
                controls[item.id] = b
                buttons.addArrangedSubview(b)
            }
            let caption = UILabel()
            caption.text = group.title
            caption.font = .systemFont(ofSize: 10.5)
            caption.textColor = HanXTheme.secondary
            caption.textAlignment = .center
            let stack = UIStackView(arrangedSubviews: [buttons, caption])
            stack.axis = .vertical
            stack.spacing = 2
            stack.alignment = .center
            row.addArrangedSubview(stack)
            if gi < tabs[index].groups.count - 1 {
                let line = UIView()
                line.backgroundColor = HanXTheme.border
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                line.heightAnchor.constraint(equalToConstant: 58).isActive = true
                row.addArrangedSubview(line)
            }
        }
        row.addArrangedSubview(UIView())
        refresh()
    }

    func showTab(titled title: String) {
        if let i = tabs.firstIndex(where: { $0.title == title }) { showTab(i) }
    }

    private func makeControl(_ item: Item) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = HanXTheme.ink
        config.imagePlacement = .top
        config.imagePadding = 3
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 11.5)
            return a
        }
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let b = UIButton(configuration: config)
        b.accessibilityLabel = item.title
        b.accessibilityIdentifier = item.id
        b.isPointerInteractionEnabled = true
        switch item.kind {
        case .button, .toggle:
            b.configuration?.title = item.title
            if let symbol = item.symbol { b.configuration?.image = UIImage(systemName: symbol) }
            b.addAction(UIAction { [weak self] _ in self?.onCommand?(item.id, item.title, 0) }, for: .primaryActionTriggered)
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        case .menu(let options):
            b.configuration?.title = item.title
            b.configuration?.image = UIImage(systemName: item.symbol ?? "chevron.down.square")
            b.showsMenuAsPrimaryAction = true
            b.menu = UIMenu(title: item.title, children: options.enumerated().map { i, option in
                UIAction(title: option) { [weak self] _ in self?.onCommand?(item.id, option, i) }
            })
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        case .field(let options):
            var c = UIButton.Configuration.bordered()
            c.baseForegroundColor = HanXTheme.ink
            c.title = options.first ?? item.title
            c.subtitle = item.title
            c.titleLineBreakMode = .byTruncatingTail
            c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs; a.font = UIFont.systemFont(ofSize: 13); return a
            }
            c.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs; a.font = UIFont.systemFont(ofSize: 9.5); a.foregroundColor = HanXTheme.secondary; return a
            }
            b.configuration = c
            b.showsMenuAsPrimaryAction = true
            let width: CGFloat = item.id == "font" ? 150 : 74
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
            b.heightAnchor.constraint(equalToConstant: 48).isActive = true
            b.menu = fieldMenu(item, options: options, button: b)
        }
        return b
    }

    private func fieldMenu(_ item: Item, options: [String], button: UIButton) -> UIMenu {
        let typed = UIAction(title: item.id == "font" ? "글꼴 선택…" : "직접 입력…", image: UIImage(systemName: "keyboard")) { [weak self, weak button] _ in
            guard let self, let button else { return }
            if self.customField?(item.id, button) == true { return }
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
        for (id, b) in controls {
            guard let item = items[id] else { continue }
            if case .field = item.kind, let value = currentValue?(id) {
                b.configuration?.title = value.isEmpty ? "—" : value
            }
            if case .toggle = item.kind {
                let on = isOn?(id) ?? false
                b.configuration?.background.backgroundColor = on ? HanXTheme.selection : .clear
                b.configuration?.baseForegroundColor = on ? HanXTheme.accent : HanXTheme.ink
                b.accessibilityTraits = on ? [.button, .selected] : .button
            }
            b.isEnabled = isEnabled?(id) ?? true
        }
    }

    func control(_ id: String) -> UIButton? { controls[id] }
}
