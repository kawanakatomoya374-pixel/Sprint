# Sprint FFI v2 設計 — LuaJIT 級（以上）のC連携と Asm 呼出し

状態: 段階1・3（数値のみの署名）実装済み。段階2・4は未着手。規範化するときは `docs/spec/15-stdlib/15-ffi.md` に反映する。

## 1. 現状の測定済みボトルネック（`src/lib/lib_ffi.c`, `stdlib/ffi.sp`）

| # | 事実 | 影響 |
|---|---|---|
| 1 | `ffi.sp` の `call(...args)` は Sprint 製ラッパ。呼出しごとに `conv`/`temps` 配列を確保し、型ごとの分岐を Sprint 側で実行 | 1回の C 呼出しに数十 VM 命令＋2〜3回の割当 |
| 2 | `_ffi.call` は呼出しごとに署名文字列 `"ret:arg,..."` を `parse_sig` で再解析 | 呼出し数に比例する純粋な無駄 |
| 3 | 全呼出しが「整数6・浮動8を渡す14引数の関数ポインタ」1種類の汎用経路 | 引数を使わない関数でも14個ロード（x86-64 SysV では可変長 `al` も未設定の暗黙依存） |
| 4 | JIT（Copy-and-Patch / Trace）から見ると ffi 呼出しは不透明な native 呼出し | 数値ループ中の `sqrt` 等でも最適化境界になる |
| 5 | 構造体は `Struct` クラス（Sprint 製）＋ `get("field")` の文字列引き | フィールド読み書きが辞書引き相当。`union`/ビットフィールド/グローバル変数/16B超値渡し引数/`long double` 未対応 |
| 6 | callback は戻り型ごとに16個の静的 trampoline | 同時に17個目が作れない。構造体引数/返り値の callback 不可 |
| 7 | Asm を呼ぶ手段がない | 本計画の新規機能 |

## 2. 設計方針

1. **宣言時に一度だけ解析し、呼出しは記述子を引くだけ**（LuaJIT の `CType` + 呼出しスタブ生成に相当）。
2. 安全の境界は変えない: `ffi` capability（`--allow-ffi`）は必須、`--deterministic` と `--allow-all` には含めない。**Asm は別 capability `asm`（`--allow-asm`、埋め込みでは `SP_CAP_ASM`）**。任意機械語の実行は FFI（既存シンボルの呼出し）より強い権限であり、`--allow-ffi` に含めない。
3. 既存の `ffi.cdef` / `ffi.open` / `fn` / `bind` / `callback` / `new` の **API と挙動は完全に互換**を保つ（既存テスト `tests/cases/stdlib/ffi_*`、`examples/ffi/` が無修正で通ること）。速くするのは内部だけ。
4. JIT 連携は「準備済み呼出し」が前提。先に VM 経路を速くし、次に JIT で inline する。

## 3. 構成

```
 ffi.sp (宣言: cdef / ctype 表)  ──►  _ffi.prep(addr, "ret:args")  ──►  PreparedCall（native 関数オブジェクト）
                                                                            │ 解析済み Sig・分類済み引数・arity
 呼出し  f(a, b)  ── VM が native として直接ディスパッチ ──► prepared_invoke(PreparedCall*, argv)
                                                                            │ 引数ごとの変換を型コードで直行
                                                                            ▼
                                                                    汎用 or 専用スタブ → C 関数
 Asm:  ffi.asm(bytes|text, "ret:args") ──► W^X 実行メモリ ──► PreparedCall（同じ呼出し経路）
```

### 3.1 PreparedCall（段階1）
- `_ffi.prep(address, sig)` は `SFunc`（native）を返す。`NativeDesc` は共有で、記述子は閉じ込めた `SNativeObj` ではなく **関数オブジェクト付随データ**として保持する（`vm_new_native` が閉じ込めデータを持てない場合は、`T_NATIVE` に call 可能ラッパを足す。実装時に `sp.h` の `SFunc`/`NativeDesc` を確認して最小の変更を選ぶ）。
- 記述子 `PCall { void *fn; int nargs, variadic; CType ret; CType args[MAX_ARGS]; SInfo ainfo[], rinfo; uint8_t nint, nfp; }`。署名解析は `prep` で1回。
- 呼出し時は引数を `argv` から直接 `int64_t ia[6]` / `double da[8]` に変換（配列確保なし）。`ffi.sp` の `call(...args)` は **構造体/関数引数など Sprint 側の前処理が必要な場合のみ**残し、純スカラ宣言（`double sqrt(double)` など）は `prep` の結果を直接返す。
- 引数の個数は `prep` 時に確定（可変長は最小個数＋可変部のみ動的）。型エラー/個数エラーのメッセージは現行と同一。

### 3.2 専用スタブ（段階2）
- 署名クラス（`nint`,`nfp`,戻り種別）ごとに最小の呼出しスタブ: 例 `(d)->d`, `(d,d)->d`, `(i)->i`, `(i,i)->i`, `(p,i)->i`。残りは汎用。x86-64 SysV 可変長関数は `%al` に浮動レジスタ数を設定する版を使う。
- 戻り値の整数変換（`i8..u32` の符号/ゼロ拡張）は表引きの1分岐。

