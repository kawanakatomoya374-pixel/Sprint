/* _win32: native Win32 window for the `window` module's "win32" backend (Windows only; a stub elsewhere).
 *
 * Same interface as lib_x11.c: open(w, h, title) returns a window object with poll(ms), present(canvas), set_title,
 * set_cursor, get_clipboard, set_clipboard and close. Window messages are turned into gui event dicts in the window
 * procedure and queued; poll() pumps the message loop and hands the queue over. Needs --allow-window and is never
 * available with --deterministic. Text arrives through WM_CHAR (UTF-16, so IME input works); named keys and Ctrl/Alt
 * combinations through WM_KEYDOWN. */
#define _POSIX_C_SOURCE 200809L
#include "sp.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#if !defined(_WIN32)
static int w32_unsupported(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv; (void)ret;
    return vm_set_error(vm, E_RUNTIME, "the win32 backend is only available on Windows");
}
const NativeDesc lib_win32_fns[] = {{"open", 3, 3, w32_unsupported}, {NULL, 0, 0, NULL}};
#else
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <windowsx.h>

/* queued event: a small tagged record; dicts are built in poll() where the VM is available */
typedef struct WEv {
    int kind; /* 1 move, 2 down, 3 up, 4 wheel, 5 key, 6 text, 7 quit */
    int x, y, button, clicks, dy;
    char mods[24];
    char text[64]; /* key name or UTF-8 text */
} WEv;

enum { QMAX = 1024, NCUR = 12 };
typedef struct W32 {
    HWND hwnd;
    int w, h, open;
    uint32_t *buf;
    WEv q[QMAX];
    int qn;
    int cur_id;
    HCURSOR cur[NCUR];
    DWORD last_t;
    int last_x, last_y, last_btn, clicks;
    wchar_t high_surrogate;
    int moved_in_queue;
} W32;

static const NativeClass w32_class;
static const wchar_t *CLASS_NAME = L"SprintWindow";
static int g_class_registered;

static void push(W32 *w, const WEv *e) {
    if (w->qn < QMAX) w->q[w->qn++] = *e;
}

static void mods_now(char *out) {
    size_t n = 0;
    out[0] = 0;
    if (GetKeyState(VK_CONTROL) & 0x8000) { memcpy(out + n, "Ctrl", 4); n += 4; }
    if (GetKeyState(VK_MENU) & 0x8000) { if (n) out[n++] = '+'; memcpy(out + n, "Alt", 3); n += 3; }
    if (GetKeyState(VK_SHIFT) & 0x8000) { if (n) out[n++] = '+'; memcpy(out + n, "Shift", 5); n += 5; }
    out[n] = 0;
}

static const char *vk_name(WPARAM vk, int shift, int *no_shift_prefix) {
    static char fk[8];
    *no_shift_prefix = 0;
    switch (vk) {
    case VK_BACK: return "Backspace";
    case VK_TAB: if (shift) { *no_shift_prefix = 1; return "ShiftTab"; } return "Tab";
    case VK_RETURN: return "Enter";
    case VK_ESCAPE: return "Escape";
    case VK_DELETE: return "Delete";
    case VK_INSERT: return "Insert";
    case VK_HOME: return "Home";
    case VK_END: return "End";
    case VK_PRIOR: return "PageUp";
    case VK_NEXT: return "PageDown";
    case VK_LEFT: return "Left";
    case VK_UP: return "Up";
    case VK_RIGHT: return "Right";
    case VK_DOWN: return "Down";
    default: break;
    }
    if (vk >= VK_F1 && vk <= VK_F12) {
        (void)snprintf(fk, sizeof fk, "F%d", (int)(vk - VK_F1) + 1);
        return fk;
    }
    return NULL;
}

