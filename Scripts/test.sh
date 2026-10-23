#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/clang-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --disable-sandbox --scratch-path .build --cache-path .build/cache "$@"
