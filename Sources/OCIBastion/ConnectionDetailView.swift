import SwiftUI

struct ConnectionDetailView: View {
    @Bindable var manager: TunnelManager
    let editWithWizard: () -> Void
    @State private var editingDestination: Destination?
    @State private var editingTunnel: LocalTunnel?
    @State private var showRename = false
    @State private var showDelete = false
    @State private var showSaveAs = false

    private var portMode: Bool { manager.settings.effectiveSessionMode == .portForwarding }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroCard(manager: manager)
                destinationsCard
                tunnelsCard
                SettingsCard(manager: manager, editWithWizard: editWithWizard)
                LogCard(manager: manager)
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(manager.selectedConnection.map { "\($0.displayEmoji) \($0.name)" } ?? String(localized: "Configuración actual"))
        .toolbar {
            if manager.selectedConnection != nil {
                Menu {
                    Button("Renombrar…") { showRename = true }
                    Button("Duplicar") { manager.duplicateSelectedConnection() }
                    Divider()
                    Button("Eliminar…", role: .destructive) { showDelete = true }
                } label: { Label("Conexión", systemImage: "ellipsis.circle") }
                .disabled(manager.isRunning)
            } else {
                Button("Guardar como conexión…") { showSaveAs = true }
            }
        }
        .sheet(item: $editingDestination) { destination in
            DestinationForm(destination: destination) { result in
                if let index = manager.settings.destinations.firstIndex(where: { $0.id == result.id }) {
                    manager.settings.destinations[index] = result
                } else {
                    manager.settings.destinations.append(result)
                }
                manager.save()
            }
        }
        .sheet(item: $editingTunnel) { tunnel in
            TunnelForm(tunnel: tunnel, portMode: portMode) { result in
                var records = manager.settings.tunnels ?? []
                if let index = records.firstIndex(where: { $0.id == result.id }) { records[index] = result }
                else { records.append(result) }
                manager.settings.tunnels = records
                manager.save()
            }
        }
        .sheet(isPresented: $showRename) {
            NameSheet(title: "Renombrar conexión", name: manager.selectedConnection?.name ?? "",
                      emoji: manager.selectedConnection?.displayEmoji ?? "🏰") { name, emoji in
                manager.renameSelectedConnection(to: name, emoji: emoji)
            }
        }
        .sheet(isPresented: $showSaveAs) {
            NameSheet(title: "Guardar como conexión", name: manager.settings.bastionName ?? "", emoji: "🏰") { name, emoji in
                manager.addConnection(named: name, emoji: emoji, from: manager.settings)
            }
        }
        .confirmationDialog("¿Eliminar «\(manager.selectedConnection?.name ?? "")»?", isPresented: $showDelete) {
            Button("Eliminar", role: .destructive) { manager.deleteSelectedConnection() }
        } message: { Text("Esta acción no se puede deshacer.") }
    }

    private var destinationsCard: some View {
        Card(title: "Servidores", emoji: "🖥️", trailing: AnyView(
            Button { editingDestination = Destination(privateKeyPath: SSHKeys.suggestedPrivateKey) } label: {
                Label("Añadir", systemImage: "plus")
            }.buttonStyle(SoftButtonStyle()))) {
            if manager.settings.destinations.isEmpty {
                Text("Sin servidores todavía. Añade uno y ábrelo con un clic.").foregroundStyle(.secondary)
            }
            ForEach(manager.settings.destinations) { destination in
                TargetRow(
                    symbol: "server.rack", color: .blue, primarySymbol: "terminal.fill",
                    title: destination.name.isEmpty ? destination.host : destination.name,
                    subtitle: "\(destination.user)@\(destination.host):\(destination.port)",
                    runner: portMode ? manager.runner(for: destination.id) : nil,
                    primaryTitle: "Abrir SSH",
                    primary: { manager.openDestination(destination) },
                    copy: { manager.copyDestinationCommand(destination) },
                    edit: { editingDestination = destination },
                    stop: { manager.disconnect(target: destination.id) },
                    remove: { manager.removeDestination(destination.id) })
            }
        }
    }

    private var tunnelsCard: some View {
        Card(title: "Túneles a puertos", emoji: "🚇", trailing: AnyView(
            Button { editingTunnel = LocalTunnel(host: "", privateKeyPath: SSHKeys.suggestedPrivateKey, remoteHost: "") } label: {
                Label("Añadir", systemImage: "plus")
            }.buttonStyle(SoftButtonStyle()))) {
            if (manager.settings.tunnels ?? []).isEmpty {
                Text("Lleva un puerto remoto (una base de datos, una consola web…) a tu Mac.").foregroundStyle(.secondary)
            }
            ForEach(manager.settings.tunnels ?? []) { tunnel in
                TargetRow(
                    symbol: tunnel.isDirect ? "arrow.left.arrow.right" : "point.3.filled.connected.trianglepath.dotted",
                    color: .purple, primarySymbol: "arrow.left.arrow.right",
                    title: tunnel.name.isEmpty ? (tunnel.isDirect ? tunnel.remoteHost : tunnel.host) : tunnel.name,
                    subtitle: "localhost:\(tunnel.localPort) → \(tunnel.remoteHost):\(tunnel.remotePort) \(String(localized: "vía")) \(tunnel.isDirect ? "Bastion" : tunnel.host)",
                    runner: portMode ? manager.runner(for: tunnel.id) : nil,
                    primaryTitle: "Abrir túnel",
                    primary: { manager.openLocalTunnel(tunnel) },
                    copy: { manager.copyLocalTunnelCommand(tunnel) },
                    edit: { editingTunnel = tunnel },
                    stop: { manager.disconnect(target: tunnel.id) },
                    remove: { manager.removeLocalTunnel(tunnel.id) })
            }
        }
    }
}

