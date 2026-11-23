# sprintssl: the front door of SprintSSL: TLS 1.3 clients over any transport, roots, and a small HTTPS client.
#
#   import sprintssl
#   let roots = sprintssl.load_roots(pem_text)                      # trusted CA certificates (PEM text, any number)
#   let t = sprintssl.TcpTransport(stack, tcp_conn)                 # netstack's TCP connection as a transport (anything with send(bytes) / recv(max, ms) works)
#   let conn = sprintssl.connect(t, "example.com", roots, now)      # handshake; throws error("ETLS", why)
#   let r = sprintssl.http_get(conn, "example.com", "/index.html")  # {status, headers, body}  (body: typed.u8)
#   conn.close()
#
# `now` is the current time in seconds since 1970 (see unix_time); nil skips the certificate date checks.
import sslcore
import sslx509 as x509
import sslasn1 as asn1
import ssltls
import typed

export func load_roots(pem_text):
    let out = []
    for der in x509.pem_certs(pem_text):
        try:
            out.append(x509.parse(der))
        catch e:
            pass         # a certificate this library cannot read (e.g. a P-521 root) is skipped
    return out

# seconds since 1970 for [year, month, day, hour, minute, second] (UTC)
export func unix_time(t):
    return asn1.days_from_civil(t[0], t[1], t[2]) * 86400 + t[3] * 3600 + t[4] * 60 + t[5]

# netstack's TCP connection as a TLS transport
export class TcpTransport:
    let st = nil
    let c = nil
    func init(self, st, c):
        self.st = st
        self.c = c
    func send(self, b):
        self.st.tcp_send(self.c, b.to_array())
        self.st.tcp_flush(self.c, 10000)
    func recv(self, max, ms):
        let p = self.st.tcp_recv(self.c, max, ms)
        if p == nil:
            return nil
        return typed.u8(p)
    func close(self):
        self.st.tcp_close(self.c)

export func connect(transport, host, roots, now, alpn = nil):
    let c = ssltls.Conn("client", transport)
    c.server_name = host
    c.roots = roots
    c.now = now
    c.alpn = alpn
    c.handshake()
    return c

func find_bytes(b, pat, start):
    let n = len(pat)
    for i in range(start, len(b) - n + 1):
        let ok = true
        for j in range(n):
            if b[i + j] != pat[j]:
                ok = false
                break
        if ok:
            return i
    return -1

func hex_val(s):
    let v = 0
    for i in range(len(s)):
        let c = s[i]
        if c >= 48 and c <= 57:
            v = v * 16 + c - 48
        elif c >= 97 and c <= 102:
            v = v * 16 + c - 87
        elif c >= 65 and c <= 70:
            v = v * 16 + c - 55
        else:
            break
    return v

# a GET request on an open connection; reads the whole answer (Content-Length, chunked or until the server closes)
export func http_get(conn, host, path, timeout = 10000):
    conn.write(sslcore.from_str("GET " .. path .. " HTTP/1.1\r\nHost: " .. host .. "\r\nUser-Agent: SprintSSL\r\nAccept: */*\r\nConnection: close\r\n\r\n"))
    let buf = sslcore.concat([[]])
    let sep = -1
    while sep < 0:
        let p = conn.read(16384, timeout)
        if p == nil or len(p) == 0:
            break
        buf = sslcore.concat([buf, p])
        sep = find_bytes(buf, [13, 10, 13, 10], 0)
    if sep < 0:
        throw error("EHTTP", "no complete response header")
    let head = sslcore.to_str(buf.slice(0, sep)).split("\r\n")
    let status = to_int(head[0].split(" ")[1])
    let headers = {}
    for i in range(1, len(head)):
        let k = head[i].find(":", 0)
        if k > 0:
            headers[head[i].slice(0, k).lower()] = head[i].slice(k + 1).trim()
    let body = buf.slice(sep + 4)
    let parts = []
    if headers["transfer-encoding"] == "chunked":
        # read until the terminating zero chunk
        let out = []
        let pos = 0
        while true:
            let eol = find_bytes(body, [13, 10], pos)
            while eol < 0:
                let p = conn.read(16384, timeout)
                if p == nil or len(p) == 0:
                    throw error("EHTTP", "truncated chunked body")
                body = sslcore.concat([body, p])
                eol = find_bytes(body, [13, 10], pos)
            let size = hex_val(sslcore.to_str(body.slice(pos, eol)))
            if size == 0:
                break
            while len(body) < eol + 2 + size + 2:
                let p = conn.read(16384, timeout)
                if p == nil or len(p) == 0:
                    throw error("EHTTP", "truncated chunk")
                body = sslcore.concat([body, p])
            out.append(body.slice(eol + 2, eol + 2 + size))
            pos = eol + 2 + size + 2
        body = sslcore.concat(out)
    elif headers["content-length"] != nil:
        let want = to_int(headers["content-length"])
        while len(body) < want:
            let p = conn.read(16384, timeout)
            if p == nil or len(p) == 0:
                break
            body = sslcore.concat([body, p])
        body = body.slice(0, want if want < len(body) else len(body))
    else:
        while true:
            let p = conn.read(16384, timeout)
            if p == nil or len(p) == 0:
                break
            body = sslcore.concat([body, p])
    return {status: status, headers: headers, body: body}
