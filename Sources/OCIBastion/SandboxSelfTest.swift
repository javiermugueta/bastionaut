#if DEBUG
import AppKit
import Foundation
import SwiftTerm

/// Lanza un proceso en un PTY de SwiftTerm, como hace el terminal integrado, y devuelve su código de salida.
private final class PTYProbe: NSObject, LocalProcessTerminalViewDelegate {
    var done: ((Int32?) -> Void)?
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { done?(exitCode) }
}

/// Autotest para comprobar la versión con sandbox: `OCIB_SANDBOX_SELFTEST=1` al lanzar el ejecutable.
@MainActor
enum SandboxSelfTest {
    /// Abre dos ventanas de terminal, teclea con eventos reales de teclado y comprueba qué llega al proceso.
    static func focusTestIfRequested() {
        guard ProcessInfo.processInfo.environment["OCIB_TERMINAL_FOCUS_TEST"] == "1" else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            func typeText(_ text: String) {
                for character in text {
                    var chars = character == "\t" ? "\t" : String(character)
                    var code: UInt16 = character == "\t" ? 48 : (character == "\r" ? 36 : (character == "@" ? 19 : 0))
                    // «@» como en el teclado español: ⌥2.
                    var flags: NSEvent.ModifierFlags = character == "@" ? [.option] : []
                    var ignoring = character == "@" ? "2" : chars
                    // ↑ ↓ ← → como flechas de verdad y ⌫ como la tecla de borrar.
                    let arrows: [Character: (Int, UInt16)] = ["↑": (NSUpArrowFunctionKey, 126), "↓": (NSDownArrowFunctionKey, 125),
                                                              "←": (NSLeftArrowFunctionKey, 123), "→": (NSRightArrowFunctionKey, 124)]
                    if let (key, keyCode) = arrows[character] {
                        chars = String(Character(UnicodeScalar(UInt32(key))!)); ignoring = chars; code = keyCode
                        flags = [.numericPad, .function]
                    } else if character == "⌫" {
                        chars = "\u{7F}"; ignoring = chars; code = 51
                    }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                                        windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                                        characters: chars, charactersIgnoringModifiers: ignoring,
                                                        isARepeat: false, keyCode: code) {
                            NSApp.sendEvent(event)
                        }
                    }
                }
            }
            for round in 1...(ProcessInfo.processInfo.environment["OCIB_FOCUS_CMD"] == nil ? 2 : 1) {
                TerminalWindows.shared.open(command: ProcessInfo.processInfo.environment["OCIB_FOCUS_CMD"] ?? "cat -vt", title: "prueba \(round)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title.contains("prueba") }?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 500_000_000)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let responder = NSApp.keyWindow?.firstResponder
                print("ventana \(round): key=\(NSApp.keyWindow?.title ?? "nil") responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil") activa=\(NSApp.isActive)")
                if ProcessInfo.processInfo.environment["OCIB_FOCUS_RAW"] == "1",
                   let view = NSApp.keyWindow?.contentView as? LocalProcessTerminalView {
                    var tio = termios()
                    let fd = view.process.childfd
                    let got = tcgetattr(fd, &tio)
                    cfmakeraw(&tio)
                    let set = tcsetattr(fd, TCSANOW, &tio)
                    print("  raw desde la app: get=\(got) set=\(set) errno=\(errno)")
                }
                if let width = ProcessInfo.processInfo.environment["OCIB_FOCUS_RESIZE"].flatMap(Double.init),
                   let window = NSApp.windows.first(where: { $0.title.contains("prueba") }) {
                    window.setContentSize(NSSize(width: width, height: 400))
                    print("  tras redimensionar: ventana=\(window.frame.size) vista=\(window.contentView?.frame.size ?? .zero) cols=\((window.contentView as? LocalProcessTerminalView)?.getTerminal().cols ?? 0)")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                for part in (ProcessInfo.processInfo.environment["OCIB_FOCUS_KEYS"] ?? "abc\t\r").split(separator: "¦") {
                    typeText(String(part))
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                print("  key tras teclear: \(NSApp.keyWindow?.title ?? "nil")")
                if let view = NSApp.windows.first(where: { $0.title.contains("prueba") })?.contentView as? LocalProcessTerminalView {
                    let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
                    print("  pantalla: \(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
                }
            }
            exit(0)
        }
    }

    static func runIfRequested() {
        focusTestIfRequested()
        guard ProcessInfo.processInfo.environment["OCIB_SANDBOX_SELFTEST"] == "1" else { return }
        Task {
            func report(_ name: String, _ ok: Bool, _ detail: String = "") { print("\(ok ? "✅" : "❌") \(name) \(detail)") }
            let home = NSHomeDirectory()
            report("contenedor", home.contains("/Library/Containers/"), home)
            report("sin acceso a ~/.oci/config", (try? String(contentsOfFile: "/Users/\(NSUserName())/.oci/config", encoding: .utf8)) == nil)
            let ssh = try? await CommandRunner.run("/usr/bin/ssh", ["-V"])
            report("ejecutar ssh", ssh?.status == 0, ssh?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            do {
                let key = try await SessionKeyStore.generate()
                report("clave temporal con ssh-keygen", FileManager.default.fileExists(atPath: key.privateKeyPath), key.privateKeyPath)
            } catch { report("clave temporal con ssh-keygen", false, error.localizedDescription) }
            if let port = OwnedTunnelRecord.freeLocalPort() {
                let listener = Process()
                listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                listener.arguments = ["-l", "127.0.0.1", String(port)]
                listener.standardError = Pipe()
                try? listener.run()
                var listening = false
                for _ in 0..<20 where !listening {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    listening = OwnedTunnelRecord.isListening(port)
                }
                report("proceso hijo escucha en 127.0.0.1", listening, "puerto \(port)")
                listener.terminate()
            }
            let probe = PTYProbe()
            let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
            view.processDelegate = probe
            let code: Int32? = await withCheckedContinuation { continuation in
                probe.done = { continuation.resume(returning: $0) }
                let launch = TerminalWindows.launch(command: ProcessInfo.processInfo.environment["OCIB_PTY_CMD"] ?? "test -t 0 && /usr/bin/ssh -V")
                view.startProcess(executable: launch.executable, args: launch.args, environment: TerminalWindows.environment())
                if let answer = ProcessInfo.processInfo.environment["OCIB_PTY_ANSWER"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { view.send(txt: answer + "\r") }
                }
            }
            report("terminal integrado (PTY + ssh)", code == 0, "código \(code.map(String.init) ?? "?")")
            let api = try? await URLSession.shared.data(from: URL(string: "https://identity.eu-madrid-1.oci.oraclecloud.com/20160918/regions")!)
            report("red hacia la API de OCI", (api?.1 as? HTTPURLResponse) != nil, "HTTP \((api?.1 as? HTTPURLResponse)?.statusCode ?? 0)")
            exit(0)
        }
    }
}
#endif
