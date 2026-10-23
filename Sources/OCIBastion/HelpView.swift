import SwiftUI

/// Bloques de contenido de la ayuda. Los textos admiten Markdown en línea (negrita, `código`, enlaces).
enum HelpBlock {
    case heading(LocalizedStringKey)
    case text(LocalizedStringKey)
    case bullets([LocalizedStringKey])
    case code(String)
    case tip(LocalizedStringKey)
}

enum HelpTopic: String, CaseIterable, Identifiable {
    case start, oci, modes, keys, targets, sessions, troubleshooting, privacy

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .start: return "Primeros pasos"
        case .modes: return "Tipos de sesión"
        case .keys: return "Claves del Bastion"
        case .targets: return "Servidores y túneles"
        case .sessions: return "Sesiones y renovación"
        case .troubleshooting: return "Problemas frecuentes"
        case .oci: return "Requisitos"
        case .privacy: return "Privacidad y datos"
        }
    }

    var symbol: String {
        switch self {
        case .start: return "sparkles"
        case .modes: return "arrow.triangle.branch"
        case .keys: return "key.fill"
        case .targets: return "server.rack"
        case .sessions: return "timer"
        case .troubleshooting: return "stethoscope"
        case .oci: return "checklist"
        case .privacy: return "lock.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .start: return .pink
        case .modes: return .indigo
        case .keys: return .orange
        case .targets: return .blue
        case .sessions: return .teal
        case .troubleshooting: return .red
        case .oci: return .cyan
        case .privacy: return .green
        }
    }

    var blocks: [HelpBlock] {
        switch self {
        case .start:
            return [
                .text("Bastionaut abre túneles hacia tus máquinas privadas de Oracle Cloud a través del servicio **Bastion**, sin que tengas que escribir comandos."),
                .heading("Antes de empezar"),
                .text("Necesitas tu clave de API de OCI, un Bastion que llegue a tus máquinas y tu IP en su lista de permitidas. El detalle está en **Requisitos**."),
                .heading("En tres pasos"),
                .bullets([
                    "**Nueva conexión ✨**: el asistente comprueba tu cuenta, busca tus bastiones en toda la tenancy y te deja añadir el primer servidor.",
                    "**Conectar 🚀**: la app crea (o reutiliza) la sesión del Bastion y abre el túnel.",
                    "**Abrir SSH** en un servidor o **Abrir túnel** en un puerto. ¡Listo!",
                ]),
                .tip("Puedes tener varias conexiones (por ejemplo, una por región o por cliente) y cambiar entre ellas desde la barra lateral o desde el icono de la barra de menús."),
                .tip("¿Quieres verla funcionar antes de configurar nada? Menú **Ayuda › Probar con datos de ejemplo 🎮**."),
            ]
        case .modes:
            return [
                .heading("SOCKS5"),
                .text("Una sola sesión para todo: la app abre un proxy SOCKS5 en tu Mac y todos los servidores pasan por él. Es lo más cómodo, pero el Bastion tiene que tener activado **FQDN y SOCKS5**."),
                .heading("Reenvío de puerto"),
                .text("Una sesión por servidor o túnel, creada al abrirlo. Funciona con **cualquier** Bastion. Cada sesión tarda unos segundos en crearse la primera vez; después se reutiliza mientras dure."),
                .tip("El asistente consulta el Bastion y te propone el modo adecuado. Puedes cambiarlo en **Ajustes ⚙️**."),
            ]
        case .keys:
            return [
                .text("El Bastion pide una clave SSH para cada sesión. Tienes dos opciones:"),
                .bullets([
                    "**Temporales (recomendado)**: la app crea una clave RSA por sesión, la guarda solo para ti (permisos 0600) y la borra cuando la sesión caduca. No tienes que hacer nada.",
                    "**Tus propias claves**: eliges un par de claves que ya tengas y la app guarda una copia privada. Deben ser claves sin contraseña; si la tuya la tiene, usa las temporales.",
                ]),
                .text("Las claves de tus **servidores** son otra cosa: las eliges en cada servidor o túnel, y pueden ser distintas en cada uno. Al elegirlas, la app guarda una copia privada dentro de ella (macOS no le deja volver a leer el archivo original)."),
            ]
        case .targets:
            return [
                .heading("Servidores 🖥️"),
                .text("Un servidor es una máquina a la que entras por SSH. **Abrir SSH** abre una ventana de Terminal o iTerm2 ya conectada. **Copiar** te deja el comando en el portapapeles por si quieres usarlo en otro sitio."),
                .heading("Túneles a puertos 🚇"),
                .text("Un túnel lleva un puerto remoto (una base de datos, una consola web…) a un puerto de tu Mac. Después conectas tu herramienta a `localhost` y ese puerto."),
                .bullets([
                    "**Directo por el Bastion**: deja vacío «Pasar por un servidor SSH». El Bastion lleva el puerto directamente. Necesita el modo reenvío de puerto.",
                    "**A través de un servidor SSH**: entra por SSH en un servidor y desde ahí llega al puerto. Úsalo cuando el servicio solo escucha dentro del servidor (por ejemplo en `127.0.0.1`).",
                ]),
                .tip("En modo reenvío de puerto, el icono de cada servidor o túnel se pone verde cuando su sesión está activa, y el botón ■ la cierra."),
            ]
        case .sessions:
            return [
                .text("Las sesiones del Bastion caducan (como mucho a las 3 horas). La cuenta atrás de la tarjeta principal te dice cuánto queda."),
                .bullets([
                    "**Reutilización**: antes de crear una sesión, la app busca una activa para el mismo destino y con tu clave. Así ahorras la espera.",
                    "**Renovación**: unos minutos antes de que caduque (30 por defecto), la app pide una sesión nueva mientras la actual sigue funcionando y cambia de una a otra con un corte mínimo.",
                    "**Reconexión**: si el túnel se cae por la red, la app reintenta sola, cada vez esperando un poco más.",
                ]),
                .tip("La duración y el margen de renovación se cambian en **Ajustes ⚙️**. Al cerrar la app se cierran los túneles; las sesiones de OCI siguen vivas hasta que caducan y se pueden reutilizar."),
            ]
        case .troubleshooting:
            return [
                .heading("«No consigo conectar con el Bastion por SSH»"),
                .text("Casi siempre es la **lista de IPs permitidas** del Bastion. Pulsa **¿Está permitida mi IP? 🌐** para comprobarlo y, si no lo está, añádela en la consola de OCI › Bastion › **Editar**. Si sales por un proxy o una VPN, cuenta la IP de salida."),
                .heading("«OCI respondió 404 NotAuthorizedOrNotFound»"),
                .text("Falta algún permiso IAM o el recurso no está en la región elegida. Mira **Requisitos**."),
                .heading("«OCI respondió 401»"),
                .text("La clave de API no está registrada en tu usuario de OCI (o es de otro usuario), o la hora del Mac está desajustada."),
                .heading("«El Bastion no tiene activado SOCKS5»"),
                .text("Cambia a **Reenvío de puerto** en Ajustes, o activa **FQDN y SOCKS5** en el Bastion."),
                .heading("«SSH rechazó la clave» en el servidor"),
                .text("La clave que elegiste para ese servidor no está autorizada en él, o el usuario no es el correcto (en Oracle Linux suele ser `opc`; en Ubuntu, `ubuntu`)."),
                .heading("«El puerto local está ocupado»"),
                .text("Otro programa usa ese puerto en tu Mac. Elige otro o cierra el programa."),
                .tip("La **Bitácora 📜** de cada conexión cuenta paso a paso lo que ha pasado. Es lo primero que hay que mirar."),
            ]
        case .oci:
            return [
                .text("Esto es todo lo que necesitas. El asistente comprueba la mayoría de estos puntos por ti."),
                .heading("En tu Mac 💻"),
                .bullets([
                    "**macOS 14 Sonoma** o posterior.",
                    "**No hace falta el OCI CLI** ni Python: la app habla directamente con la API de OCI.",
                    "Terminal (incluido en macOS) o **iTerm2** para las sesiones SSH. La primera vez, macOS te pedirá permiso para que Bastionaut controle la terminal: acéptalo (o actívalo en Ajustes del Sistema › Privacidad y seguridad › **Automatización**).",
                    "Si estás detrás de un **proxy corporativo**, la app lo detecta sola; también puedes indicarlo a mano en Ajustes.",
                ]),
                .heading("Tu cuenta de OCI ☁️"),
                .bullets([
                    "Una **clave de API** (RSA) registrada en tu usuario de OCI. Si no la tienes: consola de OCI › tu perfil › **Claves de API** › Añadir clave de API › Generar par de claves, y descarga la clave privada.",
                    "El asistente te pide la tenancy, el usuario, la región y la clave privada. Lo más rápido: pega el **fragmento de configuración** que te enseña la consola al crear la clave y se rellena solo.",
                    "La clave privada se guarda en el **Llavero** de macOS. Si estaba protegida con contraseña, la app te la pide una vez al importarla.",
                ]),
                .heading("El Bastion 🏰"),
                .bullets([
                    "Un **Bastion** activo en la misma región, cuya subred de destino llegue a tus servidores.",
                    "Las **listas de seguridad** o grupos de seguridad de red de tus servidores deben permitir el tráfico desde el Bastion (por ejemplo, el puerto 22 para SSH o el puerto de tu base de datos).",
                    "Tu **IP pública** (o la de salida de tu proxy o VPN) en la **lista de IPs permitidas** del Bastion. Si no está, la app te avisa y te deja comprobarlo.",
                    "Para el modo SOCKS5, **FQDN y SOCKS5** activado en el Bastion. El modo reenvío de puerto no lo necesita.",
                ]),
                .heading("Permisos IAM 🔐"),
                .text("Tu usuario necesita permisos para ver el Bastion y crear sesiones. Un ejemplo de política (ajusta el grupo y el compartimento):"),
                .code("""
                Allow group BastionUsers to use bastion in compartment MiCompartimento
                Allow group BastionUsers to manage bastion-session in compartment MiCompartimento
                Allow group BastionUsers to read virtual-network-family in compartment MiCompartimento
                Allow group BastionUsers to read instance-family in compartment MiCompartimento
                """),
                .bullets([
                    "La búsqueda de bastiones solo muestra los que tu usuario puede ver. Si no aparece, búscalo en un compartimento o pega su OCID.",
                    "Para listar compartimentos en el asistente, tu usuario debe poder verlos (`inspect compartments`). Si no, pega el OCID del Bastion.",
                ]),
                .heading("Tus servidores 🖥️"),
                .bullets([
                    "El **usuario** con el que entras (en Oracle Linux suele ser `opc`; en Ubuntu, `ubuntu`).",
                    "Una **clave SSH privada** autorizada en ese servidor (en su `~/.ssh/authorized_keys`). Es independiente de las claves del Bastion.",
                ]),
                .tip("Consulta la documentación de OCI Bastion para las políticas exactas de tu organización."),
            ]
        case .privacy:
            return [
                .bullets([
                    "La app habla **solo** con la API de OCI de tu región y con el Bastion. No hay telemetría.",
                    "La comprobación **¿Está permitida mi IP?** consulta `checkip.amazonaws.com`, y solo cuando la pulsas.",
                    "La app funciona dentro del **sandbox** de macOS: solo ve los archivos que tú le das.",
                    "La **clave de API** de OCI se guarda cifrada en el **Llavero** de macOS. Puedes borrarla desde Acceso a Llaveros buscando «Bastionaut».",
                    "La configuración, las claves temporales (que se borran al caducar) y las copias de las claves de tus servidores viven en la carpeta privada de la app, con permisos 0600.",
                    "Los archivos exportados incluyen rutas y OCID, pero nunca claves.",
                ]),
            ]
        }
    }
}

