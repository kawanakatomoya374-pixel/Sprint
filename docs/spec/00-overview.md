## 0. 本書について

### 0.1 規範語

- **MUST / しなければならない**: 必須。
- **MUST NOT / してはならない**: 禁止。
- **SHOULD / すべき**: 推奨。満たさなくても観測可能な挙動は変わらない。
- **MAY / してよい**: 任意機能。有効にする場合は`sprint features`に表示し、**デフォルトで無効**でなければならない。

本書における「実装定義」は§0.4に列挙したものだけである。

### 0.2 版の管理

Sprintは次の3つの版番号を独立に管理する。

| 版 | 本書での値 | 上げる条件 |
|---|---|---|
| 言語版 | 2.4 | 構文・意味の変更。互換を壊す変更はmajor。2.1〜2.4は直前の版に対する**上位互換の追加のみ**（§0.3.1〜§0.3.4） |
| bytecode format版 | major 2 / minor 0 | §16.6の規則に従う |
| C API版 | major 2 / minor 0 | 公開ヘッダの型・関数の互換を壊す変更はmajor |

v1.6はbytecode ABI major 1を「凍結」したが、本書はopcode表・ファイル形式・値表現を変更するため、major 2とする。major 1の`.spc`ファイルはSprint 2.0処理系で実行してはならない（LoadError、終了コード13）。

### 0.3 v1.6からの主要な変更（要約）

詳細は付録D。

1. 「隠れた制御フローなし」「隠れたメモリ割り当てなし」を言語原則として追加（§1.2, §1.3、付録A, B）。
2. メタメソッド（`__index`, `__next`, `__gc`, `__iter`, `setmetatable`）を**完全に削除**。演算子オーバーロードもない。
3. `finally`, `async`, `await`, `promise`, `global` を削除。cleanupは`defer`、非同期・generatorは`coroutine`に一本化。
4. array/tableの`==`はidentity比較に変更（隠れた再帰・割り当てを排除）。深い比較は明示関数。
5. 文字列はUTF-8バイト列とし、`len`はバイト数（O(1)）。コードポイント操作は明示メソッド。
6. 複合代入（`+=`等）、ビット演算、条件式、`from ... import`を追加。
7. opcode表をv2正本として全面再定義（§17.4）。v1.x系の表はすべて無効。
8. 処理系の実装言語をC11に固定し、埋め込み用C API（§20）を規定。

#### 0.3.1 2.0から2.1への追加（上位互換）

2.0のプログラムは2.1処理系でそのまま同じ意味で動く。追加は次のとおりである（`?`・`??`を字句として禁止していた§3.7の旧規定は、`??`に限って解除された）。

1. **f-string**: `f"... {式} ..."`（§3.6.1）。
2. **スライス糖衣**: `a[i:j]` は `a.slice(i, j)` の糖衣（§8.2, §8.3）。
3. **nil合体 `??`**: `a ?? b`（§7.9）。
4. **分割代入**: `let [a, b, ...rest] = e`、`let {x, y: z} = e`、`const`も同様（§5.2.1）。
5. **複合代入の追加**: `**=` `&=` `|=` `^=` `<<=` `>>=`（§4.1）。
6. **標準module `gfx`**: ソフトウェア描画canvasとPNG/PPM/BMP出力（§15.13）。
7. **native object**: ホストが定義する不透明な値`native`の実用化（`gfx.canvas`が最初の利用者）。メソッド呼出しは`obj.method(...)`で、`NativeClass`がメソッド表を持つ。
8. **C埋め込みAPI**（§20）の実装。公開ヘッダ`sprint.h`と静的ライブラリ`libsprint.a`。
9. **float表示の訂正**: §6.6の規則2・3が、同節の例（`100.0`→`100.0`）と食い違っていた。10進指数が0以上16未満のfloatは指数形式にしないと規則を改め、例と一致させた（§6.6）。2.0処理系は`100.0`を`1e+02`と表示していた。

#### 0.3.2 2.1から2.2への追加（上位互換）

