import SwiftUI

@main
struct MacLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            // The stock Quit item sends `terminate:`, which
            // applicationShouldTerminate cancels while armed — so ⌘Q silently
            // did nothing. Route it through the same intent the status-menu
            // item uses.
            CommandGroup(replacing: .appTermination) {
                Button(NSLocalizedString("maclock.menu.quit", comment: "")) {
                    appDelegate.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
