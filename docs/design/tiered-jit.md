# 統合 JIT（Copy-and-Patch 領域 JIT ＋ TraceJIT）の設計と現状

状態: フェーズ0 実装済み（TraceJIT は既定オン）。フェーズ1 以降は未実装。数値は 2026-11 の実測。

## 1. 役割分担（方針）

| 層 | 役割 | 現状 |
|---|---|---|
| インタプリタ（quickening 付き） | 冷たいコード、JIT 不採用のコード、deopt 後の再実行 | あり |
| **Copy-and-Patch 領域 JIT**（`jit.c`） | 対応範囲が広い土台。関数単位（unit）とループ単位。コンパイルが速い。**どのトレースも採用されなかったときの受け皿** | あり。fib/collatz/loop などで LuaJIT 並み |
| **TraceJIT**（`trace_ir.c` `jit_trace.c`） | 安定したホットループを、記録した実行経路で特殊化し、SSA 上で最適化（レジスタ保持・不要 store 除去・巻き上げ・allocation sinking）。**領域 JIT より速い場合だけ採用** | 既定オン。ただし採用される形が極端に狭い（§3） |

TraceJIT のバックエンドは領域 JIT と同じ stencil 表（`stencils.h`）で機械語を作る（`tr_*` atom）。つまり「Copy-and-Patch を土台に、トレースで最適化する」構成。

### 採用・降格ポリシー（不変条件）
1. **TraceJIT は領域 JIT より遅くならない**。`tools/bench/trace_cmp.sh` で全ベンチの on/off 比が 1.05 を超えたら不具合として扱う。
2. ループのルート記録は 1 回だけ（コンパイル成功でも拒否でも「確定済み」として再記録しない。`Proto.trace_settled` のビットセット）。
3. トレースが拒否・未対応なら、そのループは何も失わず領域 JIT に進む（`JIT_HOOK`）。
4. （フェーズ2）トレースの side exit が頻発するループは降格して領域 JIT に戻す（exit 率の計測で判断）。

## 2. フェーズ0（実装済み）で解決した問題

TraceJIT を既定オンにするために、まず「オンにしただけで遅くなる」原因を 4 つ潰した（`SPRINT_JIT_THRESHOLD=1e8` でインタプリタのみ測定、HEAD 比）。

| 問題 | 症状 | 対策 |
|---|---|---|
| 全命令に `trace_cap` 検査（`TRACE_STEP`） | インタプリタが 20〜55% 遅い（fib 0.43→0.52、minivm 0.14→0.22、tokenize 0.48→0.75） | インタプリタを **2 つの版にコンパイル**（`vm_loop.inc` を `RUN_LOOP_RECORDING` 0/1 で 2 回 include）。通常版には記録コードが無く、記録中だけバックエッジで記録版へ切り替える（`RS_SW_RECORD` / `RS_SW_NORMAL`）。`dt` ポインタ方式も試したが、レジスタ圧迫で minivm が +33% になり不採用 |
| `run_loop` 入場ごとに約 8KB を memset | コールバック（sort の比較関数等）が 2 倍遅い | 記録バッファの確保を最初のバックエッジまで遅延し、memset をやめた |
| 拒否したループを覚えていない | 毎反復「記録→拒否→版切替え」を繰り返す | `Proto.trace_settled`（ループヘッダのビットセット）。確定済みループは `proto_trace_blocked`（インライン数命令）で記録処理を呼ばない |
| 記録開始後にループが 2 周目へ戻らないと記録が終わらない | 記録版のまま走り続ける（命令の 18%） | ステップ上限（256）で記録を中止し、確定済みにして通常版へ戻す |

加えて、バックエッジごとの `jit_trace_site` 呼出しはトレースを 1 つも持たない関数では省略（`Proto.trace_any`）、`getenv` は初回のみ。

結果（既定設定、全ベンチ HEAD 比）: 全て ±7% のノイズ内（tokenize/fib は改善、他は同等）。`make test` `test-jit` `test-trace-jit` `test-san` `test-embed` `strict-clang` `analyze` が全て通る。

## 3. 測定で分かった TraceJIT の現状（フェーズ1以降の根拠）

1. **採用される形が玩具的**。`trace_build_ir` は「`while ローカル 比較 ローカル/定数` の形で、本体は LOAD_LOCAL/STORE_LOCAL/SMALLINT/CONST/ADD/SUB/MUL/NEG/DIV のみ、定数の型はループ条件の型と同じ」ループだけを通す。`for ... in range`、`%`、`//`、`if`、module 変数、配列、呼出しは全て拒否。fib/loop/collatz/nbody/sieve/matmul/tokenize の主ループは 1 つも採用されない（`SPRINT_TRACE_JIT_DEBUG=1` で `rejected` を確認）。
2. **採用されても速くない**。整数ループは領域 JIT と同等（0.319s 対 0.323s）。**float ループは 2 倍遅い**（2.10s 対 1.06s）。原因は f64 値を GPR に置き、演算ごとに `GPR→xmm0→演算→GPR` と往復するため（`ta_f64_binop`）。このため **f64 を含むトレースは現状採用しない**（`SPRINT_TRACE_JIT_F64=1` で解除。回帰テストは解除して実行）。
3. メモリ（load/store）・呼出し・割当てを表す IR 命令が無い。closure/oop が LuaJIT に及ばない根本原因（`trace-memory-v2.md`）。

