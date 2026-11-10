# Bastionaut — ficha de la Mac App Store

Textos listos para copiar en App Store Connect (app id 6826269991, bundle `com.javiermugueta.ocibastion`).
Idioma principal de la ficha: **Inglés (EE. UU.)**; añadir **Español (España)** como segunda localización.

Límites de Apple: nombre y subtítulo 30 caracteres, texto promocional 170, descripción 4000,
palabras clave 100 (separadas por comas, sin espacios). `Scripts/check-metadata.py` lo comprueba.

---

## Datos comunes (no dependen del idioma)

| Campo | Valor |
|---|---|
| Categoría principal | Herramientas para desarrolladores (Developer Tools) |
| Categoría secundaria | Utilidades (Utilities) |
| Copyright | © 2026 Javier Mugueta |
| Clasificación por edades | 4+ (responder «No» a todo el cuestionario) |
| Precio | Gratis (o el que decidas) |
| Privacidad de la app | **Datos no recopilados** |
| Cifrado (exportación) | Solo cifrado estándar del sistema (HTTPS/SSH): exento. `ITSAppUsesNonExemptEncryption = NO` ya está en el Info.plist |
| URL de soporte | https://javiermugueta.github.io/bastionaut/support.html |
| URL de la política de privacidad | https://javiermugueta.github.io/bastionaut/privacy.html |
| URL de marketing (opcional) | https://javiermugueta.github.io/bastionaut/ |

## Capturas

Tamaño 2560 × 1600 (16:10), en `Store/screenshots/es` y `Store/screenshots/en`. Se regeneran con `./Scripts/screenshots.sh`
(usa un modo de demostración con datos inventados).

| Archivo | ES — pie sugerido | EN — suggested caption |
|---|---|---|
| `01-conectado.png` | Tus servidores privados de Oracle Cloud, a un clic | Your private Oracle Cloud servers, one click away |
| `02-modo-oscuro.png` | Precioso también en modo oscuro | Just as lovely in Dark Mode |
| `03-ayuda-ip.png` | Si algo falla, te dice por qué y cómo arreglarlo | When something breaks, it tells you why and how to fix it |
| `04-ayuda.png` | Ayuda integrada en español e inglés | Built-in help in English and Spanish |

---

## 🇪🇸 Español (España)

**Nombre**
```
Bastionaut
```

**Subtítulo**
```
Túneles SSH a Oracle Cloud
```

**Texto promocional**
```
Entra en tus máquinas privadas de Oracle Cloud sin pelearte con comandos: busca tu Bastion, crea la sesión, abre el túnel y renuévalo antes de que caduque. 🚀
```

**Descripción**
```
Bastionaut abre túneles SSH hacia tus máquinas privadas de Oracle Cloud Infrastructure (OCI) a través del servicio Bastion, sin que tengas que escribir ni un comando.

UN ASISTENTE QUE TE LLEVA DE LA MANO
• Pega el fragmento de configuración que te da la consola de OCI y la cuenta queda lista.
• Busca tus bastiones en toda la tenancy, sin saber en qué compartimento están.
• Te propone el tipo de sesión adecuado para tu Bastion.

TÚNELES QUE SE CUIDAN SOLOS
• Modo SOCKS5: un solo túnel para todos tus servidores.
• Modo reenvío de puerto: una sesión por servidor; funciona con cualquier Bastion.
• Reutiliza sesiones activas para que no esperes.
• Renueva la sesión antes de que caduque, con una cuenta atrás siempre a la vista.
• Si la red se cae, reconecta sola.

UN CLIC PARA ENTRAR
• «Abrir SSH» abre un terminal integrado ya conectado.
• Túneles a puertos: lleva una base de datos, una consola web o lo que necesites a un puerto de tu Mac.
• Copia cualquier comando para usarlo donde quieras.

CUANDO ALGO FALLA, TE LO EXPLICA
• Detecta si tu IP no está en la lista de permitidas del Bastion y te deja comprobarla.
• Mensajes claros con consejos para arreglar cada problema y una bitácora con todo lo que pasa.
• Ayuda integrada con requisitos, permisos IAM y problemas frecuentes.

SEGURO Y PRIVADO
• Habla directamente con la API de OCI: no necesitas el OCI CLI ni Python.
• Tu clave de API se guarda cifrada en el Llavero de macOS.
• Claves temporales para el Bastion: una por sesión, que se borran al caducar.
• Funciona dentro del sandbox de macOS y no recopila ningún dato.

Varias conexiones (por región, por cliente…) con su propio emoji, icono en la barra de menús, modo oscuro y la app completa en español e inglés.

Requisitos: una cuenta de Oracle Cloud con una clave de API, un Bastion de OCI que llegue a tus servidores y tu IP en su lista de permitidas.

Basada en el proyecto original de Israel Gutiérrez, con mejoras de Javier Mugueta.
Oracle y OCI son marcas registradas de Oracle Corporation. Bastionaut es una app independiente, no afiliada a Oracle.
```

