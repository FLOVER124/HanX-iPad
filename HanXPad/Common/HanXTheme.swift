import UIKit

/// The macOS app's palette (HWTheme), as dynamic UIKit colors.
enum HanXTheme {
    static func color(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
    }
    static let paper = color(0xFFFFFF, 0x232C38)
    static let toolbar = color(0xF6F8FB, 0x202833)
    static let canvas = color(0xE7EBF1, 0x151C25)
    static let ink = color(0x203247, 0xE5ECF5)
    static let secondary = color(0x6C7D90, 0xA4B1C2)
    static let border = color(0xDCE3EC, 0x3A4657)
    static let accent = color(0x3266A8, 0x8EB6EC)
    static let selection = color(0xE7EFFA, 0x30445F)
}

/// Shared palette used by every ribbon colour menu (same order as macOS).
enum Palette {
    static let names = ["검정", "빨강", "주황", "노랑", "초록", "파랑", "보라", "흰색"]
    static let colors: [RGB] = [.black, RGB(r: 220, g: 40, b: 40), RGB(r: 235, g: 130, b: 30), RGB(r: 255, g: 225, b: 70),
                                RGB(r: 35, g: 150, b: 90), RGB(r: 40, g: 100, b: 210), RGB(r: 140, g: 65, b: 185), RGB(r: 255, g: 255, b: 255)]
    static let custom = "사용자 지정…"
}

extension RGB {
    var uiColor: UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var cgColor: CGColor { uiColor.cgColor }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if color.getWhite(&white, alpha: &a) { r = white; g = white; b = white }
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(r), g: byte(g), b: byte(b))
    }
}

extension UIViewController {
    func presentMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default))
        topmostPresenter.present(alert, animated: true)
    }

    func presentError(_ error: Error) {
        presentMessage("작업을 완료하지 못했습니다", HanXError.describe(error))
    }

    var topmostPresenter: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// One-field prompt. `completion` receives nil on cancel.
    func promptText(_ title: String, message: String? = nil, text: String = "", placeholder: String = "",
                    keyboard: UIKeyboardType = .default, confirm: String = "확인", completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.placeholder = placeholder
            field.keyboardType = keyboard
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: confirm, style: .default) { [weak alert] _ in completion(alert?.textFields?.first?.text ?? "") })
        topmostPresenter.present(alert, animated: true)
    }

    /// Several numeric fields in one alert (e.g. rows × columns).
    func promptNumbers(_ title: String, fields: [(String, Double)], completion: @escaping ([Double]?) -> Void) {
        let alert = UIAlertController(title: title, message: fields.map(\.0).joined(separator: " · "), preferredStyle: .alert)
        for (name, value) in fields {
            alert.addTextField { f in
                f.placeholder = name
                f.text = SheetValue.general(value)
                f.keyboardType = .decimalPad
            }
        }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak alert] _ in
            let values = (alert?.textFields ?? []).map { Double(($0.text ?? "").replacingOccurrences(of: ",", with: ".")) }
            completion(values.contains(where: { $0 == nil || !$0!.isFinite }) ? nil : values.map { $0! })
        })
        topmostPresenter.present(alert, animated: true)
    }

    func confirm(_ title: String, message: String, action: String, destructive: Bool = false, completion: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in completion() })
        topmostPresenter.present(alert, animated: true)
    }
}

enum HanXError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }

    static func describe(_ error: Error) -> String {
        if let f = error as? FormatError { return f.description }
        return (error as NSError).localizedFailureReason ?? error.localizedDescription
    }
}

/// Retains a UIColorPickerViewController delegate until the picker closes.
final class ColorPickerCoordinator: NSObject, UIColorPickerViewControllerDelegate {
    private static var active: ColorPickerCoordinator?
    private let completion: (RGB) -> Void

    private init(_ completion: @escaping (RGB) -> Void) { self.completion = completion }

    static func present(from host: UIViewController, title: String, initial: RGB?, source: Any?, completion: @escaping (RGB) -> Void) {
        let coordinator = ColorPickerCoordinator(completion)
        active = coordinator
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.supportsAlpha = false
        if let initial { picker.selectedColor = initial.uiColor }
        picker.delegate = coordinator
        picker.modalPresentationStyle = .popover
        PopoverAnchor.apply(picker, source: source, in: host)
        host.topmostPresenter.present(picker, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously else { return }
        completion(RGB(color))
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        ColorPickerCoordinator.active = nil
    }
}

enum PopoverAnchor {
    /// Anchors a popover to a bar item, a view, or the centre of the host.
    static func apply(_ vc: UIViewController, source: Any?, in host: UIViewController) {
        guard let pop = vc.popoverPresentationController else { return }
        if let item = source as? UIBarButtonItem { pop.barButtonItem = item; return }
        if let view = source as? UIView, view.window != nil { pop.sourceView = view; pop.sourceRect = view.bounds; return }
        pop.sourceView = host.view
        pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.safeAreaInsets.top + 60, width: 1, height: 1)
        pop.permittedArrowDirections = [.up, .down]
    }
}

extension UIImage {
    /// Raster bytes suitable for embedding (PNG keeps transparency; large photos become JPEG).
    func embeddableData(preferJPEG: Bool = false) -> (Data, String)? {
        let maxSide: CGFloat = 4096
        var image = self
        let longest = max(size.width * scale, size.height * scale)
        if longest > maxSide {
            let factor = maxSide / longest
            let target = CGSize(width: size.width * factor, height: size.height * factor)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: target, format: format).image { _ in self.draw(in: CGRect(origin: .zero, size: target)) }
        }
        if preferJPEG, let jpg = image.jpegData(compressionQuality: 0.88) { return (jpg, "jpeg") }
        if let png = image.pngData() { return (png, "png") }
        return image.jpegData(compressionQuality: 0.9).map { ($0, "jpeg") }
    }
}
