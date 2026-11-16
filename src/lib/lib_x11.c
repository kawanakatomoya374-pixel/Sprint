/* _x11: native X11 window for the `window` module's "x11" backend (Linux / BSD).
 *
 * libX11 is loaded with dlopen at run time and used through a table of function pointers, so the build needs
 * no X11 headers or libraries and a machine without X simply reports "cannot open X display".  Event records
 * are read at fixed offsets (the x86-64 / AArch64 LP64 Xlib layout) instead of through Xlib's headers.
 * A window is a native object: poll(ms) returns the events that arrived (gui event dicts), present(canvas)
 * shows a finished frame, plus title / cursor / clipboard.  It needs the window capability (--allow-window)
 * and is never available with --deterministic. */
#define _POSIX_C_SOURCE 200809L
#include "sp.h"
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <stdio.h>

#if defined(_WIN32) || defined(__wasi__)
static int x_unsupported(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv; (void)ret;
    return vm_set_error(vm, E_RUNTIME, "the x11 backend is not available on this platform");
}
const NativeDesc lib_x11_fns[] = {{"open", 3, 3, x_unsupported}, {NULL, 0, 0, NULL}};
#else
#include <dlfcn.h>
#include <poll.h>

typedef unsigned long XID; /* Window, Atom, Cursor, Time */
typedef int (*XErrHandler)(void *, void *);

typedef struct XApi {
    void *(*XOpenDisplay)(const char *);
    int (*XCloseDisplay)(void *);
    int (*XDefaultScreen)(void *);
    XID (*XRootWindow)(void *, int);
    void *(*XDefaultVisual)(void *, int);
    int (*XDefaultDepth)(void *, int);
    XID (*XCreateSimpleWindow)(void *, XID, int, int, unsigned, unsigned, unsigned, unsigned long, unsigned long);
    int (*XDestroyWindow)(void *, XID);
    int (*XSelectInput)(void *, XID, long);
    int (*XMapWindow)(void *, XID);
    XID (*XInternAtom)(void *, const char *, int);
    int (*XSetWMProtocols)(void *, XID, XID *, int);
    void (*XSetWMNormalHints)(void *, XID, void *);
    int (*XChangeProperty)(void *, XID, XID, XID, int, int, const unsigned char *, int);
    void *(*XCreateGC)(void *, XID, unsigned long, void *);
    int (*XFreeGC)(void *, void *);
    void *(*XCreateImage)(void *, void *, unsigned, int, int, char *, unsigned, unsigned, int, int);
    int (*XPutImage)(void *, XID, void *, void *, int, int, int, int, unsigned, unsigned);
    int (*XFlush)(void *);
    int (*XPending)(void *);
    int (*XNextEvent)(void *, void *);
    int (*XCheckTypedWindowEvent)(void *, XID, int, void *);
    int (*XConnectionNumber)(void *);
    int (*XLookupString)(void *, char *, int, XID *, void *);
    int (*XFilterEvent)(void *, XID);
    int (*XFree)(void *);
    int (*XSetSelectionOwner)(void *, XID, XID, XID);
    XID (*XGetSelectionOwner)(void *, XID);
    int (*XConvertSelection)(void *, XID, XID, XID, XID, XID);
    int (*XGetWindowProperty)(void *, XID, XID, long, long, int, XID, XID *, int *, unsigned long *, unsigned long *, unsigned char **);
    int (*XSendEvent)(void *, XID, int, long, void *);
    XID (*XCreateFontCursor)(void *, unsigned);
    int (*XDefineCursor)(void *, XID, XID);
    int (*XFreeCursor)(void *, XID);
    XErrHandler (*XSetErrorHandler)(XErrHandler);
    /* input method (optional: UTF-8 text for IME users) */
    char *(*XSetLocaleModifiers)(const char *);
    void *(*XOpenIM)(void *, void *, char *, char *);
    void *(*XCreateIC)(void *, ...);
    void (*XDestroyIC)(void *);
    int (*XCloseIM)(void *);
    int (*Xutf8LookupString)(void *, void *, char *, int, XID *, int *);
    void (*XSetICFocus)(void *);
} XApi;

