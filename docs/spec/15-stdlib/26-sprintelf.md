### 15.26 sprintelf（ELF ローダー / 動的リンカー）

`import sprintelf`。x86-64 の ELF64 を読み込み、再配置し、動的リンクする Sprint 製ライブラリ（同梱 module、capability 不要）。設計は C-OS カーネルの `cos_elf.c` / `cos_elf_link.c` に基づく。アドレス空間は `Space()`（仮想アドレスに置いたバイト列の領域の集まり）で表すので、ホスト上でも SprintOS 上でも同じコードで動く。

| 関数 | 仕様 |
|---|---|
| `inspect(data)` | ヘッダと PT_* を検証し、`{type, entry, min_vaddr, span, dynamic, static, interp, tls, relro, exec_stack, soname, rpath, runpath, needed[]}`を返す。壊れた ELF は ValueError |
| `Space()` | `map / unmap / r8..r64 / w8..w64 / read_bytes / write_bytes / cstr / regions` |
| `map_object(space, data, base)` | PT_LOAD を`base`に写し、動的セクションを読む（ET_EXEC は`base`が 0 になる）。オブジェクトは`{base, map_start, map_end, segs, entry, symtab, …, ifuncs}` |
| `lookup(space, obj, name, version)` | `DT_GNU_HASH`（Bloom フィルター）→`DT_HASH`→線形走査。シンボルバージョン対応（`version`が`nil`なら既定バージョンだけ） |
| `relocate(space, obj, resolver)` | RELA / REL / RELR / JMPREL。`resolver(req)`が`{address, size, …}`か`nil`を返す。弱い未定義は 0 |
| `tls_layout(objs)` / `tls_init(space, region, size, objs)` | x86-64 variant II の静的 TLS ブロックと TCB・DTV |
| `Linker(space, read_file)` | `load_executable(path, bytes, base)`、`dlopen(path, flags)`、`dlsym(handle, name)`、`dlclose(handle)`、`dlerror()`、`set_library_path`、`set_search_path`、`objects()` |

再配置の型: `RELATIVE`・`RELR`・`64`・`GLOB_DAT`・`JUMP_SLOT`・`PC32`・`PLT32`・`32`・`32S`・`PC64`・`16`・`8`・`SIZE32/64`・`COPY`・`DTPMOD64`・`DTPOFF64`・`TPOFF64`、`IRELATIVE`。IFUNC（`IRELATIVE`と ifunc シンボルへの`64`/`GLOB_DAT`/`JUMP_SLOT`）は解決関数を実行せず、`obj.ifuncs = [{target, resolver}]`に記録してスロットを 0 にする（解決関数はプロセス自身が呼ぶ。C-OS と同じ方針）。`TLSDESC`とリンク時専用の型は拒否する。

`Linker`: `DT_NEEDED`の探索順は、絶対パス → `DT_RUNPATH` → `DT_RPATH`（`$ORIGIN`展開）→ 要求元のディレクトリ → `set_library_path` → `set_search_path`。シンボルの探索範囲は、グローバルなオブジェクトを読み込み順に、続いて要求元が依存するライブラリ。`RTLD_LOCAL`・`RTLD_GLOBAL`・`RTLD_NOLOAD`・`RTLD_NODELETE`・`RTLD_DEEPBIND`、ハンドルは世代付き（閉じたハンドルが後から読み込まれたものを指さない）。`dlopen`は全部成功するか何も残さない。`dlclose`は参照が無くなった依存先もまとめて外す。起動後に自前の TLS を持つライブラリは拒否する。

検証: `tests/cases/stdlib/sprintelf.sp`（`make test`）が`tests/data/elf`の実ライブラリ（`tools/elf/mkfixtures.sh`が gcc で作る）で、検査・3 種のハッシュ形式の検索（`nm -D`と一致）・シンボルバージョン・TLS 配置・依存解決・`dlopen`/`dlclose`・不正入力の拒否を確かめる。`tools/elf/exec_check.sp`（`--allow-ffi`）は、再配置した像を同じアドレスの実メモリへ写して**実際に実行**する（PLT 経由の呼び出し、GOT 経由のデータ、関数ポインタの再配置、IFUNC、弱い未定義、RELR、シンボルバージョンの選択）。
