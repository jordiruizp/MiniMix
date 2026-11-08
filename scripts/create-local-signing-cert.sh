#!/usr/bin/env bash
# Crea en el llavero de inicio de sesión un certificado autofirmado de firma de código
# «MiniMix Local» (10 años). Con él la app tiene una identidad estable entre compilaciones,
# así los security-scoped bookmarks de los proyectos siguen siendo válidos tras actualizar.
# Solo para uso local/distribución manual (no sustituye a Developer ID ni a la notarización).
# Ejecútalo tú una vez: puede pedir la contraseña del llavero.
set -euo pipefail
name="MiniMix Local"
if security find-identity -p codesigning | grep -q "\"$name\""; then
  echo "✔ ya existe «$name»"; exit 0
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
pass="minimix-$$"
openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$tmp/id.p12" -passout "pass:$pass" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
       -out "$tmp/id.p12" -passout "pass:$pass"
security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" \
  -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$tmp/cert.pem"
security find-identity -v -p codesigning | grep "$name" && echo "✔ certificado «$name» creado"
