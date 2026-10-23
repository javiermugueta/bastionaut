#!/usr/bin/env python3
"""Comprueba los límites de Apple en Store/metadata.md (nombre, subtítulo, promo, descripción, palabras clave)."""
import re
import sys

LIMITS = {
    "Nombre": 30, "Name": 30,
    "Subtítulo": 30, "Subtitle": 30,
    "Texto promocional": 170, "Promotional text": 170,
    "Descripción": 4000, "Description": 4000,
    "Palabras clave": 100, "Keywords": 100,
}

text = open(sys.argv[1] if len(sys.argv) > 1 else "Store/metadata.md", encoding="utf-8").read()
failed = False
for section in re.split(r"^## ", text, flags=re.M)[1:]:
    title = section.splitlines()[0]
    for label, block in re.findall(r"\*\*([^*]+)\*\*[^\n]*\n```\n(.*?)\n```", section, flags=re.S):
        if label not in LIMITS:
            continue
        # Apple cuenta caracteres; las palabras clave, bytes en UTF-8.
        size = len(block.encode("utf-8")) if label in ("Palabras clave", "Keywords") else len(block)
        ok = size <= LIMITS[label]
        failed |= not ok
        print(f"{'✅' if ok else '❌'} {title[:20]:20} {label:18} {size:5}/{LIMITS[label]}")
sys.exit(1 if failed else 0)