enum { NCUR = 12 };
typedef struct XWin {
    XApi x;
    void *lib, *dpy, *gc, *img, *im, *ic;
    XID win;
    int w, h, open;
    uint32_t *buf;
    XID a_protocols, a_delete, a_clipboard, a_utf8, a_targets, a_prop, a_net_name, a_text;
    char *clip; /* text we own on CLIPBOARD, or NULL */
    size_t cliplen;
    unsigned long last_t;
    int last_x, last_y, last_btn, clicks;
    XID cur[NCUR];
    int cur_id;
} XWin;

static const NativeClass xwin_class;

/* ---- Xlib constants ------------------------------------------------------------------------- */
enum {
    EV_KEY_PRESS = 2, EV_BUTTON_PRESS = 4, EV_BUTTON_RELEASE = 5, EV_MOTION = 6, EV_EXPOSE = 12,
    EV_SELECTION_CLEAR = 29, EV_SELECTION_REQUEST = 30, EV_SELECTION_NOTIFY = 31, EV_CLIENT_MESSAGE = 33
};
enum { MASK_SHIFT = 1, MASK_CONTROL = 4, MASK_ALT = 8 };
static const long EVENT_MASK = (1L << 0) | (1L << 2) | (1L << 3) | (1L << 6) | (1L << 15) | (1L << 21);

/* ---- event record access (LP64 Xlib layout) --------------------------------------------------- */
static int32_t ev_i32(const long *e, size_t off) { int32_t v; memcpy(&v, (const char *)e + off, sizeof v); return v; }
static uint64_t ev_u64(const long *e, size_t off) { uint64_t v; memcpy(&v, (const char *)e + off, sizeof v); return v; }

static int x_error_handler(void *d, void *e) { (void)d; (void)e; return 0; }

