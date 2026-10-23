#!/bin/zsh
# Capturas para la App Store en español e inglés, con datos de demostración (no toca tu configuración).
# Lanza la app con -BastionautDemo, ajusta la ventana a 1280×800 pt y captura solo esa ventana.
# Requiere permiso de Grabación de pantalla para la terminal desde la que se ejecuta.
set -euo pipefail
cd "${0:A:h:h}"
app="dist/Bastionaut.app"
[[ -d $app ]] || CONFIGURATION=release UNIVERSAL=0 ./Scripts/build-app.sh >/dev/null
binary="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
helper="$(mktemp -d)/windows.swift"
cat > "$helper" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(w[kCGWindowNumber as String]!)\t\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)\t\(w[kCGWindowName as String] ?? "")")
}
SWIFT
swiftc -O -o "${helper%.swift}" "$helper" 2>/dev/null

capture() {  # idioma escena nombre filtro-de-título
  local lang=$1 scene=$2 name=$3 title=${4:-}
  "$binary" -BastionautDemo YES -BastionautDemoScene "$scene" -AppleLanguages "($lang)" -AppleLocale "$lang" \
    -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  local pid=$!
  local line="" id="" tries=0
  # Espera a que la ventana tenga ya su tamaño final (y un respiro para las animaciones).
  while [[ -z "$line" && $tries -lt 30 ]]; do
    sleep 0.5
    line=$("${helper%.swift}" "$pid" | grep -E "1280x800" | grep -i -- "$title" | head -1 || true)
    tries=$((tries + 1))
  done
  sleep 1.5
  id=${line%%$'\t'*}
  mkdir -p "Store/screenshots/$lang"
  if [[ -n "$id" ]]; then
    screencapture -x -o -l "$id" "Store/screenshots/$lang/$name.png"
    echo "$lang/$name.png  $(sips -g pixelWidth -g pixelHeight "Store/screenshots/$lang/$name.png" | awk '/pixel/{printf "%s ", $2}')"
  else
    echo "⚠️  $lang/$name: no encontré la ventana" >&2
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
}

for lang in es en; do
  capture $lang main      01-conectado   "🚀"
  capture $lang dark      02-modo-oscuro "🚀"
  capture $lang attention 03-ayuda-ip    "🚀"
  capture $lang help      04-ayuda "$([[ $lang == es ]] && echo Ayuda || echo Help)"
done
