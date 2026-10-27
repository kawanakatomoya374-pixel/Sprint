# ffi demo: call libc / libm from Sprint, pass a Sprint function to qsort, build a struct.
# run:  sprint run --allow-ffi examples/ffi/ffi_demo.sp
import ffi

ffi.cdef("""
double sqrt(double x);
double pow(double x, double y);
size_t strlen(const char *s);
int snprintf(char *buf, size_t n, const char *fmt, ...);
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));
struct tm { int tm_sec; int tm_min; int tm_hour; int tm_mday; int tm_mon; int tm_year; int tm_wday; int tm_yday; int tm_isdst; long tm_gmtoff; const char *tm_zone; };
struct tm *gmtime_r(const int64_t *t, struct tm *out);
""")
let c = ffi.open(nil)  # the running program: libc and libm are already loaded
let libc = c.bind(["sqrt", "pow", "strlen", "snprintf", "qsort", "gmtime_r"])

print(libc.sqrt(2.0), libc.pow(2, 20), libc.strlen("sprint"))

# printf-style formatting into a buffer
let buf = ffi.array("i8", 64)
libc.snprintf(buf, 64, "%s has %d letters (%.1f%%)", "Sprint", 6, 99.5)
print(buf.str())

# sort an int array with a Sprint comparator called from C
let nums = ffi.array("i32", 8, [42, 7, 19, 3, 88, 1, 56, 23])
libc.qsort(nums, 8, 4, (a, b) => ffi.view(a, "i32", 1).get(0) - ffi.view(b, "i32", 1).get(0))
print(nums.to_array())

# a C struct filled in by libc
let t = ffi.new("int64_t", 86400 * 365)  # one year after the epoch
let tm = ffi.new("struct tm")
libc.gmtime_r(t, tm)
print(1900 + tm.get("tm_year"), tm.get("tm_mon") + 1, tm.get("tm_mday"))
