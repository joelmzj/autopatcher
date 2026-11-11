#!/usr/bin/env bash
set -euo pipefail

# Materializar la identidad de firma para el build desde los secretos de CI.
missing=
for v in KEYSTORE_B64 KEYSTORE_PASSWORD KEY_ALIAS; do
	[ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
	echo "::error::missing Actions secret(s):$missing - refusing to sign with the template keystore." >&2
	exit 1
fi

umask 077
printf '%s' "$KEYSTORE_B64" | base64 -d > ks.keystore

# Validar formato BKS del keystore BKS
bks_magic=$(od -An -tx1 -N4 ks.keystore | tr -d ' \n')
case "$bks_magic" in
	00000002 | 424b532d) echo "[+] ks.keystore es un BouncyCastle keystore válido (magic $bks_magic)." ;;
	*)
		echo "::error::ks.keystore no es un BKS keystore válido (magic $bks_magic)." >&2
		exit 1
	;;
esac

echo "[+] Keystore instalado correctamente (ks.keystore)."

# Exportar variables de entorno para que el motor las utilice automáticamente
{
	echo "RVB_KEYSTORE=ks.keystore"
	echo "RVB_KEYSTORE_PASS=$KEYSTORE_PASSWORD"
	echo "RVB_KEY_ALIAS=$KEY_ALIAS"
} >>"$GITHUB_ENV"
echo "[+] Identidad de firma exportada exitosamente (alias: $KEY_ALIAS)."