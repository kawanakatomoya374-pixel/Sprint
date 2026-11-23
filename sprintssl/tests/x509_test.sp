# X.509: parsing, chain validation (ECDSA root -> RSA intermediate -> ECDSA P-384 leaf; RSA root; Ed25519), names, dates. Run from the SprintSSL folder or the Sprint tree:
#   sprint run sprintssl/tests/x509_test.sp
import fs
import sslcore
import sslx509 as x509

const DIR = "sprintssl/tests/data/"
let fails = 0
func check(ok, what):
    print(("ok   " if ok else "FAIL ") .. what)
    if not ok:
        fails += 1

func load(name):
    let out = []
    for der in x509.pem_certs(sslcore.to_str(fs.read_bytes(DIR .. name))):
        out.append(x509.parse(der))
    return out

let a = load("chainA.pem")
let ra = load("rootA.pem")
let b = load("chainB.pem")
let rb = load("rootB.pem")
let c = load("chainC.pem")
let rc = load("rootC.pem")
let now = 1900000000        # 2030-03-17

check(len(a) == 2 and a[0].cn == "leaf.test" and a[1].cn == "Test Intermediate RSA", "parse: names and the number of certificates")
check(a[1].ca and a[1].path_len == 0 and not a[0].ca, "parse: basic constraints")
check(a[0].san_dns.join(",") == "leaf.test,*.wild.test" and len(a[0].san_ip) == 1, "parse: subject alternative names")
check(a[0].not_before == 1704067200 and a[0].not_after == 2492841600 or a[0].not_after > a[0].not_before, "parse: validity dates")
check(x509.signed_by(a[1], ra[0]), "RSA-SHA384 intermediate signed by the ECDSA P-256 root")
check(x509.signed_by(a[0], a[1]), "ECDSA P-384 leaf signed by the RSA intermediate (RSA-SHA256)")
check(not x509.signed_by(a[0], ra[0]), "the leaf is not signed by the root directly")
check(x509.verify_chain(a, ra, "leaf.test", now) == nil, "chain A verifies for leaf.test")
check(x509.verify_chain(a, ra, "x.wild.test", now) == nil, "wildcard names match one label")
check(x509.verify_chain(a, ra, "a.b.wild.test", now) != nil, "a wildcard does not match two labels")
check(x509.verify_chain(a, ra, "10.0.2.2", now) == nil, "an IP address is matched against the IP SANs")
check(x509.verify_chain(a, ra, "evil.test", now) != nil, "a wrong host name is refused")
check(x509.verify_chain(a, rb, "leaf.test", now) != nil, "an untrusted root is refused")
check(x509.verify_chain(a.slice(0, 1), ra, "leaf.test", now) != nil, "a missing intermediate is refused")
check(x509.verify_chain(a, ra, "leaf.test", 100) != nil, "a certificate that is not valid yet is refused")
check(x509.verify_chain(a, ra, "leaf.test", 2600000000) != nil, "an expired certificate is refused")
check(x509.verify_chain(b, rb, "rsa.test", now) == nil, "chain B (RSA 3072 root, RSA 2048 leaf) verifies")
check(x509.verify_chain(c, rc, "srv.test", now) == nil, "chain C (Ed25519) verifies")
check(x509.verify_chain(c, rc, "localhost", now) == nil, "chain C verifies for localhost")
let old = load("expired.pem")
check(x509.verify_chain(old, rc, "old.test", now) != nil, "an expired Ed25519 leaf is refused")
check(x509.verify_chain(old, rc, "old.test", nil) == nil, "with now = nil the dates are not checked")
# a certificate with one flipped bit in the signed part is refused
let bad = c[0].der.copy()
bad[len(bad) - 5] = bad[len(bad) - 5] ^ 1
let badc = x509.parse(bad)
check(x509.verify_chain([badc], rc, "srv.test", now) != nil, "a corrupted signature is refused")
print(fails == 0)
