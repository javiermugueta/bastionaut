import AppKit
import SwiftTerm

/// Terminal integrado: cada «Abrir SSH» abre una ventana propia de la app con el `ssh` corriendo en un PTY.
/// (En el Mac App Store no se permite controlar Terminal o iTerm2 desde una app en sandbox.)
@MainActor
final class TerminalWindows {
    static let shared = TerminalWindows()
    private var controllers: [TerminalWindowController] = []

    func open(command: String, title: String, banner: String? = nil) {
        let controller = TerminalWindowController(command: command, title: title, banner: banner) { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        NSApp.activate()
        controller.showWindow(nil)
        controller.focusTerminal()
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
    private let terminal: SandboxTerminalView
    private let baseTitle: String
    private let onClose: (TerminalWindowController) -> Void
    private var finished = false

    init(command: String, title: String, banner: String?, onClose: @escaping (TerminalWindowController) -> Void) {
        self.baseTitle = title
        self.onClose = onClose
        terminal = SandboxTerminalView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
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
        // Opción escribe caracteres (en el teclado español, ⌥2 es @, ⌥º es \…), como en Terminal de macOS;
        // como Meta mandaría Esc+tecla y bash vería «(arg: 2)».
        terminal.optionAsMetaKey = false
        if let banner { terminal.feed(text: "\u{1B}[2m\(banner)\u{1B}[0m\r\n") }
        let launch = TerminalWindows.launch(command: command)
        terminal.startProcess(executable: launch.executable, args: launch.args,
                              environment: TerminalWindows.environment())
        terminal.syncWindowSize()
        window.makeFirstResponder(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// La ventana puede aparecer unos segundos después del clic (mientras se crea la sesión): que el teclado vaya al terminal.
    func focusTerminal() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminal)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder !== terminal { window?.makeFirstResponder(terminal) }
    }

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

/// En sandbox, ssh no puede poner su terminal en modo raw (tcsetattr da «Operation not permitted»), así que
/// sin ayuda la sesión iría línea a línea: eco doble, sin Tab, flechas ni Ctrl-C. Cuando ssh ya se ha autenticado,
/// su LocalCommand escribe una marca invisible y la app pone el modo raw desde su lado del PTY, que sí puede.
final class SandboxTerminalView: LocalProcessTerminalView {
    /// Secuencia OSC que escribe el LocalCommand del ssh interactivo; nunca llega a la pantalla.
    static let rawModeMarker = Array("\u{1B}]2;bastionaut-raw\u{07}".utf8)
    /// Marcas del askpass para ocultar lo que se escribe (frase de la clave) y volver a mostrarlo.
    static let echoOffMarker = Array("\u{1B}]2;bastionaut-noecho\u{07}".utf8)
    static let echoOnMarker = Array("\u{1B}]2;bastionaut-echo\u{07}".utf8)
    /// Aviso de ssh al no poder cambiar el modo del terminal: ya lo hace la app, así que se oculta.
    /// (Con \r\n en modo línea y solo \n si la app ya ha puesto el modo raw.)
    static let noisyLines = ["tcsetattr: Operation not permitted\r\n", "tcsetattr: Operation not permitted\n"].map { Array($0.utf8) }

    /// Trozo final que podría ser el principio de una marca partida entre dos lecturas.
    private var pending: [UInt8] = []

    override func dataReceived(slice: ArraySlice<UInt8>) {
        var bytes = pending + Array(slice)
        pending = Self.splitPartialMarker(&bytes)
        if Self.remove(Self.echoOffMarker, from: &bytes) { setEcho(false) }
        if Self.remove(Self.echoOnMarker, from: &bytes) { setEcho(true) }
        if Self.remove(Self.rawModeMarker, from: &bytes) { enterRawMode() }
        for line in Self.noisyLines { _ = Self.remove(line, from: &bytes) }
        if !bytes.isEmpty { super.dataReceived(slice: bytes[...]) }
    }

    /// SwiftTerm arranca el proceso con el PTY a 0×0 y solo lo actualiza en los cambios de tamaño posteriores:
    /// sin esto ssh pediría al servidor 80×24 aunque la ventana sea más grande.
    func syncWindowSize() {
        var size = getWindowSize()
        guard process.childfd >= 0, size.ws_col > 0, size.ws_row > 0 else { return }
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func setEcho(_ on: Bool) {
        let fd = process.childfd
        var settings = termios()
        guard fd >= 0, tcgetattr(fd, &settings) == 0 else { return }
        if on { settings.c_lflag |= tcflag_t(ECHO) } else { settings.c_lflag &= ~tcflag_t(ECHO) }
        tcsetattr(fd, TCSANOW, &settings)
    }

    func enterRawMode() {
        let fd = process.childfd
        var settings = termios()
        guard fd >= 0, tcgetattr(fd, &settings) == 0 else { return }
        Self.makeRaw(&settings)
        tcsetattr(fd, TCSANOW, &settings)
    }

    /// Lo mismo que hace ssh al empezar la sesión (enter_raw_mode).
    static func makeRaw(_ settings: inout termios) {
        settings.c_iflag |= tcflag_t(IGNPAR)
        settings.c_iflag &= ~tcflag_t(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF)
        settings.c_lflag &= ~tcflag_t(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL | IEXTEN)
        settings.c_oflag &= ~tcflag_t(OPOST)
        withUnsafeMutableBytes(of: &settings.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
    }

    static var markers: [[UInt8]] { [rawModeMarker, echoOffMarker, echoOnMarker] }

    /// Si `bytes` acaba en el principio de una marca, lo separa para juntarlo con la siguiente lectura.
    static func splitPartialMarker(_ bytes: inout [UInt8]) -> [UInt8] {
        guard let escape = bytes.lastIndex(of: 0x1B) else { return [] }
        let tail = Array(bytes[escape...])
        guard markers.contains(where: { $0.count > tail.count && $0.starts(with: tail) }) else { return [] }
        bytes.removeSubrange(escape...)
        return tail
    }

    /// Quita todas las apariciones de `pattern`; devuelve si había alguna.
    static func remove(_ pattern: [UInt8], from bytes: inout [UInt8]) -> Bool {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return false }
        var found = false
        var index = 0
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        while index < bytes.count {
            if index + pattern.count <= bytes.count, bytes[index..<index + pattern.count].elementsEqual(pattern) {
                found = true
                index += pattern.count
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        if found { bytes = result }
        return found
    }
}
