# OCI Bastion para macOS

Primera versión de una app SwiftUI para crear y mantener una sesión SOCKS5 de OCI Bastion y abrir conexiones SSH a instancias privadas.

## Requisitos

- macOS 14 o posterior.
- Un perfil en `~/.oci/config` con clave de API (la app habla directamente con la API REST de OCI; **no necesita el OCI CLI**). Admite claves PKCS#1/PKCS#8, `pass_phrase` y `security_token_file`.
- Permisos IAM para leer bastiones y gestionar sesiones (`manage bastion-session`).
- Tu IP pública dentro de la lista de IPs permitidas del Bastion. Si no lo está, la app lo detecta y te ofrece comprobar tu IP.

## Compilar y abrir

```sh
./Scripts/build-app.sh
open "dist/OCI Bastion.app"
```

El icono fuente está en `Assets/AppIcon.png`. Si se modifica, ejecuta `Scripts/build-icon.sh` para regenerar `Assets/AppIcon.icns`.

Por defecto se compila en `release` como binario universal (arm64 + x86_64) con firma ad hoc. Para una compilación de depuración rápida: `CONFIGURATION=debug ./Scripts/build-app.sh`.

## Distribución firmada y notarizada

La app se distribuye fuera del Mac App Store (necesita ejecutar `oci`, `ssh` y controlar Terminal/iTerm2, algo incompatible con App Sandbox). Requisitos, una sola vez:

1. Certificado **Developer ID Application** en el llavero (Xcode › Settings › Accounts › Manage Certificates).
2. Credenciales de notarización guardadas en el llavero:
   ```sh
   xcrun notarytool store-credentials OCIBastion-notary \
     --apple-id TU_APPLE_ID --team-id TU_TEAM_ID --password CONTRASEÑA_DE_APP
   ```

Después:

```sh
BUNDLE_ID=com.tudominio.ocibastion VERSION=0.2.0 ./Scripts/release.sh
```

Genera `dist/OCIBastion-<versión>.dmg` firmado con Hardened Runtime, notarizado y con el ticket grapado, e imprime su SHA-256 (útil para un cask de Homebrew).

## Uso

1. La primera vez se abre un **asistente**: cuenta OCI y región, búsqueda del Bastion en toda la tenancy (OCI Search), tipo de sesión, claves y primer servidor.
2. **Tipos de sesión**:
   - **SOCKS5**: un túnel para todos los servidores. Requiere «FQDN y SOCKS5» activado en el Bastion.
   - **Reenvío de puerto**: una sesión gestionada por servidor; funciona con cualquier Bastion. Cada servidor abre su sesión al pulsar **Abrir SSH**.
3. **Claves temporales** (por defecto): la app crea una clave RSA por sesión en `~/Library/Application Support/OCIBastion/keys` (0600) y la borra al caducar. También puedes usar tus propias claves.
4. La app **reutiliza** sesiones activas con margen suficiente para las que tenga la clave, y **renueva** la sesión antes de que caduque (30 min por defecto, configurable) con un corte mínimo.
5. **Túneles a puertos** llevan un puerto remoto a `127.0.0.1` de tu Mac.
6. Las conexiones guardadas aparecen en la barra lateral; los cambios se guardan solos. **Importar / Exportar** mantiene compatibilidad con los archivos de versiones anteriores.
7. La **bitácora** de cada conexión explica qué está pasando y, si algo falla, la tarjeta principal dice cómo arreglarlo.

El proxy corporativo HTTP CONNECT se detecta automáticamente (`http_proxy`, configuración del sistema o WPAD) y se usa tanto para la API como para el SSH. Al cerrar la app se cierran sus túneles; los `ssh` huérfanos de una ejecución anterior se cierran al arrancar.

## Tests

```sh
./Scripts/test.sh                                  # tests unitarios
OCIB_LIVE=1 ./Scripts/test.sh --filter LiveOCITests  # lecturas reales contra OCI (perfil DEFAULT u OCIB_PROFILE)
```

## Código fuente y datos locales

El repositorio contiene la app Swift en `Sources/OCIBastion`, los recursos en `Assets`, los scripts de compilación en `Scripts` y ejemplos anonimizados en `Tests`.

La carpeta `Tests/LocalFixtures` conserva archivos de prueba personales solo en este equipo y está excluida de Git. También se excluyen `.build`, `dist`, claves, archivos de configuración SSH y datos de ejecución. Cada usuario debe aportar su propio `~/.oci/config` y sus propias claves; la app guarda únicamente sus rutas en `~/Library/Application Support/OCIBastion/settings.json`.

Para publicar el código en GitHub, crea un repositorio vacío en la cuenta `israelgoracle`, añade su URL como remoto `origin` y sube la rama `main`. Los binarios de `dist` se distribuyen aparte del código fuente.