/* ---- load ------------------------------------------------------------------------------------- */
static int load_api(XApi *a, void **lib_out, int *have_im) {
    void *lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("libX11.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return 0;
#define LOAD(n)                                         \
    do {                                                \
        void *s_ = dlsym(lib, #n);                      \
        if (!s_) { (void)dlclose(lib); return 0; }      \
        memcpy(&a->n, &s_, sizeof s_);                  \
    } while (0)
    LOAD(XOpenDisplay); LOAD(XCloseDisplay); LOAD(XDefaultScreen); LOAD(XRootWindow); LOAD(XDefaultVisual);
    LOAD(XDefaultDepth); LOAD(XCreateSimpleWindow); LOAD(XDestroyWindow); LOAD(XSelectInput); LOAD(XMapWindow);
    LOAD(XInternAtom); LOAD(XSetWMProtocols); LOAD(XSetWMNormalHints); LOAD(XChangeProperty); LOAD(XCreateGC);
    LOAD(XFreeGC); LOAD(XCreateImage); LOAD(XPutImage); LOAD(XFlush); LOAD(XPending); LOAD(XNextEvent);
    LOAD(XCheckTypedWindowEvent); LOAD(XConnectionNumber); LOAD(XLookupString); LOAD(XFilterEvent); LOAD(XFree);
    LOAD(XSetSelectionOwner); LOAD(XGetSelectionOwner); LOAD(XConvertSelection); LOAD(XGetWindowProperty);
    LOAD(XSendEvent); LOAD(XCreateFontCursor); LOAD(XDefineCursor); LOAD(XFreeCursor); LOAD(XSetErrorHandler);
#undef LOAD
    *have_im = 1;
#define OPT(n)                                          \
    do {                                                \
        void *s_ = dlsym(lib, #n);                      \
        if (!s_) *have_im = 0;                          \
        else memcpy(&a->n, &s_, sizeof s_);             \
    } while (0)
    OPT(XSetLocaleModifiers); OPT(XOpenIM); OPT(XCreateIC); OPT(XDestroyIC); OPT(XCloseIM); OPT(Xutf8LookupString);
    OPT(XSetICFocus);
#undef OPT
    *lib_out = lib;
    return 1;
}

static void win_free(XWin *w) {
    if (w->dpy) {
        if (w->ic) w->x.XDestroyIC(w->ic);
        if (w->im) (void)w->x.XCloseIM(w->im);
        for (int i = 0; i < NCUR; i++)
            if (w->cur[i]) (void)w->x.XFreeCursor(w->dpy, w->cur[i]);
        if (w->img) (void)w->x.XFree(w->img); /* the pixel buffer is ours: XFree frees only the XImage header */
        if (w->gc) (void)w->x.XFreeGC(w->dpy, w->gc);
        if (w->win) (void)w->x.XDestroyWindow(w->dpy, w->win);
        (void)w->x.XCloseDisplay(w->dpy);
    }
    free(w->buf);
    free(w->clip);
    w->dpy = NULL; w->img = NULL; w->gc = NULL; w->ic = NULL; w->im = NULL; w->buf = NULL; w->clip = NULL; w->win = 0;
    w->open = 0;
}
static void xwin_release(void *self) {
    XWin *w = (XWin *)self;
    win_free(w);
    if (w->lib) (void)dlclose(w->lib);
    w->lib = NULL;
}

static XWin *self_win(VM *vm, SpValue v, int need_open) {
    if (v.type != T_NATIVE || AS_NATIVE(v)->cls != &xwin_class) {
        (void)vm_set_error(vm, E_TYPE, "expected an x11 window, not %s", type_name(v));
        return NULL;
    }
    XWin *w = (XWin *)AS_NATIVE(v)->data;
    if (need_open && !w->open) {
        (void)vm_set_error(vm, E_RUNTIME, "the x11 window is closed");
        return NULL;
    }
    return w;
}

/* ---- building event dicts --------------------------------------------------------------------- */
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

static size_t mods_string(unsigned state, int with_shift, char *buf) {
    size_t n = 0;
    const struct { unsigned mask; const char *name; } m[] = {{MASK_CONTROL, "Ctrl"}, {MASK_ALT, "Alt"}, {MASK_SHIFT, "Shift"}};
    for (int i = 0; i < 3; i++) {
        if (!(state & m[i].mask) || (m[i].mask == MASK_SHIFT && !with_shift)) continue;
        if (n) buf[n++] = '+';
        size_t l = strlen(m[i].name);
        memcpy(buf + n, m[i].name, l);
        n += l;
    }
    buf[n] = 0;
    return n;
}

static const char *keysym_name(unsigned long ks, int shift, int *no_shift_prefix) {
    static char fk[8];
    *no_shift_prefix = 0;
    switch (ks) {
    case 0xff08: return "Backspace";
    case 0xff09: if (shift) { *no_shift_prefix = 1; return "ShiftTab"; } return "Tab";
    case 0xfe20: *no_shift_prefix = 1; return "ShiftTab";
    case 0xff0d: case 0xff8d: return "Enter";
    case 0xff1b: return "Escape";
    case 0xffff: case 0xff9f: return "Delete";
    case 0xff63: return "Insert";
    case 0xff50: case 0xff95: return "Home";
    case 0xff57: case 0xff9c: return "End";
    case 0xff55: case 0xff9a: return "PageUp";
    case 0xff56: case 0xff9b: return "PageDown";
    case 0xff51: case 0xff96: return "Left";
    case 0xff52: case 0xff97: return "Up";
    case 0xff53: case 0xff98: return "Right";
    case 0xff54: case 0xff99: return "Down";
    default: break;
    }
    if (ks >= 0xffbe && ks <= 0xffc9) {
        (void)snprintf(fk, sizeof fk, "F%d", (int)(ks - 0xffbe) + 1);
        return fk;
    }
    return NULL;
}

static void handle_key(VM *vm, XWin *w, long *e, SArray *out) {
    char buf[64];
    XID ks = 0;
    int n;
    unsigned state = (unsigned)ev_i32(e, 80);
    if (w->ic) {
        int status = 0;
        n = w->x.Xutf8LookupString(w->ic, e, buf, (int)sizeof buf - 1, &ks, &status);
        if (status == -1) n = 0; /* XBufferOverflow */
    } else {
        n = w->x.XLookupString(e, buf, (int)sizeof buf - 1, &ks, NULL);
    }
    if (n < 0) n = 0;
    buf[n] = 0;
    int shift = (state & MASK_SHIFT) != 0, ctrl_alt = (state & (MASK_CONTROL | MASK_ALT)) != 0;
    int no_shift = 0;
    const char *name = keysym_name(ks, shift, &no_shift);
    char key[96], pre[24];
    if (name) {
        size_t pl = mods_string(state, !no_shift, pre);
        (void)snprintf(key, sizeof key, "%s%s%s", pre, pl ? "+" : "", name);
    } else if (ctrl_alt && ks >= 0x20 && ks < 0x7f) {
        char base = (char)ks;
        if (base >= 'A' && base <= 'Z') base = (char)(base - 'A' + 'a');
        size_t pl = mods_string(state, 1, pre);
        (void)snprintf(key, sizeof key, "%s+%c", pl ? pre : "", base);
    } else if (n > 0 && (unsigned char)buf[0] >= 0x20 && buf[0] != 0x7f && !ctrl_alt) {
        STable *t = new_event(vm, out, "text");
        set_str(vm, t, "text", buf, (size_t)n);
        return;
    } else {
        return; /* modifier keys alone, dead keys, ... */
    }
    STable *t = new_event(vm, out, "key");
    set_str(vm, t, "key", key, strlen(key));
}

/* ---- clipboard ownership (we answer other clients' requests for our text) -------------------- */
static void serve_selection(XWin *w, const long *e) {
    XID requestor = ev_u64(e, 40), selection = ev_u64(e, 48), target = ev_u64(e, 56), prop = ev_u64(e, 64), tm = ev_u64(e, 72);
    if (!prop) prop = target;
    int ok = 0;
    if (selection == w->a_clipboard && w->clip) {
        if (target == w->a_targets) {
            XID tl[3] = {w->a_targets, w->a_utf8, w->a_text};
            (void)w->x.XChangeProperty(w->dpy, requestor, prop, 4 /* XA_ATOM */, 32, 0, (const unsigned char *)tl, 3);
            ok = 1;
        } else if (target == w->a_utf8 || target == w->a_text) {
            (void)w->x.XChangeProperty(w->dpy, requestor, prop, target, 8, 0, (const unsigned char *)w->clip, (int)w->cliplen);
            ok = 1;
        }
    }
    long rep[24];
    memset(rep, 0, sizeof rep);
    int32_t type = EV_SELECTION_NOTIFY;
    uint64_t dp = (uint64_t)(uintptr_t)w->dpy, v[4] = {requestor, selection, target, ok ? prop : 0};
    memcpy((char *)rep, &type, 4);
    memcpy((char *)rep + 24, &dp, 8);
    memcpy((char *)rep + 32, &v[0], 8);
    memcpy((char *)rep + 40, &v[1], 8);
    memcpy((char *)rep + 48, &v[2], 8);
    memcpy((char *)rep + 56, &v[3], 8);
    memcpy((char *)rep + 64, &tm, 8);
    (void)w->x.XSendEvent(w->dpy, requestor, 0, 0, rep);
    (void)w->x.XFlush(w->dpy);
}

static void blit(XWin *w) {
    if (!w->open || !w->img) return;
    (void)w->x.XPutImage(w->dpy, w->win, w->gc, w->img, 0, 0, 0, 0, (unsigned)w->w, (unsigned)w->h);
    (void)w->x.XFlush(w->dpy);
}

/* ---- methods ---------------------------------------------------------------------------------- */
/* poll(timeout_ms): wait up to timeout for X traffic, return the gui events that arrived */
static int xm_poll(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    XWin *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_INT) return vm_set_error(vm, E_TYPE, "timeout must be an int (milliseconds)");
    int64_t ms = argv[1].as.i;
    if (ms < 0) ms = 0;
    if (ms > 60000) ms = 60000;
    SArray *out = vm_new_array(vm, 8);
    *ret = v_obj(T_ARRAY, out);
    if (ms > 0 && w->x.XPending(w->dpy) == 0) {
        struct pollfd pf = {w->x.XConnectionNumber(w->dpy), POLLIN, 0};
        (void)poll(&pf, 1, (int)ms);
    }
    STable *last_move = NULL;
    int64_t pushed = 0;
    while (w->x.XPending(w->dpy) > 0) {
        long e[24];
        (void)w->x.XNextEvent(w->dpy, e);
        if (w->x.XFilterEvent(e, 0)) continue;
        int type = ev_i32(e, 0);
        unsigned state = (unsigned)ev_i32(e, 80);
        int ex = ev_i32(e, 64), ey = ev_i32(e, 68);
        switch (type) {
        case EV_KEY_PRESS:
            last_move = NULL;
            handle_key(vm, w, e, out);
            break;
        case EV_MOTION:
            if (last_move) {
                set_int(vm, last_move, "x", ex);
                set_int(vm, last_move, "y", ey);
            } else {
                last_move = new_event(vm, out, "mouse_move");
                set_int(vm, last_move, "x", ex);
                set_int(vm, last_move, "y", ey);
            }
            break;
        case EV_BUTTON_PRESS:
        case EV_BUTTON_RELEASE: {
            last_move = NULL;
            unsigned b = (unsigned)ev_i32(e, 84);
            char mods[24];
            (void)mods_string(state, 1, mods);
            if (b >= 4 && b <= 5) {
                if (type == EV_BUTTON_PRESS) {
                    STable *t = new_event(vm, out, "wheel");
                    set_int(vm, t, "x", ex);
                    set_int(vm, t, "y", ey);
                    set_int(vm, t, "dy", b == 5 ? 1 : -1);
                }
            } else if (b >= 1 && b <= 3) {
                STable *t = new_event(vm, out, type == EV_BUTTON_PRESS ? "mouse_down" : "mouse_up");
                set_int(vm, t, "x", ex);
                set_int(vm, t, "y", ey);
                set_int(vm, t, "button", b);
                set_str(vm, t, "mods", mods, strlen(mods));
                if (type == EV_BUTTON_PRESS) {
                    unsigned long tm = (unsigned long)ev_u64(e, 56);
                    int near = (int)b == w->last_btn && abs(ex - w->last_x) <= 4 && abs(ey - w->last_y) <= 4 && tm - w->last_t <= 400;
                    w->clicks = near ? (w->clicks < 3 ? w->clicks + 1 : 3) : 1;
                    w->last_btn = (int)b; w->last_x = ex; w->last_y = ey; w->last_t = tm;
                    set_int(vm, t, "clicks", w->clicks);
                }
            }
            break;
        }
        case EV_EXPOSE:
            if (ev_i32(e, 56) == 0) blit(w);
            break;
        case EV_CLIENT_MESSAGE:
            if (ev_u64(e, 56) == w->a_delete) {
                last_move = NULL;
                (void)new_event(vm, out, "quit");
            }
            break;
        case EV_SELECTION_REQUEST:
            serve_selection(w, e);
            break;
        case EV_SELECTION_CLEAR:
            free(w->clip);
            w->clip = NULL;
            w->cliplen = 0;
            break;
        default:
            break;
        }
        if (++pushed > 4096) break; /* bounded batch */
    }
    return 0;
}

static int xm_present(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    XWin *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    int cw = 0, ch = 0;
    const uint32_t *px = gfx_canvas_pixels(argv[1], &cw, &ch);
    if (!px) return vm_set_error(vm, E_TYPE, "present needs a canvas, not %s", type_name(argv[1]));
    if (cw != w->w || ch != w->h) return vm_set_error(vm, E_VALUE, "canvas is %dx%d but the window is %dx%d", cw, ch, w->w, w->h);
    memcpy(w->buf, px, (size_t)cw * (size_t)ch * sizeof *px);
    blit(w);
    return 0;
}

static int xm_set_title(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    XWin *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "title must be a string");
    const SString *s = AS_STR(argv[1]);
    (void)w->x.XChangeProperty(w->dpy, w->win, w->a_net_name, w->a_utf8, 8, 0, (const unsigned char *)s->dp, (int)s->len);
    (void)w->x.XChangeProperty(w->dpy, w->win, 39 /* XA_WM_NAME */, 31 /* XA_STRING */, 8, 0, (const unsigned char *)s->dp, (int)s->len);
    (void)w->x.XFlush(w->dpy);
    return 0;
}

static int xm_set_cursor(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    XWin *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "cursor name must be a string");
    static const struct { const char *name; unsigned shape; } map[NCUR] = {
        {"arrow", 68}, {"ibeam", 152}, {"hand", 60}, {"grab", 58}, {"move", 52}, {"resize_h", 108},
        {"resize_v", 116}, {"crosshair", 34}, {"wait", 150}, {"no", 0}, {"none", 68}, {"default", 68}};
    int id = 0;
    for (int i = 0; i < NCUR; i++)
        if (strcmp(map[i].name, AS_STR(argv[1])->dp) == 0) { id = i; break; }
    if (id == w->cur_id && w->cur[id]) return 0;
    if (!w->cur[id]) w->cur[id] = w->x.XCreateFontCursor(w->dpy, map[id].shape);
    (void)w->x.XDefineCursor(w->dpy, w->win, w->cur[id]);
    (void)w->x.XFlush(w->dpy);
    w->cur_id = id;
    return 0;
}

