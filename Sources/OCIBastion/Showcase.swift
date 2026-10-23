import AppKit
import Foundation

/// Modo demostración para las capturas de la App Store: datos inventados, sin guardar nada ni lanzar procesos.
/// Se activa con `-BastionautDemo YES` y la escena con `-BastionautDemoScene main|dark|attention|help`.
enum Showcase {
    static let isActive = UserDefaults.standard.bool(forKey: "BastionautDemo")
    static var scene: String { UserDefaults.standard.string(forKey: "BastionautDemoScene") ?? "main" }

    static func settings() -> Settings {
        let account = OCIAccount(name: String(localized: "Producción"), tenancy: "ocid1.tenancy.oc1..aaaademo",
                                 user: "ocid1.user.oc1..aaaademo", fingerprint: "3f:9a:12:7c:44:d0:8e:b1:65:2a:9f:01:c3:7e:58:b4",
                                 region: "eu-madrid-1")
        var value = Settings()
        value.accounts = [account]
        value.accountID = account.id
        value.region = "eu-madrid-1"
        value.bastionID = "ocid1.bastion.oc1.eu-madrid-1.demo"
        value.bastionName = "bastion-prod"
        value.sessionMode = .portForwarding
        value.keyMode = .ephemeral
        value.hasCompletedOnboarding = true
        value.destinations = [
            Destination(name: String(localized: "Servidor de aplicaciones"), host: "10.0.1.23", user: "opc", privateKeyPath: "/demo"),
            Destination(name: String(localized: "Base de datos"), host: "10.0.2.40", user: "opc", privateKeyPath: "/demo"),
            Destination(name: "Jenkins", host: "10.0.3.15", user: "ubuntu", privateKeyPath: "/demo"),
        ]
        value.tunnels = [
            LocalTunnel(name: "Oracle Database", host: "", privateKeyPath: "", localPort: 11521, remoteHost: "10.0.2.40", remotePort: 1521),
            LocalTunnel(name: "Grafana", host: "10.0.3.15", user: "ubuntu", privateKeyPath: "/demo", localPort: 13000,
                        remoteHost: "127.0.0.1", remotePort: 3000),
        ]
        let current = SavedConnection(id: UUID(), name: String(localized: "Producción"), snapshot: ConnectionSnapshot(settings: value), emoji: "🚀")
        var staging = value
        staging.bastionName = "bastion-staging"
        let others = [
            SavedConnection(id: UUID(), name: "Staging", snapshot: ConnectionSnapshot(settings: staging), emoji: "🧪"),
            SavedConnection(id: UUID(), name: String(localized: "Cliente ACME"), snapshot: ConnectionSnapshot(settings: staging), emoji: "🦊"),
            SavedConnection(id: UUID(), name: "Analytics", snapshot: ConnectionSnapshot(settings: staging), emoji: "🐙"),
        ]
        value.savedConnections = [current] + others
        value.selectedSavedConnectionID = current.id
        return value
    }

    static let bastion = BastionDetails(id: "ocid1.bastion.oc1.eu-madrid-1.demo", name: "bastion-prod", compartmentId: "c",
                                        lifecycleState: "ACTIVE", dnsProxyStatus: "DISABLED", maxSessionTtlInSeconds: 10800,
                                        clientCidrBlockAllowList: ["83.45.10.0/24"])

    static var logLines: [String] {
        [
            String(localized: "🚀 Conectando «Producción»"),
            String(localized: "♻️ Servidor de aplicaciones: reutilizo una sesión que ya existía"),
            String(localized: "🎉 Servidor de aplicaciones: túnel listo en 127.0.0.1:52211"),
            String(localized: "🛎️ Oracle Database: sesión creada, esperando a OCI"),
            String(localized: "🎉 Oracle Database: túnel listo en 127.0.0.1:11521"),
            String(localized: "🖥️ Abriendo SSH a Servidor de aplicaciones"),
        ]
    }

    /// Ajusta las ventanas a 1280×800 puntos (2560×1600 en Retina), un tamaño válido para la Mac App Store.
    @MainActor
    static func arrangeWindows() {
        if scene == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        // Las ventanas de SwiftUI aparecen un poco después del arranque: se activan y ajustan varias veces.
        for delay in [0.3, 0.8, 1.5, 2.5, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate(ignoringOtherApps: true)
                let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.canBecomeMain }
                for (index, window) in windows.enumerated() {
                    let frame = NSRect(x: 80 + index * 40, y: 80, width: 1280, height: 800)
                    window.minSize = NSSize(width: 860, height: 640)
                    if window.frame != frame { window.setFrame(frame, display: true, animate: false) }
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

extension ForwardRunner {
    /// Estado fijo para el modo demostración.
    func showcase(state: TunnelState, localPort: Int?, expiresAt: Date?, command: String?) {
        applyShowcase(state: state, localPort: localPort, expiresAt: expiresAt, command: command)
    }
}
