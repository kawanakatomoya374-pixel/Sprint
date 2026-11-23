# explorer: a file manager in the manner of Windows Explorer, drawn on a canvas. The class `Explorer` has no operating-system dependencies: it draws on
# a gfx canvas, takes the events a GUI client receives from guid, and works on a file system object it is given. SprintOS wraps it in os/user/explorer.sp
# (guiclient window, fsclient file system); the host tests use sprintfs volumes.
#
#   import explorer
#   let ex = explorer.Explorer(canvas, backend, clock_ms)     # canvas: gfx canvas, backend: see below, clock: a function giving milliseconds
#   ex.on_open = func(path): ...                              # a double click / Enter on a file
#   ex.event({type: "ptr", kind: "down", x: 100, y: 80, button: 1})     # true when something changed and the canvas should be shown again
#   ex.event({type: "key", key: "Ctrl+C"}); ex.event({type: "text", text: "a"})
#
# What it has: toolbar (back, forward, up, new folder, cut, copy, paste, delete, rename, refresh), an editable address bar, a folder tree on the left,
# a details list (name, size, type, date modified; click a heading to sort), single and rubber-band selection, keyboard selection (arrows, Home, End,
# Page up/down, Shift+arrows, Ctrl+A, type a letter to jump), rename in place (F2), new folder, delete with confirmation, copy / cut / paste of files and
# folders (recursively), drag and drop onto a folder, a context menu (right button), a status bar with the item count, the selection and the free space.
#
# The backend (the file system) offers: listdir(path) -> [{kind, size, name}], stat(path) -> {kind, size, mtime}, mkdir(path), unlink(path), rmdir(path),
# rename(old, new), read_bytes(path, off, n) -> typed.u8, write_bytes(path, data, off, truncate), statfs() -> {free_blocks, blocks} (4096-byte blocks).
# Errors are thrown with error(kind, message); they are shown in a message box.
import sslcore

const W_BG = 0xffffff
const FACE = 0xf0f0f0
const TB_TOP = 0xfafafa
const TB_BOT = 0xe6e6e6
const LINE = 0xd0d0d0
const SEL_BG = 0xcce8ff
const SEL_LINE = 0x99d1ff
const HOT_BG = 0xe5f3ff
const TEXT = 0x000000
const GREY = 0x6d6d6d
const ACCENT = 0x0078d7
const ROW = 20
const TOOL_H = 34
const ADDR_H = 26
const HEAD_H = 22
const STATUS_H = 22
const TREE_W = 190
const SCROLL_W = 14
export const ROW_Y0 = TOOL_H + ADDR_H + HEAD_H

const BUTTONS = ["back", "forward", "up", "|", "new", "cut", "copy", "paste", "delete", "rename", "|", "refresh"]
const TIPS = {back: "Back", forward: "Forward", up: "Up", new: "New folder", cut: "Cut", copy: "Copy", paste: "Paste", delete: "Delete", rename: "Rename", refresh: "Refresh"}

func fail(kind, msg):
    throw error(kind, msg)

func joinp(dir, name):
    return ("/" .. name) if dir == "/" else (dir .. "/" .. name)

func dirname(p):
    let i = last_slash(p)
    if i <= 0:
        return "/"
    return p.slice(0, i)

func last_slash(p):
    let i = len(p) - 1
    while i >= 0:
        if p[i] == 47:
            return i
        i -= 1
    return -1

func basename(p):
    let i = last_slash(p)
    return p.slice(i + 1)

func ext_of(name):
    let i = len(name) - 1
    while i > 0:
        if name[i] == 46:
            return name.slice(i + 1).lower()
        i -= 1
    return ""

