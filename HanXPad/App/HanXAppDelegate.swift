import UIKit

@main
final class HanXAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FontResolver.shared.registerImportedFonts()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HanXSceneDelegate.self
        return configuration
    }

    // MARK: Menu bar (hardware keyboard ⌘ shortcuts discoverable with the ⌘ key)

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let file = UIMenu(title: "", options: .displayInline, children: [
            UIKeyCommand(title: "저장", action: #selector(HanXEditorViewController.saveDocument(_:)), input: "s", modifierFlags: .command),
            UIKeyCommand(title: "다른 형식으로 내보내기…", action: #selector(HanXEditorViewController.exportDocument(_:)), input: "s", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "인쇄…", action: #selector(HanXEditorViewController.printDocument(_:)), input: "p", modifierFlags: .command),
            UIKeyCommand(title: "닫기", action: #selector(HanXEditorViewController.closeDocument(_:)), input: "w", modifierFlags: [.command, .alternate]),
        ])
        builder.insertChild(file, atStartOfMenu: .file)
        let find = UIMenu(title: "", options: .displayInline, children: [
            UIKeyCommand(title: "찾기", action: #selector(HanXEditorViewController.showFind(_:)), input: "f", modifierFlags: .command),
        ])
        builder.insertChild(find, atEndOfMenu: .edit)
    }
}

final class HanXSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: DocumentBrowserViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let browser = DocumentBrowserViewController()
        window.rootViewController = browser
        window.tintColor = HanXTheme.accent
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser
        if let context = connectionOptions.urlContexts.first { open(context) }
        #if DEBUG
        DemoDocuments.openIfRequested(from: browser)
        #endif
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let context = URLContexts.first { open(context) }
    }

    private func open(_ context: UIOpenURLContext) {
        let url = context.url
        guard url.isFileURL else { return }
        browser?.revealDocument(at: url, importIfNeeded: !context.options.openInPlace) { [weak self] revealed, error in
            if let error { self?.browser?.presentError(error); return }
            if let revealed { self?.browser?.openDocument(at: revealed) }
        }
    }
}
