# TraceIR のメモリ・呼出し・割当て対応 — closure / oop を LuaJIT 級にするための設計

状態: 設計（未実装）。根拠は 2026-11 の測定。実装は段階ごとに独立してマージできる。

## 1. 測定（`build/sprint`、関数内ループ、1反復あたり）

| ベンチ | Sprint | LuaJIT | 差 | 1反復の内訳（callgrind / 逆アセンブル） |
|---|---|---|---|---|
| closure `r = f()`（upvalue を +1） | 2.8 ns | 0.65 ns | 4.3x | 約40命令: 呼出し先ガード、インライン予算の減算、cell の load→add→store、戻り値のスタック経由コピー、tick 減算 |
| oop フィールド2本の読み | 1.3 ns | ≈0.3 ns | 4x | 型・クラスガード＋load |
| oop `P(i, 2)`（生成のみ） | 11.1 ns | ≈1 ns | 10x | JIT 内で約92命令 + GC 約21命令。free-list 取得、`next_id`/`bytes`/objs 連結の bookkeeping、init をインライン展開した引数コピー |
| oop `p = p.add(d)` | 14.1 ns | ≈2 ns | 7x | 上に同じ |

LuaJIT は (a) ループ内で値を register に保ち続け、(b) 死んだ store を消し、(c) ループ内で生成して次の反復でしか読まないオブジェクトを**実体化せず**フィールドを SSA 値にする（allocation sinking）。Sprint の領域 JIT は値を常にスタックスロットに置く設計で、(a)(b)(c) のいずれもできない。

## 2. 試して退けた局所案（再び試さないための記録）

- **インライン戻り値を register のまま渡す**: 不可。領域 JIT の `EK_REG` 項目は「副作用なしで再計算できる」前提で、deopt 時はその項目を計算した `ppc` からインタプリタが再実行する（`gexit`）。インライン本体が cell を書き換えた後だと**二重実行**になる。戻り値をスタックに出しているのは意図的。
- **GC の調整**: 閾値は live×3、インスタンスの sweep は専用の短い経路で、既に十分。残りは sweep のメモリ追跡で、命令数では減らない。
- **割当ての bookkeeping 削減**（`next_id` を使わない等）: 数命令。差は埋まらない。

## 3. 方針: TraceIR（`trace_ir.c`/`jit_trace.c`）にメモリを足す

現在の TraceIR は i64/f64/bool/ref のスカラー演算のみ（`trace_ir.h` に load/store/call/alloc が無い）。SSA・snapshot・side trace・LRU キャッシュの基盤は既にあるので、**命令を足す**形で拡張する。領域 JIT は温存し、Trace が対応できない領域は従来どおり領域 JIT に落ちる。

### 段階A: 型付きメモリアクセス（フィールド・upvalue・配列要素）
- IR: `LOAD_FIELD(ref, slot)`, `STORE_FIELD(ref, slot, v)`, `LOAD_UPVAL(cell)`, `STORE_UPVAL(cell, v)`, `LOAD_ELEM`, `STORE_ELEM`、型・クラス・境界の `GUARD_*`。
- 最適化: 同一 `(ref, slot)` の load 前方伝搬（store→load forwarding）、ループ不変 load の巻き上げ（LICM）、死んだ store の除去、冗長ガード除去。別名解析はクラスのスロット番号で分け、不明な store（未解析の呼出し・JIT 外へ出る native）では全クリア。
- 効果見込み: closure は cell の load/store をループ越しに register 化（LuaJIT と同じ形）。フィールド読みは LICM で 1 ns を切る。
- 検証: `tools/jitfuzz_*.py` に別名パターン（同一オブジェクトへの 2 つの参照を経由した store→load）を追加。`make test-trace-jit`。

### 段階B: 呼出しのインライン記録
- recorder が `CALL`/`INVOKE` の callee を記録時の値で固定し、callee の同一性ガード＋本体を同じトレースに展開（深さ上限あり、再帰は不可）。引数・戻り値は SSA 値として受け渡すのでスタック経由コピーが消える。
- snapshot はインライン内のフレームを復元できるよう拡張（`frame` 付きエントリ）。**副作用のある命令は snapshot の確定点で区切る**ので、§2 の二重実行問題は起きない。
- 効果見込み: closure は A と合わせてループ本体が「cell を register で +1」だけになる。

### 段階C: 割当てと allocation sinking
- IR: `NEW_INSTANCE(class)` と、フィールドが定数/SSA 値である間の「仮想オブジェクト」。記録時に escape（他の store 先・native 引数・return・snapshot）を解析し、escape しないものは割当てを出さずフィールドを SSA 値として扱う。snapshot は仮想オブジェクトを実体化する記述子（クラス＋各フィールドの値）を持ち、side exit 時に割当てて復元する。
- ループをまたぐ（`p = p.add(d)` の `p`）場合は PHI の各フィールドを PHI にする。
- GC: 仮想オブジェクトは実体が無いので root にならない。実体化は snapshot 復元（割当てあり）でのみ起き、その時点では VM スタックに書き戻すので既存の精密 GC で安全。
- 効果見込み: oop の 11〜14 ns が数 ns へ。LuaJIT 比 1.1x は、このC段階の完成度に依存する。

### 段階D: 領域 JIT 側の小改善（独立）
- 呼出しごとの予算減算を、ループ周りの 1 回にまとめる。
- `STORE_MODULE`/`STORE_LOCAL` が inline 戻り値スロットから直接コピーするよう融合（reload の削減）。数命令だが安全。

## 4. 順序と判定基準
A → B → C → D の順。各段階で `closure`/`oop`/`o_*`（`/tmp` ではなく `tools/bench/` に追加する新ベンチ: `closure_fn`, `oop_alloc`, `oop_field`, `oop_add`）を LuaJIT と比較し、`make test` / `make test-trace-jit` / `make test-san` / jitfuzz が全て通ること。A 単独で closure が 2x 以上、C 完了で oop が 5x 以上改善しなければ設計を見直す。

## 5. リスク
- snapshot の複雑化（インラインフレーム、仮想オブジェクト）がバグの主因になる。fuzz と GC ストレス（`SPRINT_GC_STRESS=1`）を各段階の必須検査にする。
- トレースの採用範囲が狭いまま（ループ条件は数値2項比較のみ等、`docs/jit/README.md`）だと恩恵を受けるプログラムが限られる。A の最初にループ条件の一般化（真偽値・nil 判定・`while let`）を含める。
