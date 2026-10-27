# uinput: keyboard and mouse events for user programs. The kernel's driver does the device work; this turns
# its text lines into gui events and tracks the pointer position.
import gdev
import gui

export class Input:
    let mx = 0
    let my = 0
    func init(self, width, height):
        self.mx = width // 2
        self.my = height // 2
    func poll(self):
        let text = gdev.input()
        let out = []
        if len(text) == 0:
            return out
        for line in text.split("\n"):
            if len(line) == 0:
                continue
            let f = line.split("\t")
            let t = f[0]
            if t == "move":
                self.mx = to_int(f[1])
                self.my = to_int(f[2])
                out.append(gui.mouse_move(self.mx, self.my))
            elif t == "down":
                self.mx = to_int(f[1])
                self.my = to_int(f[2])
                out.append(gui.mouse_down(self.mx, self.my, to_int(f[3]), f[4], to_int(f[5])))
            elif t == "up":
                out.append(gui.mouse_up(to_int(f[1]), to_int(f[2]), to_int(f[3]), f[4]))
            elif t == "wheel":
                out.append(gui.wheel(to_int(f[1]), to_int(f[2]), to_int(f[3])))
            elif t == "key":
                out.append(gui.key(f[1]))
            else:
                out.append(gui.text(f[1]))
        return out
