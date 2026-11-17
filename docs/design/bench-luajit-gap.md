# LuaJIT 比較ベンチ(2026-11、追加 25 本)

`ONLY="..." NOJIT=0 sh tools/bench/cmp.sh` で測定(best of 3、jit/lj < 1 なら Sprint が速い)。
新規 `.sp` と `lua/*.lua` はアルゴリズム同一で、出力が一致することを確認済み(Lua は 1 始まりの慣用形で記述)。

| bench | 内容 | jit(s) | luajit(s) | jit/lj |
|---|---|---|---|---|
| nsievebit | ビット配列の篩 | 1.84 | 0.07 | 25.3 |
| bitops | xorshift + popcount + CRC32 | 1.24 | 0.14 | 8.6 |
| spectral | spectral-norm(整数→float 混在) | 0.87 | 0.16 | 5.5 |
| knuc | 部分文字列を key にした表の集計 | 0.29 | 0.06 | 4.5 |
| base64 | 文字列→バイト→ビット操作 | 0.64 | 0.16 | 3.9 |
| heapsort | float 配列のヒープソート | 0.71 | 0.19 | 3.7 |
| fannkuch | 配列の置換 | 1.86 | 0.51 | 3.7 |
| hashint | 整数キーの表 | 0.30 | 0.09 | 3.5 |
| fft | float 配列、ビット操作 | 0.47 | 0.14 | 3.5 |
| poly | 3 クラスの多態メソッド呼び出し | 0.21 | 0.07 | 2.9 |
| mathfn | math.sin/cos/sqrt/log/exp | 0.21 | 0.08 | 2.7 |
| coro | coroutine の generator 連鎖 | 0.27 | 0.11 | 2.4 |
| mandel | float 反復 | 0.52 | 0.26 | 2.1 |
| serialize | 再帰的な入れ子の直列化 | 0.12 | 0.08 | 1.5 |
| ray | クラスの Vec 演算 | 0.54 | 0.40 | 1.4 |
| bintrees, strfind, bfs, msort, life | | | | 1.0〜1.2 |
| lcs, bignum, montecarlo, queens | | | | 0.7〜0.9(勝ち) |

## 遅い原因(SPRINT_TRACE_JIT_DEBUG=1 の拒否理由)

1. **ビット演算 `& | ^ ~ << >>` が両 JIT で未対応**("unsupported bytecode")。nsievebit・bitops・base64・fft が該当。
2. **int と float の混在算術**("mixed or non-numeric operands")。spectral・mandel・heapsort。
3. **ネイティブ関数呼び出し**("call did not enter a function"): `len`、`a.append`、`s.slice`、`math.*`。knuc・mathfn・fill 系。
4. **表(table)の操作と `for k, v in t`**: hashint・knuc。
5. 外側ループの後方ジャンプ・"no sinkable object" で内側ループの連鎖が切れる(fannkuch・heapsort)。
6. coroutine の `yield` は未対応(coro)。

## 対応状況

- **ビット演算(済)**: トレース IR に IAND/IOR/IXOR/ISHL/ISHR を追加(`~` は XOR -1)。変数の shift は rcx を割り当てプールから外し、
  count が 0..63 の外なら deopt する(インタプリタが飽和・ValueError を処理)。領域 JIT にも専用スタンシルを追加。
  nsievebit 25.3→2.6、bitops 8.6→1.1、base64 3.9→1.7、fft 3.5→2.4。テスト: `tests/cases/jit/jit_bitops.sp`、
  ファズ(`tools/jitfuzz_trace.py`)にビット演算を追加。

## 2026-11 追記: 70 本の geomean が LuaJIT 比 1.134 → 0.934

`python3 tools/bench/all.py -n 3`(76 本、出力一致、小数は相対誤差 1e-9 で比較)。ratio < 1 なら Sprint が速い。

### 今回の改善(いずれも「実測で速くなったものだけ採用」)
| 変更 | 効果 |
|---|---|
| 領域 JIT: 多態メソッド呼び出し(クラスごとの 4 エントリキャッシュ、`pinvoke`)。単一クラス前提のコードが抜け続けたとき 1 回だけ作り直す | richards 0.47s → 0.07s、poly(下の型フィードバックと合わせて)0.26s → 0.05s |
| 領域 JIT: 呼び出し結果の型フィードバック(出口時に `INVOKE`/`CALL` の戻り値の型を記録し、再コンパイルで使う) | poly 5 倍、series 1.9 倍 |
| 領域 JIT: 分岐の合流点でスタック各位置の hint を保つ(`a[k] = (a[k] ?? 0) + 1` が毎回インタプリタへ落ちていた) | histo 0.13s → 0.04s、knuc 1.3 倍 |
| 関数 JIT: `FOR_PREP`(配列の for-in)、要素のクラスを代入時にガード | nbody_obj 0.16s → 0.06s、bst 0.62s → 0.29s |
| ネイティブからのコールバック(`map`/`filter`/`reduce`/sort の比較関数)がコンパイル済みユニットを直接呼ぶ | hof 0.21s → 0.15s、sort 0.18s → 0.12s |
| 短いループのトレースを領域 JIT へ戻す(1 入場あたり 16 反復未満) | nbody_obj、tokenize 1.6 倍、fannkuch 1.3 倍 |
| `cvtsi2sd` の前に `xorps`(偽の依存を断つ) | ffi_sqrt 0.22s → 0.12s |
| 短い文字列の interning(弱テーブル、ヒット率が低ければ停止) | knuc 1.25 倍、wordfreq 1.4 倍、メモリ半減 |
| 世代別 GC(`memory-gc.md`) | gc_long 1.3 倍、bintrees 1.15 倍 |
| `coroutine.status` の戻り値を事前確保 | coro 0.24s → 0.18s |
| 配列リテラルの一括生成、テーブル helper の既存キー高速経路、トレース出口のアトミック命令除去 | 数 % |