**Palabras clave**
```
ssh,túnel,bastion,cloud,socks5,reenvío,puerto,devops,sysadmin,servidor,terminal,sesión,proxy
```

**Novedades de esta versión** (no se pide en la primera versión; para la siguiente)
```
Primera versión de Bastionaut. 🚀
```

---

## 🇺🇸 English (U.S.)

**Name**
```
Bastionaut
```

**Subtitle**
```
SSH tunnels to Oracle Cloud
```

**Promotional text**
```
Get into your private Oracle Cloud machines without wrestling with commands: find your bastion, create the session, open the tunnel and renew it before it expires. 🚀
```

**Description**
```
Bastionaut opens SSH tunnels to your private Oracle Cloud Infrastructure (OCI) machines through the Bastion service, without you typing a single command.

AN ASSISTANT THAT WALKS YOU THROUGH IT
• Paste the configuration snippet the OCI console gives you and your account is ready.
• Finds your bastions across the whole tenancy, no need to know which compartment they live in.
• Suggests the right session type for your bastion.

TUNNELS THAT LOOK AFTER THEMSELVES
• SOCKS5 mode: a single tunnel for all your servers.
• Port forwarding mode: one session per server; works with any bastion.
• Reuses active sessions so you don't have to wait.
• Renews the session before it expires, with a countdown always in sight.
• Reconnects on its own if the network drops.

ONE CLICK TO GET IN
• "Open SSH" opens a built-in terminal already connected.
• Port tunnels: bring a database, a web console or whatever you need to a port on your Mac.
• Copy any command to use it wherever you like.

WHEN SOMETHING BREAKS, IT EXPLAINS WHY
• Detects when your IP isn't on the bastion's allowed list and lets you check it.
• Clear messages with tips to fix each problem, plus an activity log of everything that happens.
• Built-in help covering requirements, IAM permissions and troubleshooting.

SECURE AND PRIVATE
• Talks straight to the OCI API: no OCI CLI or Python needed.
• Your API key is stored encrypted in the macOS Keychain.
• Temporary bastion keys: one per session, deleted when it expires.
• Runs inside the macOS sandbox and collects no data at all.

Multiple connections (per region, per customer…) each with its own emoji, a menu bar icon, Dark Mode, and the whole app in English and Spanish.

Requirements: an Oracle Cloud account with an API key, an OCI bastion that can reach your servers, and your IP on its allowed list.

Based on the original project by Israel Gutiérrez, with improvements by Javier Mugueta.
Oracle and OCI are registered trademarks of Oracle Corporation. Bastionaut is an independent app, not affiliated with Oracle.
```

**Keywords**
```
ssh,tunnel,bastion,cloud,socks5,port forwarding,devops,sysadmin,server,terminal,session,proxy
```

**What's New** (not required for the first version)
```
First release of Bastionaut. 🚀
```

---

## Notas para la revisión de Apple (App Review Information › Notes)

En inglés, que es lo que lee el equipo de revisión. Responde a los 6 puntos que pidió Apple (Guideline 2.1, nov. 2026); máximo 4000 caracteres. Sustituir `<VIDEO_URL>` por el enlace al vídeo:

```
1. SCREEN RECORDING
Recorded on a Mac (Apple silicon) running the latest macOS, starting from launching the app: <VIDEO_URL>
It shows the typical flow with a real OCI account: launch, Connect 🚀 (bastion session created, SOCKS5 tunnel ready with countdown), Open SSH (built-in terminal connected to a private server), Open tunnel (localhost port forwarded to a private server), then the sample-data demo mode. The app has no account registration, no user-generated content and no paid content.

2. PURPOSE AND AUDIENCE
Bastionaut is for developers, DevOps engineers and system administrators who use Oracle Cloud Infrastructure (OCI). Their servers live in private networks with no public IP; the official way in is the OCI Bastion service, which requires creating a session, uploading a temporary SSH key, waiting for it, building a long ssh command and renewing the session before it expires (max 3 h). Bastionaut does all of that with one click, renews and reconnects automatically, and explains errors (e.g. the user's IP not allowed by the bastion). It is a general-purpose tool for any OCI customer, not for a specific company.

3. SETUP AND ACCESS
No login to our own service exists. Real use needs the user's own OCI tenancy: in the OCI console the user creates an API key, pastes the configuration snippet into the welcome assistant and picks the .pem key; the app then lists the bastions and the user adds servers (private IP, user, SSH key).
To review without an OCI account, use the built-in demo mode: on first launch choose "Try with sample data" (also on the empty screen and in Help). It loads sample connections, servers and tunnels in memory with a purple "Demo mode" banner; Connect 🚀 simulates the real steps; "Exit demo" restores the real configuration. Nothing is saved and no network connection is made in demo mode.

4. EXTERNAL SERVICES
- Oracle Cloud Infrastructure REST APIs of the user's own tenancy (Identity: regions, tenancies, compartments; Resource Search; Bastion: bastions and sessions), signed with the user's API key stored in the macOS Keychain.
- OCI Bastion SSH endpoint (host.bastion.<region>.oci.oraclecloud.com), through macOS's built-in /usr/bin/ssh.
- checkip.amazonaws.com, only when the user presses "Is my IP allowed?".
- SwiftTerm (open-source MIT library, bundled) for the built-in terminal.
No authentication provider, payments, analytics, advertising or AI services. The app collects no data.

5. REGIONS
The app works the same in all regions and countries. It supports every OCI region; the UI is in English and Spanish.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. Bastionaut is an independent app that uses Oracle's public, documented APIs with the user's own credentials; it is not affiliated with Oracle and contains no protected third-party content. It is based on the open-source project by Israel Gutiérrez (github.com/israelgoracle/OCIBastion_MacOs), improved by Javier Mugueta.

ENTITLEMENTS
- network.client: OCI REST API and SSH to the bastion.
- network.server: core feature. The app runs /usr/bin/ssh (child process, inherits the sandbox) with -D (SOCKS5) or -L; that ssh listens on 127.0.0.1:<port> so the user's tools (database client, browser, ssh) connect to localhost and reach a private cloud server. Loopback only. Without it tunnels fail with "bind: Operation not permitted". Seen in the video: Connect 🚀 (localhost:1080) and Open tunnel.
- files.user-selected.read-write: importing the API key and SSH keys, exporting/importing settings, via open/save panels.
No Apple Events: "Open SSH" opens a terminal window inside the app.
```

**Información de contacto para la revisión**: nombre, teléfono y email de contacto (los pide App Store Connect).
**Cuenta de demostración**: no hace falta; la app trae un **modo demostración** («Probar con datos de ejemplo») explicado en las notas.

---

## Política de privacidad (resumen; la versión completa está en `docs/privacy.html`)

### Español
> **Bastionaut no recopila ningún dato.** La app se comunica únicamente con la API de Oracle Cloud Infrastructure y con el servicio Bastion de tu propia cuenta, usando tu clave de API, que se guarda cifrada en el Llavero de tu Mac. La configuración y las claves SSH se guardan solo en tu Mac, dentro de la carpeta privada de la app. La función opcional «¿Está permitida mi IP?» consulta `checkip.amazonaws.com` únicamente cuando la pulsas. No hay analítica, publicidad ni seguimiento.

### English
> **Bastionaut collects no data.** The app only talks to the Oracle Cloud Infrastructure API and the Bastion service of your own account, using your API key, which is stored encrypted in your Mac's Keychain. Settings and SSH keys are stored only on your Mac, inside the app's private folder. The optional "Is my IP allowed?" check calls `checkip.amazonaws.com` only when you press it. There is no analytics, advertising or tracking.
