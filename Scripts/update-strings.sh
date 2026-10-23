#!/bin/zsh
# Extrae los textos localizables del código y los sincroniza con Assets/Localizable.xcstrings.
# Después, traduce las entradas nuevas en Xcode (o editando el JSON).
set -euo pipefail
cd "${0:A:h:h}"
out=.build/l10n-strings
rm -rf "$out" && mkdir -p "$out" .build/clang-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox --scratch-path .build/l10n --cache-path .build/cache \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$out" >/dev/null
catalog=Assets/Localizable.xcstrings
[[ -f $catalog ]] || echo '{"sourceLanguage":"es","strings":{},"version":"1.0"}' > "$catalog"
xcrun xcstringstool sync "$catalog" --stringsdata "$out"/*.stringsdata
echo "$(xcrun xcstringstool print "$catalog" | grep -c . ) textos en $catalog"
