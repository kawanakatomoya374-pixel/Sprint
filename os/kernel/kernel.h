/* Sprint OS kernel: shared declarations. The kernel is musl-libc plus the Sprint interpreter, running in
 * ring 0; a Linux "system call" is a jump into ksyscall() (boot.S), and the memory, console and clock
 * services behind it are in kmain.c. Hardware access for Sprint programs is the `hw` module (hw.c). */
#ifndef OS_KERNEL_H
#define OS_KERNEL_H
#include <stddef.h>
#include <stdint.h>

typedef struct Framebuffer {
    uint64_t addr;
    uint32_t pitch, width, height;
    uint8_t bpp;
    int present; /* a linear framebuffer was given by the boot loader */
} Framebuffer;

extern Framebuffer g_fb;
extern uint64_t g_mem_total, g_mem_free_pages;
typedef struct Range { uint64_t start, len; } Range;
extern Range g_user_mem[64];
extern int g_nuser_mem;

static inline void outb(uint16_t p, uint8_t v) { __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(p)); }
static inline uint8_t inb(uint16_t p) { uint8_t v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void outw(uint16_t p, uint16_t v) { __asm__ volatile("outw %0, %1" : : "a"(v), "Nd"(p)); }
static inline uint16_t inw(uint16_t p) { uint16_t v; __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void outl(uint16_t p, uint32_t v) { __asm__ volatile("outl %0, %1" : : "a"(v), "Nd"(p)); }
static inline uint32_t inl(uint16_t p) { uint32_t v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(p)); return v; }

void serial_write(const char *s, size_t n);
void serial_puts(const char *s);
uint64_t uptime_ms(void);
uint64_t uptime_us(void);
void kpanic(const char *msg) __attribute__((noreturn));
void power_off(void) __attribute__((noreturn));
void reboot(void) __attribute__((noreturn));

struct VM;
int hw_register(struct VM *vm);
void exception_report(uint64_t vec, uint64_t err, uint64_t rip, uint64_t cr2);
extern const char *g_cmdline;
size_t log_read(char *out, size_t max, size_t *cursor);
#endif
