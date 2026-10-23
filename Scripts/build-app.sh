#!/bin/zsh
# Compila y empaqueta "OCI Bastion.app".
#
# Variables opcionales:
#   CONFIGURATION  debug | release (por defecto: release)
#   UNIVERSAL      1 para generar binario arm64 + x86_64 (por defecto: 1 en release)
#   SIGN_IDENTITY  identidad de firma (por defecto: "-" firma ad hoc)
#                  p. ej. "Developer ID Application: Nombre (TEAMID)"
#   BUNDLE_ID      identificador del bundle (por defecto: com.ocibastion.app)
#   VERSION        CFBundleShortVersionString (por defecto: 0.1.0)
#   BUILD_NUMBER   CFBundleVersion (por defecto: número de commits de git)
set -euo pipefail
cd "${0:A:h:h}"

configuration="${CONFIGURATION:-release}"
universal="${UNIVERSAL:-$([[ $configuration == release ]] && echo 1 || echo 0)}"
sign_identity="${SIGN_IDENTITY:--}"
bundle_id="${BUNDLE_ID:-com.ocibastion.app}"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

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
cp Assets/LaunchITerm.applescript "$app/Contents/Resources/LaunchITerm.applescript"
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
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© $(date +%Y) OCI Bastion</string>
<key>NSAppleEventsUsageDescription</key><string>OCI Bastion abre conexiones SSH en la aplicación de terminal seleccionada.</string>
</dict></plist>
PLIST

if [[ $sign_identity == "-" ]]; then
  codesign --force --sign - "$app"
else
  # Hardened Runtime + marca de tiempo segura: obligatorios para notarizar.
  codesign --force --options runtime --timestamp \
    --entitlements Assets/OCIBastion.entitlements \
    --sign "$sign_identity" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
fi
touch "$app"
echo "$PWD/$app"
