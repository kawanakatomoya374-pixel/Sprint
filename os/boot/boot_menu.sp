# boot_menu: the boot menu both loaders (bios_loader.sp, uefi_loader.sp) show before the kernel starts.
#
# A menu spec is a string: "TIMEOUT[/DEFAULT];label|command line;label|command line;..." - TIMEOUT seconds (0: wait for a key; the menu
# starts the default entry when it runs out), DEFAULT = the number of the entry that is pre-selected (0-based).
# A string without ';' is a plain command line: no menu, the kernel starts at once.
#
#   let m = boot_menu.parse("5;Sprint OS desktop|init=boot;Self-test|init=init;Quiet desktop|init=boot quiet")
#   m.menu (bool), m.timeout, m.default, m.entries = [{label, cmdline}]
#
# Keys (screen and serial port): Up / Down (or k / j), 1-9 (select and boot), Enter (boot), e (edit the command line; Esc goes back).
# The kernel understands `init=NAME` (the first user program) and `quiet` (no output on the serial port).

const MAX_LABEL = 58
const MAX_CMDLINE = 120
const DEFAULT_SPEC = "5;Sprint OS desktop|init=boot;Sprint OS self-test (serial log)|init=init;Sprint OS desktop, quiet (no serial log)|init=boot quiet"
export const default_spec = DEFAULT_SPEC

export func parse(spec):
    if not spec.contains(";"):
        if len(spec) > MAX_CMDLINE:
            throw error("ValueError", "the command line is longer than " .. to_string(MAX_CMDLINE) .. " characters")
        return {menu: false, timeout: 0, default: 0, entries: [{label: "", cmdline: spec}]}
    let parts = spec.split(";")
    let head = parts[0]
    let timeout = 0
    let default = 0
    if head.contains("/"):
        let h = head.split("/")
        timeout = to_int(h[0])
        default = to_int(h[1])
    else:
        timeout = to_int(head)
    let entries = []
    for i in range(1, len(parts)):
        let f = parts[i].split("|")
        if len(f) != 2:
            throw error("ValueError", "menu entry '" .. parts[i] .. "' is not 'label|command line'")
        if len(f[0]) > MAX_LABEL or len(f[1]) > MAX_CMDLINE:
            throw error("ValueError", "menu entry '" .. f[0] .. "' is too long")
        entries.append({label: f[0], cmdline: f[1]})
    if len(entries) == 0 or len(entries) > 9:
        throw error("ValueError", "a menu needs 1 to 9 entries")
    if default < 0 or default >= len(entries):
        throw error("ValueError", "the default entry does not exist")
    return {menu: true, timeout: timeout, default: default, entries: entries}

func str_data(s, wide):
    let parts = []
    for i in range(len(s)):
        parts.append(to_string(s[i]))
    parts.append("0")
    return ("dw " if wide else "db ") .. parts.join(", ")

# assembler data for a loader. BIOS (real mode): menu_tab = {dw label, dw command line} per entry (absolute 16-bit addresses), ASCII labels.
# UEFI (64-bit, position independent): menu_tab = {dd label - menu_tab, dd command line - menu_tab}, UTF-16 labels. Command lines are always
# ASCII (the kernel reads them). `cmdptr` starts at the default entry's command line (the whole answer when there is no menu).
export func data(m, uefi):
    let t = "menu_on: db " .. ("1" if m.menu else "0") .. "\n"
    t = t .. "align 2\nmenu_default: dw " .. to_string(m.default) .. "\nmenu_timeout: dw " .. to_string(m.timeout) .. "\nmenu_count: dw " .. to_string(len(m.entries)) .. "\n"
    if uefi:
        t = t .. "align 4\nmenu_tab:\n"
        for i in range(len(m.entries)):
            t = t .. "    dd menu_lbl" .. to_string(i) .. " - menu_tab, menu_cmd" .. to_string(i) .. " - menu_tab\n"
    else:
        t = t .. "menu_tab:\n"
        for i in range(len(m.entries)):
            t = t .. "    dw menu_lbl" .. to_string(i) .. ", menu_cmd" .. to_string(i) .. "\n"
    for i in range(len(m.entries)):
        t = t .. "menu_lbl" .. to_string(i) .. ": " .. str_data(m.entries[i].label, uefi) .. "\n"
        t = t .. "menu_cmd" .. to_string(i) .. ": " .. str_data(m.entries[i].cmdline, false) .. "\n"
    if not uefi:
        t = t .. "cmdptr: dw menu_cmd" .. to_string(m.default) .. "\n"
    return t
