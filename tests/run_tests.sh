#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-net-smtp-server — Test Runner (SmtpSession core)
#  Usage: ./tests/run_tests.sh [/path/to/amc]
#
#  Drives the SmtpSession state machine against a real local MailStore +
#  scrypt Credentials (no socket, no TLS). Dependency closure:
#  net-mail-store (→ io-filesystem + sqlite) + crypto. Pure-AM facades
#  wire via --external; sqlite (header-runtime) via fake-cache + lock.
# ─────────────────────────────────────────────────────
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -ge 1 ]; then AMC="$1"
elif [ -n "${AMC:-}" ]; then :
elif command -v amc >/dev/null 2>&1; then AMC="$(command -v amc)"
else echo "ERROR: amc not found." >&2; exit 2; fi
[ -x "$AMC" ] || { echo "ERROR: amc '$AMC' not executable" >&2; exit 2; }
AMC_DIR="$(cd "$(dirname "$AMC")" && pwd)"
if [ -n "${AMC_RUNTIME:-}" ] && [ -d "$AMC_RUNTIME" ]; then :
elif [ -d "$AMC_DIR/runtime" ]; then AMC_RUNTIME="$AMC_DIR/runtime"
else echo "ERROR: amc runtime/ not found; set AMC_RUNTIME" >&2; exit 2; fi

sib() { local v="${!1:-}"; if [ -n "$v" ] && [ -d "$v" ]; then echo "$v"; return; fi
        if [ -d "$PKG_DIR/../$2" ]; then (cd "$PKG_DIR/../$2" && pwd); return; fi; echo ""; }
STORE_DIR="$(sib AMALGAME_MAIL_STORE amalgame-net-mail-store)"
IOFS_DIR="$(sib AMALGAME_IO_FS amalgame-io-filesystem)"
SQLITE_DIR="$(sib AMALGAME_DB_SQLITE amalgame-database-sqlite)"
CRYPTO_DIR="$(sib AMALGAME_CRYPTO amalgame-crypto)"
TLS_DIR="$(sib AMALGAME_TLS amalgame-tls)"
for v in STORE_DIR:net-mail-store IOFS_DIR:io-filesystem SQLITE_DIR:database-sqlite CRYPTO_DIR:crypto TLS_DIR:tls; do
    d="${v%%:*}"; if [ -z "${!d}" ]; then echo "ERROR: ${v##*:} not found (sibling)"; exit 2; fi
done
SQLITE_C="$SQLITE_DIR/runtime/Amalgame_Database/sqlite/sqlite3.c"
SQLITE_RUNTIME="$SQLITE_DIR/runtime"
TLS_RUNTIME="$TLS_DIR/runtime"
[ -f "$SQLITE_C" ] || { echo "ERROR: sqlite3.c not found"; exit 2; }

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
echo "  amc:     $AMC ($("$AMC" --version 2>&1 | head -1))"
echo "  store:   $STORE_DIR"; echo "  crypto:  $CRYPTO_DIR"

BUILD_DIR="$(mktemp -d -t anss-tests-XXXXXX)"
INC="-I$AMC_RUNTIME -I$SQLITE_RUNTIME -I$TLS_RUNTIME"

FAKE_CACHE="$BUILD_DIR/cache"
mkdir -p "$FAKE_CACHE/github.com/amalgame-lang/amalgame-database-sqlite"
mkdir -p "$FAKE_CACHE/github.com/amalgame-lang/amalgame-tls"
ln -s "$SQLITE_DIR" "$FAKE_CACHE/github.com/amalgame-lang/amalgame-database-sqlite/v0.4.0_deadbeef"
ln -s "$TLS_DIR"    "$FAKE_CACHE/github.com/amalgame-lang/amalgame-tls/v0.3.5_deadbeef"
export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"