static int utf16_to_utf8(const wchar_t *src, int n, char *dst, int cap) {
    return WideCharToMultiByte(CP_UTF8, 0, src, n, dst, cap, NULL, NULL);
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    W32 *w = (W32 *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (!w) return DefWindowProcW(hwnd, msg, wp, lp);
    WEv e;
    memset(&e, 0, sizeof e);
    switch (msg) {
    case WM_MOUSEMOVE:
        e.kind = 1; e.x = GET_X_LPARAM(lp); e.y = GET_Y_LPARAM(lp);
        if (w->qn > 0 && w->q[w->qn - 1].kind == 1) { w->q[w->qn - 1].x = e.x; w->q[w->qn - 1].y = e.y; return 0; }
        push(w, &e);
        return 0;
    case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN:
    case WM_LBUTTONUP: case WM_RBUTTONUP: case WM_MBUTTONUP: {
        int down = msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN;
        int btn = (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP) ? 1 : (msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP) ? 2 : 3;
        e.kind = down ? 2 : 3; e.x = GET_X_LPARAM(lp); e.y = GET_Y_LPARAM(lp); e.button = btn;
        mods_now(e.mods);
        if (down) {
            SetCapture(hwnd);
            DWORD t = GetMessageTime();
            int near = btn == w->last_btn && abs(e.x - w->last_x) <= 4 && abs(e.y - w->last_y) <= 4 && (DWORD)(t - w->last_t) <= GetDoubleClickTime();
            w->clicks = near ? (w->clicks < 3 ? w->clicks + 1 : 3) : 1;
            w->last_btn = btn; w->last_x = e.x; w->last_y = e.y; w->last_t = t;
            e.clicks = w->clicks;
        } else {
            ReleaseCapture();
        }
        push(w, &e);
        return 0;
    }
    case WM_MOUSEWHEEL: {
        POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        ScreenToClient(hwnd, &p);
        e.kind = 4; e.x = p.x; e.y = p.y; e.dy = GET_WHEEL_DELTA_WPARAM(wp) > 0 ? -1 : 1;
        push(w, &e);
        return 0;
    }
    case WM_KEYDOWN: case WM_SYSKEYDOWN: {
        int ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0, alt = (GetKeyState(VK_MENU) & 0x8000) != 0, shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        int no_shift = 0;
        const char *name = vk_name(wp, shift, &no_shift);
        char pre[24];
        mods_now(pre);
        if (!name && (ctrl || alt) && ((wp >= 'A' && wp <= 'Z') || (wp >= '0' && wp <= '9') || wp == VK_SPACE)) {
            char base[2] = {(char)(wp >= 'A' && wp <= 'Z' ? wp - 'A' + 'a' : wp == VK_SPACE ? ' ' : wp), 0};
            e.kind = 5;
            (void)snprintf(e.text, sizeof e.text, "%s+%s", pre, base);
            push(w, &e);
            return 0;
        }
        if (name) {
            if (no_shift) { /* "ShiftTab" carries Shift in its name */
                char *s = strstr(pre, "Shift");
                if (s) { if (s != pre) s[-1] = 0; else pre[0] = 0; }
            }
            e.kind = 5;
            (void)snprintf(e.text, sizeof e.text, "%s%s%s", pre, pre[0] ? "+" : "", name);
            push(w, &e);
            return 0;
        }
        break; /* printable keys: the text arrives as WM_CHAR */
    }
    case WM_CHAR: {
        wchar_t c = (wchar_t)wp;
        if (c < 0x20 || c == 0x7f) return 0; /* control characters were reported as keys */
        wchar_t pair[2];
        int n = 1;
        if (c >= 0xD800 && c < 0xDC00) { w->high_surrogate = c; return 0; }
        if (c >= 0xDC00 && c < 0xE000) {
            if (!w->high_surrogate) return 0;
            pair[0] = w->high_surrogate; pair[1] = c; n = 2;
        } else {
            pair[0] = c;
        }
        w->high_surrogate = 0;
        e.kind = 6;
        int len = utf16_to_utf8(pair, n, e.text, (int)sizeof e.text - 1);
        if (len > 0) { e.text[len] = 0; push(w, &e); }
        return 0;
    }
    case WM_CLOSE:
        e.kind = 7;
        push(w, &e);
        return 0; /* the program decides (window.run closes the window on "quit") */
    case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT && w->cur[w->cur_id]) { SetCursor(w->cur[w->cur_id]); return TRUE; }
        break;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        if (w->buf) {
            BITMAPINFO bi;
            memset(&bi, 0, sizeof bi);
            bi.bmiHeader.biSize = sizeof bi.bmiHeader;
            bi.bmiHeader.biWidth = w->w;
            bi.bmiHeader.biHeight = -w->h; /* top-down */
            bi.bmiHeader.biPlanes = 1;
            bi.bmiHeader.biBitCount = 32;
            bi.bmiHeader.biCompression = BI_RGB;
            (void)SetDIBitsToDevice(dc, 0, 0, (DWORD)w->w, (DWORD)w->h, 0, 0, 0, (UINT)w->h, w->buf, &bi, DIB_RGB_COLORS);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void w32_release(void *self) {
    W32 *w = (W32 *)self;
    if (w->hwnd) {
        SetWindowLongPtrW(w->hwnd, GWLP_USERDATA, 0);
        DestroyWindow(w->hwnd);
    }
    free(w->buf);
    w->hwnd = NULL;
    w->buf = NULL;
    w->open = 0;
}

static W32 *self_win(VM *vm, SpValue v, int need_open) {
    if (v.type != T_NATIVE || AS_NATIVE(v)->cls != &w32_class) {
        (void)vm_set_error(vm, E_TYPE, "expected a win32 window, not %s", type_name(v));
        return NULL;
    }
    W32 *w = (W32 *)AS_NATIVE(v)->data;
    if (need_open && !w->open) {
        (void)vm_set_error(vm, E_RUNTIME, "the win32 window is closed");
        return NULL;
    }
    return w;
}

static SpValue vstr(VM *vm, const char *s, size_t n) { return v_obj(T_STRING, vm_new_string(vm, s, n)); }
static void set_int(VM *vm, STable *t, const char *k, int64_t v) { table_set_str(vm, t, k, strlen(k), v_int(v)); }
static void set_str(VM *vm, STable *t, const char *k, const char *s, size_t n) {
    SpValue sv = vstr(vm, s, n);
    table_set_str(vm, t, k, strlen(k), sv);
}
static STable *new_event(VM *vm, SArray *out, const char *type) {
    STable *t = vm_new_table(vm, 6);
    (void)array_push(vm, out, v_obj(T_TABLE, t)); /* rooted through the result array before it gets fields */
    set_str(vm, t, "type", type, strlen(type));
    return t;
}

/* poll(timeout_ms): wait up to timeout for messages, return the gui events that arrived */
static int wm_poll(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    W32 *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_INT) return vm_set_error(vm, E_TYPE, "timeout must be an int (milliseconds)");
    int64_t ms = argv[1].as.i;
    if (ms < 0) ms = 0;
    if (ms > 60000) ms = 60000;
    SArray *out = vm_new_array(vm, 8);
    *ret = v_obj(T_ARRAY, out);
    MSG m;
    if (ms > 0 && !PeekMessageW(&m, NULL, 0, 0, PM_NOREMOVE) && w->qn == 0) (void)MsgWaitForMultipleObjects(0, NULL, FALSE, (DWORD)ms, QS_ALLINPUT);
    while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
        if (w->qn >= QMAX - 8) break;
    }
    for (int i = 0; i < w->qn; i++) {
        const WEv *e = &w->q[i];
        STable *t;
        switch (e->kind) {
        case 1: t = new_event(vm, out, "mouse_move"); set_int(vm, t, "x", e->x); set_int(vm, t, "y", e->y); break;
        case 2: case 3:
            t = new_event(vm, out, e->kind == 2 ? "mouse_down" : "mouse_up");
            set_int(vm, t, "x", e->x); set_int(vm, t, "y", e->y); set_int(vm, t, "button", e->button);
            set_str(vm, t, "mods", e->mods, strlen(e->mods));
            if (e->kind == 2) set_int(vm, t, "clicks", e->clicks);
            break;
        case 4: t = new_event(vm, out, "wheel"); set_int(vm, t, "x", e->x); set_int(vm, t, "y", e->y); set_int(vm, t, "dy", e->dy); break;
        case 5: t = new_event(vm, out, "key"); set_str(vm, t, "key", e->text, strlen(e->text)); break;
        case 6: t = new_event(vm, out, "text"); set_str(vm, t, "text", e->text, strlen(e->text)); break;
        case 7: (void)new_event(vm, out, "quit"); break;
        default: break;
        }
    }
    w->qn = 0;
    return 0;
}

static int wm_present(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    W32 *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    int cw = 0, ch = 0;
    const uint32_t *px = gfx_canvas_pixels(argv[1], &cw, &ch);
    if (!px) return vm_set_error(vm, E_TYPE, "present needs a canvas, not %s", type_name(argv[1]));
    if (cw != w->w || ch != w->h) return vm_set_error(vm, E_VALUE, "canvas is %dx%d but the window is %dx%d", cw, ch, w->w, w->h);
    memcpy(w->buf, px, (size_t)cw * (size_t)ch * sizeof *px);
    InvalidateRect(w->hwnd, NULL, FALSE);
    UpdateWindow(w->hwnd);
    return 0;
}

static int wm_set_title(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    W32 *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "title must be a string");
    const SString *s = AS_STR(argv[1]);
    int n = MultiByteToWideChar(CP_UTF8, 0, s->dp, (int)s->len, NULL, 0);
    wchar_t *ws = (wchar_t *)malloc(((size_t)n + 1) * sizeof *ws);
    if (!ws) return vm_set_error(vm, E_MEMORY, "out of memory");
    n = MultiByteToWideChar(CP_UTF8, 0, s->dp, (int)s->len, ws, n);
    ws[n] = 0;
    SetWindowTextW(w->hwnd, ws);
    free(ws);
    return 0;
}

