#!/bin/sh
# Creates a self-signed code signing identity in your login keychain. bundle.sh signs with it when it
# exists, so macOS keeps BudBar's Bluetooth and Input Monitoring permissions across rebuilds
# (an ad-hoc signature changes with every build, and macOS asks again each time).
set -e
name="BudBar Local Signing"
if security find-certificate -c "$name" >/dev/null 2>&1; then
    echo "\"$name\" already exists"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# macOS's own LibreSSL writes a PKCS#12 file that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$name" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
    -passout pass:budbar
security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P budbar -T /usr/bin/codesign
echo "Created \"$name\""
