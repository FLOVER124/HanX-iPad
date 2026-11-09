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
        let start = UIMenu(title: "", options: .displayInline, children: [
            UIKeyCommand(title: "새 문서", action: #selector(StartViewController.newDocumentCommand(_:)), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "열기…", action: #selector(StartViewController.openCommand(_:)), input: "o", modifierFlags: .command),
        ])
        builder.insertChild(start, atStartOfMenu: .file)
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
        else if let activity = connectionOptions.userActivities.first ?? session.stateRestorationActivity,
                let url = HanXSceneDelegate.url(from: activity) {
            DispatchQueue.main.async { start.openFile(url) }
        }
        #if DEBUG
        DemoDocuments.openIfRequested(from: start)
        #endif
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let context = URLContexts.first { open(context) }
    }

    // MARK: Windows and state restoration

    static let openActivityType = "com.hanword.editor.ipad.open-document"

    static func activity(for url: URL) -> NSUserActivity? {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        let activity = NSUserActivity(activityType: openActivityType)
        activity.title = url.lastPathComponent
        activity.addUserInfoEntries(from: ["bookmark": bookmark])
        return activity
    }

    static func url(from activity: NSUserActivity) -> URL? {
        guard activity.activityType == openActivityType, let data = activity.userInfo?["bookmark"] as? Data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// iPad: opens the document in a separate window (side by side, Stage Manager).
    static func openInNewWindow(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let activity = activity(for: url) else { return }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil)
    }

    /// Reopens the document that was in front when the system closed the app.
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let editor = (window?.rootViewController?.presentedViewController as? UINavigationController)?.viewControllers.first as? HanXEditorViewController
        else { return nil }
        return HanXSceneDelegate.activity(for: editor.baseDocument.fileURL)
    }

    /// Files opened from the Files app (in place) or shared into HanX.
    private func open(_ context: UIOpenURLContext) {
        guard context.url.isFileURL, let start else { return }
        DispatchQueue.main.async { start.openFile(context.url) }
    }
}
