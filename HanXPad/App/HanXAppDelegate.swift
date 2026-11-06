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
    private var start: StartViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let start = StartViewController()
        window.rootViewController = start
        window.tintColor = HanXTheme.accent
        window.makeKeyAndVisible()
        self.window = window
        self.start = start
        if let context = connectionOptions.urlContexts.first { open(context) }
        #if DEBUG
        DemoDocuments.openIfRequested(from: start)
        #endif
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let context = URLContexts.first { open(context) }
    }

    /// Files opened from the Files app (in place) or shared into HanX.
    private func open(_ context: UIOpenURLContext) {
        guard context.url.isFileURL, let start else { return }
        DispatchQueue.main.async { start.openFile(context.url) }
    }
}
