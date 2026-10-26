#!/bin/sh
# Starts a throwaway qbittorrent-nox (4.6+) on 127.0.0.1:8080 for the 'Qbit' tests.
#   sh tests/start-qbittorrent.sh <password> [profile-dir]
# Then: PORT_SYNC_TEST_QBIT_URL=http://127.0.0.1:8080 PORT_SYNC_TEST_QBIT_PASS=<password> pwsh -c 'Invoke-Pester ./tests'
set -eu
pass="$1"
profile="${2:-$(mktemp -d)}"
mkdir -p "$profile/qBittorrent/config"
hash=$(python3 -c '
import base64, hashlib, os, sys
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", sys.argv[1].encode(), salt, 100000, 64)
print(base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode())' "$pass")
cat > "$profile/qBittorrent/config/qBittorrent.conf" <<CONF
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Address=127.0.0.1
WebUI\Port=8080
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray($hash)"
CONF
qbittorrent-nox --profile="$profile" >"$profile/qbittorrent.out" 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s http://127.0.0.1:8080/api/v2/app/webapiVersion >/dev/null && { echo "qbittorrent-nox up, profile $profile"; exit 0; }
  sleep 1
done
echo "qbittorrent-nox did not start; see $profile/qbittorrent.out" >&2
exit 1
