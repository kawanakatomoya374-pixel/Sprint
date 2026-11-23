# SprintSSL

A TLS library for Sprint, self-contained: nothing outside this folder is needed except the Sprint interpreter (and, for the C core, a C compiler).
Copy the folder out of the Sprint tree and it still builds and runs.

Design: speed-critical primitives are C natives (`c/`: SHA-2, HMAC/HKDF, AES-GCM, ChaCha20-Poly1305, X25519, Ed25519, P-256, big-number RSA);
everything else is Sprint (`sp/`: X.509 parsing and chain validation, the TLS 1.3 / 1.2 state machine, record layer, a socket-agnostic `Conn` API).
The transport is a pair of callbacks (`send(bytes)`, `recv()`), so it runs over the SprintOS network stack, a host socket, or a test pipe.

Layout: `c/` natives (one module `sslcore`), `sp/` library (`import sprintssl`), `tests/` known-answer tests (RFC / Wycheproof vectors) and a loopback
handshake. Status: skeleton only; implementation order is in the handover notes (hashes, AEAD, X25519, handshake, X.509, Ed25519 for app packs).
