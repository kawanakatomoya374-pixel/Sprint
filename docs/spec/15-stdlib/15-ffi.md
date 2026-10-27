### 15.15 ffi（2.2、同梱module）

`import ffi`。LuaJITのFFIに似た形で、Cの共有ライブラリの関数を呼び、生メモリを読み書きし、Sprintの関数をCへコールバックとして渡す。`extern "C"`で公開した関数はC++製でも呼べる（C++の名前修飾・例外・テンプレートそのものは扱わない）。ソースは同梱module（`ffi`は予約名）で、下層はbuiltin module `_ffi`である。

**安全性（重要）**: これは言語の型安全・決定性の**外**にある。宣言の誤り、不正なaddress、ライブラリの不具合は処理系ごとの異常終了になり得る。このため:
- capability `ffi`（`--allow-ffi`、埋め込みでは`SP_CAP_FFI`）がなければ、`ffi`と`_ffi`のどの関数もPermissionErrorになる（`ffi.sizeof`・`ffi.offsetof`・`cdef`のような純粋な宣言操作を除く）。`--allow-all`には含まれない。
- `--deterministic`では`ffi` capabilityを与えても常にPermissionError（§19.3）。
- 対応ABIはSystem V x86-64とAAPCS64（AArch64、可変長引数はレジスタ渡しのLinux規約）。それ以外のplatformでは、ffiの呼出しは`RuntimeError`になる。
- Sprint側のerrorとpanicの規則（§12）は変わらない。Cのコードがpanicや例外を越えて戻ることはない。

**呼出し規約（MUST）**: 引数は整数・pointer系が最大6個、浮動小数点が最大8個（超過は`ValueError`）。構造体の値渡し・値返しは**System V x86-64でのみ**対応する: 16バイト以下の構造体はeightbyteごとに整数/SSEへ分類（`ffi`が構造体のlayoutから自動で行う）してレジスタで渡し・返し、16バイトを超える構造体の**返却**は隠しpointer（呼出し側が確保）で行う。16バイトを超える構造体の**引数**（スタック渡し）、`long double`、コールバックの構造体引数・返り値は対応しない（`ValueError`）。値渡しの引数には`ffi.new`で作った`Struct`を渡す（数値などはTypeError）。AArch64では構造体の値渡しは`RuntimeError`。可変長引数（`...`）は、固定引数の後の値を既定の拡張で渡す（int→64bit整数、float→double、string→`char*`）。

**型コード**（`_ffi`の署名`"ret:arg,arg,..."`で使う。`ffi`はC宣言から導く）: `v`（返り値のみ）`i8 u8 i16 u16 i32 u32 i64 u64 f32 f64 p s`。`p`はaddress（intで表す。nil=0、stringはそのバイト列、bufferは先頭）、`s`は`char *`（引数ではstring、返り値ではstringへの複製か、NULLならnil）。整数引数は範囲を切り詰める（`u64`の大きい値は負のintになる）。floatをintへ渡すとTypeError。

**宣言**: `ffi.cdef(src)`はCの宣言を登録する。関数prototype（`...`可）、`struct`（入れ子・固定長配列メンバ・`const char *`）、`enum`（定数は`ffi.consts`へ）、`typedef`（関数pointer型を含む）、`size_t`・`uint8_t`などの標準名。`union`・ビットフィールド・グローバル変数、16バイトを超える構造体の値渡し引数は`ValueError`。構造体のlayoutはCの規則（自然境界、末尾padding）で、`ffi.sizeof`・`ffi.offsetof`で確認できる。

| 関数 | 内容 |
|---|---|
| `ffi.open(name = nil)` | 共有ライブラリを開く（`dlopen`）。`nil`は実行中のprogram（libc・libmなど）。失敗は`IOError`。返す`Lib`は`addr(name)`（symbolのaddress）`fn(name, decl = nil)`（`decl`は`"double sqrt(double)"`のような宣言。省略時は`cdef`の宣言）`bind(names)`（名前→関数のtable）を持つ |
| `ffi.fn_at(address, decl)` | 関数pointerを関数にする（宣言は`"int(int, int)"`の形も可） |
| `ffi.callback(decl, fn)` | Sprintの関数`fn`をC関数pointerにする（`Callback`: `addr()` `release()`）。戻り値の種類（整数系/浮動小数点）ごとに16個まで同時に有効。`fn`でerrorが起きると、そのコールバックを起こした呼出しからerrorが伝わる。**宣言した関数pointer引数に関数を直接渡すと、その呼出しの間だけ自動でcallbackにする** |
| `ffi.new(type, init = nil)` | `"struct P"`/`"P"`（`Struct`）、`"int[8]"`（`Arr`）、`"double"`（要素1の`Arr`）を割り当てる。0で初期化され、GCされる |
| `ffi.array(code, n, init = nil)` / `ffi.cstr(s)` / `ffi.view(address, code, n)` | 型付き配列 / NUL終端の`char`配列 / 既存メモリの窓（範囲検査はnだけ） |
| `Arr` | `get(i)` `set(i, v)`（範囲外は`IndexError`）`count()` `to_array()` `fill_from(xs)` `str()` `addr()` |
| `Struct` | `get(name, i = nil)` `set(name, v, i = nil)`（入れ子は`Struct`、配列メンバは`Arr`、`char *`はstring）`str(name)` `to_table()` `addr()` `size()` |
| `ffi.cast(type, address)` | addressを構造体の窓として見る。`T *`を返す宣言の関数は、返り値を自動で`Struct`にする |
| `ffi.string(x, n = nil)` / `ffi.addr(x)` | addressや配列からstringへ / 値（int・view・buffer）からaddressへ |
| `ffi.sizeof(type)` `ffi.offsetof(type, field)` `ffi.abi()` `ffi.NULL` `ffi.consts` | |

関数に`Struct`・`Arr`・bufferを渡すと、そのaddressが渡る。Cが保持し続けるメモリは、Sprint側の値（`Arr`など）が生きている間だけ有効である。libraryは閉じない（`dlclose`しない）。

```sprint
import ffi
ffi.cdef("double sqrt(double); void qsort(void *b, size_t n, size_t sz, int (*cmp)(const void *, const void *));")
let c = ffi.open(nil)
let libc = c.bind(["sqrt", "qsort"])
print(libc.sqrt(2.0))
let a = ffi.array("i32", 4, [3, 1, 4, 2])
libc.qsort(a, 4, 4, (p, q) => ffi.view(p, "i32", 1).get(0) - ffi.view(q, "i32", 1).get(0))
print(a.to_array())            # [1, 2, 3, 4]    sprint run --allow-ffi demo.sp
```
