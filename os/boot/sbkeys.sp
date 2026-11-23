# Secure Boot keys, made entirely in Sprint.
#
#   sprint run --allow-random --allow-write=DIR os/boot/sbkeys.sp gen NAME [--cn "Common Name"] [--bits 2048] [--serial HEX]
#       NAME.key   the private key, PKCS#8 PEM (what `openssl genrsa` writes)
#       NAME.crt   the self-signed certificate, PEM        NAME.der   the same, DER
# (more subcommands: see the end of this file)
import der
import fs
import random
import sys
import varstore
import x509
import bn

func arg(name, default):
    for i in range(len(sys.args) - 1):
        if sys.args[i] == name:
            return sys.args[i + 1]
    return default

let cmd = sys.args[0] if len(sys.args) > 0 else ""
if cmd == "gen":
    let name = sys.args[1]
    let bits = to_int(arg("--bits", "2048"))
    let cn = arg("--cn", name)
    let key = bn.rsa_generate(bits, n => random.bytes(n))
    let serial = random.bytes(16)
    let cert = x509.self_signed(key, cn, serial, arg("--not-before", "20260101000000Z"), arg("--not-after", "20360101000000Z"))
    fs.write_file(name .. ".key", der.pem_encode("PRIVATE KEY", der.rsa_pkcs8(key)))
    fs.write_file(name .. ".crt", der.pem_encode("CERTIFICATE", cert))
    fs.write_bytes(name .. ".der", cert)
    print("generated " .. to_string(bits) .. "-bit RSA key and certificate: " .. name .. ".key " .. name .. ".crt " .. name .. ".der")

# ---- enroll: write PK / KEK / db into an OVMF variable store ----------------------------------------------------------------------------
#   sprint run --allow-read=DIR --allow-write=DIR os/boot/sbkeys.sp enroll TEMPLATE_VARS.fd OUT_VARS.fd --pk A.crt [--kek B.crt] [--db C.crt ...] [--guid OWNER-GUID]
# (--kek and --db default to the PK certificate)
if cmd == "enroll":
    let tmpl = fs.read_bytes(sys.args[1])
    let pk = nil
    let kek = nil
    let dbs = []
    let i = 3
    let owner = varstore.guid_bytes("53707269-6e74-4f53-8000-5365637572ff")
    while i < len(sys.args):
        let a = sys.args[i]
        if a == "--pk":
            pk = der.pem_decode(fs.read_file(sys.args[i + 1])).der
        elif a == "--kek":
            kek = der.pem_decode(fs.read_file(sys.args[i + 1])).der
        elif a == "--db":
            dbs.append(der.pem_decode(fs.read_file(sys.args[i + 1])).der)
        elif a == "--guid":
            owner = varstore.guid_bytes(sys.args[i + 1])
        i += 2
    if pk == nil:
        throw error("ValueError", "enroll needs --pk CERT.crt")
    if kek == nil:
        kek = pk
    if len(dbs) == 0:
        dbs.append(pk)
    fs.write_bytes(sys.args[2], varstore.enroll(tmpl, {pk: pk, kek: kek, db: dbs}, owner))
    print("enrolled PK, KEK and " .. to_string(len(dbs)) .. " db certificate(s) into " .. sys.args[2])
