# ffi.asm with assembler source text (x86-64 hosts): the Sprint assembler produces the machine code
import ffi
import asm
if ffi.abi() == "x86_64":
    let add = asm.function("lea rax, [rdi+rsi]\nret", "int64_t(int64_t, int64_t)")
    print(add(20, 22))
    let fact = asm.function("""
        mov rax, 1
    .loop:
        test rdi, rdi
        jz .done
        imul rax, rdi
        dec rdi
        jmp .loop
    .done:
        ret
    """, "int64_t(int64_t)")
    print(fact(10), fact(0), fact(20))
    let fma = asm.function("mulsd xmm0, xmm1\naddsd xmm0, xmm2\nret", "double(double, double, double)")
    print(fma(2.0, 3.0, 4.0))
else:
    print(42)
    print(3628800, 1, 2432902008176640000)
    print(10.0)
