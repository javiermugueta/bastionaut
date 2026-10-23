#!/bin/zsh
# Compila y empaqueta "OCI Bastion.app".
#
# Variables opcionales:
#   CONFIGURATION  debug | release (por defecto: release)
#   UNIVERSAL      1 para generar binario arm64 + x86_64 (por defecto: 1 en release)
#   SIGN_IDENTITY  identidad de firma (por defecto: "-" firma ad hoc)
#                  p. ej. "Developer ID Application: Nombre (TEAMID)"
#   BUNDLE_ID      identificador del bundle (por defecto: com.javiermugueta.ocibastion)
#   VERSION        CFBundleShortVersionString (por defecto: 0.1.0)
#   BUILD_NUMBER   CFBundleVersion (por defecto: número de commits de git)
#   EDITION        developer-id (por defecto) | appstore. La app es la misma y siempre va en sandbox;
#                  solo cambian la firma y, en la App Store, el perfil de aprovisionamiento.
#   PROVISIONING_PROFILE  perfil «Mac App Store Connect» (.provisionprofile), obligatorio con EDITION=appstore
set -euo pipefail
cd "${0:A:h:h}"

configuration="${CONFIGURATION:-release}"
universal="${UNIVERSAL:-$([[ $configuration == release ]] && echo 1 || echo 0)}"
sign_identity="${SIGN_IDENTITY:--}"
bundle_id="${BUNDLE_ID:-com.javiermugueta.ocibastion}"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
edition="${EDITION:-developer-id}"

mkdir -p .build/clang-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

build_args=(--disable-sandbox --scratch-path .build --cache-path .build/cache -c "$configuration")
if [[ $universal == 1 ]]; then
  build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary="$(swift build "${build_args[@]}" --show-bin-path)/OCIBastion"

app="dist/OCI Bastion.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/OCIBastion"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Español e inglés desde el catálogo de textos (editable en Xcode).
xcrun xcstringstool compile Assets/Localizable.xcstrings --output-directory "$app/Contents/Resources" --language es --language en
# Al pasar a sandbox, macOS mueve los datos de versiones anteriores al contenedor de la app.
cp Assets/container-migration.plist "$app/Contents/Resources/container-migration.plist"
for lang in es en; do mkdir -p "$app/Contents/Resources/$lang.lproj"; cp "Assets/$lang.lproj/InfoPlist.strings" "$app/Contents/Resources/$lang.lproj/"; done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundle_id}</string>
<key>CFBundleName</key><string>OCI Bastion</string>
<key>CFBundleDisplayName</key><string>OCI Bastion</string>
<key>CFBundleExecutable</key><string>OCIBastion</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build_number}</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Original: Israel (israelgoracle) · Improvements: Javier Mugueta · © $(date +%Y)</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>NSAppleEventsUsageDescription</key><string>OCI Bastion opens SSH connections in the terminal app you choose.</string>
</dict></plist>
PLIST

if [[ $edition == appstore ]]; then
  [[ -f "${PROVISIONING_PROFILE:-}" ]] || { echo "Falta PROVISIONING_PROFILE (perfil Mac App Store Connect)." >&2; exit 1; }
  cp "$PROVISIONING_PROFILE" "$app/Contents/embedded.provisionprofile"
  codesign --force --options runtime --timestamp \
    --entitlements Assets/OCIBastion.appstore.entitlements \
    --sign "$sign_identity" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
elif [[ $sign_identity == "-" ]]; then
  # Firma local, también con sandbox: así se prueba lo mismo que se distribuye.
  codesign --force --sign - --entitlements Assets/OCIBastion.entitlements "$app"
else
  # Hardened Runtime + marca de tiempo segura: obligatorios para notarizar.
  codesign --force --options runtime --timestamp \
    --entitlements Assets/OCIBastion.entitlements \
    --sign "$sign_identity" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
fi
touch "$app"
echo "$PWD/$app"
