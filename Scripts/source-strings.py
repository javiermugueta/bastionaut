#!/usr/bin/env python3
"""Genera la tabla Localizable.strings del idioma de origen (español) a partir del catálogo.

xcstringstool solo compila los idiomas con traducción explícita; sin esta tabla, macOS
caería al inglés para los usuarios con el sistema en español."""
import json, plistlib, sys

catalog, output = sys.argv[1], sys.argv[2]
data = json.load(open(catalog, encoding="utf-8"))
source = data.get("sourceLanguage", "es")
table = {}
for key, entry in data["strings"].items():
    unit = entry.get("localizations", {}).get(source, {}).get("stringUnit")
    table[key] = unit["value"] if unit else key
with open(output, "wb") as f:
    plistlib.dump(table, f, fmt=plistlib.FMT_XML)
print(f"{len(table)} textos en {output}")