結論: 現時点では TraceJIT は「安全に既定オンにできた基盤」であって、速度の利得はまだ無い。利得を出すにはフェーズ1〜3が必要。

## 4. 今後のフェーズ（バックエンド → ビルダーの順に修正）

フェーズ1の着手前調査で、**ビルダーだけ広げても速くならない**ことが分かった。バックエンドに次の欠落があるため、順序をバックエンド先行に改めた。

| 欠落 | 根拠 | 影響 |
|---|---|---|
| `IDIV` / `IMOD` を生成しない | `jit_trace.c:711` で `RETURN` と同じ「未対応」扱い | `%` `//` を含むループ（collatz、tokenize、loop）を通せない |
| ガードの出口が 1 種類 | 全 `GUARD_TRUE` が `TA_EXIT`（ループ条件偽の出口）へ飛ぶ | 本体内 `if` を「反復先頭へ戻して再実行」する deopt 出口で表せない |
| f64 を GPR に置く | `ta_f64_binop` が演算ごとに `GPR→xmm0→演算→GPR` | float ループが領域 JIT の 2 倍遅い（§3） |

### フェーズ1（バックエンド）
1. ✅ **実装済み** `IDIV` / `IMOD`: Sprint の床除算・床剰余の意味論で生成（2 のべき乗は `sar` / `and`、それ以外は `cqo; idiv` ＋符号補正、除数 0 と `INT64_MIN / -1` は deopt 出口）。
2. `GUARD_TRUE` の `aux` で出口を選べるようにする: 0 = ループ出口（従来）、1 = deopt（反復先頭の状態へ復元してヘッダからインタプリタで再実行）。スナップショットは既存の DEOPT 記述子を再利用。
3. f64 を XMM レジスタに割当て（`ta_alloc_regs` に XMM プール。PHI は固定割当て、exit stencil の FROM_IR 復元も XMM 対応）。完了後に f64 ゲート（§3）を外す。
   実装の要点: 除数が 0 / -1 なら deopt、2 のべき乗定数は `sar` / `and`（除算なし）、その他の小さな定数は逆数乗算（領域 JIT と同じ `jit_magic_of`）、変数除数は両オペランドが 32bit に収まる非負数なら 32bit `div`、それ以外は `idiv` ＋床補正。`rax`/`rdx` はプール末尾に置き、実際に使われたときだけ push/pop。実測（関数内ループ、Trace オン/オフ）: 定数 `%8`・`//4` のループ 0.39s 対 0.60〜0.68s（**1.6倍速**）、変数除数 0.75s 対 1.22s（**1.65倍速**）、`% 1000003` は 1.26s 対 1.15〜1.23s（同等）。
   併せて修正した不具合: 例外を捕捉した後、`cold.ev` が残るため版切替えの条件が偽になり続け、以降のループが一切記録されなかった。`cold` 状態を版の切替え時に丸ごと引き継ぐ方式に変え、切替えの条件自体をなくした（`RunCold`）。
4. 検証: 既存の IR 単体テスト（`trace_ir.c` 末尾の不変条件テスト）に IDIV/IMOD/新ガードを追加、`jitfuzz*.py` に生成パターンを追加。`trace_cmp.sh` で整数・float ループが領域 JIT 以上であること。

### フェーズ2（ビルダー）
- 記録済みステップ列（`TraceStep`）を ocode 上でデコードし、型付き SSA に抽象解釈する汎用ビルダーへ置き換える。対象: ローカル、整数・float の混在演算、`%` `//`、比較＋条件分岐（取った方向を deopt ガードとして出す）、`for ... in range`（RANGE_NEXT の cur/stop/step を整数の loop-carried 値に）、module 変数（entry で型ガードし、全 exit で書き戻す疑似ローカル）。
- 降格: exit が一定率を超えたトレースは無効化し領域 JIT へ戻す。偏りのない分岐（collatz の `n % 2`）での性能崖を防ぐ。
- 検証: fuzz に分岐・混在型を追加。`trace_cmp.sh` が全ベンチ 1.05 以下、かつ loop / collatz / nbody で領域 JIT 以上。

### フェーズ3: メモリ・呼出し・割当て
- `trace-memory-v2.md` の段階A〜C。closure / oop の LuaJIT 比 4〜10x の差を詰める本命。

## 5. 作業ルール
- 各フェーズで `make test` / `test-jit` / `test-trace-jit` / `test-san` / `test-embed` / `strict-clang` / `analyze` を全て通す。
- 利得は `tools/bench/trace_cmp.sh`（Trace オン/オフ）と `tools/bench/cmp.sh`（LuaJIT/V8/C 比較）の数値で示す。数値が出ないものは既定にしない。
