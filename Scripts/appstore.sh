#!/bin/zsh
# Compila la versión Mac App Store (sandbox), la empaqueta en .pkg firmado, la valida y la sube a App Store Connect.
# Subir NO publica nada: la build aparece en App Store Connect / TestFlight hasta que la envíes a revisión.
#
# Requisitos (una vez):
#   - Certificados «Apple Distribution» y «Mac Installer Distribution» en el llavero (Xcode › Settings › Accounts).
#   - App ID com.javiermugueta.ocibastion y perfil «Mac App Store Connect» descargado.
#   - La app creada en App Store Connect con ese bundle ID.
#   - Clave de API en ~/.private_keys/AuthKey_<KEY_ID>.p8
#
# Variables:
#   PROVISIONING_PROFILE  ruta al .provisionprofile (obligatoria)
#   VERSION               versión visible (por defecto 0.2.0); BUILD_NUMBER debe crecer en cada subida
#   ASC_KEY_ID / ASC_ISSUER_ID  clave de API de App Store Connect (la .p8 en ~/.private_keys/AuthKey_<ID>.p8).
#                         Se pueden dejar en .appstore.env (no se sube a Git):  ASC_KEY_ID=…  ASC_ISSUER_ID=…
#   UPLOAD=0              solo compilar, empaquetar y validar
set -euo pipefail
cd "${0:A:h:h}"

find_identity() { security find-identity -v "$@" | sed -n 's/.*"\(.*\)"/\1/p' }
app_identity="${APP_SIGN_IDENTITY:-$(find_identity -p codesigning | grep -E '^(Apple Distribution|3rd Party Mac Developer Application):' | head -1)}"
installer_identity="${INSTALLER_SIGN_IDENTITY:-$(find_identity | grep -E '^(Mac Installer Distribution|3rd Party Mac Developer Installer):' | head -1)}"
[[ -n "$app_identity" ]] || { echo "Falta el certificado «Apple Distribution» en el llavero." >&2; exit 1; }
[[ -n "$installer_identity" ]] || { echo "Falta el certificado «Mac Installer Distribution» en el llavero." >&2; exit 1; }

[[ -f .appstore.env ]] && source .appstore.env
key_id="${ASC_KEY_ID:?Define ASC_KEY_ID (o créalo en .appstore.env)}"
issuer_id="${ASC_ISSUER_ID:?Define ASC_ISSUER_ID (o créalo en .appstore.env)}"
version="${VERSION:-0.2.0}"

EDITION=appstore CONFIGURATION=release SIGN_IDENTITY="$app_identity" VERSION="$version" ./Scripts/build-app.sh

pkg="dist/Bastionaut-${version}-appstore.pkg"
rm -f "$pkg"
productbuild --component "dist/appstore/Bastionaut.app" /Applications --sign "$installer_identity" "$pkg"

xcrun altool --validate-app -f "$pkg" -t macos --apiKey "$key_id" --apiIssuer "$issuer_id"
if [[ "${UPLOAD:-1}" == 1 ]]; then
  upload_log="$(mktemp)"
  xcrun altool --upload-app -f "$pkg" -t macos --apiKey "$key_id" --apiIssuer "$issuer_id" 2>&1 | tee "$upload_log"
  delivery="$(sed -n 's/.*Delivery UUID: *\([0-9a-f-]*\).*/\1/p' "$upload_log" | head -1)"
  rm -f "$upload_log"
  [[ -n "$delivery" ]] || { echo "No se obtuvo el identificador de la entrega." >&2; exit 1; }
  # La validación previa no detecta todo: esperamos al procesado de Apple y mostramos su resultado.
  echo "Esperando a que Apple procese la build ($delivery)…"
  build_status="$(xcrun altool --build-status --delivery-id "$delivery" --wait --apiKey "$key_id" --apiIssuer "$issuer_id" 2>&1)"
  echo "$build_status" | grep -E "BUILD-STATUS|IMPORT-STATUS|PROCESSING-ERRORS|description" || echo "$build_status"
  if echo "$build_status" | grep -q "BUILD-STATUS: FAILED"; then exit 1; fi
fi
echo "$PWD/$pkg"