LOCK_BAK=""
[ -f "$PKG_DIR/amalgame.lock" ] && { LOCK_BAK="$BUILD_DIR/lock.bak"; cp "$PKG_DIR/amalgame.lock" "$LOCK_BAK"; }
trap '
    rm -f "$PKG_DIR/_test.am"; rm -rf "$BUILD_DIR"
    if [ -n "$LOCK_BAK" ] && [ -f "$LOCK_BAK" ]; then mv "$LOCK_BAK" "$PKG_DIR/amalgame.lock"; else rm -f "$PKG_DIR/amalgame.lock"; fi
' EXIT
cat > "$PKG_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-database-sqlite"
git  = "github.com/amalgame-lang/amalgame-database-sqlite"
tag  = "v0.4.0"
rev  = "deadbeefcafebabe0000000000000000000000ab"

[[package]]
name = "amalgame-tls"
git  = "github.com/amalgame-lang/amalgame-tls"
tag  = "v0.3.5"
rev  = "deadbeefcafebabe0000000000000000000000ab"
EOF

EXT="--external $STORE_DIR/facade.am --external $IOFS_DIR/facade.am --external $CRYPTO_DIR/facade.am"

echo "── precompile sqlite3.c ──"
gcc -O2 $INC -w -c "$SQLITE_C" -o "$BUILD_DIR/sqlite3.o" || { echo "sqlite3.c failed"; exit 1; }

build_dep_o() { # name  dir  extra-external
    "$AMC" --lib -o "$BUILD_DIR/$1" "$2/facade.am" $3 >/dev/null 2>&1
    gcc -O2 $INC -Wno-incompatible-pointer-types -c "$BUILD_DIR/$1.c" -o "$BUILD_DIR/$1.o" 2>"$BUILD_DIR/gcc.log" \
        || { echo -e "${RED}$1 build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }
}
echo "── build dependency .o ──"
build_dep_o iofs   "$IOFS_DIR"   ""
build_dep_o crypto "$CRYPTO_DIR" ""
build_dep_o store  "$STORE_DIR"  "--external $IOFS_DIR/facade.am"

echo "── build smtp-server facade .o ──"
( cd "$PKG_DIR" && "$AMC" --lib -o "$BUILD_DIR/facade" facade.am $EXT ) 2>&1 | tail -15
gcc -O2 $INC -Wno-incompatible-pointer-types -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}facade build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

echo "── build + run test ──"
cp "$SCRIPT_DIR/smtpsession_test.am" "$PKG_DIR/_test.am"
( cd "$PKG_DIR" && "$AMC" -o "$BUILD_DIR/test" _test.am $EXT --external facade.am ) 2>&1 | tail -15
gcc -O2 $INC -Wno-incompatible-pointer-types "$BUILD_DIR/test.c" \
    "$BUILD_DIR/facade.o" "$BUILD_DIR/store.o" "$BUILD_DIR/iofs.o" "$BUILD_DIR/crypto.o" "$BUILD_DIR/sqlite3.o" \
    -lgc -lm -lssl -lcrypto -lz -ldl -lpthread -o "$BUILD_DIR/test" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}test link failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

OUT="$("$BUILD_DIR/test" 2>&1)"; echo "$OUT"
PASS=0; FAIL=0
check() { if echo "$OUT" | grep -qF "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo -e "  ${RED}MISSING${NC}: $1"; fi; }
check "[PASS] greeting"
check "[PASS] ehlo pre-tls caps"
check "[PASS] auth refused pre-tls"
check "[PASS] starttls signal"
check "[PASS] ehlo post-tls caps"
check "[PASS] auth login success"
check "[PASS] mail/rcpt/data dialogue"
check "[PASS] delivered + dot-unstuffed"
check "[PASS] auth login failure"
check "[PASS] quit"
check "[PASS] unknown command"
echo "$OUT" | grep -q "\[FAIL\]" && FAIL=$((FAIL+1))
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}"
echo "────────────────────────────────────────────"
[ "$FAIL" -eq 0 ]