static int xm_set_clipboard(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    XWin *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "clipboard text must be a string");
    const SString *s = AS_STR(argv[1]);
    char *c = malloc((size_t)s->len + 1);
    if (!c) return vm_set_error(vm, E_MEMORY, "out of memory");
    memcpy(c, s->dp, s->len);
    free(w->clip);
    w->clip = c;
    w->cliplen = s->len;
    (void)w->x.XSetSelectionOwner(w->dpy, w->a_clipboard, w->win, 0);
    (void)w->x.XFlush(w->dpy);
    return 0;
}

static int xm_get_clipboard(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    XWin *w = self_win(vm, argv[0], 1);
    if (!w) return 1;
    *ret = vstr(vm, "", 0);
    if (w->clip && w->x.XGetSelectionOwner(w->dpy, w->a_clipboard) == w->win) {
        *ret = vstr(vm, w->clip, w->cliplen);
        return 0;
    }
    if (!w->x.XGetSelectionOwner(w->dpy, w->a_clipboard)) return 0;
    (void)w->x.XConvertSelection(w->dpy, w->a_clipboard, w->a_utf8, w->a_prop, w->win, 0);
    (void)w->x.XFlush(w->dpy);
    for (int waited = 0; waited < 500; waited += 10) {
        long e[24];
        if (!w->x.XCheckTypedWindowEvent(w->dpy, w->win, EV_SELECTION_NOTIFY, e)) {
            struct pollfd pf = {w->x.XConnectionNumber(w->dpy), POLLIN, 0};
            (void)poll(&pf, 1, 10);
            continue;
        }
        XID prop = ev_u64(e, 56);
        if (!prop) return 0; /* owner refused the conversion */
        XID type = 0;
        int fmt = 0;
        unsigned long n = 0, after = 0;
        unsigned char *data = NULL;
        if (w->x.XGetWindowProperty(w->dpy, w->win, prop, 0, 1 << 20, 1, 0, &type, &fmt, &n, &after, &data) == 0 && data) {
            if (fmt == 8) *ret = vstr(vm, (const char *)data, (size_t)n);
            (void)w->x.XFree(data);
        }
        return 0;
    }
    return 0;
}

