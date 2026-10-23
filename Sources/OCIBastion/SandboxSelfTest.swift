#if DEBUG
import Foundation

/// Autotest para comprobar la versión con sandbox: `OCIB_SANDBOX_SELFTEST=1` al lanzar el ejecutable.
@MainActor
enum SandboxSelfTest {
    static func runIfRequested() {
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
            let api = try? await URLSession.shared.data(from: URL(string: "https://identity.eu-madrid-1.oci.oraclecloud.com/20160918/regions")!)
            report("red hacia la API de OCI", (api?.1 as? HTTPURLResponse) != nil, "HTTP \((api?.1 as? HTTPURLResponse)?.statusCode ?? 0)")
            exit(0)
        }
    }
}
#endif
