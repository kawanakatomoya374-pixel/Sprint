#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    void *s = dlopen("/lib/x86_64-linux-gnu/libselinux.so.1", RTLD_NOW);
    printf("libselinux: %s\n", s ? "ok" : dlerror());
    void *h = dlopen("/lib/x86_64-linux-gnu/libpcre2-8.so.0", RTLD_NOW);
    printf("dlopen: %s\n", h ? "ok" : dlerror());
    if (h) {
        void *f = dlsym(h, "pcre2_serialize_get_number_of_codes_8");
        void *g = dlsym(h, "pcre2_compile_8");
        printf("dlsym: serialize=%s compile=%s\n", f ? "found" : "MISSING", g ? "found" : "MISSING");
    }
    return 0;
}
