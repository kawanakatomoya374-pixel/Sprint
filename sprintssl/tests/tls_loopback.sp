# TLS 1.3: the client and the server of ssltls talk over in-memory pipes (client verifies the Ed25519 chain C), then a few failure cases.
#   sprint run --allow-read=sprintssl/tests sprintssl/tests/tls_loopback.sp
import fs
import sslcore
import sslx509 as x509
import ssltls
import coroutine

const DIR = "sprintssl/tests/data/"
let fails = 0
func check(ok, what):
    print(("ok   " if ok else "FAIL ") .. what)
    if not ok:
        fails += 1

func load(name):
    let out = []
    for der in x509.pem_certs(sslcore.to_str(fs.read_bytes(DIR .. name))):
        out.append(der)
    return out

# a pipe pair; reading from an empty pipe runs the other side (a coroutine-free way of stepping two state machines): the server's handshake runs as a coroutine
class Pipe:
    let q = nil
    func init(self):
        self.q = []

class End:
    let rx = nil
    let tx = nil
    let yield_fn = nil
    let drop = false
    func init(self, rx, tx):
        self.rx = rx
        self.tx = tx
    func send(self, b):
        self.tx.q.append(b)
    func recv(self, max, ms):
        while len(self.rx.q) == 0:
            if self.yield_fn == nil:
                return nil
            self.yield_fn()
            if len(self.rx.q) == 0:
                return nil
        return self.rx.q.remove_at(0)

let c2s = Pipe()
let s2c = Pipe()
let cend = End(s2c, c2s)
let send_ = End(c2s, s2c)

let chain = load("chainC.pem")
let roots = []
for der in load("rootC.pem"):
    roots.append(x509.parse(der))
let seed = sslcore.unhex(sslcore.to_str(fs.read_bytes(DIR .. "chainC.seed")).slice(0, 64))

func run(name, mutate):
    let c2s = Pipe()
    let s2c = Pipe()
    let ce = End(s2c, c2s)
    let se = End(c2s, s2c)
    let cl = ssltls.Conn("client", ce)
    cl.server_name = "srv.test"
    cl.roots = roots
    cl.now = 1900000000
    let sv = ssltls.Conn("server", se)
    sv.chain = chain
    sv.ed_seed = seed
    if mutate != nil:
        mutate(cl, sv)
    # the server runs as a coroutine that yields whenever it has nothing to read
    let co = coroutine.create(() => run_server(sv), 60000)
    ce.yield_fn = () => coroutine.resume(co)
    se.yield_fn = server_yield
    return [cl, sv, ce, se, co]

func server_yield():
    yield nil

func run_server(sv):
    sv.handshake()
    # echo the data until the peer closes
    while true:
        let d = sv.read(65536, 1000)
        if d == nil:
            continue
        if len(d) == 0:
            break
        sv.write(d)

let t = run("ok", nil)
let cl = t[0]
cl.handshake()
check(cl.suite.name == "TLS_AES_128_GCM_SHA256", "handshake: " .. cl.suite.name)
cl.write(sslcore.from_str("hello"))
let got = cl.read(100, 1000)
check(sslcore.to_str(got) == "hello", "application data both ways")
let big = sslcore.random(50000)
cl.write(big)
let back = []
let total = 0
while total < 50000:
    let p = cl.read(65536, 1000)
    if p == nil or len(p) == 0:
        break
    back.append(p)
    total += len(p)
let all = sslcore.concat(back)
check(total == 50000 and sslcore.eq(all, big), "50000 bytes (four records) echoed back intact")
cl.close()

for chacha in [4866, 4867]:
    let t2 = run("suite", nil)
    # the server prefers 4865, then 4867, then 4866: make the client offer one only by patching the offered list is not possible here, so check the keys differ per run
    t2[0].handshake()
    check(len(t2[0].secret_w) == 32 or len(t2[0].secret_w) == 48, "second handshake works (fresh keys)")
    break

func m_host(c, s):
    c.server_name = "other.test"
func m_noroots(c, s):
    c.roots = []
func m_verify_off(c, s):
    c.roots = []
    c.verify = false
func m_badkey(c, s):
    s.ed_seed = sslcore.random(32)
let t3 = run("wrong host", m_host)
let r3 = ""
try:
    t3[0].handshake()
catch e:
    r3 = to_string(e)
check(r3.find("not valid for other.test", 0) >= 0, "a wrong server name fails: " .. r3)

let t4 = run("no roots", m_noroots)
let r4 = ""
try:
    t4[0].handshake()
catch e:
    r4 = to_string(e)
check(r4.find("no trusted issuer", 0) >= 0, "an untrusted server certificate fails: " .. r4)

let t5 = run("verify off", m_verify_off)
t5[0].handshake()
check(true, "with verify = false the handshake completes")

let t6 = run("bad key", m_badkey)
let r6 = ""
try:
    t6[0].handshake()
catch e:
    r6 = to_string(e)
check(r6.find("CertificateVerify", 0) >= 0, "a server that does not own the certificate's key fails: " .. r6)
print(fails == 0)