2.1のプログラムは2.2処理系でそのまま同じ意味で動く。追加はすべて**糖衣**であり、新しい実行時の意味・opcodeを持たない（既存の構文へ展開される）。

1. **アロー関数**: `x => e`、`(a, b = 1) => e`、`() => e`（§9.1）。`func(x): e`と同じ意味で、本体は式1つ。
2. **パイプ `|>`**: `x |> f`は`f(x)`、`x |> f(a, b)`は`f(x, a, b)`（§7.10）。行頭の`|>`は直前の式の続きとして扱う。
3. **内包表記**: `[e for x in xs if c]`、`{k: v for k, v in t}`（§11.5）。
4. **`for x in xs if cond:`**: 本体を`if cond:`で包む糖衣（§11.2）。
5. **標準module**: `gfx`にclip・角丸・グラデーション・anti-alias線・`hash`/`diff`等を追加（§15.13）。同梱module `gui`にlayout engine・ScrollView・theme・animation・記録/再生・snapshot検査を追加（§15.14）。
6. **match式**: `match x:`＋`case p => e`の腕を値として使える（§11.4）。文の`match`でも`case p => 式`と書ける。
7. **FFI**: 同梱module `ffi`でCの共有ライブラリ（`extern "C"`で公開したC++を含む）を呼べる。capability `ffi`（`--allow-ffi`）が必要で、`--deterministic`では使えない（§15.15, §19.2）。
8. **字句**: `=>`と`|>`が演算子になった（§3.7）。`?` `?.` `++` `--` `!` `@` `$`は引き続き存在しない。

#### 0.3.3 2.2から2.3への追加（上位互換）

2.2のプログラムは2.3処理系でそのまま同じ意味で動く。構文の追加はすべて**糖衣**であり、新しいopcodeを持たない。追加された形はどれも2.2では`ParseError`/`LexError`だったもので、既存のプログラムの意味は変わらない。

1. **`in` / `not in`**: `x in c`は配列の要素・文字列の部分文字列・tableのkeyの有無（§7.12）。
2. **連鎖比較**: `a < b <= c`は各項を1回だけ評価し、前の比較が偽なら以降を評価しない（§7.6）。2.2では`ParseError`だった。
3. **オプショナル連鎖と代入**: `a?.b` `a?.f(x)` `a?[i]`（§7.11）、`a ??= v`（§7.9）。2.2では`?`が字句エラーだった。
4. **多重代入**: `a, b = b, a`、`a, b = pair`（§5.2.2）。
5. **束縛つき条件**: `if let x = e:`と`while let x = e:`（§11.1）。`e`が`nil`でないときだけ`x`を束縛して本体を実行する。
6. **`for`・内包表記の分割代入**: `for [a, b] in xs:`、`for {x, y: z} in xs:`、`[a + b for [a, b] in xs]`（§11.2）。
7. **table literalの省略形**: `{x, y}`は`{x: x, y: y}`（§8.4）。
8. **生文字列**: `r"..."` `r'...'` `r"""..."""`はエスケープを解釈しない（§3.6）。
9. **標準module**: 同梱module `itertools`・`strutil`（§15.16, §15.17。`gui` `ffi`と同じく予約名なので、プロジェクトが同名の`itertools.sp`/`strutil.sp`を持つ場合は2.3では改名が必要で、これが上位互換の唯一の例外である）。`gui`に`MenuBar` `Tree` `Table` `Splitter` `Spinner` `RadioGroup` `PopupMenu`・tooltip・toastを追加（§15.14）。
10. **処理系**: 同梱moduleのsource hashを遅延計算し、`import gui`の起動を速くした。観測できる意味は変わらない。

#### 0.3.4 2.3から2.4への追加（上位互換）