### 3.3 JIT 連携（段階3）
- `jit.c`（Copy-and-Patch）: `OP_CALL` で callee が PreparedCall かつ純スカラ署名なら、ガード（callee 同一性）＋「レジスタへ直接ロード → `call fn` → 戻り値のタグ付け」の stencil を張る（現在の `math_fast1`/`math_pure_native` と同じ発想: 既に `sqrt` 等はこの道がある）。
- `jit_trace.c`/`trace_ir.c`: `CALL_C` IR ノードを追加。副作用あり（再順序化・CSE 禁止）、GC セーフポイントなし（C が Sprint を再入するのは callback のみ → callback を含む署名はトレース不可）。
- 純関数（`sqrt`,`sin`,`abs` 等）は宣言時の `pure` 注記で CSE/LICM を許可（`ffi.cdef("... __attribute__((const))")` 相当の注記を受理）。

### 3.4 型システム拡張（段階4）
- ネイティブ `CData` 表現: `{ptr, ctype*, owner}`。`s.x` / `s.x = v` を **インライン・キャッシュ付きフィールド参照**にする（`ctype` からオフセット/型を一度だけ解決）。`Struct.get("name")` は互換のため残す。
- `union`、ビットフィールド、固定長配列、グローバル変数（`ffi.cdef("extern int errno_like;")` → `lib.var("name")`）、`long double`（x87/16B スタック）、16B 超値渡し引数（MEMORY クラス＝スタック渡し）を `cdef` で受理。
- 戻り値 `T *` は `CData`（nil/0 は nil）。`ffi.gc(cdata, finalizer)`（GC 時に finalizer。Sprint の GC は非 moving mark/sweep なので pointer 固定は不要）。

### 3.5 callback（段階4）
- 戻り型ごと16個の静的 trampoline をやめ、実行メモリにスロット表と `mov r10, slot; jmp common` の小スタブを動的生成（asm capability と同じ W^X アロケータを共有）。上限は動的（既定4096、`ffi.callback_limit`）。
- 構造体値渡し/返却（≤16B）を callback でも許可。

### 3.6 Asm 呼出し（段階1で最小実装）
- `ffi.asm(code, sig)`: `code` は **機械語バイト列（string/array/buffer）**。署名は C ABI（SysV x86-64 / AAPCS64）。ホスト以外の ISA の機械語は検証不能なので実行時にユーザ責任とする。
- 実行メモリは `mmap(RW)` → コピー → `mprotect(RX)`（`jit.c` と同じ W^X。RWX は作らない）。`asm` capability がなければ PermissionError、`--deterministic` では常に PermissionError。
- 返り値は PreparedCall（FFI 呼出しと同じ経路・同じ型変換・同じ callback 引数サポート）。`release()` で `munmap`。GC 時に未解放ならファイナライザで解放。
- アセンブラ文字列（`"mov rax, rdi; ret"`）は**外部依存を増やさないため段階1では対象外**。`tools/` のアセンブラ連携または最小の x86-64 エンコーダは別段階（必要ならユーザに確認）。
- 注意（仕様に明記）: Asm コードは Sprint VM のレジスタ/スタック規約に触れない純 C ABI 関数であること。callee-saved レジスタを保存すること。GC はこのコード実行中に動かない（Sprint を再入しない限り）。

## 4. 性能目標と検証

| ベンチ（新規 `tools/bench/ffi_*`） | 内容 | 目標 |
|---|---|---|
| ffi_sqrt | `sqrt` を 5000万回（ループ内） | LuaJIT FFI の 1.1x 以内→超え（段階3） |
| ffi_strlen | `strlen("...")` 1000万回 | 同上 |
| ffi_qsort | callback 付き `qsort` 100万要素 | LuaJIT 同等 |
| ffi_struct | `struct` フィールド読み書き 5000万回 | 段階4 |
| ffi_asm | `add2`/`fma` 機械語 5000万回 | C インライン無しの下限と比較 |

各段階: `make test`（331件）＋ `make debug && make test-san` ＋ 新規 `tests/cases/stdlib/ffi_prep.sp`（準備済み呼出しの型変換/エラーメッセージが旧経路と同一であることを両経路で比較）。LuaJIT/C/V8 比較は `tools/bench/cmp.sh` に ffi ベンチを追加して行う。

## 5. 段階

1. **PreparedCall（VM経路）＋ `ffi.asm` ＋ `asm` capability** — 実装済み（`_ffi.prep` / `_ffi.asm`、`lib_ffi.c` の `PrepFn`）
2. 専用スタブ — 未着手
3. JIT inline — **実装済み**。署名が「引数すべて i64/u64/f64（整数6・浮動8まで）、非可変長、戻り値が文字列/構造体以外」のとき、`jit.c` の `emit_ffcall` が stencil `ff_fn`（呼出し先の `PrepFn` 同一性ガード）→ `ff_ia*`/`ff_fa*`（引数の型ガード＋レジスタ載せ）→ `ff_call`（C関数を直接 call）→ `ff_sx*`/`ff_zx*`/`ff_r*`（戻り値の拡張と格納）を並べる。ガード失敗は C 関数の実行前に `JIT_X` で抜け、インタプリタが同じ呼出しをやり直す（副作用なし）。ポインタ/文字列引数・callback を含む署名は、再入や割当てを伴い得るため対象外（ヘルパー経由 `jh_ffi` か通常経路）。実測: `sqrt` 2000万回ループ 9.26s → 約0.08s（呼出し単体）。
4. CData/union/ビットフィールド/グローバル変数/動的 callback — 未着手
