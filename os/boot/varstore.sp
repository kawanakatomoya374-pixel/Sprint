# varstore: UEFI Secure Boot variables, written by Sprint into an edk2 / OVMF variable store (the *_VARS.fd file of a QEMU firmware).
#
#   let esl = varstore.esl_x509(cert_der, owner_guid)                 # an EFI_SIGNATURE_LIST holding one certificate
#   let vars = varstore.enroll(template_bytes, {pk: cert, kek: cert, db: [cert, ...]}, owner_guid)
#   fs.write_bytes("vars.fd", vars)                                    # QEMU: -drive if=pflash,unit=1,file=vars.fd
#
# The store holds AUTHENTICATED_VARIABLE_HEADER records (StartId 0x55AA, state 0x3f, attributes, time stamp, name, vendor GUID, data) from the
# first free byte after the store header; enrolling appends PK, KEK and db (time-based authenticated variables carrying the ESL directly, the way
# the firmware keeps them), SecureBootEnable = 1 and CustomMode = 0.

export const GUID_X509 = [0xa1, 0x59, 0xc0, 0xa5, 0xe4, 0x94, 0xa7, 0x4a, 0x87, 0xb5, 0xab, 0x15, 0x5c, 0x2b, 0xf0, 0x72]
export const GUID_GLOBAL = [0x61, 0xdf, 0xe4, 0x8b, 0xca, 0x93, 0xd2, 0x11, 0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c]
export const GUID_DB = [0xcb, 0xb2, 0x19, 0xd7, 0x3a, 0x3d, 0x96, 0x45, 0xa3, 0xbc, 0xda, 0xd0, 0x0e, 0x67, 0x65, 0x6f]
const GUID_SBENABLE = [0xc7, 0x0b, 0xa3, 0xf0, 0x08, 0xaf, 0x56, 0x45, 0x99, 0xc4, 0x00, 0x10, 0x09, 0xc9, 0x3a, 0x44]
const GUID_CUSTOM = [0x0c, 0xec, 0x76, 0xc0, 0x28, 0x70, 0x99, 0x43, 0xa0, 0x72, 0x71, 0xee, 0x5c, 0x44, 0x8b, 0x9f]

const ATTR_NV_BS = 3                 # non-volatile, boot service
const ATTR_AUTH = 0x27               # + runtime access + time-based authenticated write

func put16(b, o, v):
    b[o] = v & 255
    b[o + 1] = (v >> 8) & 255

func put32(b, o, v):
    for i in range(4):
        b[o + i] = (v >> (8 * i)) & 255

func get16(b, o):
    return b[o] | (b[o + 1] << 8)

func get32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

export func guid_bytes(text):                   # "11111111-2222-3333-4444-555555555555" -> the 16 bytes in memory order
    let h = text.replace("-", "")
    let D = "0123456789abcdef"
    let raw = []
    for i in range(16):
        raw.append(D.find(h.slice(2 * i, 2 * i + 1).lower()) * 16 + D.find(h.slice(2 * i + 1, 2 * i + 2).lower()))
    return [raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]]

export func esl_x509(cert, owner):
    let sigsize = 16 + len(cert)
    let out = []
    for b in GUID_X509:
        out.append(b)
    let hdr = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    put32(hdr, 0, 28 + sigsize)
    put32(hdr, 4, 0)
    put32(hdr, 8, sigsize)
    for b in hdr:
        out.append(b)
    for b in owner:
        out.append(b)
    for b in cert:
        out.append(b)
    return out

func efi_time():
    let t = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    put16(t, 0, 2026)
    t[2] = 1
    t[3] = 1
    return t

# append one variable at the first free position of the store
func add_var(img, name, guid, attrs, data, time):
    let p = 0x64
    while p + 60 < len(img) and get16(img, p) == 0x55aa:
        let ns = get32(img, p + 36)
        let ds = get32(img, p + 40)
        p = (p + 60 + ns + ds + 3) & -4
    let end = 0x48 + get32(img, 0x58)
    let ns = 2 * (len(name) + 1)
    if p + 60 + ns + len(data) > end:
        throw error("MemoryError", "the variable store is full")
    for i in range(p, p + 60 + ns + len(data)):
        if img[i] != 0xff:
            throw error("ValueError", "the variable store is not empty where the next variable goes (is this an edk2 store?)")
    put16(img, p, 0x55aa)
    img[p + 2] = 0x3f
    img[p + 3] = 0
    put32(img, p + 4, attrs)
    for i in range(8):
        img[p + 8 + i] = 0
    for i in range(16):
        img[p + 16 + i] = time[i]
    put32(img, p + 32, 0)
    put32(img, p + 36, ns)
    put32(img, p + 40, len(data))
    for i in range(16):
        img[p + 44 + i] = guid[i]
    for i in range(len(name)):
        img[p + 60 + 2 * i] = name[i]
        img[p + 61 + 2 * i] = 0
    img[p + 60 + 2 * len(name)] = 0
    img[p + 61 + 2 * len(name)] = 0
    for i in range(len(data)):
        img[p + 60 + ns + i] = data[i]

export func enroll(template, keys, owner):
    let img = []
    for b in template:
        img.append(b)
    if len(img) < 0x1000 or get32(img, 0x28) != 0x4856465f:      # "_FVH"
        throw error("ValueError", "not an edk2 variable store (firmware volume signature missing)")
    let t = efi_time()
    add_var(img, "CustomMode", GUID_CUSTOM, ATTR_NV_BS, [0], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    add_var(img, "KEK", GUID_GLOBAL, ATTR_AUTH, esl_x509(keys.kek, owner), t)
    add_var(img, "PK", GUID_GLOBAL, ATTR_AUTH, esl_x509(keys.pk, owner), t)
    add_var(img, "SecureBootEnable", GUID_SBENABLE, ATTR_NV_BS, [1], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    let db = []
    for c in keys.db:
        for b in esl_x509(c, owner):
            db.append(b)
    add_var(img, "db", GUID_DB, ATTR_AUTH, db, t)
    return img