1. **別moduleのclassを`extends`できる**: `class B extends m.A:` / `from m import A` の後の `class B extends A:`（§10.1）。§10.1が最初から要求していたが、2.3までの処理系は`NameError`で拒否していた。親の**フィールド初期化式は親を宣言したmoduleのscopeで評価される**（子のmoduleから見えない名前も使える）。exportされたclassのフィールド初期化は、コンパイラが生成する隠しmodule変数の関数（祖先の初期化を含む）として公開されるため、`export`の有無でclassの意味は変わらない。
2. **標準module `guiplus`**（§15.18）: `Chart`（line/area/bar/scatter/pie/donut）`CanvasView` `ColorPicker` `Calendar` `IconButton` `Toolbar` `StatusBar`と19個のベクタicon。`guiplus`は予約名。
3. **`gui`の拡張**（§15.14）: テキスト編集（選択・clipboard・undo/redo・単語移動・ダブル/トリプルクリック・Shift選択）、イベントの`mods`・`clicks`、キーマップ`app.bind`、スクロールバー、折り返し`Label`、`Flow` `Stack` `Expander`、ドラッグ＆ドロップ。

#### 0.3.5 2.5から2.6への追加（上位互換）

1. **日本語**（2.5）: `gfx`が12×12の日本語字形を描き（`gfx.text_advance`）、`gui`の幅計算・折り返し・テキスト編集が日本語に対応する（§15.13、§15.14）。
2. **標準module `window` `vfs` `proc` `wm`**（§15.19）: ウィンドウのバックエンド層（headlessを同梱）、メモリ上のファイルシステム、協調マルチタスクのカーネルとシェル、ウィンドウ・タスクバー・ターミナルを持つデスクトップ。
3. **`gui`の拡張**（§15.14）: 当たり判定の形状（楕円・角丸・多角形・マスク）、クリック透過、マウスポインタの形状と描画。

### 0.4 実装定義として許可する事項（これ以外はない）

1. GCアルゴリズム（mark-and-sweep、インクリメンタル、世代別など）。ただし§18の観測可能な挙動は固定。
2. table内部のハッシュ関数とハッシュシード（反復順は挿入順で固定されるため観測不能）。
3. 短い文字列のinterning有無。
4. bytecodeのdispatch方式（switch / computed goto）。
5. 診断・エラーの**メッセージ本文**（翻訳可）。class・code・位置は固定。
6. `gc.stats()`が返す数値。
7. オブジェクトのメモリ上のサイズ（したがって`max_heap_bytes`に到達する時点）。
8. `math`の超越関数の結果（プラットフォームのlibmに従う）。

### 0.5 早見表（非規範：まず最初に読む）

```sprint
import math                       # builtin module。user moduleも `import a.b`
from util.mathx import inc        # user module（export されたものだけ）

export const LIMIT = 10           # module外へ公開

class Counter:                    # 単一継承。フィールドは宣言必須
    let n = 0
    func init(self, start):
        self.n = start
    func bump(self):
        self.n += 1
        return self.n

func risky(x):
    if x < 0:
        throw error("ValueError", "negative")
    return math.sqrt(x)

let c = Counter(5)
for i in range(3):                # range は for では割り当てなし
    c.bump()
print(c.n)                        # 8

try:
    risky(-1)
catch e:
    print(e.kind, e.message)      # ValueError negative

let squares = [1, 2, 3].map(func(x): x * x)       # 高階メソッド（§8.3）
match squares:
    case [first, _, _]:
        print("first =", first)
    case _:
        print("other shape")

func read(path):
    defer print("done")           # 関数を抜ける時に実行
    return path

let [lo, hi, ...others] = [1, 9, 4, 5]            # 分割代入（§5.2.1）
let {name, age: years} = {name: "Ada", age: 36}
print(f"{name} is {years}; range {lo}..{hi}")     # f-string（§3.6.1）
print(others[1:], nil ?? "fallback")              # スライス、nil合体（§8.3, §7.9）

import gfx                        # ソフトウェア描画（§15.13）
let img = gfx.canvas(64, 64, gfx.rgb(255, 255, 255))
img.fill_circle(32, 32, 20, gfx.rgb(200, 30, 30))
img.save_png("out.png")           # --allow-write=DIR が必要
```

