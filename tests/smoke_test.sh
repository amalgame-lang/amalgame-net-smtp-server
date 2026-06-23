#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-net-smtp-server — loopback SMTP smoke test
#  Builds a real SmtpServer on 127.0.0.1:2526 (self-signed cert, one
#  AUTH account), drives it with a Python smtplib client doing
#  EHLO → STARTTLS → AUTH → send, and asserts the message was delivered
#  into the MailStore. Exercises the full TCP + STARTTLS + AUTH path.
# ─────────────────────────────────────────────────────
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -ge 1 ]; then AMC="$1"; elif [ -n "${AMC:-}" ]; then :
elif command -v amc >/dev/null 2>&1; then AMC="$(command -v amc)"
else echo "ERROR: amc not found." >&2; exit 2; fi
AMC_DIR="$(cd "$(dirname "$AMC")" && pwd)"
[ -n "${AMC_RUNTIME:-}" ] && [ -d "$AMC_RUNTIME" ] || AMC_RUNTIME="$AMC_DIR/runtime"

sib() { local v="${!1:-}"; if [ -n "$v" ] && [ -d "$v" ]; then echo "$v"; return; fi
        if [ -d "$PKG_DIR/../$2" ]; then (cd "$PKG_DIR/../$2" && pwd); return; fi; echo ""; }
STORE_DIR="$(sib AMALGAME_MAIL_STORE amalgame-net-mail-store)"
IOFS_DIR="$(sib AMALGAME_IO_FS amalgame-io-filesystem)"
SQLITE_DIR="$(sib AMALGAME_DB_SQLITE amalgame-database-sqlite)"
CRYPTO_DIR="$(sib AMALGAME_CRYPTO amalgame-crypto)"
TLS_DIR="$(sib AMALGAME_TLS amalgame-tls)"
SQLITE_C="$SQLITE_DIR/runtime/Amalgame_Database/sqlite/sqlite3.c"
INC="-I$AMC_RUNTIME -I$SQLITE_DIR/runtime -I$TLS_DIR/runtime"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

command -v python3 >/dev/null || { echo "ERROR: python3 required"; exit 2; }
command -v openssl  >/dev/null || { echo "ERROR: openssl required"; exit 2; }

SMOKE=/tmp/amalgame-smtp-smoke
rm -rf "$SMOKE"; mkdir -p "$SMOKE/store"
openssl req -x509 -newkey rsa:2048 -keyout "$SMOKE/key.pem" -out "$SMOKE/cert.pem" \
    -days 1 -nodes -subj "/CN=mail.test" >/dev/null 2>&1

BUILD_DIR="$(mktemp -d -t anss-smoke-XXXXXX)"
FAKE_CACHE="$BUILD_DIR/cache"
mkdir -p "$FAKE_CACHE/github.com/amalgame-lang/amalgame-database-sqlite" \
         "$FAKE_CACHE/github.com/amalgame-lang/amalgame-tls"
ln -s "$SQLITE_DIR" "$FAKE_CACHE/github.com/amalgame-lang/amalgame-database-sqlite/v0.4.0_deadbeef"
ln -s "$TLS_DIR"    "$FAKE_CACHE/github.com/amalgame-lang/amalgame-tls/v0.3.5_deadbeef"
export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"
LOCK_BAK=""; [ -f "$PKG_DIR/amalgame.lock" ] && { LOCK_BAK="$BUILD_DIR/lock.bak"; cp "$PKG_DIR/amalgame.lock" "$LOCK_BAK"; }
SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    rm -f "$PKG_DIR/_smoke.am"; rm -rf "$BUILD_DIR"
    if [ -n "$LOCK_BAK" ] && [ -f "$LOCK_BAK" ]; then mv "$LOCK_BAK" "$PKG_DIR/amalgame.lock"; else rm -f "$PKG_DIR/amalgame.lock"; fi
}
trap cleanup EXIT
cat > "$PKG_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-database-sqlite"
git = "github.com/amalgame-lang/amalgame-database-sqlite"
tag = "v0.4.0"
rev = "deadbeefcafebabe0000000000000000000000ab"

