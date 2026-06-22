# NOTICE — amalgame-net-smtp-server

## Authorship

Copyright 2026 Bastien Mouget. The Amalgame facade code in this
repository is original work — see `facade.am` and the `amalgame.toml`
manifest.

This package is part of the Amalgame ecosystem
([github.com/amalgame-lang/Amalgame](https://github.com/amalgame-lang/Amalgame)).

## License

Licensed under the Apache License, Version 2.0 — see `LICENSE`.

## Third-party content

None vendored. `SmtpSession` is pure Amalgame; it builds on
`amalgame-net-mail-store` (delivery) and `amalgame-crypto`
(`Password.Verify`, scrypt). `SmtpServer`'s transport uses
the runtime's built-in TcpServer/TcpConn and `amalgame-tls`.
