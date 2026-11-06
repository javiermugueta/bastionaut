#!/bin/sh
# Askpass del terminal integrado de Bastionaut.
# En sandbox, ssh no puede abrir /dev/tty para preguntar (huella del servidor, frase de la clave…),
# pero sí el dispositivo del PTY de la ventana (/dev/ttysNNN), que el terminal deja en OCIB_TTY.
tty="${OCIB_TTY:-}"
case "$tty" in
  /dev/tty?*) [ -c "$tty" ] || exit 1 ;;
  *) exit 1 ;;
esac
secret=
case "$1" in
  *assword*|*assphrase*|*PIN*|*passcode*) secret=1 ;;
esac
printf '%s ' "$1" > "$tty"
[ -n "$secret" ] && stty -echo < "$tty"
IFS= read -r answer < "$tty"
result=$?
[ -n "$secret" ] && { stty echo < "$tty"; printf '\n' > "$tty"; }
[ $result -eq 0 ] || exit 1
printf '%s\n' "$answer"
