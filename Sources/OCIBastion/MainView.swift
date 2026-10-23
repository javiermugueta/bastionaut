import SwiftUI
import UniformTypeIdentifiers

enum WizardMode: Identifiable {
    case create
    case edit
    var id: Int { self == .create ? 0 : 1 }
}

struct MainView: View {
    @Bindable var manager: TunnelManager
    @State private var wizard: WizardMode?
    @State private var showImportConfirmation = false
    @State private var importPlan: ConfigurationImportPlan?
    @State private var pendingDelete: SavedConnection?
    @State private var renaming: SavedConnection?
    @Environment(\.openWindow) private var openHelp

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if manager.selectedConnection != nil || !manager.settings.bastionID.isEmpty {
                ConnectionDetailView(manager: manager, editWithWizard: { wizard = .edit })
            } else {
                EmptyStateView(start: { wizard = .create }, tryDemo: { manager.enterDemo() })
            }
        }
        .fontDesign(.rounded)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { HelpButton() }
        }
        .overlay(alignment: .bottom) {
            if let toast = manager.toast {
                Text(toast)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(manager.toastIsError ? Color.white : Color.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(manager.toastIsError ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(.regularMaterial),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture { manager.toast = nil }
                    .shadow(radius: 8, y: 4)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.toast)
        .sheet(item: $wizard) { mode in
            WizardView(manager: manager, mode: mode, firstRun: manager.needsOnboarding) { wizard = nil }
        }
        .onChange(of: manager.isDemo) { if !manager.isDemo && manager.needsOnboarding { wizard = .create } }
        .onAppear {
            if manager.needsOnboarding && !manager.isDemo { wizard = .create }
            if Showcase.launchedForScreenshots && Showcase.scene == "help" {
                HelpRouter.shared.topic = .targets
                openHelp(id: "help")
            }
        }
        .confirmationDialog("¿Sobrescribir?", isPresented: $showImportConfirmation) {
            Button("Importar y sobrescribir", role: .destructive) {
                if let importPlan { manager.applyImport(importPlan) }
                importPlan = nil
            }
            Button("Cancelar", role: .cancel) { importPlan = nil }
        } message: { Text(importWarning) }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { manager.settings.selectedSavedConnectionID },
            set: { manager.selectConnection($0) }
        )) {
            Section("Conexiones") {
                ForEach(manager.savedConnections) { connection in
                    HStack(spacing: 10) {
                        Text(connection.displayEmoji).font(.title3)
                        Text(connection.name).lineLimit(1)
                        Spacer()
                        if connection.id == manager.settings.selectedSavedConnectionID && manager.isRunning {
                            Circle().fill(manager.overallState.tint).frame(width: 8, height: 8)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(connection.id))
                    .contextMenu {
                        Button("Renombrar…") { renaming = connection }
                        Button("Duplicar") { manager.duplicateConnection(id: connection.id) }
                            .disabled(manager.isRunning)
                        Divider()
                        Button("Eliminar…", role: .destructive) { pendingDelete = connection }
                    }
                }
            }
        }
        .onDeleteCommand {
            if let selected = manager.selectedConnection { pendingDelete = selected }
        }
        .confirmationDialog("¿Eliminar «\(pendingDelete?.name ?? "")»?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Eliminar", role: .destructive) {
                if let pendingDelete { manager.deleteConnection(id: pendingDelete.id) }
                pendingDelete = nil
            }
        } message: { Text("Esta acción no se puede deshacer.") }
        .sheet(item: $renaming) { connection in
            NameSheet(title: "Renombrar conexión", name: connection.name, emoji: connection.displayEmoji) { name, emoji in
                manager.renameConnection(id: connection.id, to: name, emoji: emoji)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    // Desde la demo, crear una conexión de verdad empieza por salir de ella.
                    if manager.isDemo { manager.exitDemo() }
                    wizard = .create
                } label: {
                    Label("Nueva conexión", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(FunButtonStyle())
                .disabled(manager.isRunning && !manager.isDemo)
                Menu {
                    Button("Importar…") { importConfiguration() }
                    Divider()
                    Button("Exportar todo…") { export(.all) }
                    Button("Exportar esta conexión…") { export(.active) }
                } label: {
                    Label("Importar / Exportar", systemImage: "shippingbox")
                }
                .menuStyle(.borderlessButton)
                .disabled(manager.isRunning || manager.isDemo)
            }
            .padding(12)
        }
    }

    private var importWarning: String {
        guard let importPlan else { return "" }
        var changes: [String] = []
        if importPlan.archive.current != nil { changes.append("la configuración actual") }
        if !importPlan.conflictingNames.isEmpty {
            changes.append("las conexiones " + importPlan.conflictingNames.joined(separator: ", "))
        }
        return "\(importPlan.fileName) sobrescribirá " + changes.joined(separator: " y ") + ". El resto se conserva."
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let plan = manager.prepareImport(from: url) else { return }
        if plan.needsConfirmation {
            importPlan = plan
            showImportConfirmation = true
        } else {
            manager.applyImport(plan)
        }
    }

    private func export(_ scope: ExportScope) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = scope == .all ? "OCI-Bastion-todo.json" : "OCI-Bastion-\(manager.selectedConnection?.name ?? "activa").json"
        if panel.runModal() == .OK, let url = panel.url { manager.exportConfiguration(to: url, scope: scope) }
    }
}

struct EmptyStateView: View {
    let start: () -> Void
    let tryDemo: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("🏰").font(.system(size: 90))
            Text("Aquí no hay nadie todavía").font(.largeTitle.weight(.heavy))
            Text("Te acompaño paso a paso: cuenta OCI, Bastion y tu primer servidor.\nEn un par de minutos estarás dentro.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("¡Empecemos! 🚀", action: start).buttonStyle(FunButtonStyle())
            Button("¿Sin cuenta de OCI a mano? Probar con datos de ejemplo 🎮", action: tryDemo)
                .buttonStyle(SoftButtonStyle())
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
