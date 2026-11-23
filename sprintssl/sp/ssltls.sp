# ssltls: TLS 1.3 (RFC 8446) for SprintSSL: the client, and a small server (used by the tests and for serving over SprintOS).
#
#   let c = ssltls.Conn("client", transport)        # transport: send(bytes) and recv(max, ms): bytes, nil on timeout, an empty value at the end of the stream
#   c.server_name = "example.com"; c.roots = [...parsed certificates]; c.now = unix seconds (nil: dates are not checked)
#   c.handshake()                                   # throws error("ETLS", reason) on any failure
#   c.write(sslcore.from_str("GET / HTTP/1.1\r\n..."))
#   let part = c.read(4096, 5000)                   # bytes; empty at the end (close_notify); nil on timeout
#   c.close()
#
# Cipher suites: TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256. Key exchange: X25519 (no HelloRetryRequest). Certificates:
# RSA (PKCS#1 v1.5 chains, RSA-PSS handshake signatures), ECDSA P-256 / P-384, Ed25519. Not done: session resumption / 0-RTT, client certificates (an empty
# Certificate is sent when asked), TLS 1.2, post-handshake authentication.
import sslcore
import sslx509 as x509

const SUITES = {
    4865: {name: "TLS_AES_128_GCM_SHA256", hash: 256, klen: 16, aead: "gcm"},
    4866: {name: "TLS_AES_256_GCM_SHA384", hash: 384, klen: 32, aead: "gcm"},
    4867: {name: "TLS_CHACHA20_POLY1305_SHA256", hash: 256, klen: 32, aead: "chacha"}
}
const T_CCS = 20
const T_ALERT = 21
const T_HS = 22
const T_APP = 23
const H_CLIENT_HELLO = 1
const H_SERVER_HELLO = 2
const H_NEW_TICKET = 4
const H_ENC_EXT = 8
const H_CERT = 11
const H_CERT_REQ = 13
const H_CERT_VERIFY = 15
const H_FINISHED = 20
const H_KEY_UPDATE = 24
const HRR_RANDOM = "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c"

func fail(msg):
    throw error("ETLS", msg)

func u16(v):
    return [(v >> 8) & 255, v & 255]

func u24(v):
    return [(v >> 16) & 255, (v >> 8) & 255, v & 255]

func vec8(b):
    return sslcore.concat([[len(b)], b])

func vec16(b):
    return sslcore.concat([u16(len(b)), b])

func vec24(b):
    return sslcore.concat([u24(len(b)), b])

func rd16(b, o):
    return (b[o] << 8) | b[o + 1]

func rd24(b, o):
    return (b[o] << 16) | (b[o + 1] << 8) | b[o + 2]

func ext(type, body):
    return sslcore.concat([u16(type), vec16(body)])

func hs_msg(type, body):
    return sslcore.concat([[type], vec24(body)])

# HKDF-Expand-Label (RFC 8446 7.1)
func expand_label(h, secret, label, ctx, n):
    let lb = sslcore.from_str("tls13 " .. label)
    let info = sslcore.concat([u16(n), vec8(lb), vec8(ctx)])
    return sslcore.hkdf_expand(h, secret, info, n)

# a traffic direction: key, iv, sequence number
class Dir:
    let key = nil
    let iv = nil
    let seq = 0
    let aead = "gcm"
    let on = false

func xor_seq(iv, seq):
    let n = []
    for i in range(12):
        n.append(iv[i])
    for i in range(8):
        n[11 - i] = n[11 - i] ^ ((seq >> (8 * i)) & 255)
    return sslcore.concat([n])

