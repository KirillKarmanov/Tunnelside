#!/bin/bash
# Создаёт в связке ключей «Вход» самоподписанный сертификат для подписи кода «Tunnelside Local Signing».
# Нужен один раз на машину: им подписываются и приложение, и фоновая служба, а служба
# принимает команды только от приложения с той же подписью.
# Платный Apple Developer ID не нужен. Закрытый ключ создаётся во временной папке и
# после импорта удаляется — остаётся только в связке ключей.
set -euo pipefail

NAME="${SIGN_IDENTITY:-Tunnelside Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Сертификат «${NAME}» уже есть в связке ключей"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(openssl rand -hex 16)"
# 3DES/SHA1 — формат PKCS#12, который гарантированно читает `security import`
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
    -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "✓ Сертификат «${NAME}» создан, срок действия 10 лет"
openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1
echo "  При первой подписи macOS может спросить доступ к ключу — нажмите «Всегда разрешать»."