覚えておくこと（詳細は各章）:

| 規則 | 要点 |
|---|---|
| ブロック | `:`＋インデント。`pass`で空ブロック（§3.2） |
| 型 | nil / bool / int(64bit) / float / string(UTF-8) / array / table / function / class / instance / module / iterator / coroutine / error（§6.1） |
| 等値 | array・tableの`==`は同一性。内容比較は`deep_equal`（§7.6） |
| 文字列 | `len`はバイト数。文字単位は`s.char_count()`・`s.codepoints()`（§8.2） |
| エラー | `throw error(kind, msg)`、`try/catch`。panicは捕捉できない（§12） |
| 隠れた処理なし | 暗黙の割り当て・暗黙のコード実行は付録A・Bに列挙したものだけ（§1.2, §1.3） |
| 権限 | fs・random・clockは既定で制限。`--allow-read=DIR`等で明示（§19.2） |

### 0.6 このリファレンス実装（`sprint`）の対応状況

本節は非規範である。仕様に対して実装がどこまで到達しているかを示す。

| 領域 | 状況 |
|---|---|
| 字句・構文・コンパイラ | 完了（class/match/defer/yield/export に加え、f-string、スライス糖衣、`??`、分割代入、追加の複合代入、2.2のアロー関数・パイプ`\|>`・内包表記・`for … if`、2.3の`in`・連鎖比較・`?.`・`??=`・多重代入・`if let`/`while let`・`for`の分割代入・table省略形・生文字列を含む） |
| VM（スタックVM、defer、coroutine、native再入） | 完了 |
| module / package | `import`・`from`・`export`、循環/未発見/重複/root外の検出、`Sprint.toml`の`source_root`、`SPRINT_PATH`。同梱module（`gui`・`ffi`、§14.3・§15.14・§15.15）。**未対応**: `[dependencies]`と`Sprint.lock` |
| 標準ライブラリ | prelude、`math` `str` `table` `io` `sys` `time` `gc` `coroutine` `json` `random` `fs` `gfx` `typed`、同梱module `gui`（ウィジェットtoolkit＋イベントループ、headless）、iterator（`range`値・`s.codepoints()`）、array高階メソッド、native object。**未対応**: `str.format`の拡張書式 |
| CLI | `run` `check` `compile` `exec` `disasm` `version` `features`、`--allow-*`、`--no-quicken`、`--no-jit`、`repl`（§23.1）、`fmt [--check] [-w]`（§23.2）、`lint [--json]`（§23.3）。**未対応**: `lint --alloc`、`test`、`inspect` |
| `.spc`イメージとverifier（§16, §17.9） | 実装済み（`sprint compile` / `sprint exec`、`run`も画像を自動判別）。checksum・SHA-256・section構造・verifier（命令境界、jump先、index範囲、stack高さ・handler深さの抽象解釈、class/link検査）を備え、変異ファジング（`make fuzz`）で検証 |
| C埋め込みAPI（§20） | 実装済み（`src/sprint.h`、`make lib`で`build/libsprint.a`、サンプル`examples/embed/host.c`、テスト`make test-embed`）。**未対応**: カスタムアロケータ（`SpConfig.alloc`は`NULL`のみ、§20.8） |
| 実行性能 | 命令の融合（quickening）、step budget、サイズクラスpool、inline cache、コンストラクタ高速パス（§10.3の注）、int除算/剰余のインライン化、x86-64 Linuxのループ向けCopy-and-Patch JIT（§17.10）を備える。観測可能な挙動は変わらず、`--no-quicken` / `--no-jit`との差分テストで検証 |
| 品質ゲート | `-Werror`＋約70警告＋hardening、ASan/UBSan、`-fanalyzer`、回帰テスト（`make test` `make test-san` `make test-embed` `make analyze` `make fuzz`） |

診断には補助情報が付く: 未定義名には近い名前の候補（`did you mean 'x'?`）、import忘れの可能性がある標準module名にはその旨が表示される（本文は実装定義、§0.4）。
