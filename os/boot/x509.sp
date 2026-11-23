# x509: a self-signed X.509 v3 certificate for an RSA key (SHA-256 with RSA, basicConstraints CA:TRUE, a subject key identifier).
#   let der_bytes = x509.self_signed(key, "Sprint OS signing key", serial_bytes, "20260101000000Z", "20360101000000Z")
import bn
import der
import hash

const OID_SHA256_RSA = "1.2.840.113549.1.1.11"

func name_of(cn):
    return der.seq(der.set_of(der.seq(der.oid("2.5.4.3"), der.utf8(cn))))

export func self_signed(key, cn, serial, not_before, not_after):
    let alg = der.seq(der.oid(OID_SHA256_RSA), der.null_())
    let spki = der.seq(der.seq(der.oid("1.2.840.113549.1.1.1"), der.null_()), der.bit_string(der.rsa_public_key(key)))
    let ski = der.slice(hash.sha256(der.rsa_public_key(key)), 0, 20)
    let exts = der.tlv(0xa3, der.seq(
        der.seq(der.oid("2.5.29.14"), der.octets(der.octets(ski))),
        der.seq(der.oid("2.5.29.19"), der.bool_true(), der.octets(der.seq(der.bool_true())))))
    # the serial number must be a positive INTEGER: clear the top bit
    let sn = []
    for b in serial:
        sn.append(b)
    sn[0] = sn[0] & 0x7f
    if sn[0] == 0:
        sn[0] = 1
    let tbs = der.seq(der.tlv(0xa0, der.tlv(0x02, [2])), der.integer_be(sn), alg, name_of(cn), der.seq(der.time_of(not_before), der.time_of(not_after)),
                      name_of(cn), spki, exts)
    # EMSA-PKCS1-v1_5 / SHA-256, then the private operation
    let k = len(key.n)
    let t = der.cat([0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20], hash.sha256(tbs))
    let em = [0x00, 0x01]
    for i in range(k - len(t) - 3):
        em.append(0xff)
    em.append(0x00)
    em = der.cat(em, t)
    let sig = bn.rsa_private(em, key, k)
    return der.seq(tbs, alg, der.bit_string(sig))
