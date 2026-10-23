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
• «Abrir SSH» abre Terminal o iTerm2 ya conectados.
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
• "Open SSH" opens Terminal or iTerm2 already connected.
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

En inglés, que es lo que lee el equipo de revisión:

```
Bastionaut is a client for the Oracle Cloud Infrastructure (OCI) Bastion service. It needs an OCI tenancy with an API key and a Bastion resource, so it cannot be fully exercised without an Oracle Cloud account. All OCI calls go directly to the official OCI REST API with the user's own API key, which is stored in the macOS Keychain. The app collects no data.

Entitlements:
- com.apple.security.network.client: OCI REST API and SSH connections to the Bastion.
- com.apple.security.network.server: the bundled system ssh process listens only on 127.0.0.1 for the user's port forwards (SOCKS5 / local forwarding).
- com.apple.security.files.user-selected.read-write: importing the user's API key (.pem) and SSH keys, and exporting/importing connection settings, always through the open/save panels.
- com.apple.security.temporary-exception.apple-events (com.apple.Terminal, com.googlecode.iterm2): the core feature "Open SSH" opens a new Terminal or iTerm2 window running the ssh command for the selected server. This is done with a single "do script" / "create window" Apple Event when the user clicks the button; the user can also just copy the command instead.
```

**Información de contacto para la revisión**: nombre, teléfono y email de contacto (los pide App Store Connect).
**Cuenta de demostración**: no aplica (requiere una tenancy de OCI propia); explicado en las notas.

---

## Política de privacidad (resumen; la versión completa está en `docs/privacy.html`)

### Español
> **Bastionaut no recopila ningún dato.** La app se comunica únicamente con la API de Oracle Cloud Infrastructure y con el servicio Bastion de tu propia cuenta, usando tu clave de API, que se guarda cifrada en el Llavero de tu Mac. La configuración y las claves SSH se guardan solo en tu Mac, dentro de la carpeta privada de la app. La función opcional «¿Está permitida mi IP?» consulta `checkip.amazonaws.com` únicamente cuando la pulsas. No hay analítica, publicidad ni seguimiento.

### English
> **Bastionaut collects no data.** The app only talks to the Oracle Cloud Infrastructure API and the Bastion service of your own account, using your API key, which is stored encrypted in your Mac's Keychain. Settings and SSH keys are stored only on your Mac, inside the app's private folder. The optional "Is my IP allowed?" check calls `checkip.amazonaws.com` only when you press it. There is no analytics, advertising or tracking.