func size_text(n):
    if n < 1024:
        return to_string(n) .. " B"
    if n < 1024 * 1024:
        return to_string((n + 1023) // 1024) .. " KB"
    if n < 1024 * 1024 * 1024:
        let t = (n * 10 + 524288) // 1048576
        return to_string(t // 10) .. "." .. to_string(t % 10) .. " MB"
    let g = (n * 10 + 536870912) // 1073741824
    return to_string(g // 10) .. "." .. to_string(g % 10) .. " GB"

func two(n):
    return ("0" .. to_string(n)) if n < 10 else to_string(n)

func civil_from_days(n):
    let z = n + 719468
    let era = z // 146097
    let doe = z - era * 146097
    let yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    let doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    let mp = (5 * doy + 2) // 153
    let d = doy - (153 * mp + 2) // 5 + 1
    let m = mp + 3 if mp < 10 else mp - 9
    let y = yoe + era * 400
    return [y + 1 if m <= 2 else y, m, d]

func date_text(t):
    if t <= 0:
        return ""
    let c = civil_from_days(t // 86400)
    let s = t % 86400
    return to_string(c[0]) .. "-" .. two(c[1]) .. "-" .. two(c[2]) .. " " .. two(s // 3600) .. ":" .. two((s % 3600) // 60)

func type_text(e):
    if e.kind == "dir":
        return "File folder"
    let x = ext_of(e.name)
    if x == "":
        return "File"
    return x.upper() .. " File"

func clamp(v, lo, hi):
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v

func imin(a, b):
    return a if a < b else b

func imax(a, b):
    return a if a > b else b

func fit(c, s, w):
    # the text cut to w pixels with ".." when it does not fit
    if c.text_width(s) <= w:
        return s
    let n = len(s)
    while n > 1 and c.text_width(s.slice(0, n) .. "..") > w:
        n -= 1
    return s.slice(0, n) .. ".."

# ---- icons (16 x 16) ----
func draw_folder(c, x, y):
    c.fill_rect(x, y + 3, 7, 3, 0xe8b830)
    c.fill_rect(x, y + 5, 15, 9, 0xf7d25a)
    c.rect(x, y + 5, 15, 9, 0xc9971a)
    c.fill_rect(x + 1, y + 7, 13, 1, 0xfbe590)

func draw_file(c, x, y, ext):
    let tint = 0x7a9fd6
    if ext == "sp":
        tint = 0x2e8b57
    elif ext == "txt" or ext == "md":
        tint = 0x9aa0a6
    elif ext == "png" or ext == "bmp" or ext == "jpg":
        tint = 0xd9822b
    elif ext == "mp3" or ext == "wav":
        tint = 0xa855c7
    c.fill_rect(x + 2, y + 1, 11, 14, 0xffffff)
    c.rect(x + 2, y + 1, 11, 14, 0x808080)
    c.fill_rect(x + 3, y + 2, 9, 3, tint)
    c.line(x + 4, y + 7, x + 10, y + 7, 0xb0b0b0)
    c.line(x + 4, y + 9, x + 10, y + 9, 0xb0b0b0)
    c.line(x + 4, y + 11, x + 8, y + 11, 0xb0b0b0)

func draw_button_icon(c, name, x, y, on):
    let col = 0x303030 if on else 0xa8a8a8
    if name == "back":
        c.line(x + 3, y + 8, x + 12, y + 8, col)
        c.line(x + 3, y + 8, x + 7, y + 4, col)
        c.line(x + 3, y + 8, x + 7, y + 12, col)
        c.line(x + 4, y + 8, x + 8, y + 4, col)
        c.line(x + 4, y + 8, x + 8, y + 12, col)
    elif name == "forward":
        c.line(x + 3, y + 8, x + 12, y + 8, col)
        c.line(x + 12, y + 8, x + 8, y + 4, col)
        c.line(x + 12, y + 8, x + 8, y + 12, col)
        c.line(x + 11, y + 8, x + 7, y + 4, col)
        c.line(x + 11, y + 8, x + 7, y + 12, col)
    elif name == "up":
        c.line(x + 8, y + 13, x + 8, y + 3, col)
        c.line(x + 8, y + 3, x + 4, y + 7, col)
        c.line(x + 8, y + 3, x + 12, y + 7, col)
        c.line(x + 7, y + 3, x + 3, y + 7, col)
        c.line(x + 9, y + 3, x + 13, y + 7, col)
    elif name == "new":
        draw_folder(c, x, y)
        c.fill_rect(x + 10, y + 1, 5, 5, 0x39a845 if on else 0xa8a8a8)
        c.line(x + 12, y + 2, x + 12, y + 4, 0xffffff)
        c.line(x + 11, y + 3, x + 13, y + 3, 0xffffff)
    elif name == "cut":
        c.line(x + 4, y + 2, x + 10, y + 11, col)
        c.line(x + 11, y + 2, x + 5, y + 11, col)
        c.circle(x + 4, y + 12, 2, col)
        c.circle(x + 11, y + 12, 2, col)
    elif name == "copy":
        c.rect(x + 2, y + 2, 8, 10, col)
        c.fill_rect(x + 6, y + 5, 8, 10, 0xffffff)
        c.rect(x + 6, y + 5, 8, 10, col)
    elif name == "paste":
        c.rect(x + 2, y + 3, 11, 12, col)
        c.fill_rect(x + 5, y + 1, 5, 4, col)
        c.fill_rect(x + 5, y + 8, 8, 8, 0xffffff)
        c.rect(x + 5, y + 8, 8, 8, col)
    elif name == "delete":
        c.line(x + 3, y + 3, x + 12, y + 12, 0xd13438 if on else 0xa8a8a8)
        c.line(x + 12, y + 3, x + 3, y + 12, 0xd13438 if on else 0xa8a8a8)
        c.line(x + 4, y + 3, x + 12, y + 11, 0xd13438 if on else 0xa8a8a8)
        c.line(x + 11, y + 3, x + 3, y + 11, 0xd13438 if on else 0xa8a8a8)
    elif name == "rename":
        c.rect(x + 1, y + 4, 14, 8, col)
        c.line(x + 4, y + 6, x + 4, y + 10, col)
        c.line(x + 7, y + 8, x + 12, y + 8, col)
    elif name == "refresh":
        c.circle(x + 8, y + 8, 5, col)
        c.fill_rect(x + 8, y + 1, 5, 5, 0xf3f3f3)
        c.fill_triangle(x + 8, y + 1, x + 13, y + 3, x + 8, y + 6, col)

export class Explorer:
    let c = nil
    let fs = nil
    let clock = nil
    let w = 0
    let h = 0
    let cwd = "/"
    let entries = nil
    let sel = nil                 # name -> true
    let focus = -1                # index of the focused row
    let anchor = -1
    let scroll = 0                # first visible row
    let sort_key = "name"
    let sort_asc = true
    let back = nil
    let fwd = nil
    let clip = nil                # {paths, cut}
    let modal = nil
    let edit = nil                # {kind, text, cur, all, name}
    let menu = nil                # {x, y, items: [[label, action, enabled]]}
    let tree_open = nil           # path -> true
    let tree_rows = nil
    let tree_scroll = 0
    let hot_btn = ""
    let drag = nil                # {kind: "band" | "items" | "scroll", ...}
    let last_click = nil
    let mtimes = nil
    let status = ""
    let tip = ""
    let on_open = nil
    let on_apps = nil
    let typed = ""
    let typed_at = 0
    let dirty_tree = true
    func init(self, canvas, backend, clock):
        self.c = canvas
        self.fs = backend
        self.clock = clock
        self.w = canvas.width()
        self.h = canvas.height()
        self.entries = []
        self.sel = {}
        self.back = []
        self.fwd = []
        self.tree_open = {"/": true}
        self.tree_rows = []
        self.mtimes = {}
        self.refresh()
        self.draw()

    # ---- geometry ----
    func body_y(self):
        return TOOL_H + ADDR_H
    func list_x(self):
        return TREE_W
    func rows_y(self):
        return self.body_y() + HEAD_H
    func visible_rows(self):
        return (self.h - STATUS_H - self.rows_y()) // ROW
    func list_w(self):
        return self.w - TREE_W
    func need_scroll(self):
        return len(self.entries) > self.visible_rows()
    func col_name_w(self):
        return self.list_w() - 80 - 110 - 130 - (SCROLL_W if self.need_scroll() else 0)

    # ---- the directory ----
    func message(self, text):
        self.modal = {kind: "message", text: text}

    func sort_entries(self):
        let key = self.sort_key
        let asc = self.sort_asc
        func less(a, b):
            if a.kind != b.kind:
                return a.kind == "dir"
            let r = 0
            if key == "size":
                r = a.size - b.size
            elif key == "type":
                let ta = type_text(a)
                let tb = type_text(b)
                r = -1 if ta < tb else (1 if ta > tb else 0)
            elif key == "date":
                r = self.mtime_of(a.name) - self.mtime_of(b.name)
            if r == 0:
                let na = a.name.lower()
                let nb = b.name.lower()
                r = -1 if na < nb else (1 if na > nb else 0)
                return r < 0
            return (r < 0) if asc else (r > 0)
        self.entries.sort(less)

    func mtime_of(self, name):
        let p = joinp(self.cwd, name)
        let v = self.mtimes[p]
        if v == nil:
            v = 0
            try:
                v = self.fs.stat(p).mtime
            catch e:
                v = 0
            self.mtimes[p] = v
        return v

    func refresh(self):
        let old = self.sel
        try:
            self.entries = self.fs.listdir(self.cwd)
        catch e:
            self.entries = []
            self.status = "Cannot read " .. self.cwd .. ": " .. to_string(e)
        self.mtimes = {}
        if self.sort_key == "date":
            for e in self.entries:
                self.mtime_of(e.name)
        self.sort_entries()
        self.sel = {}
        for e in self.entries:
            if old[e.name]:
                self.sel[e.name] = true
        self.focus = clamp(self.focus, -1, len(self.entries) - 1)
        self.scroll = clamp(self.scroll, 0, imax(0, len(self.entries) - self.visible_rows()))
        self.dirty_tree = true

    func goto(self, path, remember = true):
        let p = path
        if len(p) > 1 and p[len(p) - 1] == 47:
            p = p.slice(0, len(p) - 1)
        if p == "":
            p = "/"
        try:
            let st = self.fs.stat(p)
            if st.kind != "dir":
                self.message(p .. " is not a folder")
                return false
        catch e:
            self.message("Windows cannot find '" .. p .. "'.\nCheck the spelling and try again.")
            return false
        if remember and p != self.cwd:
            self.back.append(self.cwd)
            self.fwd = []
        self.cwd = p
        self.sel = {}
        self.focus = -1
        self.anchor = -1
        self.scroll = 0
        self.status = ""
        self.refresh()
        return true

    func go_back(self):
        if len(self.back) == 0:
            return nil
        let p = self.back.pop()
        self.fwd.append(self.cwd)
        self.goto(p, false)

    func go_forward(self):
        if len(self.fwd) == 0:
            return nil
        let p = self.fwd.pop()
        self.back.append(self.cwd)
        self.goto(p, false)

    func go_up(self):
        if self.cwd != "/":
            self.goto(dirname(self.cwd))

    func selected_names(self):
        let out = []
        for e in self.entries:
            if self.sel[e.name]:
                out.append(e.name)
        return out

    func entry_named(self, name):
        for e in self.entries:
            if e.name == name:
                return e
        return nil

    # ---- operations ----
    func unique_name(self, dir, base, suffix = ""):
        let names = {}
        for e in self.fs.listdir(dir):
            names[e.name] = true
        let n = base .. suffix
        let i = 2
        while names[n]:
            n = base .. " (" .. to_string(i) .. ")" .. suffix
            i += 1
        return n

    func new_folder(self):
        try:
            let name = self.unique_name(self.cwd, "New folder")
            self.fs.mkdir(joinp(self.cwd, name))
            self.refresh()
            self.select_only(name)
            self.begin_rename(name)
        catch e:
            self.message("Could not create the folder.\n" .. to_string(e))

    func select_only(self, name):
        self.sel = {}
        self.sel[name] = true
        for i in range(len(self.entries)):
            if self.entries[i].name == name:
                self.focus = i
                self.anchor = i
                self.show_row(i)

    func show_row(self, i):
        let v = self.visible_rows()
        if i < self.scroll:
            self.scroll = i
        elif i >= self.scroll + v:
            self.scroll = i - v + 1
        self.scroll = clamp(self.scroll, 0, imax(0, len(self.entries) - v))

    func begin_rename(self, name = nil):
        let n = name
        if n == nil:
            let s = self.selected_names()
            if len(s) != 1:
                return nil
            n = s[0]
        self.edit = {kind: "rename", text: n, cur: len(n), all: true, name: n}

    func do_rename(self, old, new):
        if new == old:
            return nil
        if new == "" or new.find("/", 0) >= 0:
            self.message("The file name is not valid.")
            return nil
        if self.entry_named(new) != nil:
            self.message("A file with the name '" .. new .. "' already exists.")
            return nil
        try:
            self.fs.rename(joinp(self.cwd, old), joinp(self.cwd, new))
            self.refresh()
            self.select_only(new)
        catch e:
            self.message("Could not rename.\n" .. to_string(e))

    func ask_delete(self):
        let names = self.selected_names()
        if len(names) == 0:
            return nil
        let what = "'" .. names[0] .. "'" if len(names) == 1 else to_string(len(names)) .. " items"
        self.modal = {kind: "confirm", title: "Delete", text: "Are you sure you want to permanently delete " .. what .. "?", yes: "delete", names: names}

    func remove_tree(self, path):
        let st = self.fs.stat(path)
        if st.kind == "dir":
            for e in self.fs.listdir(path):
                self.remove_tree(joinp(path, e.name))
            self.fs.rmdir(path)
        else:
            self.fs.unlink(path)

    func do_delete(self, names):
        try:
            for n in names:
                self.remove_tree(joinp(self.cwd, n))
        catch e:
            self.message("Could not delete.\n" .. to_string(e))
        self.sel = {}
        self.refresh()

    func set_clip(self, cut):
        let names = self.selected_names()
        if len(names) == 0:
            return nil
        let paths = []
        for n in names:
            paths.append(joinp(self.cwd, n))
        self.clip = {paths: paths, cut: cut}
        self.status = to_string(len(paths)) .. " item(s) " .. ("cut" if cut else "copied")

    func copy_tree(self, src, dst):
        let st = self.fs.stat(src)
        if st.kind == "dir":
            self.fs.mkdir(dst)
            for e in self.fs.listdir(src):
                self.copy_tree(joinp(src, e.name), joinp(dst, e.name))
        else:
            self.fs.write_bytes(dst, sslcore.concat([[]]), 0, true)
            let off = 0
            while off < st.size:
                let n = imin(32768, st.size - off)
                let data = self.fs.read_bytes(src, off, n)
                self.fs.write_bytes(dst, data, off, false)
                off += n

    func inside(self, dir, path):
        return path == dir or (len(path) > len(dir) and path.slice(0, len(dir)) == dir and (dir == "/" or path[len(dir)] == 47))

    func paste_into(self, dir, paths, cut):
        let last = nil
        try:
            for p in paths:
                let name = basename(p)
                if cut:
                    if self.inside(p, dir):
                        self.message("You cannot move a folder into itself.")
                        return nil
                    if dirname(p) == dir:
                        continue
                    let target = joinp(dir, name)
                    if self.fs.exists(target):
                        target = joinp(dir, self.unique_name(dir, name))
                    self.fs.rename(p, target)
                    last = basename(target)
                else:
                    if self.inside(p, dir):
                        self.message("You cannot copy a folder into itself.")
                        return nil
                    let st = self.fs.stat(p)
                    let target = joinp(dir, name)
                    if self.fs.exists(target):
                        let base = name
                        let sfx = ""
                        if st.kind != "dir" and ext_of(name) != "":
                            sfx = "." .. ext_of(name)
                            base = name.slice(0, len(name) - len(sfx))
                        target = joinp(dir, self.unique_name(dir, base .. " - Copy", sfx))
                    self.copy_tree(p, target)
                    last = basename(target)
        catch e:
            self.message("The operation failed.\n" .. to_string(e))
        self.mtimes = {}
        if dir == self.cwd:
            self.refresh()
            if last != nil:
                self.select_only(last)
        else:
            self.refresh()

    func paste(self):
        if self.clip == nil:
            return nil
        self.paste_into(self.cwd, self.clip.paths, self.clip.cut)
        if self.clip.cut:
            self.clip = nil

    func open_entry(self, e):
        let p = joinp(self.cwd, e.name)
        if e.kind == "dir":
            self.goto(p)
        elif self.on_open != nil:
            self.on_open(p)
        else:
            self.status = "Opened " .. p

    # ---- selection ----
    func move_focus(self, to, extend):
        let n = len(self.entries)
        if n == 0:
            return nil
        let i = clamp(to, 0, n - 1)
        if extend and self.anchor >= 0:
            self.sel = {}
            for k in range(imin(self.anchor, i), imax(self.anchor, i) + 1):
                self.sel[self.entries[k].name] = true
        else:
            self.sel = {}
            self.sel[self.entries[i].name] = true
            self.anchor = i
        self.focus = i
        self.show_row(i)

    func select_all(self):
        self.sel = {}
        for e in self.entries:
            self.sel[e.name] = true

    # ---- the folder tree ----
    func build_tree(self):
        let rows = []
        func add(path, name, depth):
            let open = self.tree_open[path] == true
            rows.append({path: path, name: name, depth: depth, open: open})
            if open:
                let kids = []
                try:
                    for e in self.fs.listdir(path):
                        if e.kind == "dir":
                            kids.append(e.name)
                catch e:
                    kids = []
                kids.sort((a, b) => a.lower() < b.lower())
                for k in kids:
                    add(joinp(path, k), k, depth + 1)
        add("/", "SprintFS (/)", 0)
        self.tree_rows = rows
        self.dirty_tree = false

    func tree_visible(self):
        return (self.h - STATUS_H - self.body_y()) // ROW

    # ---- text editing (address bar, rename) ----
    func edit_key(self, key):
        let ed = self.edit
        let k = key
        if k == "Enter":
            let kind = ed.kind
            let text = ed.text
            self.edit = nil
            if kind == "addr":
                self.goto(text)
            elif kind == "rename":
                self.do_rename(ed.name, text)
            return true
        if k == "Escape":
            self.edit = nil
            return true
        if k == "Backspace":
            if ed.all:
                ed.text = ""
                ed.cur = 0
                ed.all = false
            elif ed.cur > 0:
                ed.text = ed.text.slice(0, ed.cur - 1) .. ed.text.slice(ed.cur)
                ed.cur -= 1
            return true
        if k == "Delete":
            if ed.all:
                ed.text = ""
                ed.cur = 0
                ed.all = false
            elif ed.cur < len(ed.text):
                ed.text = ed.text.slice(0, ed.cur) .. ed.text.slice(ed.cur + 1)
            return true
        if k == "Left":
            ed.all = false
            ed.cur = imax(0, ed.cur - 1)
            return true
        if k == "Right":
            ed.all = false
            ed.cur = imin(len(ed.text), ed.cur + 1)
            return true
        if k == "Home":
            ed.all = false
            ed.cur = 0
            return true
        if k == "End":
            ed.all = false
            ed.cur = len(ed.text)
            return true
        if k == "Ctrl+A":
            ed.all = true
            return true
        return false

    func edit_text(self, s):
        let ed = self.edit
        if ed.all:
            ed.text = ""
            ed.cur = 0
            ed.all = false
        ed.text = ed.text.slice(0, ed.cur) .. s .. ed.text.slice(ed.cur)
        ed.cur += len(s)

    # ---- events ----
    func event(self, e):
        let changed = false
        if e.type == "ptr":
            changed = self.on_ptr(e)
        elif e.type == "key":
            changed = self.on_key(e.key)
        elif e.type == "text":
            changed = self.on_text(e.text)
        if changed:
            self.draw()
        return changed

    func on_text(self, s):
        if self.modal != nil:
            return false
        if self.edit != nil:
            self.edit_text(s)
            return true
        # type a letter to jump to the next name that starts with it
        let t = self.clock()
        if t - self.typed_at > 1000:
            self.typed = ""
        self.typed_at = t
        self.typed = self.typed .. s.lower()
        let n = len(self.entries)
        for step in range(n):
            let i = (self.focus + (1 if len(self.typed) == 1 else 0) + step) % n if n > 0 else 0
            if n > 0 and self.entries[i].name.lower().starts_with(self.typed):
                self.move_focus(i, false)
                return true
        return false

    func on_key(self, k):
        if self.modal != nil:
            let m = self.modal
            if m.kind == "message":
                if k == "Enter" or k == "Escape" or k == "Space":
                    self.modal = nil
                return true
            if k == "Enter" or k == "Y" or k == "y":
                self.modal = nil
                if m.yes == "delete":
                    self.do_delete(m.names)
                return true
            if k == "Escape" or k == "N" or k == "n":
                self.modal = nil
            return true
        if self.menu != nil:
            self.menu = nil
            if k == "Escape":
                return true
        if self.edit != nil:
            return self.edit_key(k)
        let ctrl = k.starts_with("Ctrl+")
        let shift = k.find("Shift+", 0) >= 0
        let base = k
        let at = last_plus(k)
        if at >= 0:
            base = k.slice(at + 1)
        if ctrl and (base == "a" or base == "A"):
            self.select_all()
            return true
        if ctrl and (base == "c" or base == "C"):
            self.set_clip(false)
            return true
        if ctrl and (base == "x" or base == "X"):
            self.set_clip(true)
            return true
        if ctrl and (base == "v" or base == "V"):
            self.paste()
            return true
        if ctrl and shift and (base == "n" or base == "N"):
            self.new_folder()
            return true
        if ctrl and (base == "l" or base == "L"):
            self.edit = {kind: "addr", text: self.cwd, cur: len(self.cwd), all: true, name: ""}
            return true
        if base == "F5":
            self.refresh()
            return true
        if base == "F2":
            self.begin_rename()
            return true
        if base == "Delete":
            self.ask_delete()
            return true
        if base == "Backspace":
            self.go_up()
            return true
        if k == "Alt+Left":
            self.go_back()
            return true
        if k == "Alt+Right":
            self.go_forward()
            return true
        if k == "Alt+Up":
            self.go_up()
            return true
        if base == "Enter":
            let names = self.selected_names()
            if len(names) >= 1:
                let en = self.entry_named(names[0])
                if en != nil:
                    self.open_entry(en)
            return true
        let v = self.visible_rows()
        if base == "Down":
            self.move_focus(self.focus + 1, shift)
            return true
        if base == "Up":
            self.move_focus(self.focus - 1 if self.focus > 0 else 0, shift)
            return true
        if base == "Home":
            self.move_focus(0, shift)
            return true
        if base == "End":
            self.move_focus(len(self.entries) - 1, shift)
            return true
        if base == "PageDown":
            self.move_focus(self.focus + v, shift)
            return true
        if base == "PageUp":
            self.move_focus(self.focus - v, shift)
            return true
        if base == "Escape":
            self.sel = {}
            return true
        return false

    func row_at(self, y):
        let r = (y - self.rows_y()) // ROW + self.scroll
        return r

    func in_list(self, x, y):
        return x >= TREE_W and y >= self.rows_y() and y < self.h - STATUS_H

    func button_at(self, x, y):
        if y < 3 or y >= TOOL_H - 3:
            return ""
        let bx = 6
        for b in BUTTONS:
            if b == "|":
                bx += 10
                continue
            if x >= bx and x < bx + 28:
                return b
            bx += 30
        return ""

    func button_enabled(self, b):
        if b == "back":
            return len(self.back) > 0
        if b == "forward":
            return len(self.fwd) > 0
        if b == "up":
            return self.cwd != "/"
        if b == "cut" or b == "copy" or b == "delete":
            return len(self.selected_names()) > 0
        if b == "rename":
            return len(self.selected_names()) == 1
        if b == "paste":
            return self.clip != nil
        return true

    func press_button(self, b):
        if not self.button_enabled(b):
            return nil
        if b == "back":
            self.go_back()
        elif b == "forward":
            self.go_forward()
        elif b == "up":
            self.go_up()
        elif b == "new":
            self.new_folder()
        elif b == "cut":
            self.set_clip(true)
        elif b == "copy":
            self.set_clip(false)
        elif b == "paste":
            self.paste()
        elif b == "delete":
            self.ask_delete()
        elif b == "rename":
            self.begin_rename()
        elif b == "refresh":
            self.refresh()

    func open_menu(self, x, y, on_item):
        let items = []
        if on_item:
            items.append(["Open", "open", true])
            items.append(["Cut", "cut", true])
            items.append(["Copy", "copy", true])
            items.append(["Delete", "delete", true])
            items.append(["Rename", "rename", len(self.selected_names()) == 1])
        else:
            items.append(["Refresh", "refresh", true])
            items.append(["Paste", "paste", self.clip != nil])
            items.append(["New folder", "new", true])
            items.append(["Select all", "all", true])
        let mw = 130
        let mh = 4 + 22 * len(items)
        self.menu = {x: imin(x, self.w - mw - 2), y: imin(y, self.h - mh - 2), w: mw, items: items}

    func menu_click(self, x, y):
        let m = self.menu
        self.menu = nil
        if x < m.x or x >= m.x + m.w or y < m.y or y >= m.y + 4 + 22 * len(m.items):
            return true
        let i = (y - m.y - 2) // 22
        if i < 0 or i >= len(m.items) or not m.items[i][2]:
            return true
        let a = m.items[i][1]
        if a == "open":
            let names = self.selected_names()
            if len(names) > 0:
                self.open_entry(self.entry_named(names[0]))
        elif a == "all":
            self.select_all()
        else:
            self.press_button(a)
        return true

    func modal_click(self, x, y):
        let m = self.modal
        let bw = 300
        let bh = 110
        let bx = (self.w - bw) // 2
        let by = (self.h - bh) // 2
        if m.kind == "message":
            if x >= bx + bw - 80 and x < bx + bw - 12 and y >= by + bh - 32 and y < by + bh - 10:
                self.modal = nil
            return true
        if y >= by + bh - 32 and y < by + bh - 10:
            if x >= bx + bw - 160 and x < bx + bw - 92:
                self.modal = nil
                if m.yes == "delete":
                    self.do_delete(m.names)
            elif x >= bx + bw - 80 and x < bx + bw - 12:
                self.modal = nil
        return true

    func on_ptr(self, e):
        let x = e.x
        let y = e.y
        if self.modal != nil:
            if e.kind == "down":
                return self.modal_click(x, y)
            return false
        if self.menu != nil:
            if e.kind == "down":
                return self.menu_click(x, y)
            return false
        if e.kind == "move":
            return self.on_move(x, y)
        if e.kind == "up":
            return self.on_up(x, y)
        # a press
        if self.edit != nil:
            let was = self.edit
            self.edit = nil
            if was.kind == "rename":
                self.do_rename(was.name, was.text)
            # the press itself still does its job below
        if y < TOOL_H:
            let b = self.button_at(x, y)
            if b != "":
                self.press_button(b)
            return true
        if y < TOOL_H + ADDR_H:
            self.edit = {kind: "addr", text: self.cwd, cur: len(self.cwd), all: true, name: ""}
            return true
        if x < TREE_W and y >= self.body_y() and y < self.h - STATUS_H:
            return self.tree_click(x, y)
        if y >= self.body_y() and y < self.rows_y() and x >= TREE_W:
            return self.header_click(x)
        if self.in_list(x, y):
            return self.list_press(e)
        return false

    func tree_click(self, x, y):
        if self.dirty_tree:
            self.build_tree()
        let i = (y - self.body_y()) // ROW + self.tree_scroll
        if i < 0 or i >= len(self.tree_rows):
            return true
        let r = self.tree_rows[i]
        let ax = 6 + r.depth * 14
        if x >= ax and x < ax + 12:
            self.tree_open[r.path] = not r.open
            self.dirty_tree = true
        else:
            self.goto(r.path)
        return true

    func header_click(self, x):
        let nx = TREE_W + self.col_name_w()
        let key = "name"
        if x >= nx + 130 + 110:
            key = "size"
        elif x >= nx + 130:
            key = "type"
        elif x >= nx:
            key = "date"
        if key == self.sort_key:
            self.sort_asc = not self.sort_asc
        else:
            self.sort_key = key
            self.sort_asc = true
        self.sort_entries()
        return true

    func list_press(self, e):
        let x = e.x
        let y = e.y
        let n = len(self.entries)
        # the scroll bar
        if self.need_scroll() and x >= self.w - SCROLL_W:
            let v = self.visible_rows()
            let track = v * ROW
            let thumb_h = imax(16, track * v // n)
            let max_scroll = n - v
            let ty = self.rows_y() + (track - thumb_h) * self.scroll // imax(1, max_scroll)
            if y >= ty and y < ty + thumb_h:
                self.drag = {kind: "scroll", dy: y - ty}
            else:
                self.scroll = clamp(self.scroll + (v if y > ty else -v), 0, max_scroll)
            return true
        let i = self.row_at(y)
        let right = e.button == 3
        if i >= 0 and i < n:
            let en = self.entries[i]
            let now = self.clock()
            if not self.sel[en.name]:
                self.sel = {}
                self.sel[en.name] = true
            if not right:
                let lc = self.last_click
                if lc != nil and lc.name == en.name and now - lc.t < 450:
                    self.last_click = nil
                    self.focus = i
                    self.open_entry(en)
                    return true
                self.last_click = {name: en.name, t: now}
                # a click on an already selected single item starts a rename on the second click only after the double click time; not done here
                self.drag = {kind: "items", x0: x, y0: y, moved: false}
            self.focus = i
            self.anchor = i
            if right:
                self.open_menu(x, y, true)
            return true
        # the empty area: clear the selection, rubber band
        self.sel = {}
        self.last_click = nil
        if right:
            self.open_menu(x, y, false)
        else:
            self.drag = {kind: "band", x0: x, y0: y + self.scroll * ROW}
        return true

    func on_move(self, x, y):
        let d = self.drag
        if d == nil:
            let b = self.button_at(x, y) if y < TOOL_H else ""
            if b != self.hot_btn:
                self.hot_btn = b
                return true
            return false
        let n = len(self.entries)
        if d.kind == "scroll":
            let v = self.visible_rows()
            let track = v * ROW
            let thumb_h = imax(16, track * v // n)
            let span = imax(1, track - thumb_h)
            let pos = clamp(y - d.dy - self.rows_y(), 0, span)
            self.scroll = pos * (n - v) // span
            return true
        if d.kind == "items":
            if not d.moved and (abs_i(x - d.x0) > 4 or abs_i(y - d.y0) > 4):
                d.moved = true
            d.x = x
            d.y = y
            return d.moved
        if d.kind == "band":
            d.x = x
            d.y = y + self.scroll * ROW
            # rows touched by the band
            let top = imin(d.y0, d.y)
            let bot = imax(d.y0, d.y)
            self.sel = {}
            let first = (top - self.rows_y()) // ROW
            let last = (bot - self.rows_y()) // ROW
            for i in range(imax(0, first), imin(n - 1, last) + 1):
                self.sel[self.entries[i].name] = true
            return true
        return false

    func on_up(self, x, y):
        let d = self.drag
        self.drag = nil
        if d == nil:
            return false
        if d.kind == "items" and d.moved:
            # dropped on a folder row in the list, or on a node of the tree
            let target = nil
            if self.in_list(x, y):
                let i = self.row_at(y)
                if i >= 0 and i < len(self.entries) and self.entries[i].kind == "dir" and not self.sel[self.entries[i].name]:
                    target = joinp(self.cwd, self.entries[i].name)
            elif x < TREE_W and y >= self.body_y() and y < self.h - STATUS_H:
                if self.dirty_tree:
                    self.build_tree()
                let k = (y - self.body_y()) // ROW + self.tree_scroll
                if k >= 0 and k < len(self.tree_rows):
                    target = self.tree_rows[k].path
            if target != nil:
                let paths = []
                for nme in self.selected_names():
                    paths.append(joinp(self.cwd, nme))
                self.paste_into(target, paths, true)
            return true
        return d.kind == "band" or d.kind == "scroll" or d.moved == true

    # ---- drawing ----
    func draw(self):
        let c = self.c
        c.clear_clip()
        c.clear(FACE)
        if self.dirty_tree:
            self.build_tree()
        self.draw_list()
        self.draw_tree()
        self.draw_toolbar()
        self.draw_address()
        self.draw_status()
        if self.menu != nil:
            self.draw_menu()
        if self.modal != nil:
            self.draw_modal()
        c.clear_clip()

    func draw_toolbar(self):
        let c = self.c
        c.gradient_rect(0, 0, self.w, TOOL_H, TB_TOP, TB_BOT)
        c.line(0, TOOL_H - 1, self.w, TOOL_H - 1, LINE)
        let bx = 6
        for b in BUTTONS:
            if b == "|":
                c.line(bx + 4, 6, bx + 4, TOOL_H - 8, LINE)
                bx += 10
                continue
            let on = self.button_enabled(b)
            if on and self.hot_btn == b:
                c.fill_rect(bx, 3, 28, TOOL_H - 7, HOT_BG)
                c.rect(bx, 3, 28, TOOL_H - 7, SEL_LINE)
            draw_button_icon(c, b, bx + 6, 8, on)
            bx += 30

    func draw_address(self):
        let c = self.c
        let y = TOOL_H
        c.fill_rect(0, y, self.w, ADDR_H, FACE)
        c.fill_rect(8, y + 3, self.w - 16, ADDR_H - 6, W_BG)
        c.rect(8, y + 3, self.w - 16, ADDR_H - 6, LINE)
        draw_folder(c, 12, y + 5)
        if self.edit != nil and self.edit.kind == "addr":
            let ed = self.edit
            c.set_clip(32, y + 4, self.w - 50, ADDR_H - 8)
            if ed.all:
                c.fill_rect(32, y + 6, c.text_width(ed.text) + 2, 13, ACCENT)
                c.text(33, y + 9, ed.text, 0xffffff)
            else:
                c.text(33, y + 9, ed.text, TEXT)
                let cx = 33 + c.text_width(ed.text.slice(0, ed.cur)) + (1 if ed.cur > 0 else 0)
                c.line(cx, y + 6, cx, y + 18, TEXT)
            c.clear_clip()
        else:
            # the path as clickable parts "SprintFS > home > user"
            c.text(33, y + 9, self.cwd, TEXT)

    func draw_tree(self):
        let c = self.c
        let y0 = self.body_y()
        c.fill_rect(0, y0, TREE_W, self.h - STATUS_H - y0, W_BG)
        c.line(TREE_W - 1, y0, TREE_W - 1, self.h - STATUS_H, LINE)
        c.set_clip(0, y0, TREE_W - 1, self.h - STATUS_H - y0)
        let vis = self.tree_visible()
        # keep the current folder in view
        for i in range(len(self.tree_rows)):
            if self.tree_rows[i].path == self.cwd:
                if i < self.tree_scroll:
                    self.tree_scroll = i
                elif i >= self.tree_scroll + vis:
                    self.tree_scroll = i - vis + 1
        self.tree_scroll = clamp(self.tree_scroll, 0, imax(0, len(self.tree_rows) - vis))
        for k in range(vis):
            let i = k + self.tree_scroll
            if i >= len(self.tree_rows):
                break
            let r = self.tree_rows[i]
            let y = y0 + k * ROW
            let ax = 6 + r.depth * 14
            if r.path == self.cwd:
                c.fill_rect(0, y, TREE_W - 1, ROW, SEL_BG)
            # the expander
            c.rect(ax, y + 5, 9, 9, 0x909090)
            c.line(ax + 2, y + 9, ax + 6, y + 9, 0x404040)
            if not r.open:
                c.line(ax + 4, y + 7, ax + 4, y + 11, 0x404040)
            draw_folder(c, ax + 13, y + 2)
            c.text(ax + 32, y + 6, r.name, TEXT)
        c.clear_clip()

    func draw_list(self):
        let c = self.c
        let x0 = TREE_W
        let y0 = self.body_y()
        let lw = self.list_w()
        c.fill_rect(x0, y0, lw, self.h - STATUS_H - y0, W_BG)
        # the heading
        c.gradient_rect(x0, y0, lw, HEAD_H, 0xffffff, 0xf3f3f3)
        c.line(x0, y0 + HEAD_H - 1, self.w, y0 + HEAD_H - 1, LINE)
        let nw = self.col_name_w()
        let cols = [["Name", "name", x0, nw], ["Date modified", "date", x0 + nw, 130], ["Type", "type", x0 + nw + 130, 110], ["Size", "size", x0 + nw + 240, 80]]
        for col in cols:
            c.line(col[2] + col[3] - 1, y0 + 3, col[2] + col[3] - 1, y0 + HEAD_H - 4, LINE)
            c.text(col[2] + 6, y0 + 7, col[0], TEXT)
            if self.sort_key == col[1]:
                let ax = col[2] + col[3] // 2
                if self.sort_asc:
                    c.fill_triangle(ax - 3, y0 + 3, ax + 3, y0 + 3, ax, y0 + 6, 0x808080)
                else:
                    c.fill_triangle(ax - 3, y0 + 6, ax + 3, y0 + 6, ax, y0 + 3, 0x808080)
        let v = self.visible_rows()
        let n = len(self.entries)
        let ry = self.rows_y()
        c.set_clip(x0, ry, lw, v * ROW + 1)
        if n == 0:
            c.text(x0 + 24, ry + 12, "This folder is empty.", GREY)
        for k in range(v):
            let i = k + self.scroll
            if i >= n:
                break
            let e = self.entries[i]
            let y = ry + k * ROW
            let on = self.sel[e.name] == true
            if on:
                c.fill_rect(x0 + 1, y, lw - 2 - (SCROLL_W if self.need_scroll() else 0), ROW, SEL_BG)
                c.rect(x0 + 1, y, lw - 2 - (SCROLL_W if self.need_scroll() else 0), ROW, SEL_LINE)
            if i == self.focus and not on:
                c.rect(x0 + 1, y, lw - 2 - (SCROLL_W if self.need_scroll() else 0), ROW, 0xb0b0b0)
            if e.kind == "dir":
                draw_folder(c, x0 + 6, y + 2)
            else:
                draw_file(c, x0 + 6, y + 2, ext_of(e.name))
            let cut = self.clip != nil and self.clip.cut and self.clip.paths.contains(joinp(self.cwd, e.name))
            let col = 0x9a9a9a if cut else TEXT
            if self.edit != nil and self.edit.kind == "rename" and self.edit.name == e.name:
                let ed = self.edit
                c.fill_rect(x0 + 24, y + 1, nw - 30, ROW - 2, 0xffffff)
                c.rect(x0 + 24, y + 1, nw - 30, ROW - 2, ACCENT)
                c.set_clip(x0 + 25, y + 2, nw - 32, ROW - 4)
                if ed.all:
                    c.fill_rect(x0 + 26, y + 3, c.text_width(ed.text) + 2, ROW - 6, ACCENT)
                    c.text(x0 + 27, y + 6, ed.text, 0xffffff)
                else:
                    c.text(x0 + 27, y + 6, ed.text, TEXT)
                    let cx = x0 + 27 + c.text_width(ed.text.slice(0, ed.cur)) + (1 if ed.cur > 0 else 0)
                    c.line(cx, y + 4, cx, y + ROW - 5, TEXT)
                c.set_clip(x0, ry, lw, v * ROW + 1)
            else:
                c.text(x0 + 27, y + 6, fit(c, e.name, nw - 34), col)
            c.text(x0 + nw + 6, y + 6, date_text(self.mtime_of(e.name)), GREY)
            c.text(x0 + nw + 136, y + 6, type_text(e), GREY)
            if e.kind != "dir":
                let st = size_text(e.size)
                c.text(x0 + nw + 320 - 8 - c.text_width(st), y + 6, st, GREY)
        # rubber band and drag feedback
        let d = self.drag
        if d != nil and d.kind == "band" and d.x != nil:
            let bx = imin(d.x0, d.x)
            let by = imin(d.y0, d.y) - self.scroll * ROW
            c.set_alpha(70)
            c.fill_rect(bx, by, abs_i(d.x - d.x0), abs_i(d.y - d.y0), ACCENT)
            c.set_alpha(255)
            c.rect(bx, by, abs_i(d.x - d.x0), abs_i(d.y - d.y0), ACCENT)
        if d != nil and d.kind == "items" and d.moved:
            c.set_alpha(160)
            c.fill_rect(d.x + 8, d.y + 6, 110, 16, SEL_BG)
            c.set_alpha(255)
            c.text(d.x + 12, d.y + 10, to_string(len(self.selected_names())) .. " item(s)", TEXT)
        c.clear_clip()
        # the scroll bar
        if self.need_scroll():
            let sx = self.w - SCROLL_W
            c.fill_rect(sx, ry, SCROLL_W, v * ROW, 0xf0f0f0)
            let track = v * ROW
            let thumb_h = imax(16, track * v // n)
            let ty = ry + (track - thumb_h) * self.scroll // imax(1, n - v)
            c.fill_rect(sx + 2, ty, SCROLL_W - 4, thumb_h, 0xc1c1c1)

    func draw_status(self):
        let c = self.c
        let y = self.h - STATUS_H
        c.fill_rect(0, y, self.w, STATUS_H, FACE)
        c.line(0, y, self.w, y, LINE)
        let n = len(self.entries)
        let names = self.selected_names()
        let text = to_string(n) .. " item" .. ("" if n == 1 else "s")
        if len(names) > 0:
            let total = 0
            for nme in names:
                let en = self.entry_named(nme)
                if en != nil and en.kind != "dir":
                    total += en.size
            text = text .. "   |   " .. to_string(len(names)) .. " selected"
            if total > 0:
                text = text .. "  " .. size_text(total)
        if self.status != "":
            text = text .. "   |   " .. self.status
        c.text(8, y + 7, text, TEXT)
        try:
            let sf = self.fs.statfs()
            let free = sf.free_blocks * 4096
            let all = sf.blocks * 4096
            let t = size_text(free) .. " free of " .. size_text(all)
            c.text(self.w - 8 - c.text_width(t), y + 7, t, GREY)
        catch e:
            pass

    func draw_menu(self):
        let c = self.c
        let m = self.menu
        let mh = 4 + 22 * len(m.items)
        c.fill_rect(m.x + 2, m.y + 2, m.w, mh, 0xc8c8c8)
        c.fill_rect(m.x, m.y, m.w, mh, 0xf5f5f5)
        c.rect(m.x, m.y, m.w, mh, 0x909090)
        for i in range(len(m.items)):
            let it = m.items[i]
            c.text(m.x + 14, m.y + 9 + i * 22, it[0], TEXT if it[2] else 0xa0a0a0)

    func draw_modal(self):
        let c = self.c
        let m = self.modal
        c.set_alpha(90)
        c.fill_rect(0, 0, self.w, self.h, 0x000000)
        c.set_alpha(255)
        let bw = 300
        let bh = 110
        let bx = (self.w - bw) // 2
        let by = (self.h - bh) // 2
        c.fill_rect(bx + 3, by + 3, bw, bh, 0x606060)
        c.fill_rect(bx, by, bw, bh, 0xffffff)
        c.rect(bx, by, bw, bh, ACCENT)
        c.fill_rect(bx + 1, by + 1, bw - 2, 20, ACCENT)
        c.text(bx + 8, by + 7, m.title if m.kind == "confirm" else "File Explorer", 0xffffff)
        c.set_clip(bx + 8, by + 26, bw - 16, 50)
        c.text(bx + 12, by + 32, m.text, TEXT)
        c.clear_clip()
        c.fill_rect(bx + 1, by + bh - 40, bw - 2, 39, 0xf0f0f0)
        if m.kind == "confirm":
            self.button(bx + bw - 160, by + bh - 32, 68, 22, "Yes", true)
            self.button(bx + bw - 80, by + bh - 32, 68, 22, "No", false)
        else:
            self.button(bx + bw - 80, by + bh - 32, 68, 22, "OK", true)

    func button(self, x, y, w, h, label, default):
        let c = self.c
        c.fill_rect(x, y, w, h, 0xe1e1e1)
        c.rect(x, y, w, h, ACCENT if default else 0xadadad)
        c.text(x + (w - c.text_width(label)) // 2, y + 7, label, TEXT)

func abs_i(v):
    return v if v >= 0 else -v

func last_plus(k):
    let i = len(k) - 2
    while i >= 0:
        if k[i] == 43:
            return i
        i -= 1
    return -1

# a backend over a SprintFS volume object (sprintfs.mount(...)): for programs that hold the volume themselves, and for the tests
export class VolumeBackend:
    let v = nil
    func init(self, volume):
        self.v = volume
    func listdir(self, path):
        let out = []
        for name in self.v.listdir(path):
            let st = self.v.lstat(joinp(path, name))
            out.append({kind: st.kind, size: st.size, name: name})
        return out
    func stat(self, path):
        return self.v.stat(path)
    func exists(self, path):
        return self.v.exists(path)
    func mkdir(self, path):
        self.v.mkdir(path)
    func unlink(self, path):
        self.v.unlink(path)
    func rmdir(self, path):
        self.v.rmdir(path)
    func rename(self, old, new):
        self.v.rename(old, new)
    func read_bytes(self, path, off, n):
        let f = self.v.open(path, "r")
        f.seek(off)
        let d = f.read(n)
        f.close()
        return d
    func write_bytes(self, path, data, off, truncate):
        let f = self.v.open(path, "r+" if self.v.exists(path) else "w+")
        if truncate:
            f.truncate(0)
        f.seek(off)
        f.write(data)
        f.close()
        return len(data)
    func statfs(self):
        return self.v.statfs()
