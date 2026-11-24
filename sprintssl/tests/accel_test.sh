#!/bin/sh
# builds the portable copy of the accelerated code (SSL_NO_ACCEL, entry points renamed port_*) and compares it with the hardware paths
set -e
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
cc -O2 -fno-stack-protector -DSSL_NO_ACCEL -Dssl_aes_gcm_seal=port_ssl_aes_gcm_seal -Dssl_aes_gcm_open=port_ssl_aes_gcm_open \
   -Dssl_chacha_seal=port_ssl_chacha_seal -Dssl_chacha_open=port_ssl_chacha_open -Isprintssl/c -c sprintssl/c/aead.c -o "$T/aead_port.o"
cc -O2 -fno-stack-protector -DSSL_NO_ACCEL -Dssl_sha256_init=port_sha256_init -Dssl_sha256_update=port_sha256_update -Dssl_sha256_final=port_sha256_final \
   -Dssl_sha512_init=port_sha512_init -Dssl_sha512_update=port_sha512_update -Dssl_sha512_final=port_sha512_final -Dssl_hash_len=port_hash_len -Dssl_hash=port_hash \
   -Dssl_hmac=port_hmac -Dssl_hkdf_extract=port_hkdf_extract -Dssl_hkdf_expand=port_hkdf_expand -Dssl_accel_sha256=port_accel_sha256 -Isprintssl/c -c sprintssl/c/hash.c -o "$T/hash_port.o"
cat > "$T/shim.c" <<'EOS'
#include "sslcore.h"
int port_hash(int alg, const uint8_t *p, size_t n, uint8_t *out);
int port_accel_sha256(void) { return 0; }
int port_ssl_hash_sha256(const uint8_t *p, size_t n, uint8_t *out) { return port_hash(256, p, n, out); }
EOS
cc -O2 -Isprintssl/c -o "$T/accel_cmp" sprintssl/tests/accel_cmp.c "$T/shim.c" sprintssl/c/aead.c sprintssl/c/hash.c sprintssl/c/accel.c "$T/aead_port.o" "$T/hash_port.o"
"$T/accel_cmp"
rm -rf "$T"
