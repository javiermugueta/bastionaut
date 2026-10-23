import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: () -> Void = {}

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainActor.assumeIsolated { SandboxSelfTest.runIfRequested() }
        #endif
        if Showcase.launchedForScreenshots { MainActor.assumeIsolated { Showcase.arrangeWindows() } }
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate()
    }
}

@main
struct OCIBastionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var manager = TunnelManager()

    var body: some Scene {
        WindowGroup("Bastionaut", id: "main") {
            MainView(manager: manager)
                .frame(minWidth: 860, minHeight: 640)
                .onAppear {
                    appDelegate.onTerminate = { [manager] in
                        MainActor.assumeIsolated {
                            manager.save()
                            manager.stopAllNow()
                        }
                    }
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands { HelpCommands(manager: manager) }

        Window("Ayuda de Bastionaut", id: "help") {
            HelpView()
        }
        .defaultSize(width: 900, height: 640)

        MenuBarExtra {
            StatusMenu(manager: manager)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .overlay(alignment: .bottomTrailing) {
                    if manager.isConnected {
                        Circle().fill(.green).frame(width: 5, height: 5)
                    }
                }
                .accessibilityLabel("Bastionaut")
        }
    }
}

struct StatusMenu: View {
    let manager: TunnelManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = manager.overallState
        Text("\(state.emoji) \(state.title)")
        if let connection = manager.selectedConnection { Text("\(connection.displayEmoji) \(connection.name)") }
        if let expires = manager.sessionExpiresAt {
            Text("Sesión hasta las \(expires.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        if manager.isRunning {
            Button("Desconectar") { manager.disconnect() }
        } else {
            Button("Conectar 🚀") { manager.connect() }
        }
        if manager.isConnected, !manager.settings.destinations.isEmpty {
            Menu("Abrir SSH") {
                ForEach(manager.settings.destinations) { destination in
                    Button(destination.name.isEmpty ? destination.host : destination.name) { manager.openDestination(destination) }
                }
            }
        }
        if !manager.savedConnections.isEmpty && !manager.isRunning {
            Menu("Cambiar de conexión") {
                ForEach(manager.savedConnections) { connection in
                    Button("\(connection.displayEmoji) \(connection.name)") { manager.selectConnection(connection.id) }
                }
            }
        }
        Divider()
        Button("Abrir Bastionaut") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Ayuda") {
            HelpRouter.shared.topic = .start
            openWindow(id: "help")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Salir") { manager.disconnect(); NSApp.terminate(nil) }
    }
}
