import AppKit
import SwiftTerm

/// Terminal integrado: cada «Abrir SSH» abre una ventana propia de la app con el `ssh` corriendo en un PTY.
/// (En el Mac App Store no se permite controlar Terminal o iTerm2 desde una app en sandbox.)
@MainActor
final class TerminalWindows {
    static let shared = TerminalWindows()
    private var controllers: [TerminalWindowController] = []

    func open(command: String, title: String) {
        let controller = TerminalWindowController(command: command, title: title) { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }

    var openCount: Int { controllers.count }

    /// Al salir de la app se cierran los ssh que sigan abiertos.
    func terminateAll() {
        controllers.forEach { $0.terminate() }
    }

    /// Argumentos con los que se lanza el comando: un shell no interactivo que ejecuta la línea de `ssh` ya escapada.
    /// Antes deja en OCIB_TTY el dispositivo del PTY para el askpass (el sandbox no deja abrir /dev/tty).
    nonisolated static func launch(command: String) -> (executable: String, args: [String]) {
        ("/bin/sh", ["-c", "OCIB_TTY=$(tty); export OCIB_TTY; " + command])
    }

    /// Entorno del proceso: el de SwiftTerm más el askpass de la app, para que ssh pueda preguntar.
    nonisolated static func environment(askpass: String? = Bundle.main.path(forResource: "askpass", ofType: "sh")) -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if let askpass, FileManager.default.isExecutableFile(atPath: askpass) {
            environment += ["SSH_ASKPASS=\(askpass)", "SSH_ASKPASS_REQUIRE=force"]
        }
        return environment
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    private let baseTitle: String
    private let onClose: (TerminalWindowController) -> Void
    private var finished = false

    init(command: String, title: String, onClose: @escaping (TerminalWindowController) -> Void) {
        self.baseTitle = title
        self.onClose = onClose
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "🖥️ \(title)"
        window.contentView = terminal
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.cascadeTopLeft(from: NSPoint(x: 120, y: 120))
        window.center()
        super.init(window: window)
        window.delegate = self
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let launch = TerminalWindows.launch(command: command)
        terminal.startProcess(executable: launch.executable, args: launch.args,
                              environment: TerminalWindows.environment())
        window.makeFirstResponder(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func terminate() {
        guard !finished else { return }
        finished = true
        terminal.terminate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    func windowWillClose(_ notification: Notification) {
        terminate()
        onClose(self)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            finished = true
            let code = exitCode.map { String($0) } ?? "?"
            let note = String(localized: "Conexión cerrada (código \(code)). Ya puedes cerrar esta ventana.")
            source.feed(text: "\r\n\u{1B}[2m— \(note) —\u{1B}[0m\r\n")
            window?.title = "🖥️ \(baseTitle) — " + String(localized: "cerrada")
        }
    }
}