export class Conn:
    let role = "client"
    let io = nil
    let server_name = nil
    let roots = nil
    let now = nil
    let verify = true
    let alpn = nil
    # server side
    let chain = nil              # the certificate chain to send (DER, leaf first)
    let ed_seed = nil            # the Ed25519 seed of the leaf key
    # state
    let suite = nil
    let rd = nil
    let wr = nil
    let inbuf = nil
    let hsbuf = nil
    let transcript = nil
    let app = nil                # received application data not yet read
    let eof = false
    let secret_r = nil
    let secret_w = nil
    let peer_chain = nil
    let sent_alert = false
    let negotiated_alpn = nil
    func init(self, role, io):
        self.role = role
        self.io = io
        self.rd = Dir()
        self.wr = Dir()
        self.inbuf = sslcore.concat([[]])
        self.hsbuf = sslcore.concat([[]])
        self.transcript = []
        self.app = []

    # ---- records ----
    func send_plain(self, type, body):
        self.io.send(sslcore.concat([[type, 3, 3], u16(len(body)), body]))

    func send_record(self, type, body):
        if not self.wr.on:
            self.send_plain(type, body)
            return nil
        let inner = sslcore.concat([body, [type]])
        let n = len(inner) + 16
        let hdr = [23, 3, 3, (n >> 8) & 255, n & 255]
        let nonce = xor_seq(self.wr.iv, self.wr.seq)
        self.wr.seq += 1
        let ct = nil
        if self.wr.aead == "gcm":
            ct = sslcore.gcm_seal(self.wr.key, nonce, hdr, inner)
        else:
            ct = sslcore.chacha_seal(self.wr.key, nonce, hdr, inner)
        self.io.send(sslcore.concat([hdr, ct]))

    # take n bytes from the stream (waiting up to ms in total); nil on timeout
    func need(self, n, ms):
        while len(self.inbuf) < n:
            let part = self.io.recv(16384, ms)
            if part == nil:
                return false
            if len(part) == 0:
                fail("connection closed")
            self.inbuf = sslcore.concat([self.inbuf, part])
        return true

    # the next record: [type, bytes] with encryption removed; nil on timeout
    func read_record(self, ms):
        if not self.need(5, ms):
            return nil
        let ln = rd16(self.inbuf, 3)
        if ln > 16384 + 256:
            fail("record too long")
        if not self.need(5 + ln, 5000 if ms < 5000 else ms):
            fail("timed out inside a record")
        let hdr = self.inbuf.slice(0, 5)
        let body = self.inbuf.slice(5, 5 + ln)
        self.inbuf = self.inbuf.slice(5 + ln)
        let type = hdr[0]
        if type == T_CCS:
            return [T_CCS, body]
        if not self.rd.on:
            return [type, body]
        if type != T_APP:
            fail("unencrypted record after the handshake keys")
        let nonce = xor_seq(self.rd.iv, self.rd.seq)
        self.rd.seq += 1
        let pt = nil
        if self.rd.aead == "gcm":
            pt = sslcore.gcm_open(self.rd.key, nonce, hdr, body)
        else:
            pt = sslcore.chacha_open(self.rd.key, nonce, hdr, body)
        if pt == nil:
            fail("bad record MAC")
        let i = len(pt) - 1
        while i >= 0 and pt[i] == 0:
            i -= 1
        if i < 0:
            fail("empty inner plaintext")
        return [pt[i], pt.slice(0, i)]

    # ---- handshake message reading ----
    # the next whole handshake message [type, body, raw]
    func read_hs(self, ms):
        while true:
            if len(self.hsbuf) >= 4:
                let n = rd24(self.hsbuf, 1)
                if len(self.hsbuf) >= 4 + n:
                    let raw = self.hsbuf.slice(0, 4 + n)
                    self.hsbuf = self.hsbuf.slice(4 + n)
                    return [raw[0], raw.slice(4), raw]
            let r = self.read_record(ms)
            if r == nil:
                fail("handshake timed out")
            if r[0] == T_CCS:
                continue
            if r[0] == T_ALERT:
                self.on_alert(r[1])
                fail("alert during the handshake")
            if r[0] != T_HS:
                fail("unexpected record type " .. to_string(r[0]) .. " during the handshake")
            self.hsbuf = sslcore.concat([self.hsbuf, r[1]])

    func on_alert(self, b):
        if len(b) >= 2 and b[1] == 0:
            self.eof = true
            return nil
        let d = b[1] if len(b) >= 2 else 0
        self.eof = true
        fail("alert " .. to_string(d) .. " from the peer")

    func th(self):
        return sslcore.hash(self.suite.hash, sslcore.concat(self.transcript))

    # ---- keys ----
    func set_dir(self, dir, secret):
        let h = self.suite.hash
        dir.key = expand_label(h, secret, "key", [], self.suite.klen)
        dir.iv = expand_label(h, secret, "iv", [], 12)
        dir.seq = 0
        dir.aead = self.suite.aead
        dir.on = true

    func fin_data(self, secret, thash):
        let h = self.suite.hash
        let fk = expand_label(h, secret, "finished", [], len(thash))
        return sslcore.hmac(h, fk, thash)

    # ---- the client ----
    func client_hello(self, priv):
        let rnd = sslcore.random(32)
        let sid = sslcore.random(32)
        let pub = sslcore.x25519_base(priv)
        let exts = []
        if self.server_name != nil:
            exts.append(ext(0, vec16(sslcore.concat([[0], vec16(sslcore.from_str(self.server_name))]))))
        exts.append(ext(10, vec16(u16(29))))
        exts.append(ext(13, vec16(sslcore.concat([u16(0x0804), u16(0x0805), u16(0x0403), u16(0x0503), u16(0x0807), u16(0x0401), u16(0x0501)]))))
        exts.append(ext(43, vec8([3, 4])))
        exts.append(ext(51, vec16(sslcore.concat([u16(29), vec16(pub)]))))
        if self.alpn != nil:
            let names = []
            for a in self.alpn:
                names.append(vec8(sslcore.from_str(a)))
            exts.append(ext(16, vec16(sslcore.concat(names))))
        let body = sslcore.concat([[3, 3], rnd, vec8(sid), vec16(sslcore.concat([u16(4865), u16(4866), u16(4867)])), [1, 0], vec16(sslcore.concat(exts))])
        return [hs_msg(H_CLIENT_HELLO, body), sid]

    func handshake(self):
        if self.role == "client":
            self.handshake_client()
        else:
            self.handshake_server()

    func handshake_client(self):
        let priv = sslcore.random(32)
        let ch = self.client_hello(priv)
        self.send_record(T_HS, ch[0])
        # the ServerHello is read before the hash is known: keep the raw messages until the suite is chosen
        let sh = self.read_hs(10000)
        if sh[0] != H_SERVER_HELLO:
            fail("expected a ServerHello")
        let b = sh[1]
        if len(b) < 38:
            fail("short ServerHello")
        if sslcore.hex(b.slice(2, 34)) == HRR_RANDOM:
            fail("the server asked for a HelloRetryRequest (only X25519 is offered)")
        let o = 34
        let sidlen = b[o]
        o += 1 + sidlen
        let cs = rd16(b, o)
        o += 3
        self.suite = SUITES[cs]
        if self.suite == nil:
            fail("the server chose an unsupported cipher suite")
        let elen = rd16(b, o)
        o += 2
        let end = o + elen
        let version = 0
        let share = nil
        while o < end:
            let t = rd16(b, o)
            let l = rd16(b, o + 2)
            let v = b.slice(o + 4, o + 4 + l)
            if t == 43:
                version = rd16(v, 0)
            elif t == 51:
                if rd16(v, 0) != 29 or rd16(v, 2) != 32:
                    fail("the server chose a key exchange group that was not offered")
                share = v.slice(4, 36)
            o += 4 + l
        if version != 0x0304:
            fail("the server does not speak TLS 1.3")
        if share == nil:
            fail("no key share in the ServerHello")
        self.transcript = [ch[0], sh[2]]
        let shared = sslcore.x25519(priv, share)
        if shared == nil:
            fail("bad key share")
        let h = self.suite.hash
        let hl = 32 if h == 256 else 48
        let zeros = []
        for i in range(hl):
            zeros.append(0)
        let early = sslcore.hkdf_extract(h, [], zeros)
        let empty_hash = sslcore.hash(h, [])
        let derived = expand_label(h, early, "derived", empty_hash, hl)
        let hs = sslcore.hkdf_extract(h, derived, shared)
        let t1 = self.th()
        let c_hs = expand_label(h, hs, "c hs traffic", t1, hl)
        let s_hs = expand_label(h, hs, "s hs traffic", t1, hl)
        self.set_dir(self.rd, s_hs)
        self.set_dir(self.wr, c_hs)
        # the rest of the server flight is protected: keep reading records with the handshake keys, but our own CH was plain
        self.wr.on = false
        let cert_req = false
        let msg = self.read_hs(10000)
        if msg[0] != H_ENC_EXT:
            fail("expected EncryptedExtensions")
        self.parse_enc_ext(msg[1])
        self.transcript.append(msg[2])
        msg = self.read_hs(10000)
        if msg[0] == H_CERT_REQ:
            cert_req = true
            self.transcript.append(msg[2])
            msg = self.read_hs(10000)
        if msg[0] != H_CERT:
            fail("expected Certificate")
        self.peer_chain = self.parse_certs(msg[1])
        self.transcript.append(msg[2])
        let th_cert = self.th()
        msg = self.read_hs(10000)
        if msg[0] != H_CERT_VERIFY:
            fail("expected CertificateVerify")
        self.check_cert_verify(msg[1], th_cert)
        self.transcript.append(msg[2])
        let th_cv = self.th()
        msg = self.read_hs(10000)
        if msg[0] != H_FINISHED:
            fail("expected Finished")
        if not sslcore.eq(msg[1], self.fin_data(s_hs, th_cv)):
            fail("bad Finished from the server")
        self.transcript.append(msg[2])
        let th_sf = self.th()
        # our flight
        self.wr.on = true
        if cert_req:
            let em = hs_msg(H_CERT, sslcore.concat([vec8([]), vec24([])]))
            self.send_record(T_HS, em)
            self.transcript.append(em)
        let fin = hs_msg(H_FINISHED, self.fin_data(c_hs, self.th()))
        self.send_record(T_HS, fin)
        self.transcript.append(fin)
        # application keys
        let derived2 = expand_label(h, hs, "derived", empty_hash, hl)
        let master = sslcore.hkdf_extract(h, derived2, zeros)
        self.secret_r = expand_label(h, master, "s ap traffic", th_sf, hl)
        self.secret_w = expand_label(h, master, "c ap traffic", th_sf, hl)
        self.set_dir(self.rd, self.secret_r)
        self.set_dir(self.wr, self.secret_w)
        self.hsbuf = sslcore.concat([[]])

    func parse_enc_ext(self, b):
        let o = 2
        while o + 4 <= len(b):
            let t = rd16(b, o)
            let l = rd16(b, o + 2)
            if t == 16 and l >= 4:
                let v = b.slice(o + 4, o + 4 + l)
                self.negotiated_alpn = sslcore.to_str(v.slice(3, 3 + v[2]))
            o += 4 + l

    func parse_certs(self, b):
        let ctxl = b[0]
        let o = 1 + ctxl
        let total = rd24(b, o)
        o += 3
        let end = o + total
        let chain = []
        while o < end:
            let cl = rd24(b, o)
            let der = b.slice(o + 3, o + 3 + cl)
            o += 3 + cl
            let el = rd16(b, o)
            o += 2 + el
            try:
                chain.append(x509.parse(der))
            catch e:
                fail("unreadable certificate: " .. to_string(e))
        if len(chain) == 0:
            fail("the server sent no certificate")
        if self.verify:
            if self.roots == nil:
                fail("no trusted roots were given (set roots, or verify = false)")
            let why = x509.verify_chain(chain, self.roots, self.server_name, self.now)
            if why != nil:
                fail("certificate rejected: " .. why)
        return chain

    func check_cert_verify(self, b, thash):
        let scheme = rd16(b, 0)
        let sl = rd16(b, 2)
        let sig = b.slice(4, 4 + sl)
        let ctx = sslcore.concat([sslcore.from_str("                                                                "), sslcore.from_str("TLS 1.3, server CertificateVerify"), [0], thash])
        let leaf = self.peer_chain[0]
        let ok = false
        if scheme == 0x0804:
            ok = x509.verify_with(leaf, "rsa-pss", 256, ctx, sig)
        elif scheme == 0x0805:
            ok = x509.verify_with(leaf, "rsa-pss", 384, ctx, sig)
        elif scheme == 0x0403:
            ok = leaf.key_curve == "1.2.840.10045.3.1.7" and x509.verify_with(leaf, "ecdsa", 256, ctx, sig)
        elif scheme == 0x0503:
            ok = leaf.key_curve == "1.3.132.0.34" and x509.verify_with(leaf, "ecdsa", 384, ctx, sig)
        elif scheme == 0x0807:
            ok = x509.verify_with(leaf, "ed25519", 0, ctx, sig)
        else:
            fail("unsupported signature scheme " .. to_string(scheme))
        if not ok:
            fail("bad CertificateVerify signature")

    # ---- the server ----
    func handshake_server(self):
        let msg = self.read_hs(15000)
        if msg[0] != H_CLIENT_HELLO:
            fail("expected a ClientHello")
        let b = msg[1]
        let o = 34
        let sid = b.slice(o + 1, o + 1 + b[o])
        o += 1 + b[o]
        let csl = rd16(b, o)
        let offered = []
        for i in range(csl // 2):
            offered.append(rd16(b, o + 2 + 2 * i))
        o += 2 + csl
        o += 1 + b[o]
        let el = rd16(b, o)
        o += 2
        let end = o + el
        let share = nil
        let tls13 = false
        let sigalgs = []
        while o < end:
            let t = rd16(b, o)
            let l = rd16(b, o + 2)
            let v = b.slice(o + 4, o + 4 + l)
            if t == 43:
                for i in range(1, len(v), 2):
                    if rd16(v, i) == 0x0304:
                        tls13 = true
            elif t == 51:
                let p = 2
                while p + 4 <= len(v):
                    let g = rd16(v, p)
                    let kl = rd16(v, p + 2)
                    if g == 29 and kl == 32:
                        share = v.slice(p + 4, p + 4 + kl)
                    p += 4 + kl
            elif t == 13:
                for i in range(2, len(v), 2):
                    sigalgs.append(rd16(v, i))
            o += 4 + l
        if not tls13 or share == nil:
            fail("the client offers no TLS 1.3 with X25519")
        if not sigalgs.contains(0x0807):
            fail("the client does not accept Ed25519 signatures")
        let cs = 0
        for s in [4865, 4867, 4866]:
            if offered.contains(s):
                cs = s
                break
        if cs == 0:
            fail("no common cipher suite")
        self.suite = SUITES[cs]
        let priv = sslcore.random(32)
        let pub = sslcore.x25519_base(priv)
        let shared = sslcore.x25519(priv, share)
        if shared == nil:
            fail("bad key share")
        let sh_body = sslcore.concat([[3, 3], sslcore.random(32), vec8(sid), u16(cs), [0], vec16(sslcore.concat([ext(43, u16(0x0304)), ext(51, sslcore.concat([u16(29), vec16(pub)]))]))])
        let sh = hs_msg(H_SERVER_HELLO, sh_body)
        self.transcript = [msg[2], sh]
        self.send_record(T_HS, sh)
        self.send_plain(T_CCS, [1])
        let h = self.suite.hash
        let hl = 32 if h == 256 else 48
        let zeros = []
        for i in range(hl):
            zeros.append(0)
        let early = sslcore.hkdf_extract(h, [], zeros)
        let empty_hash = sslcore.hash(h, [])
        let hs = sslcore.hkdf_extract(h, expand_label(h, early, "derived", empty_hash, hl), shared)
        let t1 = self.th()
        let c_hs = expand_label(h, hs, "c hs traffic", t1, hl)
        let s_hs = expand_label(h, hs, "s hs traffic", t1, hl)
        self.set_dir(self.wr, s_hs)
        let ee = hs_msg(H_ENC_EXT, vec16([]))
        self.send_record(T_HS, ee)
        self.transcript.append(ee)
        let entries = []
        for der in self.chain:
            entries.append(sslcore.concat([vec24(der), vec16([])]))
        let cert = hs_msg(H_CERT, sslcore.concat([vec8([]), vec24(sslcore.concat(entries))]))
        self.send_record(T_HS, cert)
        self.transcript.append(cert)
        let ctx = sslcore.concat([sslcore.from_str("                                                                "), sslcore.from_str("TLS 1.3, server CertificateVerify"), [0], self.th()])
        let sig = sslcore.ed25519_sign(self.ed_seed, ctx)
        let cv = hs_msg(H_CERT_VERIFY, sslcore.concat([u16(0x0807), vec16(sig)]))
        self.send_record(T_HS, cv)
        self.transcript.append(cv)
        let fin = hs_msg(H_FINISHED, self.fin_data(s_hs, self.th()))
        self.send_record(T_HS, fin)
        self.transcript.append(fin)
        let th_sf = self.th()
        let derived2 = expand_label(h, hs, "derived", empty_hash, hl)
        let master = sslcore.hkdf_extract(h, derived2, zeros)
        # read the client's Finished with the handshake keys
        self.set_dir(self.rd, c_hs)
        let m2 = self.read_hs(15000)
        if m2[0] != H_FINISHED:
            fail("expected the client's Finished")
        if not sslcore.eq(m2[1], self.fin_data(c_hs, th_sf)):
            fail("bad Finished from the client")
        self.secret_w = expand_label(h, master, "s ap traffic", th_sf, hl)
        self.secret_r = expand_label(h, master, "c ap traffic", th_sf, hl)
        self.set_dir(self.wr, self.secret_w)
        self.set_dir(self.rd, self.secret_r)
        self.hsbuf = sslcore.concat([[]])

    # ---- application data ----
    func write(self, data):
        let o = 0
        while o < len(data):
            let n = len(data) - o
            if n > 16384:
                n = 16384
            self.send_record(T_APP, data.slice(o, o + n))
            o += n
        return len(data)

    # up to max bytes; empty when the peer closed; nil when nothing came within ms
    func read(self, max, ms):
        while len(self.app) == 0:
            if self.eof:
                return sslcore.concat([[]])
            let r = self.read_record(ms)
            if r == nil:
                return nil
            if r[0] == T_APP:
                self.app = r[1]
            elif r[0] == T_ALERT:
                self.on_alert(r[1])
            elif r[0] == T_HS:
                self.post_handshake(r[1])
            elif r[0] == T_CCS:
                continue
            else:
                fail("unexpected record type")
        let n = max if max < len(self.app) else len(self.app)
        let out = self.app.slice(0, n)
        self.app = self.app.slice(n)
        return out

    func post_handshake(self, b):
        let o = 0
        while o + 4 <= len(b):
            let t = b[o]
            let l = rd24(b, o + 1)
            if t == H_KEY_UPDATE:
                let h = self.suite.hash
                let hl = 32 if h == 256 else 48
                self.secret_r = expand_label(h, self.secret_r, "traffic upd", [], hl)
                self.set_dir(self.rd, self.secret_r)
                if b[o + 4] == 1:
                    self.send_record(T_HS, hs_msg(H_KEY_UPDATE, [0]))
                    self.secret_w = expand_label(h, self.secret_w, "traffic upd", [], hl)
                    self.set_dir(self.wr, self.secret_w)
            o += 4 + l

    func close(self):
        if not self.sent_alert:
            self.sent_alert = true
            try:
                self.send_record(T_ALERT, [1, 0])
            catch e:
                pass
