# amalgame-net-smtp-server

A **receiving ESMTP server** for the native Amalgame mail server
(Phase 3). A dedicated package, so the existing client
[`amalgame-net-smtp`](https://github.com/amalgame-lang/amalgame-net-smtp)
(used by Mosaic contact forms) stays lean.

Receive-only by design: it accepts mail and stores it locally via
[`amalgame-net-mail-store`](https://github.com/amalgame-lang/amalgame-net-mail-store);
it never forwards, so it is **not an open relay**. See
[`native-mail-server.md`](https://github.com/amalgame-lang/Amalgame/blob/main/docs/proposals/native-mail-server.md).

## Two layers

| Layer | Status |
|---|---|
| **`SmtpSession`** — the ESMTP command state machine (pure logic, socket/TLS-free, unit-tested 11/11) | ✅ v0.1.0 |
| **`SmtpServer`** — the TcpServer accept loop + STARTTLS upgrade (transport, loopback smoke-tested) | ✅ v0.1.0 |

`SmtpSession` is the heart: you feed it one command line at a time and it
returns the response to send, accumulates the DATA payload (with RFC 5321
dot-unstuffing), authenticates, and on end-of-DATA delivers the message
into a `MailStore`. It owns no socket and no TLS, so it is fully
unit-testable by driving it with strings — which is how the 11/11 test
suite exercises the whole dialogue end-to-end against a real local store.

```amalgame
import Amalgame.Net.SmtpServer
import Amalgame.Net.Mail

let store: MailStore   = MailStore.Open("/var/mail/alice")
let s:     SmtpSession = new SmtpSession(store, "mail.example.com")
s.AddPassword("alice", "s3cret")        // or AddUserHash(name, scryptHash)

// the transport feeds lines and writes back what Feed returns:
send(conn, s.Greeting())                // 220 ...
loop {
    let line = readLine(conn)
    let resp = s.Feed(line)             // "" while mid-DATA
    if (String_Length(resp) > 0) { send(conn, resp) }
    if (s.WantsTlsUpgrade()) { /* STARTTLS handshake */ s.SetTlsActive(true) }
    if (s.IsQuit()) { break }
}
```

## Protocol coverage (v0.1.0)

- **EHLO/HELO** — multi-line 250 capability list; advertises `STARTTLS`
  before TLS and `AUTH PLAIN LOGIN` only after (no credentials in the
  clear).
- **STARTTLS** — surfaced as a signal (`WantsTlsUpgrade`) for the
  transport to perform the handshake, then `SetTlsActive(true)` (which
  resets the session per RFC 3207).
- **AUTH PLAIN / LOGIN** — base64-decoded (inline, NUL-safe for PLAIN)
  and verified against **scrypt** hashes via `amalgame-crypto`
  `Password.Verify` — the same hashes `amalgame-auth` stores, so **one
  unified family account** across files / calendars / contacts / mail —
  without dragging in amalgame-auth's HTTP-coupled wrappers. AUTH is
  refused before TLS.
- **MAIL / RCPT / DATA** — envelope + payload; on `.` the message is
  delivered to the configured mailbox (default `INBOX`) and the UID is
  returned in the `250` reply.
- **RSET / NOOP / VRFY / QUIT** and unknown-command handling.

## Auth note

Verifying via `amalgame-crypto` `Password.Verify` (instead of importing
`amalgame-auth`'s `Credentials`) is deliberate: `amalgame-auth` pulls in
`amalgame-net-http` (its `BasicAuth` is HTTP-shaped), which a mail server
should not depend on. The scrypt hashes are identical, so the unified
account is preserved. When `amalgame-auth` grows a protocol-neutral
`Credentials` core (no net-http), this package can switch to it.


## Security hardening (v0.2.0)

Anti-abuse guards, enabled by `SmtpServer.WithLocalDomain("amalgame.me")`
(or `SmtpSession.WithLocalDomain`):

- **No open relay / no backscatter** — an unauthenticated sender may only
  deliver to a *local* recipient (`<user>@amalgame.me`); any other RCPT is
  refused `550` **during** the transaction (never accepted-then-bounced).
  Authenticated users may relay anywhere.
- **Anti-spoofing** — an unauthenticated `MAIL FROM:<…@amalgame.me>` (a
  client pretending to be one of your own users) is refused `550`.
- **AUTH brute-force lockout** — after 5 failed AUTH the session refuses
  further attempts (`454`); a STARTTLS does not reset the counter.
- **Resource limits** — `WithMaxSize(bytes)` (advertised SIZE, oversize →
  `552`), `WithMaxRecipients(n)` (`452`). Null sender `<>` accepted (bounces).

Still ahead (audit): per-IP rate-limit + connection caps + idle timeouts in
the transport, inbound SPF/DKIM/DMARC verification, greylisting, DNSBL.

## Running the server

```amalgame
let store: MailStore = MailStore.Open("/var/mail/alice")
let srv:   SmtpServer = new SmtpServer(store, "mail.example.com")
srv.AddPassword("alice", "s3cret")                 // or AddUserHash(name, scryptHash)
let s2: SmtpServer = srv.WithCert("/etc/ssl/cert.pem", "/etc/ssl/key.pem")  // enables STARTTLS
s2.Serve(2525)                                     // blocking; one connection at a time (v0.1)
```

The accepted connection's fd is read once (via `@c`), driving the
plaintext dialogue with `recv`/`send`; on an accepted `STARTTLS` the fd
is wrapped in an `amalgame-tls` server `TlsStream` and the dialogue
continues over TLS. **Verified end-to-end** by `tests/smoke_test.sh`: a
real Python `smtplib` client does EHLO → STARTTLS → AUTH LOGIN → send,
and the message lands in the store.

> Security: develop and run on a local port. Exposing `:25` to the
> internet stays gated behind the security-audit step in the
> [proposal](https://github.com/amalgame-lang/Amalgame/blob/main/docs/proposals/native-mail-server.md).

## Out of scope (v0.1.0)

- A worker pool / concurrent connections (v0.1 serves one at a time);
  implicit-TLS submission on `:465`.
- Per-recipient mailbox routing (all accepted mail → the configured
  mailbox); SIZE enforcement; rate-limit / lockout; DKIM/SPF (later
  phases).

## Dependencies

- [`amalgame-net-mail-store`](https://github.com/amalgame-lang/amalgame-net-mail-store) `>=0.1.0`
- [`amalgame-crypto`](https://github.com/amalgame-lang/amalgame-crypto) `>=0.6.0`
- [`amalgame-tls`](https://github.com/amalgame-lang/amalgame-tls) `>=0.3.5`

## Tests

```sh
# siblings net-mail-store, io-filesystem, database-sqlite, crypto alongside
bash tests/run_tests.sh /path/to/amc
```

Drives `SmtpSession` against a real local `MailStore` + scrypt account,
socket-free and deterministic — 11/11.

## License

Apache-2.0 — see `LICENSE` and `NOTICE.md`.