[[package]]
name = "amalgame-tls"
git = "github.com/amalgame-lang/amalgame-tls"
tag = "v0.3.5"
rev = "deadbeefcafebabe0000000000000000000000ab"
EOF
EXT="--external $STORE_DIR/facade.am --external $IOFS_DIR/facade.am --external $CRYPTO_DIR/facade.am"

echo "── build ──"
gcc -O2 $INC -w -c "$SQLITE_C" -o "$BUILD_DIR/sqlite3.o" || { echo "sqlite3 failed"; exit 1; }
bo() { "$AMC" --lib -o "$BUILD_DIR/$1" "$2/facade.am" $3 >/dev/null 2>&1
       gcc -O2 $INC -Wno-incompatible-pointer-types -c "$BUILD_DIR/$1.c" -o "$BUILD_DIR/$1.o" 2>"$BUILD_DIR/g.log" \
         || { echo -e "${RED}$1 failed${NC}"; cat "$BUILD_DIR/g.log"; exit 1; }; }
bo iofs "$IOFS_DIR" ""
bo crypto "$CRYPTO_DIR" ""
bo store "$STORE_DIR" "--external $IOFS_DIR/facade.am"
( cd "$PKG_DIR" && "$AMC" --lib -o "$BUILD_DIR/facade" facade.am $EXT ) >/dev/null 2>&1
gcc -O2 $INC -Wno-incompatible-pointer-types -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>"$BUILD_DIR/g.log" \
    || { echo -e "${RED}facade failed${NC}"; cat "$BUILD_DIR/g.log"; exit 1; }
cp "$SCRIPT_DIR/smoke_server.am" "$PKG_DIR/_smoke.am"
( cd "$PKG_DIR" && "$AMC" -o "$BUILD_DIR/smoke" _smoke.am $EXT --external facade.am ) >/dev/null 2>&1
gcc -O2 $INC -Wno-incompatible-pointer-types "$BUILD_DIR/smoke.c" \
    "$BUILD_DIR/facade.o" "$BUILD_DIR/store.o" "$BUILD_DIR/iofs.o" "$BUILD_DIR/crypto.o" "$BUILD_DIR/sqlite3.o" \
    -lgc -lm -lssl -lcrypto -lz -ldl -lresolv -lpthread -o "$BUILD_DIR/smoke" 2>"$BUILD_DIR/g.log" \
    || { echo -e "${RED}smoke link failed${NC}"; cat "$BUILD_DIR/g.log"; exit 1; }

echo "── run server ──"
"$BUILD_DIR/smoke" >"$BUILD_DIR/srv.out" 2>&1 &
SRV_PID=$!
for i in $(seq 1 50); do
    grep -q "SMOKE-SERVER-READY" "$BUILD_DIR/srv.out" 2>/dev/null && \
      python3 -c "import socket; socket.create_connection(('127.0.0.1',2526),1).close()" 2>/dev/null && break
    sleep 0.2
done

echo "── client: EHLO → STARTTLS → AUTH LOGIN → send ──"
python3 - <<'PY'
import smtplib, ssl, sys
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
try:
    s = smtplib.SMTP("127.0.0.1", 2526, timeout=10)
    s.ehlo("client.test"); s.starttls(context=ctx); s.ehlo("client.test")
    s.login("alice", "s3cret")
    s.sendmail("sender@example.com", ["alice@mail.test"],
               "Subject: Smoke\r\nFrom: sender@example.com\r\n\r\nhello over TLS smoke")
    s.quit()
    print("CLIENT-OK")
except Exception as e:
    print("CLIENT-ERR", e); sys.exit(1)
PY
CLIENT_RC=$?

echo "── assert delivery ──"
PASS=0; FAIL=0
[ "$CLIENT_RC" -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo -e "  ${RED}client failed${NC}"; }
if grep -rqs "hello over TLS smoke" "$SMOKE/store"; then
    PASS=$((PASS+1)); echo -e "  ${GREEN}message delivered to store${NC}"
else
    FAIL=$((FAIL+1)); echo -e "  ${RED}message NOT found in store${NC}"; echo "  server log:"; sed 's/^/    /' "$BUILD_DIR/srv.out"
fi
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC} | ${RED}FAIL: $FAIL${NC}"
[ "$FAIL" -eq 0 ]