### 残る差(ratio 1.7 以上)
| bench | ratio | 理由 |
|---|---|---|
| coro | 3.1 | コルーチンの切り替えがインタプリタ内(`resume` / `status` の呼び出しと `exec_save/load`)。JIT の対象外 |
| knuc | 2.9 | `slice` で作る文字列キー。interning 後も表検索と `sm_slice` の C 呼び出しが残る |
| ffi_sqrt | 2.5 | 毎回の呼び出しの前後でスロット経由(レジスタ渡しなし)。モジュール変数 `s` の書き戻し |
| hof | 2.3 | 要素ごとの `vm_call`(約 50 命令)。HOF 自体を JIT 内でインライン展開する必要がある |
| hashint | 2.1 | 60 万キーの表でキャッシュミス支配。16 バイト値のエントリ(LuaJIT は 8 バイト) |
| mandel | 2.0 | 純粋なループは 1.2 倍。内側ループ(トレース)のピクセルごとの入退場が残り |
| hanoi | 1.9 | 自己再帰の呼び出し 1 回あたり約 35 命令(フレーム 6 フィールド、`UC_CHECKS`) |

### 試して採用しなかったもの
- 型が分かっている ffi 引数のタグチェック省略(0.221s → 0.225s)。
- インタプリタ `GET_MEMBER` のモジュール高速経路(変化なし)。
- GC: 生存率に応じた間隔(メモリ増)、スイープの高速経路(変化なし)、マークのプリフェッチ(逆効果)。LTO(悪化)。PGO は約 7% だがばらつきが大きく既定にしていない(`make pgo`)。

## 2026-11 追記 2: GUI と JIT

- ラスタライザ: 透過ブレンド (`hline`) と塗りつぶし (`fill32`) を SSE2 化、丸角の inset をテーブル化、5x7 文字描画を行優先・分岐なしに。guidraw 0.134s → 0.110s、3000 回描画 0.97s → 0.89s。
- JIT: ネイティブオブジェクトのメソッド (キャンバス描画; 受け手のクラスは毎回再検査)、`table.name`、文字列などへの `==` / `!=`、`gfx.text_advance` / `gfx.rgb` を JIT から直接呼べるように。tests/cases/jit/jit_canvas_calls.sp。
- GUI の時間の約 6 割は C のラスタライザ (text / fill / blend / 丸角)。JIT で縮むインタプリタ分は残りの 3 割程度で、効果は約 5%。
- coro: INVOKE のモジュールメンバ参照と文字列比較の高速パス (約 5%)。
- 全 76 本 geomean 0.940 (出力不一致 0)。

## 2026-11 追記 3: 領域 JIT の float レジスタ固定、パック配列の書き込み、文字列 slice

- 領域 JIT: 呼び出しを含まない最内ループの float ローカル（最大 3 個）を xmm5-7 にループ越しで保持 (`pin_*`)。メモリが常に最新なので出口は変更なし。mandel 0.66s → 0.38s（LuaJIT 比 1.25）。tests/cases/jit/jit_float_pin.sp。
- TraceJIT: パック配列への書き込みが、範囲検査（`TIR_ST_RANGE`）と要素型検査（`TIR_ST_TAG`）をループ入口の検査と共有。配列アクセスは `mov r10,[arr+items]; movsd x,[r10+idx*8]`。lu 0.112s → 0.104s。tests/cases/jit/jit_packed_store.sp。
- JIT: `s.slice(a, b)` を専用ヘルパーに、`t[k] = t[k] + 1` の get→set で検索を 1 回に。knuc 0.183s → 0.150s。tests/cases/jit/jit_slice_table.sp。
- トレース: `to_float` と準備済み libm `sqrt` を IR 命令に（ffi_sqrt 0.145s → 0.048s）。
- 全 76 本 geomean 0.898、出力不一致 0。
- 残り（比 1.7 以上）: knuc 2.4、coro 2.8、hashint 2.0、hof 2.0、tokenize 1.9、base64 1.8、hanoi 1.8、lu 1.75。

## 2026-11 追記 4: 「簡単なところ」の取りこぼし探し

深い設計に入る前に、遅いベンチを 1 本ずつ callgrind で見て、単純な取りこぼしを直した。
- トレースの float 可換演算が右オペランドの寿命終了時にそのレジスタへ書く: lu 0.104s → 0.062s、rotate 0.177s → 0.085s（命令 1 つの無駄が大きかった）。
- `type(v)` が「組み込み関数の呼び出し」として JIT に拒否され、関数ごとインタプリタだった: serialize 0.120s → 0.087s。
- テーブルリテラル `{...}` が JIT 未対応（`build` が丸ごとインタプリタ）: 同上。
- `arr_join` が 1 文字の要素ごとに memcpy を呼んでいた: base64 0.262s → 0.21s。
- `t[k] = t[k] + 1` の get→set で検索を共有（文字列キーと整数キー）: knuc 0.183s → 0.150s、hashint -6%、histo -15%。
- `s.slice(a, b)` の専用ヘルパー。
- 全 76 本 geomean 0.883、出力不一致 0。
