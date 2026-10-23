import SwiftUI

/// Asistente paso a paso para crear una conexión o cambiar la cuenta y el Bastion de la actual.
struct WizardView: View {
    enum Step: Int, CaseIterable {
        case welcome, account, bastion, keys, server, name

        var title: String {
            switch self {
            case .welcome: return "¡Hola! 👋"
            case .account: return "Tu cuenta de OCI ☁️"
            case .bastion: return "Elige el Bastion 🏰"
            case .keys: return "¿Cómo entramos? 🔑"
            case .server: return "Tu primer servidor 🖥️"
            case .name: return "Ponle nombre ✨"
            }
        }
    }

    let manager: TunnelManager
    let mode: WizardMode
    let firstRun: Bool
    let close: () -> Void

    @State private var step: Step = .account
    @State private var draft = Settings()
    @State private var regions: [String] = []
    @State private var accountOK = false
    @State private var busy = false
    @State private var busyMessage: String?
    @State private var ipReport: String?
    @State private var checkingIP = false
    @State private var problem: String?
    @State private var bastions: [BastionItem] = []
    @State private var bastionFilter = ""
    @State private var bastionDetails: BastionDetails?
    @State private var showManualBastion = false
    @State private var compartments: [CompartmentItem] = []
    @State private var compartmentID = ""
    @State private var destination = Destination(privateKeyPath: SSHKeys.suggestedPrivateKey)
    @State private var name = ""
    @State private var emoji = Palette.emojis.randomElement() ?? "🏰"

