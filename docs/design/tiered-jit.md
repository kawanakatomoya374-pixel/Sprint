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
4. （フェーズ1）トレースの side exit が頻発するループは降格して領域 JIT に戻す（exit 率の計測で判断）。

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

## 4. 今後のフェーズ

### フェーズ1: 汎用の経路ベース IR ビルダー
- 記録済みステップ列（`TraceStep`、実行された pc の列）を ocode 上でデコードし、型付き SSA に抽象解釈する汎用ビルダーに置き換える。対象: ローカル、整数・float の混在演算（int+float は float）、`%` `//`、比較＋条件分岐（取った方向のガードとして出す）、`for ... in range`（RANGE_NEXT の cur/stop/step を整数の loop-carried 値として扱う）、module 変数（entry で型ガードし、全 exit で書き戻す疑似ローカル）。
- exit は「反復の先頭状態を復元してヘッダからインタプリタで再実行」で統一できる（反復内に副作用が無いため。既存の arith deopt と同じ考え方）。
- 降格: exit が一定回数・一定率を超えたトレースは無効化し領域 JIT へ戻す。偏りのない分岐（collatz の `n % 2`）での性能崖を防ぐ。side trace（既存）で分岐の両側を覆えるものは残す。
- 検証: `tools/jitfuzz*.py` に分岐・混在型の生成を追加。`trace_cmp.sh` が全ベンチ 1.05 以下。

### フェーズ2: f64 を XMM レジスタで保持
- `ta_alloc_regs` に XMM プールを追加し、f64 の PHI・中間値を XMM に固定割当て。snapshot の exit stencil（FROM_IR 復元）も XMM 対応にする。ここで f64 ゲートを外し、nbody 系で領域 JIT（0.19s）と LuaJIT（0.17s）の双方を上回ることを目標にする。

### フェーズ3: メモリ・呼出し・割当て
- `trace-memory-v2.md` の段階A〜C（load/store と前方伝搬・LICM、呼出しの展開、allocation sinking）。closure / oop の LuaJIT 比 4〜10x の差を詰める本命。

## 5. 作業ルール
- 各フェーズで `make test` / `test-jit` / `test-trace-jit` / `test-san` / `test-embed` / `strict-clang` / `analyze` を全て通す。
- 利得は `tools/bench/trace_cmp.sh`（Trace オン/オフ）と `tools/bench/cmp.sh`（LuaJIT/V8/C 比較）の数値で示す。数値が出ないものは既定にしない。
