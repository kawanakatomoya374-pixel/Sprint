# ps2: keyboard and mouse drivers for the PC's 8042 controller, written in Sprint on top of hw.inb/outb.
# Input(w, h).poll() returns gui events (mouse_move / mouse_down / mouse_up / wheel / key / text) for
# everything the devices reported since the last call. Polling only - there are no interrupts.
import hw
import math

# event constructors (the same shapes the gui module uses)
func ev_key(name):
    return {type: "key", key: name}
func ev_text(s):
    return {type: "text", text: s}
func ev_move(x, y):
    return {type: "mouse_move", x: x, y: y}
func ev_down(x, y, button, mods, clicks):
    return {type: "mouse_down", x: x, y: y, button: button, mods: mods, clicks: clicks}
func ev_up(x, y, button, mods):
    return {type: "mouse_up", x: x, y: y, button: button, mods: mods}
func ev_wheel(x, y, dy):
    return {type: "wheel", x: x, y: y, dy: dy}

# one event as a tab-separated line (the form user programs read through the input system call)
export func encode(ev):
    let t = ev.type
    if t == "mouse_move":
        return "move\t" .. to_string(ev.x) .. "\t" .. to_string(ev.y)
    if t == "mouse_down":
        return "down\t" .. to_string(ev.x) .. "\t" .. to_string(ev.y) .. "\t" .. to_string(ev.button) .. "\t" .. ev.mods .. "\t" .. to_string(ev.clicks)
    if t == "mouse_up":
        return "up\t" .. to_string(ev.x) .. "\t" .. to_string(ev.y) .. "\t" .. to_string(ev.button) .. "\t" .. ev.mods
    if t == "wheel":
        return "wheel\t" .. to_string(ev.x) .. "\t" .. to_string(ev.y) .. "\t" .. to_string(ev.dy)
    if t == "key":
        return "key\t" .. ev.key
    return "text\t" .. ev.text

const DATA = 0x60
const CMD = 0x64

func wait_in():
    for i in range(200000):
        if hw.inb(CMD) & 2 == 0:
            return true
    return false

func wait_out():
    for i in range(200000):
        if hw.inb(CMD) & 1 != 0:
            return true
    return false

func send_cmd(c):
    wait_in()
    hw.outb(CMD, c)

func send_data(d):
    wait_in()
    hw.outb(DATA, d)

func read_data():
    if wait_out():
        return hw.inb(DATA)
    return -1

func flush():
    for i in range(64):
        if hw.inb(CMD) & 1 == 0:
            return nil
        hw.inb(DATA)

# a byte to the mouse (through the controller); returns its answer (0xFA = ACK)
func mouse_cmd(b):
    send_cmd(0xD4)
    send_data(b)
    return read_data()

# scancode set 1, unshifted and shifted, indexed by scancode (0 = not a printable key)
const PLAIN = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 "
const SHIFT = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 "

const NAMED = {0x01: "Escape", 0x0E: "Backspace", 0x0F: "Tab", 0x1C: "Enter", 0x3A: "CapsLock",
               0x3B: "F1", 0x3C: "F2", 0x3D: "F3", 0x3E: "F4", 0x3F: "F5", 0x40: "F6", 0x41: "F7",
               0x42: "F8", 0x43: "F9", 0x44: "F10", 0x57: "F11", 0x58: "F12"}
const EXT = {0x48: "Up", 0x50: "Down", 0x4B: "Left", 0x4D: "Right", 0x47: "Home", 0x4F: "End",
             0x49: "PageUp", 0x51: "PageDown", 0x53: "Delete", 0x52: "Insert", 0x1C: "Enter"}