// MARK: Tarjeta principal

struct HeroCard: View {
    @Bindable var manager: TunnelManager

    var body: some View {
        let state = manager.overallState
        HStack(alignment: .center, spacing: 20) {
            BouncingEmoji(emoji: state.emoji, active: state.isBusy, size: 64)
                .id(state.emoji)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.title).font(.system(size: 28, weight: .heavy, design: .rounded))
                Text(state.subtitle).foregroundStyle(.white.opacity(0.9)).lineLimit(8).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if state.isBusy {
                    ProgressView().progressViewStyle(.linear).tint(.white).frame(maxWidth: 320)
                }
                if let allowList = manager.bastionDetails?.clientCidrBlockAllowList, !allowList.isEmpty,
                   case .needsAttention = state {
                    HStack {
                        Button(manager.isCheckingPublicIP ? "Comprobando…" : "¿Está permitida mi IP? 🌐") {
                            manager.checkPublicIP()
                        }
                        .buttonStyle(FunButtonStyle(tint: .black.opacity(0.45)))
                        .disabled(manager.isCheckingPublicIP)
                        if manager.isCheckingPublicIP { ProgressView().controlSize(.small).tint(.white) }
                    }
                }
                if let report = manager.publicIPReport {
                    Text(report).font(.callout.weight(.semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Chip(text: manager.settings.effectiveSessionMode == .socks ? "SOCKS5" : String(localized: "Reenvío de puerto"), tint: .white)
                    if let name = manager.settings.bastionName { Chip(text: "🏰 \(name)", tint: .white) }
                    if let region = manager.settings.region { Chip(text: "🌍 \(region)", tint: .white) }
                    if state.isConnected, manager.settings.effectiveSessionMode == .socks {
                        Chip(text: "127.0.0.1:\(manager.settings.socksPort)", tint: .white)
                    }
                }
            }
            .foregroundStyle(.white)
            Spacer()
            VStack(spacing: 10) {
                if let expires = manager.sessionExpiresAt {
                    CountdownRing(expiresAt: expires, total: TimeInterval(manager.settings.ttlSeconds))
                }
                if manager.isRunning {
                    Button { manager.disconnect() } label: { Label("Desconectar", systemImage: "stop.circle.fill") }
                        .buttonStyle(FunButtonStyle(tint: .black.opacity(0.55)))
                } else {
                    Button { manager.connect() } label: { Label("Conectar 🚀", systemImage: "power") }
                        .buttonStyle(FunButtonStyle(tint: .black.opacity(0.55)))
                }
                if manager.isConnected {
                    Button { manager.copyBastionCommand() } label: { Label("Copiar SSH del Bastion", systemImage: "doc.on.doc") }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(state == .idle ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(state.tint.gradient))
        }
        .animation(.easeInOut(duration: 0.4), value: state)
    }
}

struct CountdownRing: View {
    let expiresAt: Date
    let total: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 6)
                Circle().trim(from: 0, to: total > 0 ? min(1, remaining / total) : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(Self.format(remaining)).font(.system(.callout, design: .rounded).monospacedDigit().weight(.bold))
                    Text("sesión").font(.caption2)
                }.foregroundStyle(.white)
            }
            .frame(width: 74, height: 74)
            .help("La sesión de OCI caduca a las \(expiresAt.formatted(date: .omitted, time: .shortened))")
        }
    }

    static func format(_ value: TimeInterval) -> String {
        let seconds = Int(value)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: Filas

struct TargetRow: View {
    let symbol: String
    let color: Color
    let primarySymbol: String
    let title: String
    let subtitle: String
    let runner: ForwardRunner?
    let primaryTitle: LocalizedStringKey
    let primary: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let stop: () -> Void
    let remove: () -> Void
    @State private var confirmDelete = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: runner?.state.isConnected == true ? .green : color)
                .animation(.easeInOut, value: runner?.state)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.headline)
                    if let runner, runner.state.isBusy { ProgressView().controlSize(.mini) }
                    if let runner, runner.state != .idle {
                        Chip(text: String(localized: "\(runner.state.emoji) \(runner.state.isConnected ? "127.0.0.1:\(runner.localPort ?? 0)" : runner.state.title)"),
                             tint: runner.state.tint)
                            .help(runner.state.subtitle)
                    }
                }
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                if runner?.isActive == true {
                    Button(action: stop) { Image(systemName: "stop.fill") }
                        .buttonStyle(CircleIconButtonStyle(tint: .orange)).help("Cerrar la sesión de este destino")
                }
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(CircleIconButtonStyle(tint: .blue)).help("Copiar comando")
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(CircleIconButtonStyle(tint: .purple)).help("Editar")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(CircleIconButtonStyle(tint: .red)).help("Eliminar")
            }
            .opacity(hovering ? 1 : 0.7)
            Button(action: primary) { Label(primaryTitle, systemImage: primarySymbol) }.buttonStyle(FunButtonStyle())
        }
        .padding(10)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .confirmationDialog("¿Eliminar «\(title)»?", isPresented: $confirmDelete) {
            Button("Eliminar", role: .destructive, action: remove)
        }
    }
}

