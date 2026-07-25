import ApexCore
import SwiftUI

@main
struct ApexCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    /// Read straight from defaults rather than through `AppState`.
    ///
    /// Driving `MenuBarExtra(isInserted:)` from a binding that resolves through
    /// an `ObservableObject` the `App` observes puts the scene list and AppKit's
    /// main menu into a mutual invalidation loop: `scenesDidChange` rebuilds the
    /// menu, the rebuild invalidates the graph, and the app pins a core forever
    /// without ever showing a window. `@AppStorage` is a plain value, so the
    /// scene list settles after one pass.
    @AppStorage("showsMenuBarHUD") private var showsMenuBarHUD = true

    var body: some Scene {
        Window("ApexClean", id: "main") {
            RootView()
                .environmentObject(state)
        }
        .defaultSize(width: 1_180, height: 780)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About ApexClean") { openWindow(id: "about") }
            }

            CommandGroup(after: .appInfo) {
                Divider()
                Button("Scan My Mac") {
                    state.go(to: .smartCare)
                    state.cleanup.scan()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Set Up ApexClean…") { state.restartOnboarding() }
            }

            CommandMenu("Go") {
                ForEach(Destination.allCases) { page in
                    Button(page.title) { state.go(to: page) }
                        .keyboardShortcut(page.shortcut, modifiers: .command)
                }
                Divider()
                Toggle("Show in Menu Bar", isOn: $showsMenuBarHUD)
            }
        }

        Window("About ApexClean", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        MenuBarExtra(isInserted: $showsMenuBarHUD) {
            MenuBarHUD(vitals: state.vitals).environmentObject(state)
        } label: {
            MenuBarLabel(vitals: state.vitals)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar HUD outlives the window; closing the window should not
        // quit an app whose whole point is to sit quietly in the menu bar.
        false
    }
}