export class Input:
    let width = 0
    let height = 0
    let mx = 0
    let my = 0
    let buttons = 0
    let ctrl = false
    let alt = false
    let shift = false
    let caps = false
    let ext = false
    let pkt = []
    let has_wheel = false
    let last_click_ms = -10000
    let last_click_btn = 0
    let click_count = 0
    let last_click_x = 0
    let last_click_y = 0
    let have_mouse = false
    func init(self, width, height):
        self.width = width
        self.height = height
        self.mx = width // 2
        self.my = height // 2
        self.pkt = []
        self.start()
    func start(self):
        send_cmd(0xAD)
        send_cmd(0xA7)
        flush()
        send_cmd(0x20)
        let cfg = read_data()
        if cfg < 0:
            cfg = 0x45
        cfg = (cfg | 0x40) & ~0x33        # keep translation to set 1, no interrupts, clocks on
        send_cmd(0x60)
        send_data(cfg)
        send_cmd(0xAE)
        send_cmd(0xA8)
        send_data(0xF4)                    # keyboard: enable scanning
        read_data()
        if mouse_cmd(0xF6) == 0xFA:
            self.have_mouse = true
            # the IntelliMouse sequence: sample rate 200, 100, 80 turns the wheel on
            for r in [200, 100, 80]:
                mouse_cmd(0xF3)
                mouse_cmd(r)
            mouse_cmd(0xF2)
            let id = read_data()
            self.has_wheel = id == 3
            mouse_cmd(0xF4)
        flush()
    func mods(self):
        let m = []
        if self.ctrl:
            m.append("Ctrl")
        if self.alt:
            m.append("Alt")
        if self.shift:
            m.append("Shift")
        return m.join("+")
    # events from everything the controller has buffered
    func poll(self):
        let out = []
        let n = 0
        while hw.inb(CMD) & 1 != 0 and n < 256:
            let st = hw.inb(CMD)
            let b = hw.inb(DATA)
            n += 1
            if st & 0x20 != 0:
                self.mouse_byte(b, out)
            else:
                self.key_byte(b, out)
        return out
    func key_byte(self, b, out):
        if b == 0xE0:
            self.ext = true
            return nil
        if b == 0xE1 or b == 0xFA or b == 0xAA or b == 0xFE:
            return nil
        let up = b & 0x80 != 0
        let code = b & 0x7F
        let ext = self.ext
        self.ext = false
        if code == 0x1D:
            self.ctrl = not up
            return nil
        if code == 0x38:
            self.alt = not up
            return nil
        if code == 0x2A or code == 0x36:
            self.shift = not up
            return nil
        if up:
            return nil
        if code == 0x3A and not ext:
            self.caps = not self.caps
            return nil
        let name = nil
        if ext:
            name = EXT[code]
        else:
            name = NAMED[code]
        if name == nil and not ext and code < len(PLAIN) and PLAIN[code] != 0:
            let ch = PLAIN[code]
            let letter = ch >= 97 and ch <= 122
            let shifted = self.shift != (self.caps and letter)
            let s = SHIFT.slice(code, code + 1) if shifted else PLAIN.slice(code, code + 1)
            if self.ctrl or self.alt:
                let base = PLAIN.slice(code, code + 1)
                name = "Space" if base == " " else base
            else:
                if s == " ":
                    out.append(ev_key("Space"))
                out.append(ev_text(s))
                return nil
        if name == nil:
            return nil
        let pre = ""
        if self.ctrl:
            pre = pre .. "Ctrl+"
        if self.alt:
            pre = pre .. "Alt+"
        if self.shift and (name.char_count() > 1 or self.ctrl or self.alt):
            pre = pre .. "Shift+"
        out.append(ev_key(pre .. name))
    func clamp_pos(self):
        if self.mx < 0:
            self.mx = 0
        if self.my < 0:
            self.my = 0
        if self.mx >= self.width:
            self.mx = self.width - 1
        if self.my >= self.height:
            self.my = self.height - 1
    func mouse_byte(self, b, out):
        if len(self.pkt) == 0 and b & 8 == 0:
            return nil                      # out of sync: wait for a first byte
        self.pkt.append(b)
        let need = 4 if self.has_wheel else 3
        if len(self.pkt) < need:
            return nil
        let p = self.pkt
        self.pkt = []
        if p[0] & 0xC0 != 0:
            return nil                      # overflow
        let dx = p[1] - (256 if p[0] & 0x10 != 0 else 0)
        let dy = p[2] - (256 if p[0] & 0x20 != 0 else 0)
        let wheel = 0
        if need == 4:
            wheel = p[3] & 15
            if wheel > 7:
                wheel -= 16
        if dx != 0 or dy != 0:
            self.mx += dx
            self.my -= dy
            self.clamp_pos()
            out.append(ev_move(self.mx, self.my))
        let nb = p[0] & 7
        let changed = nb ^ self.buttons
        for bit in [1, 2, 4]:
            if changed & bit != 0:
                let btn = 1 if bit == 1 else (3 if bit == 2 else 2)
                if nb & bit != 0:
                    let now = hw.ticks_ms()
                    if btn == self.last_click_btn and now - self.last_click_ms < 400 and math.abs(self.mx - self.last_click_x) < 5 and math.abs(self.my - self.last_click_y) < 5:
                        self.click_count += 1
                    else:
                        self.click_count = 1
                    self.last_click_ms = now
                    self.last_click_btn = btn
                    self.last_click_x = self.mx
                    self.last_click_y = self.my
                    out.append(ev_down(self.mx, self.my, btn, self.mods(), self.click_count))
                else:
                    out.append(ev_up(self.mx, self.my, btn, self.mods()))
        self.buttons = nb
        if wheel != 0:
            out.append(ev_wheel(self.mx, self.my, wheel))
