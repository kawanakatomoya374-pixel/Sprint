# SprintSSL

A TLS library for Sprint, self-contained: nothing outside this folder is needed except the Sprint interpreter's source headers (for the C binding) and a C compiler.
The speed-critical primitives are C; everything else is Sprint.

| Part | Where | What |
|---|---|---|
| `c/` | `sslcore` | SHA-256/384/512, HMAC, HKDF, AES-128/256-GCM, ChaCha20-Poly1305, X25519, Ed25519 (sign and verify), RSA public operation, ECDSA verify and ECDH on P-256 / P-384, a random generator. Plain C11 (`sslcore.h`), checked against Python's `cryptography` and the RFC vectors. `sslcore_sp.c` binds it to Sprint as the module `sslcore` (byte strings are `typed.u8`). |
| `sp/sslasn1.sp` | DER reader/writer | |
| `sp/sslx509.sp` | X.509 | parsing, PEM, signature verification (RSA PKCS#1 v1.5 and PSS, ECDSA, Ed25519), chain building and validation against trusted roots, dates, host names (SAN, wildcards, IP addresses), CA / path-length checks |
| `sp/ssltls.sp` | TLS 1.3 | record layer, key schedule, client handshake and a small server (Ed25519 certificates), `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`, X25519, KeyUpdate |
| `sp/sprintssl.sp` | front door | `connect(transport, host, roots, now)`, the netstack transport, a small HTTPS client (`http_get`: Content-Length, chunked or until close) |
| `tests/` | | `kat_test.sp` (RFC vectors), `x509_test.sp` (chains over ECDSA / RSA / Ed25519, names, dates), `tls_loopback.sp` (client and server in memory), `gen_pki.py` (makes the certificates in `tests/data`) |

```
import sprintssl
let roots = sprintssl.load_roots(pem_text)
let conn = sprintssl.connect(transport, "example.com", roots, sprintssl.unix_time([2026, 11, 23, 12, 0, 0]))
let r = sprintssl.http_get(conn, "example.com", "/")        # {status, headers, body}
conn.close()
```

A transport is any object with `send(bytes)` and `recv(max, ms)` (bytes, `nil` on timeout, empty at the end). Over the SprintOS network stack use `sprintssl.TcpTransport(stack, tcp_connection)`.

## Using it

In the Sprint tree the C files are part of the interpreter build (the `Makefile` globs `sprintssl/c/*.c`) and the `.sp` files are bundled like the standard library, so `import sprintssl` works
in the interpreter and in SprintOS. `make test` runs `sprintssl/tests/*.sp`; `make os-net-test` runs the network tests in QEMU, including TLS against Python's `ssl` (ECDSA chain with an intermediate,
RSA, Ed25519, 200 KB body, a refused untrusted chain) and an HTTPS GET of a GitHub Pages site (through a TCP relay on the host).
Outside the tree: build `c/*.c` with `make` here (needs `-I<Sprint>/src`), register `lib_sslcore_fns` as the module `sslcore`, and put `sp/` on the import path.

## Limits (honest list)

- Variable-time big-number code: ECDSA/RSA verification only touches public values, but `ecdh` / `ec_pub` on P-256/P-384 with a secret scalar is not constant time. X25519 and Ed25519 signing use the constant-time-style ladder of TweetNaCl, but the AES S-box and GHASH are table/bitwise code that is not hardened against cache attacks.
- No TLS 1.2, no session resumption, no 0-RTT, no client certificates (an empty one is sent when asked), no HelloRetryRequest (only X25519 is offered), no revocation checking (OCSP / CRL), no name constraints, no P-521 or SHA-1 certificates.
- The random generator mixes `getrandom` (Linux) or RDRAND / the time-stamp counter (SprintOS) with seeds from the caller. Under QEMU's default CPU there is no RDRAND, so the output is only as good as `sslcore.seed()` input: fine for tests, not for production.
- The root store is whatever you pass in; SprintOS does not ship one yet.
