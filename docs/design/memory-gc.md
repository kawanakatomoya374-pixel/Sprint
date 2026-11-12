# メモリ効率と GC（LuaJIT との比較）

`python3 tools/bench/mem.py build/sprint` が `tools/bench/mem/*.sp` と `*.lua` の実時間とピーク RSS を比べる（出力が同じことも確認する）。

## 実施した変更
| 変更 | 効果 |
|---|---|
| GC の起動閾値を生存ヒープの 3 倍から 2 倍へ（`SPRINT_GC_FACTOR` で変更可） | clos 1.47→0.99、strs 1.53→1.01、bigtbl 1.73→1.32（メモリ比）。時間は変わらず |
| 8 エントリ以下の表はハッシュ索引を持たない（線形走査）、リテラルは正確な容量、索引なしで拡張は realloc | tabs の 1 表あたり約 80 バイト減 |
| 表リテラルは直接追加（`table_init_small`）、整数キーの専用パスと安い整数ハッシュ | 表リテラルと整数キーの命令数減 |
| 小さい配列（要素 4 個以下で作られたもの）は要素をオブジェクトブロックに同居（`Obj.icap`） | trees 62→52MB、割り当て 1 回減 |
| **パック配列**: 型メモ `Obj.xt` が T_BOOL / T_INT / T_FLOAT の配列は要素を 8 バイトのペイロードだけで持つ | arrays 87→60MB。数値配列のメモリが半分 |
| 型メモが数値の配列は GC のマークで走査しない | sieve の命令数 12% 減 |
| コルーチンのスタックブロックは mmap（触れていないページは RSS に載らない）、終了時に即解放 | 既定 4096 スロットで 2 万個作っても RSS 166MB |
| `tr_append_fast`: トレース内の append をインラインで実行 | 配列の構築ループ約 1.5 倍 |

## パック配列の不変条件（SArray）
- `array_packed(a)` は `xt ∈ {T_BOOL, T_INT, T_FLOAT}`。このとき全要素がその型で、`data` は `int64_t[cap]`（bool は 0/1）。それ以外は 16 バイトの `SpValue[cap]`（boxed）。
- レイアウトの変更は `array_push` / `array_put` / `array_unpack` / `array_relayout` だけが行う。`xt` を直接書かない。`items` を直接触るコードは `array_get` / `array_set` を使う（C のフィールド名を `data` に変えて全使用箇所を洗い出した）。
- 領域 JIT: `getidx` / `setidx` / `arr_next` / `aappend` のスタンシルが実行時に `xt` でレイアウトを分岐する。レジスタ経路（`do_get_index` / `do_set_index`）は、標本配列のレイアウトで packed か boxed かを選び、packed は `xt` のガード、boxed は「packed でない」ガードを付ける。
- トレース JIT: `ALOAD` の `aux` ビット 4 が packed。`ASTORE` の `imm == 2` が packed への書き込み。どちらもレイアウトのガード（`xt == tag` / packed でない）を反復の最後の deopt 点より前に置く。範囲外の型を書くと deopt して、インタプリタがパックを解く。
- sort は packed の int 配列をその場でソートする。ffi は引数配列を `array_unpack` してから渡す。

## 残る差（対 LuaJIT）
- coros: 1 コルーチンあたり約 4KB（仕様の最小スタック・frame・handler 領域）。LuaJIT は約 0.7KB。
- arrays: 2.0 倍（LuaJIT の配列は 8 バイト。こちらは garbage の閾値 2 倍とヘッダ分）。
