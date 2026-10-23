# Bastionaut

Bastionaut es una app de macOS para abrir túneles SSH a instancias privadas de Oracle Cloud a través del servicio OCI Bastion. Autor original: Israel Gutiérrez · Mejoras: Javier Mugueta.

🌐 Web: https://javiermugueta.github.io/bastionaut/ · [Soporte](https://javiermugueta.github.io/bastionaut/support.html) · [Privacidad](https://javiermugueta.github.io/bastionaut/privacy.html)

## Requisitos

La ayuda de la app (menú **Ayuda › Ayuda de Bastionaut**, ⌘?) los explica con detalle en el tema **Requisitos**.

**En tu Mac**
- macOS 14 Sonoma o posterior.
- No hace falta el OCI CLI ni Python: la app usa directamente la API REST de OCI. Funciona dentro del sandbox de macOS.
- Terminal o iTerm2. La primera vez, acepta el permiso de **Automatización** para que la app abra las sesiones SSH.
- Proxy corporativo HTTP CONNECT opcional (se detecta solo o se indica a mano).

**Cuenta de OCI**
- Una clave de API RSA registrada en tu usuario (consola de OCI › tu perfil › Claves de API). En el asistente se introducen tenancy, usuario, región y la clave privada (archivo `.pem` o pegada; se puede pegar el fragmento de configuración de la consola). La huella se calcula sola y la clave se guarda en el Llavero de macOS.

**Bastion**
- Un Bastion activo en la región, con subred de destino que llegue a tus servidores, y listas de seguridad que permitan el tráfico desde el Bastion.
- Tu IP pública (o la de salida de tu proxy o VPN) en la lista de IPs permitidas del Bastion. Si no lo está, la app lo detecta y te ofrece comprobarla.
- Para el modo SOCKS5, «FQDN y SOCKS5» activado. El modo reenvío de puerto funciona con cualquier Bastion.

**Permisos IAM** (ejemplo, ajusta grupo y compartimento):

```
Allow group BastionUsers to use bastion in compartment MiCompartimento
Allow group BastionUsers to manage bastion-session in compartment MiCompartimento
Allow group BastionUsers to read virtual-network-family in compartment MiCompartimento
Allow group BastionUsers to read instance-family in compartment MiCompartimento
```

**Servidores**
- Usuario (`opc` en Oracle Linux, `ubuntu` en Ubuntu…) y una clave SSH privada autorizada en el servidor.

## Compilar y abrir

```sh
./Scripts/build-app.sh
open "dist/Bastionaut.app"
```

El icono fuente está en `Assets/AppIcon.png`. Si se modifica, ejecuta `Scripts/build-icon.sh` para regenerar `Assets/AppIcon.icns`.

Por defecto se compila en `release` como binario universal (arm64 + x86_64) con firma ad hoc. Para una compilación de depuración rápida: `CONFIGURATION=debug ./Scripts/build-app.sh`.

## Distribución

Hay **una sola versión** de la app, siempre en sandbox. Solo cambia la firma según el canal:

- **Mac App Store**: `PROVISIONING_PROFILE=~/Downloads/xxx.provisionprofile ./Scripts/appstore.sh` compila, firma con Apple Distribution, crea el `.pkg`, lo valida y lo sube a App Store Connect con la clave de API de `~/.private_keys`. Subir no publica nada.
- **Fuera de la tienda** (`.dmg` notarizado con Developer ID), con `./Scripts/release.sh`.

Al pasar a sandbox, `Assets/container-migration.plist` hace que macOS mueva los datos de versiones anteriores (`~/Library/Application Support/OCIBastion`) al contenedor de la app.

### Developer ID y notarización

Requisitos, una sola vez:

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

1. La primera vez se abre un **asistente**: cuenta OCI (clave de API) y región, búsqueda del Bastion en toda la tenancy (OCI Search), tipo de sesión, claves y primer servidor.
2. **Tipos de sesión**:
   - **SOCKS5**: un túnel para todos los servidores. Requiere «FQDN y SOCKS5» activado en el Bastion.
   - **Reenvío de puerto**: una sesión gestionada por servidor; funciona con cualquier Bastion. Cada servidor abre su sesión al pulsar **Abrir SSH**.
3. **Claves temporales** (por defecto): la app crea una clave RSA por sesión en `~/Library/Application Support/OCIBastion/keys` (0600) y la borra al caducar. También puedes usar tus propias claves.
4. La app **reutiliza** sesiones activas con margen suficiente para las que tenga la clave, y **renueva** la sesión antes de que caduque (30 min por defecto, configurable) con un corte mínimo.
5. **Túneles a puertos** llevan un puerto remoto a `127.0.0.1` de tu Mac.
6. Las conexiones guardadas aparecen en la barra lateral; los cambios se guardan solos. **Importar / Exportar** mantiene compatibilidad con los archivos de versiones anteriores.
7. La **bitácora** de cada conexión explica qué está pasando y, si algo falla, la tarjeta principal dice cómo arreglarlo.

El proxy corporativo HTTP CONNECT se detecta automáticamente (`http_proxy`, configuración del sistema o WPAD) y se usa tanto para la API como para el SSH. Al cerrar la app se cierran sus túneles; los `ssh` huérfanos de una ejecución anterior se cierran al arrancar.

## Idiomas

La app está en **español e inglés** y sigue el idioma del sistema (inglés para cualquier otro idioma). Los textos viven en `Assets/Localizable.xcstrings`, que se puede editar en Xcode. Si añades o cambias textos en el código:

```sh
./Scripts/update-strings.sh   # extrae los textos con el compilador y sincroniza el catálogo
```

Después traduce las entradas nuevas en el catálogo; `build-app.sh` lo compila en `es.lproj` y `en.lproj`. Para probar otro idioma sin cambiar el del sistema: `open "dist/Bastionaut.app" --args -AppleLanguages '(en)'`.

## Tests

```sh
./Scripts/test.sh                                  # tests unitarios
OCIB_LIVE=1 ./Scripts/test.sh --filter LiveOCITests  # lecturas reales contra OCI (perfil DEFAULT u OCIB_PROFILE)
```

## Código fuente y datos locales

El repositorio contiene la app Swift en `Sources/OCIBastion`, los recursos en `Assets`, los scripts de compilación en `Scripts` y ejemplos anonimizados en `Tests`.

La carpeta `Tests/LocalFixtures` conserva archivos de prueba personales solo en este equipo y está excluida de Git. También se excluyen `.build`, `dist`, claves, archivos de configuración SSH y datos de ejecución. Cada usuario aporta su propia clave de API (que la app guarda en el Llavero) y sus claves SSH (de las que guarda una copia privada en su contenedor, `~/Library/Containers/com.javiermugueta.ocibastion`).

Para publicar el código en GitHub, crea un repositorio vacío en la cuenta `israelgoracle`, añade su URL como remoto `origin` y sube la rama `main`. Los binarios de `dist` se distribuyen aparte del código fuente.
