#!/bin/bash
# Creates Porpoise's self-signed code-signing identity in .signing/ (not the login keychain).
# macOS ties privacy grants (Full Disk Access…) to the signing identity, so every release must be signed with
# the same one: back up .signing/ (it is git-ignored) — losing it means users re-grant access after updating.
# .signing/porpoise-identity.p12 (password in .signing/p12-password) is the backup and the release CI's secret.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=.signing
KC=$PWD/$DIR/porpoise.keychain-db
PW=porpoise-local
[ -f "$KC" ] && { echo "signing identity already set up"; exit 0; }
mkdir -p $DIR && cd $DIR
cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Porpoise Signing
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
# -legacy: the keychain tools only read the older PKCS#12 encryption.
P12PW=$(openssl rand -hex 24)
echo -n "$P12PW" > p12-password
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out porpoise-identity.p12 -passout pass:"$P12PW"
chmod 600 p12-password porpoise-identity.p12
security create-keychain -p $PW "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p $PW "$KC"
security import porpoise-identity.p12 -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW "$KC" >/dev/null
rm -f key.pem
echo "created signing identity in $DIR"
