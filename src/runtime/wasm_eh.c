/* WebAssembly (WASI) only: the exception tag that setjmp/longjmp is lowered to (LLVM -wasm-enable-sjlj). wasi-libc's longjmp
 * throws it and the toolchain's libc does not define it, so the program does. The VM uses setjmp/longjmp for errors. */
#if defined(__wasi__)
__asm__(".globl __c_longjmp\n"
        ".tagtype __c_longjmp i32\n"
        "__c_longjmp:\n");
#endif
typedef int sp_wasm_eh_unit_nonempty; /* ISO C: a translation unit is not empty */
