#!/bin/zsh
# Genera un DMG firmado con Developer ID, lo notariza y grapa el ticket.
#
# Requisitos previos (una sola vez):
#   1. Certificado "Developer ID Application" instalado en el llavero.
#   2. Perfil de notarytool guardado en el llavero:
#        xcrun notarytool store-credentials OCIBastion-notary \
#          --apple-id TU_APPLE_ID --team-id TU_TEAM_ID --password CONTRASEÑA_DE_APP
#
# Variables:
#   SIGN_IDENTITY   (opcional) por defecto la primera "Developer ID Application" del llavero
#   NOTARY_PROFILE  (opcional) por defecto OCIBastion-notary
#   BUNDLE_ID, VERSION, BUILD_NUMBER  se pasan a build-app.sh
set -euo pipefail
cd "${0:A:h:h}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No se encontró ningún certificado \"Developer ID Application\" en el llavero." >&2
  echo "Créalo en https://developer.apple.com/account/resources/certificates o desde Xcode > Settings > Accounts." >&2
  exit 1
fi
export SIGN_IDENTITY
notary_profile="${NOTARY_PROFILE:-OCIBastion-notary}"
version="${VERSION:-0.1.0}"
export VERSION="$version"

CONFIGURATION=release ./Scripts/build-app.sh

app="dist/Bastionaut.app"
dmg="dist/Bastionaut-${version}.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Bastionaut" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"

xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

shasum -a 256 "$dmg"
echo "$PWD/$dmg"
