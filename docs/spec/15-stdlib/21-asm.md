### 15.21 asm（x86 / x86-64 アセンブラ）

`import asm`。Sprintだけで書かれた、Intel構文（NASM互換のサブセット）のアセンブラ。出力はフラットバイナリ（`array`の整数0〜255）で、**capabilityは要らない**（結果はデータであり、ファイルに書く・実行するのは別のAPI）。リアルモード（16ビット）、保護モード（32ビット）、ロングモード（64ビット）を同じソースで切り替えられるので、ブートセクタからカーネルの入口までをSprintだけで作れる（`examples/boot/boot.sp`）。

| 関数 | 割当 | 仕様 |
|---|---|---|
| `asm.assemble(src, opts = {})` | A | `opts`は`{bits: 16, org: 0, defines: {NAME: 値}}`。`{bytes, symbols, size, bits, org}`を返す。`symbols`はラベル名→アドレスのtable。エラーは`AsmError`（行番号付き） |
| `asm.boot_sector(src, opts = {})` | A | `bits: 16, org: 0x7c00`で組み、510バイトまで0で埋めて`0x55 0xAA`を付ける（`assemble`と同じ戻り値） |
| `asm.function(src, decl)` | — | 64ビットで組んで`ffi.asm`で関数にする（x86-64ホストのみ、`--allow-ffi --allow-asm`が要る）。`asm.function("lea rax, [rdi+rsi]\nret", "int64_t(int64_t, int64_t)")` |

ファイルへは`fs.write_bytes`（§15.7）。

**構文**
- `label:`（コロン無しも`db`/`equ`/`times`の前では可）、`.local`（直前のグローバルラベルの下）、`;`コメント、`%define NAME トークン列`、`%assign NAME 式`。
- ディレクティブ: `bits 16|32|64`（`[bits 16]`も可）、`use16/32/64`、`org`、`db dw dd dq`（文字列可）、`resb resw resd resq`、`times 式 命令またはデータ`、`NAME equ 式`、`align N[, db FILL]`、`alignb`、`default rel|abs`、`section`/`global`/`extern`/`cpu`（無視）。
- 式: `+ - * / // % << >> & | ^ ~`と括弧、数値（`0x1F` `1Fh` `0b101` `101b` `0o17` `17q` `1_000` `'A'`）、`$`（命令の先頭アドレス）、`$$`（`org`）、ラベル。前方参照は複数パスで解く。
- オペランド: レジスタ（`al`〜`r15b`、`ax`〜`r15w`、`eax`〜`r15d`、`rax`〜`r15`、`es cs ss ds fs gs`、`cr0`〜`cr15`、`dr0`〜`dr7`、`xmm0`〜`xmm15`）、即値、`[base+index*scale+disp]`（16ビットは`[bx+si]`等）、`byte/word/dword/qword [..]`、`es:[..]`、`[rel x]`/`[rip+x]`、`seg:off`（far）、`short`/`near`/`far`。
- `jmp`/`jcc`は短い形から始めて、届かなければ`near`に伸ばす（NASMの`-Ox`と同じ。縮めない）。即値はNASMと同様、オペランド幅に切り詰めてからimm8に収まれば短い形を選ぶ（ラベルを含む式は縮めない）。

**命令**: 算術・論理（`add or adc sbb and sub xor cmp test`）、`mov`（制御・デバッグ・セグメントレジスタ、`moffs`形を含む）、`xchg lea push pop inc dec neg not mul imul div idiv`、シフト・ローテート（`shl shr sar rol ror rcl rcr shld shrd`）、`jmp call jcc loop jcxz/jecxz/jrcxz ret retf iret int`、文字列命令（`movs* cmps* stos* lods* scas* ins* outs*`と`rep/repe/repne/lock`）、`in out`、`lgdt lidt sgdt sidt lldt ltr sldt str smsw lmsw invlpg`、`movzx movsx movsxd setcc cmovcc bt/bts/btr/btc bsf bsr bswap xadd cmpxchg popcnt lzcnt tzcnt`、`cpuid rdtsc rdmsr wrmsr syscall sysret sysenter sysexit swapgs wbinvd invd rsm clts pause xlat *fence ud2 hlt cli sti`ほか、SSE/SSE2（`movaps movups movapd movdqa movdqu movss movsd movd movq`、`add/sub/mul/div/min/max/sqrt{ps,pd,ss,sd}`、`and/or/xor/andn`、`ucomis* comis*`、`cvt*`、整数SIMDの`pxor por pand padd* psub* pcmpeq* punp* pshufd shufps`）。

**検証**: `make asm-check`（`nasm`が必要）が、16/32/64ビットで約4万通りの命令エンコードとラベルを含むプログラムをNASMの出力とバイト単位で比較する（全件一致）。`make boot-test`（`qemu-system-x86_64`が必要）は、`examples/boot/boot.sp`が作る起動イメージをQEMUで起動し、ロングモードに入って64ビット演算の結果をシリアルに出すことまで確認する。

**未対応**: AVX以降、x87、`%macro`/`%if`/`%include`、`incbin`、ELF/PEなどのオブジェクト形式（フラットバイナリのみ）、AArch64のアセンブラ。