static int wm_set_cursor(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    W32 *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "cursor name must be a string");
    static const struct { const char *name; LPCWSTR res; } map[NCUR] = {
        {"arrow", IDC_ARROW}, {"ibeam", IDC_IBEAM}, {"hand", IDC_HAND}, {"grab", IDC_HAND}, {"move", IDC_SIZEALL},
        {"resize_h", IDC_SIZEWE}, {"resize_v", IDC_SIZENS}, {"crosshair", IDC_CROSS}, {"wait", IDC_WAIT}, {"no", IDC_NO},
        {"none", IDC_ARROW}, {"default", IDC_ARROW}};
    int id = 0;
    for (int i = 0; i < NCUR; i++)
        if (strcmp(map[i].name, AS_STR(argv[1])->dp) == 0) { id = i; break; }
    if (!w->cur[id]) w->cur[id] = LoadCursorW(NULL, map[id].res);
    w->cur_id = id;
    SetCursor(w->cur[id]);
    return 0;
}

static int wm_set_clipboard(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    W32 *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "clipboard text must be a string");
    const SString *s = AS_STR(argv[1]);
    int n = MultiByteToWideChar(CP_UTF8, 0, s->dp, (int)s->len, NULL, 0);
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, ((size_t)n + 1) * sizeof(wchar_t));
    if (!g) return vm_set_error(vm, E_MEMORY, "out of memory");
    wchar_t *p = (wchar_t *)GlobalLock(g);
    n = MultiByteToWideChar(CP_UTF8, 0, s->dp, (int)s->len, p, n);
    p[n] = 0;
    GlobalUnlock(g);
    if (!OpenClipboard(w->hwnd)) { GlobalFree(g); return 0; }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, g)) GlobalFree(g);
    CloseClipboard();
    return 0;
}

