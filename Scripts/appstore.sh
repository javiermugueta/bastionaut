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
#   ASC_KEY_ID / ASC_ISSUER_ID  clave de API (por defecto U2LFZZ42BX y el issuer del equipo)
#   UPLOAD=0              solo compilar, empaquetar y validar
set -euo pipefail
cd "${0:A:h:h}"

find_identity() { security find-identity -v "$@" | sed -n 's/.*"\(.*\)"/\1/p' }
app_identity="${APP_SIGN_IDENTITY:-$(find_identity -p codesigning | grep -E '^(Apple Distribution|3rd Party Mac Developer Application):' | head -1)}"
installer_identity="${INSTALLER_SIGN_IDENTITY:-$(find_identity | grep -E '^(Mac Installer Distribution|3rd Party Mac Developer Installer):' | head -1)}"
[[ -n "$app_identity" ]] || { echo "Falta el certificado «Apple Distribution» en el llavero." >&2; exit 1; }
[[ -n "$installer_identity" ]] || { echo "Falta el certificado «Mac Installer Distribution» en el llavero." >&2; exit 1; }

key_id="${ASC_KEY_ID:-U2LFZZ42BX}"
issuer_id="${ASC_ISSUER_ID:-69a6de91-5590-47e3-e053-5b8c7c11a4d1}"
version="${VERSION:-0.2.0}"

EDITION=appstore CONFIGURATION=release SIGN_IDENTITY="$app_identity" VERSION="$version" ./Scripts/build-app.sh

pkg="dist/OCIBastion-${version}-appstore.pkg"
rm -f "$pkg"
productbuild --component "dist/OCI Bastion.app" /Applications --sign "$installer_identity" "$pkg"

xcrun altool --validate-app -f "$pkg" -t macos --apiKey "$key_id" --apiIssuer "$issuer_id"
if [[ "${UPLOAD:-1}" == 1 ]]; then
  xcrun altool --upload-app -f "$pkg" -t macos --apiKey "$key_id" --apiIssuer "$issuer_id"
fi
echo "$PWD/$pkg"
