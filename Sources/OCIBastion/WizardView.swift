import SwiftUI

/// Asistente paso a paso para crear una conexión o cambiar la cuenta y el Bastion de la actual.
struct WizardView: View {
    enum Step: Int, CaseIterable {
        case welcome, account, bastion, keys, server, name

        var title: String {
            switch self {
            case .welcome: return String(localized: "¡Hola! 👋")
            case .account: return String(localized: "Tu cuenta de OCI ☁️")
            case .bastion: return String(localized: "Elige el Bastion 🏰")
            case .keys: return String(localized: "¿Cómo entramos? 🔑")
            case .server: return String(localized: "Tu primer servidor 🖥️")
            case .name: return String(localized: "Ponle nombre ✨")
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
    @State private var accountDraft = OCIAccount()
    @State private var accountChoice: UUID?
    @State private var keyText = ""
    @State private var keyPassphrase = ""
    @State private var importedKey: ImportedAPIKey?
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
            HelpButton(topic: step == .keys ? .modes : (step == .bastion ? .oci : .start))
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
            Bullet("☁️", "Hablo directamente con la API de OCI con tu clave de API, que guardo en el Llavero. No hace falta el OCI CLI.")
            Bullet("🏰", "Busco tus Bastiones en toda la tenancy, sin que tengas que saber en qué compartimento están.")
            Bullet("🔑", "Si quieres, me encargo de las claves del Bastion: creo una por sesión y la borro al caducar.")
            Bullet("⏳", "Renuevo la sesión antes de que caduque para que no se te corte nada.")
            DemoOffer { manager.enterDemo(); close() }
                .padding(.top, 6)
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Necesito los datos de tu clave de API de OCI. Los encuentras en la consola de OCI › tu perfil › **Claves de API**.")
                .foregroundStyle(.secondary)
            if manager.accounts.isEmpty && mode == .create {
                DemoOffer { manager.enterDemo(); close() }
            }
            appAccount
            Form {
                ProxyPicker(settings: $draft)
                if accountOK {
                    Picker("Región", selection: Binding(get: { draft.region ?? "" }, set: { draft.region = $0 })) {
                        ForEach(regions, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.region) { bastions = []; bastionDetails = nil }
            HStack {
                Button(accountOK ? "Volver a probar" : "Probar conexión 🔌") { testAccount() }.disabled(busy)
                if accountOK { Label("¡Conectado! \(regions.count) región(es) disponibles", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
        }
    }

    private var appAccount: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !manager.accounts.isEmpty {
                Picker("Cuenta", selection: Binding(get: { accountChoice }, set: { selectAccount($0) })) {
                    ForEach(manager.accounts) { Text("☁️ \($0.displayName)").tag(Optional($0.id)) }
                    Divider()
                    Text("➕ Nueva cuenta…").tag(UUID?.none)
                }
            }
            if accountChoice == nil {
                AccountFields(account: $accountDraft, keyText: $keyText, passphrase: $keyPassphrase, imported: importedKey)
                    .onChange(of: accountDraft) { accountOK = false }
                    .onChange(of: keyText) { accountOK = false; importedKey = nil }
            } else if let chosen = manager.accounts.first(where: { $0.id == accountChoice }) {
                Text("Tenancy …\(String(chosen.tenancy.suffix(12))) · \(chosen.region) · huella \(chosen.fingerprint)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

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
                Text("No encontré bastiones en \(draft.region ?? String(localized: "la región")). Prueba con otra región o búscalo en un compartimento.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                if busy && bastions.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack {
                            Text("🏯").font(.title2)
                            VStack(alignment: .leading) {
                                Text("Bastion de ejemplo").font(.headline)
                                Text("…ocid1.bastion").font(.caption.monospaced())
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        .redacted(reason: .placeholder)
                        .modifier(Pulse())
                    }
                }
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
                    Chip(text: bastionDetails.supportsSOCKS ? String(localized: "SOCKS5 ✅") : String(localized: "SOCKS5 ❌"), tint: bastionDetails.supportsSOCKS ? .green : .orange)
                    if let ttl = bastionDetails.maxSessionTtlInSeconds { Chip(text: String(localized: "Sesión máx. \(ttl / 60) min")) }
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
                ChoiceCard(emoji: "🧦", title: String(localized: "SOCKS5"), detail: String(localized: "Un solo túnel para todos tus servidores. El más cómodo."),
                           selected: draft.effectiveSessionMode == .socks,
                           disabledReason: bastionDetails?.supportsSOCKS == false ? String(localized: "Este Bastion no tiene SOCKS5 activado") : nil) {
                    draft.sessionMode = .socks
                }
                ChoiceCard(emoji: "🎯", title: String(localized: "Reenvío de puerto"), detail: String(localized: "Una sesión por servidor. Funciona con cualquier Bastion."),
                           selected: draft.effectiveSessionMode == .portForwarding) {
                    draft.sessionMode = .portForwarding
                }
            }
            Text("Claves del Bastion").font(.headline)
            HStack(spacing: 12) {
                ChoiceCard(emoji: "✨", title: String(localized: "Temporales (recomendado)"),
                           detail: String(localized: "Creo una clave por sesión, la guardo solo para ti y la borro al caducar."),
                           selected: draft.effectiveKeyMode == .ephemeral) { draft.keyMode = .ephemeral }
                ChoiceCard(emoji: "🗝️", title: String(localized: "Mis propias claves"), detail: String(localized: "Elige un par de claves que ya tengas."),
                           selected: draft.effectiveKeyMode == .custom) { draft.keyMode = .custom }
            }
            if draft.effectiveKeyMode == .custom {
                FileField(placeholder: "Clave pública (.pub)", path: $draft.publicKeyPath, directory: NSHomeDirectory() + "/.ssh", importsKey: true)
                FileField(placeholder: "Clave privada", path: $draft.privateKeyPath, directory: NSHomeDirectory() + "/.ssh", importsKey: true)
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
            fresh.proxyMode = draft.proxyMode
            fresh.proxyHost = draft.proxyHost
            fresh.proxyPort = draft.proxyPort
            fresh.terminalApp = draft.terminalApp
            fresh.accountID = draft.accountID
            fresh.keyMode = .ephemeral
            draft = fresh
        }
        accountChoice = draft.accountID ?? manager.accounts.first?.id
        step = steps.first ?? .account
    }

    private func move(_ delta: Int) {
        guard let index = steps.firstIndex(of: step) else { return }
        let target = min(max(0, index + delta), steps.count - 1)
        problem = nil
        withAnimation(.easeInOut(duration: 0.2)) { step = steps[target] }
        if step == .bastion && bastions.isEmpty { searchBastions() }
        if step == .bastion && bastionDetails == nil && !draft.bastionID.isEmpty { selectBastion(draft.bastionID, name: draft.bastionName) }
        if step == .account && !accountOK && accountChoice != nil { testAccount() }
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

    private func run(_ message: String.LocalizationValue, _ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        withAnimation { busyMessage = String(localized: message) }
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
                let proxy = try await manager.resolvedProxy(for: snapshot, destination: PublicIP.serviceURL)
                ipReport = PublicIP.report(ip: try await PublicIP.fetch(proxy: proxy), allowList: allowList)
            } catch { ipReport = error.localizedDescription }
        }
    }

    private func selectAccount(_ id: UUID?) {
        accountChoice = id
        accountOK = false
        if id == nil {
            accountDraft = OCIAccount()
            keyText = ""
            keyPassphrase = ""
            importedKey = nil
        }
    }

    private func testAccount() {
        var snapshot = draft
        let newAccount = accountChoice == nil
        var candidate = accountDraft
        let pem = keyText
        let passphrase = keyPassphrase
        if let accountChoice { snapshot.accountID = accountChoice }
        run("Hablando con OCI para comprobar tu cuenta… 🔌") {
            var profile: OCIProfile?
            var key: ImportedAPIKey?
            if newAccount {
                for (value, field) in [(candidate.tenancy, "OCID de la tenancy"), (candidate.user, "OCID del usuario"),
                                       (candidate.region, "Región")] where value.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw BastionError.message(String(localized: "Falta «\(String(localized: String.LocalizationValue(field)))»."))
                }
                candidate.region = try InputCheck.region(candidate.region)
                guard !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BastionError.message(String(localized: "Falta la clave privada de API: elige el archivo .pem o pégala."))
                }
                let prepared = try await APIKeyImport.prepare(pem: pem, passphrase: passphrase)
                importedKey = prepared
                key = prepared
                if !candidate.fingerprint.isEmpty && candidate.fingerprint.lowercased() != prepared.fingerprint {
                    throw BastionError.message(String(localized: "La huella escrita (\(candidate.fingerprint)) no corresponde a esta clave (\(prepared.fingerprint)). ¿Es la clave correcta?"))
                }
                candidate.fingerprint = prepared.fingerprint
                accountDraft.fingerprint = prepared.fingerprint
                profile = candidate.profile(privateKeyPEM: prepared.pem)
            }
            let client = try await manager.client(for: snapshot, profile: profile)
            let subscribed = try await client.regionSubscriptions()
                .filter { $0.status == nil || $0.status == "READY" }
                .map(\.regionName).sorted()
            regions = subscribed.isEmpty ? [client.profile.region] : subscribed
            if draft.region == nil || !(regions.contains(draft.region ?? "")) { draft.region = client.profile.region }
            if newAccount, let key {
                if candidate.name.isEmpty { candidate.name = String(localized: "Cuenta \(candidate.region)") }
                try manager.saveAccount(candidate, key: key)
                accountDraft = candidate
                accountChoice = candidate.id
            }
            draft.accountID = accountChoice
            accountOK = true
        }
    }

    private func searchBastions() {
        let snapshot = draft
        run("Buscando bastiones en toda la tenancy (\(snapshot.region ?? String(localized: "región del perfil")))… 🔎") {
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

/// Parpadeo suave para las filas de relleno mientras se carga.
private struct Pulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// Datos de una cuenta de OCI introducidos a mano.
struct AccountFields: View {
    @Binding var account: OCIAccount
    @Binding var keyText: String
    @Binding var passphrase: String
    let imported: ImportedAPIKey?
    @State private var snippet = ""
    @State private var showSnippet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Atajo: pega el fragmento de configuración que te da la consola de OCI", isExpanded: $showSnippet) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $snippet)
                        .font(.caption.monospaced())
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    Button("Rellenar los campos ✨") {
                        if account.fill(fromSnippet: snippet) { showSnippet = false }
                    }
                    .disabled(snippet.isEmpty)
                }
                .padding(.top, 6)
            }
            Form {
                TextField("Nombre", text: $account.name, prompt: Text("Mi tenancy"))
                TextField("OCID de la tenancy", text: $account.tenancy, prompt: Text("ocid1.tenancy.oc1..aaaa…"))
                TextField("OCID del usuario", text: $account.user, prompt: Text("ocid1.user.oc1..aaaa…"))
                TextField("Región", text: $account.region, prompt: Text("eu-madrid-1"))
                TextField("Huella (opcional)", text: $account.fingerprint, prompt: Text("La calculo a partir de la clave"))
                Section("Clave privada de API") {
                    HStack {
                        Button("Elegir archivo .pem…") {
                            let panel = NSOpenPanel()
                            panel.showsHiddenFiles = true
                            panel.allowedContentTypes = [.data, .text]
                            if panel.runModal() == .OK, let url = panel.url,
                               let contents = try? String(contentsOf: url, encoding: .utf8) {
                                keyText = contents
                            }
                        }
                        Text("o pégala aquí abajo").foregroundStyle(.secondary).font(.caption)
                    }
                    TextEditor(text: $keyText)
                        .font(.caption2.monospaced())
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    if keyText.contains("ENCRYPTED") {
                        SecureField("Contraseña de la clave", text: $passphrase)
                    }
                    if let imported {
                        Label("Clave RSA válida · huella \(imported.fingerprint)", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            Text("🔐 La clave privada se guarda cifrada en tu Llavero de macOS, solo para esta app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Invitación a probar la app con datos de ejemplo, sin cuenta de OCI.
struct DemoOffer: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("🎮").font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("¿Sin cuenta de OCI a mano?").font(.headline)
                Text("Prueba la app con datos de ejemplo. No se conecta nada de verdad.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Probar con datos de ejemplo", action: action).buttonStyle(SoftButtonStyle(tint: .purple))
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