/// Tema de ayuda que se muestra al abrir la ventana (lo cambian los enlaces de ayuda en contexto).
@Observable
@MainActor
final class HelpRouter {
    static let shared = HelpRouter()
    var topic: HelpTopic = .start
}

struct HelpView: View {
    @Bindable private var router = HelpRouter.shared

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: Binding(get: { router.topic }, set: { if let value = $0 { router.topic = value } })) { topic in
                Label { Text(topic.title) } icon: { IconTile(symbol: topic.symbol, color: topic.color, size: 24) }
                    .padding(.vertical, 2)
                    .tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        IconTile(symbol: router.topic.symbol, color: router.topic.color, size: 44)
                        Text(router.topic.title).font(.system(size: 28, weight: .heavy, design: .rounded))
                    }
                    .padding(.bottom, 4)
                    ForEach(Array(router.topic.blocks.enumerated()), id: \.offset) { _, block in
                        HelpBlockView(block: block)
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .id(router.topic)
        }
        .fontDesign(.rounded)
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(.title3.weight(.bold)).padding(.top, 6)
        case .text(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        case .tip(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("💡")
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Abre la ventana de ayuda en un tema concreto.
struct HelpButton: View {
    var topic: HelpTopic = .start
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            HelpRouter.shared.topic = topic
            openWindow(id: "help")
        } label: { Image(systemName: "questionmark") }
        .buttonStyle(CircleIconButtonStyle(tint: .accentColor))
        .help("Ayuda")
    }
}

struct HelpCommands: Commands {
    let manager: TunnelManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Acerca de Bastionaut") { AppCredits.showAboutPanel() }
        }
        CommandGroup(replacing: .help) {
            Button("Ayuda de Bastionaut") {
                HelpRouter.shared.topic = .start
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
            Button("Problemas frecuentes") {
                HelpRouter.shared.topic = .troubleshooting
                openWindow(id: "help")
            }
            Divider()
            if manager.isDemo {
                Button("Salir de la demo") { manager.exitDemo() }
            } else {
                Button("Probar con datos de ejemplo 🎮") {
                    manager.enterDemo()
                    openWindow(id: "main")
                }
                .disabled(manager.isRunning)
            }
        }
    }
}

/// Enlace de texto a un tema de ayuda, para mostrar junto a un error.
struct HelpLink: View {
    let topic: HelpTopic
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            HelpRouter.shared.topic = topic
            openWindow(id: "help")
        } label: {
            Label("¿Qué pasa? 📖", systemImage: "questionmark.circle.fill")
        }
        .buttonStyle(FunButtonStyle(tint: .black.opacity(0.45)))
    }
}
