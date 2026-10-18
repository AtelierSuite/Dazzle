import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showSourceCode(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/AtelierSuite/Dazzle") else { return }
        NSWorkspace.shared.open(url)
    }
}
