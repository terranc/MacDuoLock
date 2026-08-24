import SwiftUI

@main
struct MacLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            // Point ⌘, at the AppKit settings window instead of presenting the
            // Settings scene, so the menu bar item and ⌘, raise the same window.
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("maclock.menu.settings", comment: "")) {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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