// MARK: Ajustes

struct SettingsCard: View {
    @Bindable var manager: TunnelManager
    let editWithWizard: () -> Void
    @State private var expanded = false

    var body: some View {
        Card(title: "Ajustes", emoji: "⚙️", trailing: AnyView(
            Button { withAnimation(.spring(response: 0.3)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .buttonStyle(CircleIconButtonStyle(tint: .accentColor))
            .help(expanded ? "Ocultar" : "Mostrar"))) {
            if expanded {
                Form {
                    Section {
                        LabeledContent("Cuenta OCI", value: "\(manager.settings.profile) · \(manager.settings.region ?? String(localized: "región del perfil"))")
                        LabeledContent("Bastion", value: manager.settings.bastionName ?? manager.settings.bastionID)
                        Button("Cambiar cuenta o Bastion con el asistente ✨", action: editWithWizard)
                    }
                    Section("Sesión") {
                        Picker("Modo", selection: Binding(get: { manager.settings.effectiveSessionMode },
                                                          set: { manager.settings.sessionMode = $0 })) {
                            Text("SOCKS5 (un túnel para todo)").tag(SessionMode.socks)
                            Text("Reenvío de puerto (uno por destino)").tag(SessionMode.portForwarding)
                        }
                        if manager.settings.effectiveSessionMode == .socks {
                            PortField(title: "Puerto SOCKS5 local", value: $manager.settings.socksPort)
                        }
                        Stepper("Duración: \(manager.settings.ttlSeconds / 60) min",
                                value: $manager.settings.ttlSeconds, in: 1800...10800, step: 900)
                        Stepper("Renovar \(manager.settings.renewMarginMinutes ?? 30) min antes de caducar",
                                value: Binding(get: { manager.settings.renewMarginMinutes ?? 30 },
                                               set: { manager.settings.renewMarginMinutes = $0 }), in: 5...60, step: 5)
                    }
                    Section("Claves del Bastion") {
                        Picker("Claves", selection: Binding(get: { manager.settings.effectiveKeyMode },
                                                            set: { manager.settings.keyMode = $0 })) {
                            Text("Temporales, me encargo yo 🔑").tag(KeyMode.ephemeral)
                            Text("Uso mis propias claves").tag(KeyMode.custom)
                        }
                        if manager.settings.effectiveKeyMode == .custom {
                            FileField(placeholder: "Clave pública", path: $manager.settings.publicKeyPath)
                            FileField(placeholder: "Clave privada", path: $manager.settings.privateKeyPath)
                        }
                    }
                    Section("Red y terminal") {
                        ProxyPicker(settings: $manager.settings)
                        if !manager.proxyDescription.isEmpty {
                            Text(manager.proxyDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Terminal", selection: Binding(get: { manager.settings.effectiveTerminalApp },
                                                              set: { manager.settings.terminalApp = $0 })) {
                            Text("Terminal").tag(TerminalApp.terminal)
                            Text("iTerm2").tag(TerminalApp.iterm)
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(manager.isRunning)
                .onChange(of: manager.settings.sessionMode) { manager.save() }
                .onChange(of: manager.settings.keyMode) { manager.save() }
                .onChange(of: manager.settings.ttlSeconds) { manager.save() }
                .onChange(of: manager.settings.renewMarginMinutes) { manager.save() }
                .onChange(of: manager.settings.terminalApp) { manager.save() }
                .onChange(of: manager.settings.proxyMode) { manager.save() }
                if manager.isRunning {
                    Text("Desconecta para cambiar los ajustes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProxyPicker: View {
    @Binding var settings: Settings

    var body: some View {
        Picker("Proxy", selection: Binding(get: { settings.effectiveProxyMode }, set: { settings.proxyMode = $0 })) {
            Text("Automático").tag(ProxyMode.automatic)
            Text("Manual").tag(ProxyMode.manual)
            Text("Sin proxy").tag(ProxyMode.direct)
        }
        if settings.effectiveProxyMode == .manual {
            HStack {
                TextField("Host del proxy", text: $settings.proxyHost)
                PortField(title: "Puerto", value: $settings.proxyPort).frame(width: 80)
            }
        }
    }
}

struct LogCard: View {
    @Bindable var manager: TunnelManager

    var body: some View {
        Card(title: "Bitácora", emoji: "📜", trailing: AnyView(
            Button { manager.clearLog() } label: { Image(systemName: "trash") }
                .buttonStyle(CircleIconButtonStyle(tint: .red))
                .help("Limpiar")
                .disabled(manager.log.isEmpty))) {
            if manager.log.isEmpty {
                Text("Aquí iré apuntando lo que pase.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.log.suffix(40).reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(entry.message).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Formularios

enum SSHKeys {
    static var suggestedPrivateKey: String {
        let home = NSHomeDirectory()
        return ["id_ed25519", "id_rsa", "id_ecdsa"].map { "\(home)/.ssh/\($0)" }
            .first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }
}

struct DestinationForm: View {
    @State var destination: Destination
    let onSave: (Destination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("🖥️ Servidor").font(.title2.weight(.bold))
            DestinationFields(destination: $destination)
            HStack {
                if destination.host.isEmpty || destination.user.isEmpty {
                    Label("Faltan la IP y el usuario del servidor.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Guardar") { onSave(destination); dismiss() }
                    .buttonStyle(FunButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination.host.isEmpty || destination.user.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct DestinationFields: View {
    @Binding var destination: Destination

    var body: some View {
        Form {
            TextField("Nombre", text: $destination.name, prompt: Text("Mi servidor"))
            TextField("IP privada o DNS", text: $destination.host, prompt: Text("10.0.1.23"))
            TextField("Usuario", text: $destination.user)
            PortField(title: "Puerto SSH", value: $destination.port, prompt: "22")
            LabeledContent("Clave privada") {
                FileField(placeholder: "~/.ssh/id_rsa", path: $destination.privateKeyPath, directory: NSHomeDirectory() + "/.ssh")
            }
        }
        .formStyle(.grouped)
    }
}

struct TunnelForm: View {
    @State var tunnel: LocalTunnel
    let portMode: Bool
    let onSave: (LocalTunnel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var throughServer: Bool

    init(tunnel: LocalTunnel, portMode: Bool, onSave: @escaping (LocalTunnel) -> Void) {
        _tunnel = State(initialValue: tunnel)
        self.portMode = portMode
        self.onSave = onSave
        // En SOCKS5 hace falta un servidor SSH; en reenvío de puerto, solo si ya lo tenía.
        _throughServer = State(initialValue: !portMode || !tunnel.isDirect)
    }

    /// Qué falta para poder guardar; `nil` si está completo.
    private var missing: String? {
        if tunnel.remoteHost.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Falta el host remoto.") }
        if tunnel.remotePort == 0 { return String(localized: "Falta el puerto remoto.") }
        if tunnel.localPort == 0 { return String(localized: "Falta el puerto en tu Mac.") }
        if throughServer && tunnel.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Falta la IP del servidor SSH (o desmarca «Pasar por un servidor SSH»).")
        }
        if throughServer && tunnel.privateKeyPath.isEmpty { return String(localized: "Falta la clave privada del servidor SSH.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("🚇 Túnel a un puerto").font(.title2.weight(.bold))
            Text(throughServer
                 ? "Entro por SSH en el servidor y llevo su puerto remoto a un puerto de tu Mac."
                 : "El Bastion lleva el puerto remoto directamente a un puerto de tu Mac. Sin servidores intermedios.")
                .foregroundStyle(.secondary)
            Form {
                Section("Destino") {
                    TextField("Nombre", text: $tunnel.name, prompt: Text("Base de datos"))
                    TextField(throughServer ? "Host remoto (visto desde el servidor)" : "IP privada o DNS", text: $tunnel.remoteHost,
                              prompt: Text("10.0.1.23"))
                    PortField(title: "Puerto remoto", value: $tunnel.remotePort, prompt: "1521")
                    PortField(title: "Puerto en tu Mac", value: $tunnel.localPort, prompt: "11521")
                }
                Section {
                    Toggle("Pasar por un servidor SSH", isOn: $throughServer).disabled(!portMode)
                    if throughServer {
                        TextField("IP privada o DNS", text: $tunnel.host, prompt: Text("10.0.1.10"))
                        TextField("Usuario", text: $tunnel.user)
                        PortField(title: "Puerto SSH", value: $tunnel.sshPort, prompt: "22")
                        LabeledContent("Clave privada") {
                            FileField(placeholder: "~/.ssh/id_rsa", path: $tunnel.privateKeyPath, directory: NSHomeDirectory() + "/.ssh")
                        }
                    }
                } footer: {
                    Text(portMode
                         ? "Útil si el puerto solo escucha dentro del servidor (p. ej. 127.0.0.1)."
                         : "En modo SOCKS5 el túnel siempre pasa por un servidor SSH.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let missing {
                    Label(missing, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var result = tunnel
                    if !throughServer { result.host = "" }
                    onSave(result)
                    dismiss()
                }
                .buttonStyle(FunButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(missing != nil)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct NameSheet: View {
    let title: LocalizedStringKey
    @State var name: String
    @State var emoji: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.bold))
            NameAndEmojiFields(name: $name, emoji: $emoji)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Guardar") { onSave(name, emoji); dismiss() }
                    .buttonStyle(FunButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct NameAndEmojiFields: View {
    @Binding var name: String
    @Binding var emoji: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(emoji).font(.system(size: 40))
                TextField("Nombre de la conexión", text: $name).textFieldStyle(.roundedBorder).font(.title3)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 8), spacing: 8) {
                ForEach(Palette.emojis, id: \.self) { option in
                    Button { emoji = option } label: {
                        Text(option).font(.title2)
                            .frame(width: 38, height: 38)
                            .background(option == emoji ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