static int wm_get_clipboard(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    W32 *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    *ret = vstr(vm, "", 0);
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT) || !OpenClipboard(w->hwnd)) return 0;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t *p = (const wchar_t *)GlobalLock(h);
        if (p) {
            int n = WideCharToMultiByte(CP_UTF8, 0, p, -1, NULL, 0, NULL, NULL);
            if (n > 1) {
                char *u = (char *)malloc((size_t)n);
                if (u) {
                    (void)WideCharToMultiByte(CP_UTF8, 0, p, -1, u, n, NULL, NULL);
                    *ret = vstr(vm, u, (size_t)n - 1);
                    free(u);
                }
            }
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return 0;
}

static int wm_close(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    W32 *w = self_win(vm, argv[0], 0);
    if (!w) return 1;
    w32_release(w);
    return 0;
}

static const NativeDesc w32_methods[] = {
    {"poll", 2, 2, wm_poll}, {"present", 2, 2, wm_present}, {"set_title", 2, 2, wm_set_title},
    {"set_cursor", 2, 2, wm_set_cursor}, {"set_clipboard", 2, 2, wm_set_clipboard},
    {"get_clipboard", 1, 1, wm_get_clipboard}, {"close", 1, 1, wm_close}, {NULL, 0, 0, NULL}};
