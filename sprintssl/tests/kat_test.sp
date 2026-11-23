# Known-answer tests for the sslcore primitives (RFC 6234, 4231, 5869, 8439, 7748, 8032; NIST GCM test case 4). Run from the Sprint tree:
#   sprint run sprintssl/tests/kat_test.sp
import sslcore

let fails = 0
func check(ok, what):
    print(("ok   " if ok else "FAIL ") .. what)
    if not ok:
        fails += 1

func h(s):
    return sslcore.unhex(s)

func hx(b):
    return sslcore.hex(b)

let abc = sslcore.from_str("abc")
check(hx(sslcore.hash(256, abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc")
check(hx(sslcore.hash(384, abc)) == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "SHA-384 of abc")
check(hx(sslcore.hash(512, abc)) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512 of abc")
let big = []
for i in range(1000):
    big.append(97)
check(hx(sslcore.hash(256, big)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3", "SHA-256 of 1000 x 'a' (several blocks, an array argument)")
check(hx(sslcore.hmac(256, sslcore.from_str("Jefe"), sslcore.from_str("what do ya want for nothing?"))) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA-256 (RFC 4231 case 2)")
let ikm = h("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
let salt = h("000102030405060708090a0b0c")
let info = h("f0f1f2f3f4f5f6f7f8f9")
let prk = sslcore.hkdf_extract(256, salt, ikm)
check(hx(prk) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", "HKDF-Extract (RFC 5869 test 1)")
check(hx(sslcore.hkdf_expand(256, prk, info, 42)) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "HKDF-Expand (RFC 5869 test 1)")

# AES-128-GCM, NIST test case 4
let gk = h("feffe9928665731c6d6a8f9467308308")
let gn = h("cafebabefacedbaddecaf888")
let gp = h("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
let ga = h("feedfacedeadbeeffeedfacedeadbeefabaddad2")
let gc = sslcore.gcm_seal(gk, gn, ga, gp)
check(hx(gc) == "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e0915bc94fbc3221a5db94fae95ae7121a47", "AES-128-GCM seal (NIST test case 4)")
check(hx(sslcore.gcm_open(gk, gn, ga, gc)) == hx(gp), "AES-128-GCM open")
let tampered = gc.copy()
tampered[3] = tampered[3] ^ 1
check(sslcore.gcm_open(gk, gn, ga, tampered) == nil, "AES-GCM refuses a changed ciphertext")

# ChaCha20-Poly1305, RFC 8439 2.8.2
let ck = h("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
let cn = h("070000004041424344454647")
let ca = h("50515253c0c1c2c3c4c5c6c7")
let cp = sslcore.from_str("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
let cc = sslcore.chacha_seal(ck, cn, ca, cp)
check(hx(cc.slice(0, 16)) == "d31a8d34648e60db7b86afbc53ef7ec2" and hx(cc.slice(len(cc) - 16)) == "1ae10b594f09e26a7e902ecbd0600691", "ChaCha20-Poly1305 seal (RFC 8439)")
check(sslcore.to_str(sslcore.chacha_open(ck, cn, ca, cc)) == sslcore.to_str(cp), "ChaCha20-Poly1305 open")

# X25519, RFC 7748 5.2
check(hx(sslcore.x25519(h("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"), h("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))) == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", "X25519 (RFC 7748 5.2)")
let a_priv = h("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
let b_priv = h("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
let a_pub = sslcore.x25519_base(a_priv)
let b_pub = sslcore.x25519_base(b_priv)
check(hx(sslcore.x25519(a_priv, b_pub)) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742" and hx(sslcore.x25519(b_priv, a_pub)) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "X25519 key agreement (RFC 7748 6.1)")

# Ed25519, RFC 8032 test 1 and 2
let seed1 = h("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
check(hx(sslcore.ed25519_pub(seed1)) == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "Ed25519 public key (RFC 8032 test 1)")
let sig1 = sslcore.ed25519_sign(seed1, [])
check(hx(sig1) == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", "Ed25519 signature of the empty message")
check(sslcore.ed25519_verify(sig1, [], sslcore.ed25519_pub(seed1)), "Ed25519 verify")
check(not sslcore.ed25519_verify(sig1, [1], sslcore.ed25519_pub(seed1)), "Ed25519 refuses another message")
let seed2 = h("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
let sig2 = sslcore.ed25519_sign(seed2, h("72"))
check(hx(sig2) == "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00", "Ed25519 signature (RFC 8032 test 2)")

# ECDH on P-256 against known public keys: d = 1 gives the generator
let one = h("0000000000000000000000000000000000000000000000000000000000000001")
let gpub = sslcore.ec_pub(256, one)
check(hx(gpub) == "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5", "P-256: 1 * G is the generator")
let two = h("0000000000000000000000000000000000000000000000000000000000000002")
check(hx(sslcore.ec_pub(256, two)) == "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1", "P-256: 2 * G")
check(hx(sslcore.ecdh(256, gpub, two)).slice(0, 64) == "7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978", "P-256 ECDH: the shared x coordinate")
let r = sslcore.random(64)
check(len(r) == 64 and not sslcore.eq(r, sslcore.random(64)), "random: 64 bytes, two calls differ")
print(fails == 0)
