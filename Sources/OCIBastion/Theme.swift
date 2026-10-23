import SwiftUI

extension TunnelState {
    var emoji: String {
        switch self {
        case .idle: return "😴"
        case .working: return "🛠️"
        case .connected: return "🚀"
        case .renewing: return "⏳"
        case .reconnecting: return "🔁"
        case .needsAttention: return "🆘"
        }
    }

    var title: String {
        switch self {
        case .idle: return String(localized: "Echando la siesta")
        case .working: return String(localized: "Manos a la obra…")
        case .connected: return String(localized: "¡En órbita!")
        case .renewing: return String(localized: "Renovando la sesión")
        case .reconnecting: return String(localized: "Se cayó, reintentando…")
        case .needsAttention: return String(localized: "Necesito tu ayuda")
        }
    }

    var subtitle: String {
        switch self {
        case .idle: return String(localized: "Pulsa conectar cuando quieras salir de paseo.")
        case .working(let step): return step
        case .connected: return String(localized: "El túnel está abierto. ¡A trabajar!")
        case .renewing: return String(localized: "Pido una sesión nueva antes de que caduque la actual.")
        case .reconnecting(let reason): return reason
        case .needsAttention(let reason): return reason
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .gray
        case .working, .renewing: return .orange
        case .connected: return .green
        case .reconnecting: return .yellow
        case .needsAttention: return .red
        }
    }

    var isBusy: Bool {
        switch self {
        case .working, .renewing, .reconnecting: return true
        default: return false
        }
    }
}

enum Palette {
    static let gradient = LinearGradient(colors: [Color(red: 0.42, green: 0.32, blue: 0.95), Color(red: 0.98, green: 0.45, blue: 0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let emojis = ["🏰", "🚀", "🐙", "🦄", "🛰️", "🐳", "🦊", "🌮", "🍕", "🎸", "🧪", "🔥", "🌵", "🐝", "🪐", "🎯"]
}

struct Card<Content: View>: View {
    let title: LocalizedStringKey
    let emoji: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(emoji).font(.title2)
                Text(title).font(.title3.weight(.bold))
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary))
    }
}

struct FunButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        FunButton(configuration: configuration, tint: tint)
    }

    private struct FunButton: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let color = isEnabled ? tint : Color.gray
            configuration.label
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.8))
                .background(color.gradient, in: Capsule())
                .opacity(isEnabled ? 1 : 0.55)
                .shadow(color: color.opacity(isEnabled ? 0.35 : 0), radius: configuration.isPressed ? 2 : 6,
                        y: configuration.isPressed ? 1 : 3)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

/// Campo de puerto que actualiza el valor al teclear (los campos con `format:` solo lo hacen al pulsar Intro).
struct PortField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    var prompt: String = ""

    var body: some View {
        TextField(title, text: Binding(
            get: { value == 0 ? "" : String(value) },
            set: { value = Int($0.filter(\.isNumber).prefix(5)) ?? 0 }
        ), prompt: Text(prompt))
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Emoji que rebota mientras hay trabajo en curso.
struct BouncingEmoji: View {
    let emoji: String
    let active: Bool
    var size: CGFloat = 56
    @State private var up = false

    var body: some View {
        Text(emoji)
            .font(.system(size: size))
            .offset(y: active && up ? -6 : 0)
            .animation(active ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: up)
            .onAppear { up = true }
            .contentTransition(.identity)
    }
}

func pickFile(showHidden: Bool = true, directory: String? = nil) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.showsHiddenFiles = showHidden
    if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct FileField: View {
    let placeholder: LocalizedStringKey
    @Binding var path: String
    var directory: String? = nil
    /// Claves SSH: en la versión App Store se guarda una copia privada, porque el sandbox no deja volver a leer la ruta.
    var importsKey = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("", text: $path, prompt: Text(placeholder)).labelsHidden().textFieldStyle(.roundedBorder)
                    .disabled(importsKey && AppEdition.isAppStore)
                Button("Elegir…") {
                    guard let value = pickFile(directory: directory) else { return }
                    if importsKey && AppEdition.isAppStore {
                        do { path = try SSHKeyImport.importCopy(of: URL(fileURLWithPath: value)); problem = nil }
                        catch { problem = error.localizedDescription }
                    } else {
                        path = value
                    }
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }
}

enum SSHKeyImport {
    static var directory: URL {
        Settings.fileURL.deletingLastPathComponent().appendingPathComponent("keys/imported", isDirectory: true)
    }

    /// Copia la clave a la carpeta privada de la app (0600) y devuelve la ruta de la copia.
    static func importCopy(of source: URL) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + source.lastPathComponent)
        try manager.copyItem(at: source, to: target)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target.path
    }
}

/// Icono en un cuadrado redondeado de color, al estilo de Ajustes del Sistema.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: color.opacity(0.3), radius: 3, y: 1)
    }
}

/// Botón circular de icono con fondo al pasar el ratón.
struct CircleIconButtonStyle: ButtonStyle {
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        CircleIcon(configuration: configuration, tint: tint)
    }

    private struct CircleIcon: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? tint : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? tint.opacity(0.15) : Color.primary.opacity(0.05)))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Cápsula de color suave para acciones secundarias como «Añadir».
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.25 : 0.14), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
