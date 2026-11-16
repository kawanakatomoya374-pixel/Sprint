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

## 世代別 GC（スティッキーマークビット、非移動）
JIT が機械語にオブジェクトのアドレスを埋め込むので、オブジェクトは動かさない。マークビットを GC 後も残して「古い世代」とみなす方式。

- **色**（`Obj.marked` の下位 2 ビット）: 0 = 白（若い）、1 = 灰（このサイクルで到達・キュー済み）、2 / 3 = 黒 A / 黒 B（古い）。ビット 2（`GC_REM`）は「記憶集合に入っている」。古い世代の色は `vm->gc_black`（2 または 3）。
- **マイナー GC**（既定）: ルートと記憶集合から、若いオブジェクトだけをマークする（黒は「到達済み」として辿らない）。若いオブジェクトのリスト区間（`vm->objs` から `vm->gc_young_end` の手前まで）だけをスイープし、生き残りは黒＝古くなる。
- **メジャー GC**: `gc_black` を 2↔3 で反転して、古いオブジェクトを一括で「未マーク」にし、全体をマークしてスイープする（全オブジェクトのクリア走査が要らない）。ヒープが前回メジャー後の 2 倍になる（`gc_major_next`）か、`gc.collect()` で起きる。
- **ライトバリア**: 古い（`marked & 6 == 2`）オブジェクトに参照型の値を書くとき、そのオブジェクトを記憶集合へ（`gc_wb`、遅い経路は `gc_remember`）。配列・テーブル・インスタンスのフィールド・セル（upvalue）・エラーの `suppressed` の書き込みは C 側で、JIT は 6 つのスタンシル（`stfld` `stfldk` `stup*` `setidx_*` `aappend_*`）と、領域 JIT が手書きする `do_set_member` / `do_set_index` の経路（`emit_wb` → `wbk` / `wbm`）で行う。スロー経路は `vm->jit_wb`（`sp_jit_wb_stub`）で、記憶集合に空きがあれば数命令で追記し、なければ全レジスタを保存して `gc_remember` を呼ぶ。
- **コルーチン**: 動いたあとのコルーチンのスタックには GC が見ていない値があるので、`yield` で古いコルーチンを記憶する。
- **弱参照**: intern テーブルは GC 後・スイープ前に、白（または反転前の色）のエントリを落とす。
- **トリガ**: 次の GC は「生存量 + 窓」（窓 = max(`gc_nursery` 4MB, 生存量の 75%)、最大 64MB、メジャー閾値で頭打ち）。直前のマイナーで割り当ての 6 割以上が昇格した（ヒープが育つだけ）ときは、メジャー閾値まで待つ。
- **検証モード**: `SPRINT_GC_VERIFY=1` で、各マイナー GC の前に全オブジェクトを走査し、古い親が白い子を持つのに記憶されていなければ即座に `abort` する。バリアの取りこぼしは、これと `SPRINT_GC_STRESS=1`（毎回 GC）・`SPRINT_JIT_THRESHOLD=1` を組み合わせて全テストを流して潰した（`tests/cases/stdlib/gc_generational.sp` はバリアを無効にすると落ちる）。
- **ノブ**: `SPRINT_GC_GEN=0`（毎回メジャー）、`SPRINT_GC_NURSERY_KB`、`SPRINT_GC_WINDOW_PCT`、`SPRINT_GC_TRACE=1|2`（合計 / 1 回ごと）。

### 効果（JIT あり、既定）
| ベンチ | 変更前 | 世代別 |
|---|---|---|
| gc_long | 0.35s | 0.27s（1.3 倍） |
| bintrees | 0.60s | 0.52s（1.15 倍） |
| gc | 0.034s | 0.031s |
| bst / linkedlist / base64 | — | 3〜10% 遅い（古いオブジェクトを大量に書き換える、または大きな一時配列が育つ型） |

GC 時間そのものは bintrees で 171ms → 88ms に半減する。インタプリタ実行中は変異体の時間が支配的なので、壁時計の差は小さい。
