#!/usr/bin/env bash
set -euo pipefail

# Materializar la identidad de firma para el build desde los secretos de CI.
missing=
for v in KEYSTORE_B64 KEYSTORE_P12_B64 KEYSTORE_PASSWORD KEY_ALIAS; do
	[ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
	echo "::error::missing Actions secret(s):$missing - refusing to sign with the template keystore." >&2
	exit 1
fi

umask 077
printf '%s' "$KEYSTORE_B64" | base64 -d > ks.keystore
printf '%s' "$KEYSTORE_P12_B64" | base64 -d > ks-p12.keystore

# Validar formato BKS del keystore BKS
bks_magic=$(od -An -tx1 -N4 ks.keystore | tr -d ' \n')
case "$bks_magic" in
	00000002 | 424b532d) echo "[+] ks.keystore es un BouncyCastle keystore válido (magic $bks_magic)." ;;
	*)
		echo "::error::ks.keystore no es un BKS keystore válido (magic $bks_magic)." >&2
		exit 1
	;;
esac

# Validar el alias y la contraseña en el almacén PKCS12 si keytool está disponible
if command -v keytool >/dev/null 2>&1; then
	if keytool -list -keystore ks-p12.keystore -storetype PKCS12 \
		-storepass "$KEYSTORE_PASSWORD" -alias "$KEY_ALIAS" >/dev/null 2>&1; then
		echo "[+] ks-p12.keystore es PKCS12 y contiene el alias '$KEY_ALIAS'."
	else
		echo "::error::El alias '$KEY_ALIAS' no es legible en ks-p12.keystore (revisa la contraseña o el alias)." >&2
		exit 1
	fi
else
	echo "[!] keytool no está disponible en el PATH - omitiendo la verificación PKCS12."
fi

echo "[+] Keystores instalados correctamente (ks.keystore y ks-p12.keystore)."

# Exportar variables de entorno para que el motor las utilice automáticamente
{
	echo "RVB_KEYSTORE=ks.keystore"
	echo "RVB_KEYSTORE_P12=ks-p12.keystore"
	echo "RVB_KEYSTORE_PASS=$KEYSTORE_PASSWORD"
	echo "RVB_KEY_ALIAS=$KEY_ALIAS"
} >>"$GITHUB_ENV"
echo "[+] Identidad de firma exportada exitosamente (alias: $KEY_ALIAS)."