static const NativeClass w32_class = {"win32_window", w32_methods, w32_release, NULL};

/* open(w, h, title) -> window */
static int w_open(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (!(vm->caps & CAP_WINDOW) || vm->deterministic)
        return vm_set_error(vm, E_PERM, "windows are not permitted (run with --allow-window; never available with --deterministic)");
    if (argv[0].type != T_INT || argv[1].type != T_INT) return vm_set_error(vm, E_TYPE, "width and height must be ints");
    if (argv[2].type != T_STRING) return vm_set_error(vm, E_TYPE, "title must be a string");
    int64_t W = argv[0].as.i, H = argv[1].as.i;
    if (W < 1 || H < 1 || W > 16384 || H > 16384) return vm_set_error(vm, E_VALUE, "window size out of range");

    SNativeObj *o = vm_new_native_obj(vm, &w32_class, sizeof(W32));
    W32 *w = (W32 *)o->data;
    memset(w, 0, sizeof *w);
    *ret = v_obj(T_NATIVE, o); /* cleaned up by the GC if anything below fails */
    HINSTANCE inst = GetModuleHandleW(NULL);
    if (!g_class_registered) {
        (void)SetProcessDPIAware(); /* pixels are pixels: no bitmap scaling on high-DPI displays */
        WNDCLASSEXW wc;
        memset(&wc, 0, sizeof wc);
        wc.cbSize = sizeof wc;
        wc.style = CS_OWNDC;
        wc.lpfnWndProc = wndproc;
        wc.hInstance = inst;
        wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
        wc.lpszClassName = CLASS_NAME;
        if (!RegisterClassExW(&wc)) return vm_set_error(vm, E_IO, "cannot register the window class (error %lu)", (unsigned long)GetLastError());
        g_class_registered = 1;
    }
    w->w = (int)W;
    w->h = (int)H;
    w->buf = (uint32_t *)calloc((size_t)W * (size_t)H, sizeof *w->buf);
    if (!w->buf) return vm_set_error(vm, E_MEMORY, "out of memory");
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX; /* fixed size: the canvas has one size */
    RECT r = {0, 0, (LONG)W, (LONG)H};
    AdjustWindowRect(&r, style, FALSE);
    const SString *t = AS_STR(argv[2]);
    int n = MultiByteToWideChar(CP_UTF8, 0, t->dp, (int)t->len, NULL, 0);
    wchar_t *wt = (wchar_t *)malloc(((size_t)n + 1) * sizeof *wt);
    if (!wt) return vm_set_error(vm, E_MEMORY, "out of memory");
    n = MultiByteToWideChar(CP_UTF8, 0, t->dp, (int)t->len, wt, n);
    wt[n] = 0;
    w->hwnd = CreateWindowExW(0, CLASS_NAME, wt, style, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, NULL, NULL, inst, NULL);
    free(wt);
    if (!w->hwnd) return vm_set_error(vm, E_IO, "cannot create the window (error %lu)", (unsigned long)GetLastError());
    SetWindowLongPtrW(w->hwnd, GWLP_USERDATA, (LONG_PTR)w);
    w->open = 1;
    ShowWindow(w->hwnd, SW_SHOW);
    UpdateWindow(w->hwnd);
    return 0;
}

const NativeDesc lib_win32_fns[] = {{"open", 3, 3, w_open}, {NULL, 0, 0, NULL}};
#endif