static int xm_close(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    XWin *w = self_win(vm, argv[0], 0);
    if (!w) return 1;
    win_free(w);
    return 0;
}

static const NativeDesc xwin_methods[] = {
    {"poll", 2, 2, xm_poll}, {"present", 2, 2, xm_present}, {"set_title", 2, 2, xm_set_title},
    {"set_cursor", 2, 2, xm_set_cursor}, {"set_clipboard", 2, 2, xm_set_clipboard},
    {"get_clipboard", 1, 1, xm_get_clipboard}, {"close", 1, 1, xm_close}, {NULL, 0, 0, NULL}};
static const NativeClass xwin_class = {"x11_window", xwin_methods, xwin_release, NULL};

/* ---- module function -------------------------------------------------------------------------- */
/* open(w, h, title) -> window */
static int x_open(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (!(vm->caps & CAP_WINDOW) || vm->deterministic)
        return vm_set_error(vm, E_PERM, "windows are not permitted (run with --allow-window; never available with --deterministic)");
    if (argv[0].type != T_INT || argv[1].type != T_INT) return vm_set_error(vm, E_TYPE, "width and height must be ints");
    if (argv[2].type != T_STRING) return vm_set_error(vm, E_TYPE, "title must be a string");
    int64_t W = argv[0].as.i, H = argv[1].as.i;
    if (W < 1 || H < 1 || W > 16384 || H > 16384) return vm_set_error(vm, E_VALUE, "window size out of range");

    SNativeObj *o = vm_new_native_obj(vm, &xwin_class, sizeof(XWin));
    XWin *w = (XWin *)o->data;
    memset(w, 0, sizeof *w);
    *ret = v_obj(T_NATIVE, o); /* released (and cleaned up) by the GC if anything below fails */
    int have_im = 0;
    if (!load_api(&w->x, &w->lib, &have_im)) return vm_set_error(vm, E_IO, "cannot load libX11 (is X11 installed?)");
    (void)w->x.XSetErrorHandler(x_error_handler);
    w->dpy = w->x.XOpenDisplay(NULL);
    if (!w->dpy) {
        const char *d = getenv("DISPLAY");
        return vm_set_error(vm, E_IO, "cannot open the X display (DISPLAY=%s)", d ? d : "unset");
    }
    int scr = w->x.XDefaultScreen(w->dpy);
    void *vis = w->x.XDefaultVisual(w->dpy, scr);
    int depth = w->x.XDefaultDepth(w->dpy, scr);
    uint64_t rm = 0, gm = 0, bm = 0;
    memcpy(&rm, (const char *)vis + 24, 8);
    memcpy(&gm, (const char *)vis + 32, 8);
    memcpy(&bm, (const char *)vis + 40, 8);
    if ((depth != 24 && depth != 32) || rm != 0xff0000 || gm != 0xff00 || bm != 0xff) {
        win_free(w);
        return vm_set_error(vm, E_RUNTIME, "unsupported X visual (need 24/32-bit TrueColor with 8-bit RGB masks)");
    }
    w->w = (int)W;
    w->h = (int)H;
    w->win = w->x.XCreateSimpleWindow(w->dpy, w->x.XRootWindow(w->dpy, scr), 0, 0, (unsigned)W, (unsigned)H, 0, 0, 0x202020);
    w->open = 1;
    w->buf = calloc((size_t)W * (size_t)H, sizeof *w->buf);
    if (!w->buf) { win_free(w); return vm_set_error(vm, E_MEMORY, "out of memory"); }
    w->gc = w->x.XCreateGC(w->dpy, w->win, 0, NULL);
    w->img = w->x.XCreateImage(w->dpy, vis, (unsigned)depth, 2 /* ZPixmap */, 0, (char *)w->buf, (unsigned)W, (unsigned)H, 32, 0);
    if (!w->gc || !w->img) { win_free(w); return vm_set_error(vm, E_RUNTIME, "cannot create the X graphics context"); }
    w->a_protocols = w->x.XInternAtom(w->dpy, "WM_PROTOCOLS", 0);
    w->a_delete = w->x.XInternAtom(w->dpy, "WM_DELETE_WINDOW", 0);
    w->a_clipboard = w->x.XInternAtom(w->dpy, "CLIPBOARD", 0);
    w->a_utf8 = w->x.XInternAtom(w->dpy, "UTF8_STRING", 0);
    w->a_targets = w->x.XInternAtom(w->dpy, "TARGETS", 0);
    w->a_prop = w->x.XInternAtom(w->dpy, "SPRINT_SELECTION", 0);
    w->a_net_name = w->x.XInternAtom(w->dpy, "_NET_WM_NAME", 0);
    w->a_text = 31; /* XA_STRING */
    (void)w->x.XSetWMProtocols(w->dpy, w->win, &w->a_delete, 1);
    {   /* a fixed-size window: the canvas has one size */
        long hints[10];
        memset(hints, 0, sizeof hints);
        int32_t wh[2] = {(int32_t)W, (int32_t)H};
        uint64_t flags = 16 | 32; /* PMinSize | PMaxSize */
        memcpy((char *)hints, &flags, 8);
        memcpy((char *)hints + 24, wh, 8);
        memcpy((char *)hints + 32, wh, 8);
        w->x.XSetWMNormalHints(w->dpy, w->win, hints);
    }
    if (have_im) {
        if (!setlocale(LC_CTYPE, "")) (void)setlocale(LC_CTYPE, "C.UTF-8");
        (void)w->x.XSetLocaleModifiers("");
        w->im = w->x.XOpenIM(w->dpy, NULL, NULL, NULL);
        if (w->im) {
            w->ic = w->x.XCreateIC(w->im, "inputStyle", (unsigned long)0x0408, "clientWindow", w->win, "focusWindow", w->win, (void *)NULL);
            if (!w->ic) { (void)w->x.XCloseIM(w->im); w->im = NULL; }
            else w->x.XSetICFocus(w->ic);
        }
    }
    (void)w->x.XSelectInput(w->dpy, w->win, EVENT_MASK);
    SpValue title = argv[2];
    (void)w->x.XChangeProperty(w->dpy, w->win, w->a_net_name, w->a_utf8, 8, 0, (const unsigned char *)AS_STR(title)->dp, (int)AS_STR(title)->len);
    (void)w->x.XChangeProperty(w->dpy, w->win, 39, 31, 8, 0, (const unsigned char *)AS_STR(title)->dp, (int)AS_STR(title)->len);
    (void)w->x.XMapWindow(w->dpy, w->win);
    (void)w->x.XFlush(w->dpy);
    return 0;
}

const NativeDesc lib_x11_fns[] = {{"open", 3, 3, x_open}, {NULL, 0, 0, NULL}};
#endif
