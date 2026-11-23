# authenticode: signs a PE32+ (EFI application) with an RSA key, the way Secure Boot firmware verifies it, written in Sprint.
#
#   let signed = authenticode.sign(pe_bytes, key_pem_text, cert_pem_text)    # the same image plus an embedded PKCS#7 signature
#   authenticode.image_hash(pe_bytes)                                        # the Authenticode SHA-256 of a (signed or unsigned) PE image
#
# The signature is a PKCS#7 SignedData (SHA-256 with RSA, PKCS#1 v1.5) around an SpcIndirectDataContent that carries the image hash, in a
# WIN_CERTIFICATE appended to the file and referenced from the Certificate Table data directory. The key and the certificate come
# from outside (for example `openssl req -x509 -newkey rsa:2048 -nodes ...`); only the signing is done here.
import bn
import der
import hash

const OID_SIGNED_DATA = "1.2.840.113549.1.7.2"
const OID_SPC_INDIRECT = "1.3.6.1.4.1.311.2.1.4"
const OID_SPC_PE_IMAGE = "1.3.6.1.4.1.311.2.1.15"
const OID_SHA256 = "2.16.840.1.101.3.4.2.1"
const OID_RSA = "1.2.840.113549.1.1.1"
const OID_CONTENT_TYPE = "1.2.840.113549.1.9.3"
const OID_MESSAGE_DIGEST = "1.2.840.113549.1.9.4"

func u16(b, o):
    return b[o] | (b[o + 1] << 8)

func u32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

func put32(b, o, v):
    for i in range(4):
        b[o + i] = (v >> (8 * i)) & 255

# the Authenticode hash: everything except the checksum, the Certificate Table directory entry and the certificate data
export func image_hash(pe):
    let pe_off = u32(pe, 0x3c)
    let opt = pe_off + 24
    let checksum = opt + 64
    let cert_dir = opt + 112 + 4 * 8
    let headers = u32(pe, opt + 60)
    let nsec = u16(pe, pe_off + 6)
    let sec0 = opt + u16(pe, pe_off + 20)
    let data = []
    func add(lo, hi):
        for i in range(lo, hi):
            data.append(pe[i])
    add(0, checksum)
    add(checksum + 4, cert_dir)
    add(cert_dir + 8, headers)
    # sections in file order, then whatever trails the last one (except the certificate table)
    let secs = []
    for i in range(nsec):
        let h = sec0 + i * 40
        secs.append([u32(pe, h + 20), u32(pe, h + 16)])      # [PointerToRawData, SizeOfRawData]
    secs.sort((a, b) => a[0] - b[0])
    let end = headers
    for s in secs:
        if s[1] > 0:
            add(s[0], s[0] + s[1])
            end = s[0] + s[1]
    let cert_off = u32(pe, cert_dir)
    let stop = cert_off if cert_off != 0 else len(pe)
    if stop > end:
        add(end, stop)
    return hash.sha256(data)

# EMSA-PKCS1-v1_5 for SHA-256, `k` bytes
func pkcs1_pad(digest, k):
    let prefix = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20]
    let t = der.cat(prefix, digest)
    let em = [0x00, 0x01]
    for i in range(k - len(t) - 3):
        em.append(0xff)
    em.append(0x00)
    return der.cat(em, t)

func utf16be(s):
    let out = []
    for i in range(len(s)):
        out.append(0)
        out.append(s[i])
    return out

export func sign(pe, key_pem, cert_pem):
    let key = der.rsa_private_key(der.pem_decode(key_pem).der)
    let cert = der.pem_decode(cert_pem).der
    let ids = der.cert_ids(cert)
    let k = len(key.n)
    let sha256_alg = der.seq(der.oid(OID_SHA256), der.null_())
    # SpcIndirectDataContent { SpcAttributeTypeAndOptionalValue { spcPEImageData, SpcPeImageData }, DigestInfo { sha256, hash } }
    let moniker = der.tlv(0x80, utf16be("<<<Obsolete>>>"))
    let pe_image_data = der.seq([0x03, 0x01, 0x00], der.tlv(0xa0, der.tlv(0xa2, moniker)))
    let spc = der.seq(der.seq(der.oid(OID_SPC_PE_IMAGE), pe_image_data), der.seq(sha256_alg, der.octets(image_hash(pe))))
    # the message digest covers the content octets of that SEQUENCE (without its own tag and length)
    let spc_content = der.slice(spc, der.read(spc, 0).start, len(spc))
    let content_digest = hash.sha256(spc_content)
    let attrs = der.cat(
        der.seq(der.oid(OID_CONTENT_TYPE), der.set_of(der.oid(OID_SPC_INDIRECT))),
        der.seq(der.oid(OID_MESSAGE_DIGEST), der.set_of(der.octets(content_digest))))
    # the signature is over the attributes encoded as a SET (tag 0x31); inside SignerInfo they carry the implicit [0] tag (0xa0)
    let to_sign = hash.sha256(der.tlv(0x31, attrs))
    let em = pkcs1_pad(to_sign, k)
    let sig = bn.rsa_private(em, key, k)
    # self-check with the public exponent before anything is written
    let check = bn.rsa_public(sig, 65537, key.n)
    for i in range(k):
        if check[i] != em[i]:
            throw error("ValueError", "the RSA signature does not verify: is the key the one of the certificate (and 65537 its public exponent)?")
    let signer = der.seq(der.tlv(0x02, [0x01]), der.seq(ids.issuer, ids.serial), sha256_alg, der.tlv(0xa0, attrs),
                         der.seq(der.oid(OID_RSA), der.null_()), der.octets(sig))
    let signed_data = der.seq(der.tlv(0x02, [0x01]), der.set_of(sha256_alg), der.seq(der.oid(OID_SPC_INDIRECT), der.tlv(0xa0, spc)),
                              der.tlv(0xa0, cert), der.set_of(signer))
    let pkcs7 = der.seq(der.oid(OID_SIGNED_DATA), der.tlv(0xa0, signed_data))
    # WIN_CERTIFICATE: length, revision 0x0200, type 2 (PKCS signed data), the blob, padded to 8 bytes
    let total = 8 + len(pkcs7)
    let padded = (total + 7) // 8 * 8
    let out = []
    let pe_off = u32(pe, 0x3c)
    let cert_dir = pe_off + 24 + 112 + 4 * 8
    let base = u32(pe, cert_dir)
    let body_end = len(pe) if base == 0 else base           # re-signing replaces an old signature
    for i in range(body_end):
        out.append(pe[i])
    while len(out) % 8 != 0:
        out.append(0)
    let at = len(out)
    let w = [0, 0, 0, 0, 0, 2, 2, 0]
    put32(w, 0, padded)
    for b in w:
        out.append(b)
    for b in pkcs7:
        out.append(b)
    while len(out) < at + padded:
        out.append(0)
    put32(out, cert_dir, at)
    put32(out, cert_dir + 4, padded)
    return out