    private var steps: [Step] {
        var result: [Step] = mode == .create && firstRun ? [.welcome] : []
        result += [.account, .bastion, .keys]
        if mode == .create { result += [.server, .name] }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let busyMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(busyMessage).font(.callout.weight(.semibold))
                            ProgressView().progressViewStyle(.linear)
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity)
                    }
                    content
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .fontDesign(.rounded)
        .onAppear(perform: prepare)
    }

    // MARK: Estructura

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(.quaternary))
                        .frame(height: 6)
                }
            }
            Text(step.title).font(.system(size: 26, weight: .heavy, design: .rounded))
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if step != steps.first {
                Button("Atrás") { move(-1) }
            }
            Button(step == steps.last ? (mode == .create ? "¡Listo! 🎉" : "Guardar cambios") : "Siguiente") { next() }
                .buttonStyle(FunButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || busy)
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .account: account
        case .bastion: bastion
        case .keys: keys
        case .server: server
        case .name: naming
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .account: return accountOK
        case .bastion: return !draft.bastionID.isEmpty
        case .keys:
            if draft.effectiveSessionMode == .socks && bastionDetails?.supportsSOCKS == false { return false }
            return draft.effectiveKeyMode == .ephemeral || (!draft.publicKeyPath.isEmpty && !draft.privateKeyPath.isEmpty)
        case .server: return true
        case .name: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: Pasos

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voy a ayudarte a entrar en tus máquinas privadas de OCI sin pelearte con comandos.")
                .font(.title3)
            Bullet("☁️", "Uso tu `~/.oci/config` para hablar directamente con la API de OCI. No hace falta el OCI CLI.")
            Bullet("🏰", "Busco tus Bastiones en toda la tenancy, sin que tengas que saber en qué compartimento están.")
            Bullet("🔑", "Si quieres, me encargo de las claves del Bastion: creo una por sesión y la borro al caducar.")
            Bullet("⏳", "Renuevo la sesión antes de que caduque para que no se te corte nada.")
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Necesito un perfil de `~/.oci/config` con una clave de API.").foregroundStyle(.secondary)
            Form {
                LabeledContent("Archivo") {
                    FileField(placeholder: "~/.oci/config", path: $draft.configPath, directory: NSHomeDirectory() + "/.oci")
                }
                Picker("Perfil", selection: $draft.profile) {
                    ForEach(profiles, id: \.self) { Text($0).tag($0) }
                }
                ProxyPicker(settings: $draft)
                if accountOK {
                    Picker("Región", selection: Binding(get: { draft.region ?? "" }, set: { draft.region = $0 })) {
                        ForEach(regions, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.configPath) { accountOK = false }
            .onChange(of: draft.profile) { accountOK = false }
            .onChange(of: draft.region) { bastions = []; bastionDetails = nil }
            HStack {
                Button(accountOK ? "Volver a probar" : "Probar conexión 🔌") { testAccount() }.disabled(busy)
                if accountOK { Label("¡Conectado! \(regions.count) región(es) disponibles", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
            if profiles.isEmpty {
                Text("¿No tienes configuración? Créala con `oci setup config` o desde la consola de OCI › Perfil › Claves de API › Añadir clave de API.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var profiles: [String] { (try? OCIConfig.profiles(at: draft.configPath)) ?? [] }

    private var filteredBastions: [BastionItem] {
        bastionFilter.isEmpty ? bastions : bastions.filter { $0.name.localizedCaseInsensitiveContains(bastionFilter) }
    }

    private var bastion: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Filtrar por nombre", text: $bastionFilter).textFieldStyle(.roundedBorder)
                Button("Buscar de nuevo") { searchBastions() }.disabled(busy)
            }
            if bastions.isEmpty && !busy {
                Text("No encontré bastiones en \(draft.region ?? "la región"). Prueba con otra región o búscalo en un compartimento.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(filteredBastions) { item in
                    Button { selectBastion(item.id, name: item.name) } label: {
                        HStack {
                            Text(item.id == draft.bastionID ? "🏰" : "🏯").font(.title2)
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text("…" + item.id.suffix(12)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.id == draft.bastionID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        .padding(10)
                        .background(item.id == draft.bastionID ? Color.green.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let bastionDetails {
                HStack {
                    Chip(text: bastionDetails.supportsSOCKS ? "SOCKS5 ✅" : "SOCKS5 ❌", tint: bastionDetails.supportsSOCKS ? .green : .orange)
                    if let ttl = bastionDetails.maxSessionTtlInSeconds { Chip(text: "Sesión máx. \(ttl / 60) min") }
                }
                if let cidrs = bastionDetails.clientCidrBlockAllowList, !cidrs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Este Bastion solo acepta conexiones desde: \(cidrs.joined(separator: ", "))", systemImage: "shield.lefthalf.filled")
                            .font(.callout)
                        HStack {
                            Button(checkingIP ? "Comprobando…" : "¿Está permitida mi IP? 🌐") { checkIP(cidrs) }.disabled(checkingIP)
                            if checkingIP { ProgressView().controlSize(.small) }
                        }
                        if let ipReport { Text(ipReport).font(.callout.weight(.semibold)).textSelection(.enabled) }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            DisclosureGroup("¿No aparece? Búscalo en un compartimento o pega su OCID", isExpanded: $showManualBastion) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Compartimento", selection: $compartmentID) {
                            Text("Selecciona…").tag("")
                            ForEach(compartments) { Text($0.label).tag($0.id) }
                        }
                        Button("Cargar") { loadCompartments() }.disabled(busy)
                    }
                    .onChange(of: compartmentID) { if !compartmentID.isEmpty { listBastions(in: compartmentID) } }
                    TextField("OCID del Bastion", text: Binding(get: { draft.bastionID }, set: { value in
                        draft.bastionID = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.bastionName = nil
                        bastionDetails = nil
                    }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { selectBastion(draft.bastionID, name: nil) }
                }
                .padding(.top, 8)
            }
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tipo de sesión").font(.headline)
            HStack(spacing: 12) {
                ChoiceCard(emoji: "🧦", title: "SOCKS5", detail: "Un solo túnel para todos tus servidores. El más cómodo.",
                           selected: draft.effectiveSessionMode == .socks,
                           disabledReason: bastionDetails?.supportsSOCKS == false ? "Este Bastion no tiene SOCKS5 activado" : nil) {
                    draft.sessionMode = .socks
                }
                ChoiceCard(emoji: "🎯", title: "Reenvío de puerto", detail: "Una sesión por servidor. Funciona con cualquier Bastion.",
                           selected: draft.effectiveSessionMode == .portForwarding) {
                    draft.sessionMode = .portForwarding
                }
            }
            Text("Claves del Bastion").font(.headline)
            HStack(spacing: 12) {
                ChoiceCard(emoji: "✨", title: "Temporales (recomendado)",
                           detail: "Creo una clave por sesión, la guardo solo para ti y la borro al caducar.",
                           selected: draft.effectiveKeyMode == .ephemeral) { draft.keyMode = .ephemeral }
                ChoiceCard(emoji: "🗝️", title: "Mis propias claves", detail: "Elige un par de claves que ya tengas.",
                           selected: draft.effectiveKeyMode == .custom) { draft.keyMode = .custom }
            }
            if draft.effectiveKeyMode == .custom {
                FileField(placeholder: "Clave pública (.pub)", path: $draft.publicKeyPath, directory: NSHomeDirectory() + "/.ssh")
                FileField(placeholder: "Clave privada", path: $draft.privateKeyPath, directory: NSHomeDirectory() + "/.ssh")
            }
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Opcional: añade ahora el servidor al que quieres entrar. Puedes añadir más después.")
                .foregroundStyle(.secondary)
            DestinationFields(destination: $destination)
        }
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: 14) {
            NameAndEmojiFields(name: $name, emoji: $emoji)
            Text("Al terminar verás la conexión en la barra lateral. Pulsa **Conectar 🚀** y listo.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Acciones

    private func prepare() {
        draft = manager.settings
        if mode == .create {
            var fresh = Settings()
            fresh.configPath = draft.configPath.isEmpty ? OCIConfig.defaultPath : draft.configPath
            fresh.profile = draft.profile
            fresh.proxyMode = draft.proxyMode
            fresh.proxyHost = draft.proxyHost
            fresh.proxyPort = draft.proxyPort
            fresh.terminalApp = draft.terminalApp
            fresh.keyMode = .ephemeral
            draft = fresh
        }
        if !profiles.contains(draft.profile) { draft.profile = profiles.first ?? "DEFAULT" }
        step = steps.first ?? .account
    }

    private func move(_ delta: Int) {
        guard let index = steps.firstIndex(of: step) else { return }
        let target = min(max(0, index + delta), steps.count - 1)
        problem = nil
        withAnimation(.easeInOut(duration: 0.2)) { step = steps[target] }
        if step == .bastion && bastions.isEmpty { searchBastions() }
        if step == .bastion && bastionDetails == nil && !draft.bastionID.isEmpty { selectBastion(draft.bastionID, name: draft.bastionName) }
        if step == .account && !accountOK && !profiles.isEmpty { testAccount() }
        if step == .name && name.isEmpty { name = draft.bastionName ?? "" }
    }

    private func next() {
        if step == steps.last { return finish() }
        move(1)
    }

    private func finish() {
        if mode == .edit {
            manager.applyDraft(draft)
            return close()
        }
        var result = draft
        if !destination.host.isEmpty { result.destinations = [destination] }
        if manager.addConnection(named: name, emoji: emoji, from: result) { close() }
    }

    private func run(_ message: String, _ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        withAnimation { busyMessage = message }
        Task {
            do { try await work() } catch { problem = (error as? BastionError)?.userMessage ?? error.localizedDescription }
            busy = false
            withAnimation { busyMessage = nil }
        }
    }

    private func checkIP(_ allowList: [String]) {
        checkingIP = true
        let snapshot = draft
        Task {
            defer { checkingIP = false }
            do {
                let proxy = try await manager.resolvedProxy(for: snapshot)
                ipReport = PublicIP.report(ip: try await PublicIP.fetch(proxy: proxy), allowList: allowList)
            } catch { ipReport = error.localizedDescription }
        }
    }

    private func testAccount() {
        let snapshot = draft
        run("Hablando con OCI para comprobar tu cuenta… 🔌") {
            let client = try await manager.client(for: snapshot)
            let subscribed = try await client.regionSubscriptions()
                .filter { $0.status == nil || $0.status == "READY" }
                .map(\.regionName).sorted()
            regions = subscribed.isEmpty ? [client.profile.region] : subscribed
            if draft.region == nil || !(regions.contains(draft.region ?? "")) { draft.region = client.profile.region }
            accountOK = true
        }
    }

    private func searchBastions() {
        let snapshot = draft
        run("Buscando bastiones en toda la tenancy (\(snapshot.region ?? "región del perfil"))… 🔎") {
            bastions = try await manager.client(for: snapshot).searchBastions()
            if bastions.count == 1, draft.bastionID.isEmpty, let only = bastions.first { selectBastion(only.id, name: only.name) }
        }
    }

    private func selectBastion(_ id: String, name: String?) {
        guard !id.isEmpty else { return }
        draft.bastionID = id
        draft.bastionName = name
        let snapshot = draft
        ipReport = nil
        run("Consultando el Bastion… 🏰") {
            let details = try await manager.client(for: snapshot).getBastion(id: id)
            bastionDetails = details
            draft.bastionName = details.name
            draft.compartmentID = details.compartmentId
            if draft.sessionMode == nil { draft.sessionMode = details.supportsSOCKS ? .socks : .portForwarding }
            if !details.supportsSOCKS { draft.sessionMode = .portForwarding }
            if let maxTTL = details.maxSessionTtlInSeconds { draft.ttlSeconds = min(max(1800, maxTTL), 10800) }
        }
    }

    private func loadCompartments() {
        let snapshot = draft
        run("Cargando compartimentos… 📂") {
            let client = try await manager.client(for: snapshot)
            compartments = OCIAPIClient.compartmentItems(tenancyID: client.profile.tenancy,
                                                         records: try await client.listCompartments())
        }
    }

    private func listBastions(in compartment: String) {
        let snapshot = draft
        run("Buscando bastiones en el compartimento… 🔎") {
            bastions = try await manager.client(for: snapshot).listBastions(compartmentID: compartment)
        }
    }
}

private struct Bullet: View {
    let emoji: String
    let text: LocalizedStringKey

    init(_ emoji: String, _ text: LocalizedStringKey) {
        self.emoji = emoji
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(emoji).font(.title2)
            Text(text)
        }
    }
}

struct ChoiceCard: View {
    let emoji: String
    let title: String
    let detail: String
    let selected: Bool
    var disabledReason: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(emoji).font(.title)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? .green : .secondary)
                }
                Text(title).font(.headline)
                Text(disabledReason ?? detail).font(.caption).foregroundStyle(disabledReason == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .opacity(disabledReason == nil ? 1 : 0.6)
    }
}
