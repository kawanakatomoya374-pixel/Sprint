## 12. エラー・try・defer・panic・assert

### 12.1 error値

error値は不変オブジェクトで、次のフィールドを読める（書くとTypeError）。フィールドの読み出しは割り当てをしない。

| フィールド | 型 | 内容 |
|---|---|---|
| `kind` | string | error class名（`"TypeError"`等、またはユーザー定義名） |
| `code` | int | §12.2の表。ユーザー定義kindは`100` |
| `message` | string | メッセージ |
| `cause` | error / nil | 生成時に明示的に指定した原因 |
| `data` | any | 生成時に指定した任意の値（既定`nil`） |
| `file` / `line` / `column` | string / int / int | 生成地点 |
| `suppressed` | error / nil | §12.4.3で記録された抑制エラー（最初の1個） |

- **traceはerror生成時に捕捉する**（`error(...)`の呼出し地点、またはVMが失敗を検出した地点）。`throw`はtraceを変更しない。同じerrorを再`throw`してもtraceは元のまま。
- traceは最大`max_trace_frames`（既定64）frameまで保持し、超えた分は中央を省略して件数を記録する。
- traceの文字列は`error_trace(e)`（A）で取得する。

### 12.2 error class表（正本）

| code | kind | 種別 | catch | 主な発生条件 |
|---:|---|---|---|---|
| 1 | TypeError | 実行時 | 可 | 演算・呼出しの型不一致、arity不一致 |
| 2 | NameError | 診断/実行時 | 可 | 未解決名（コンパイル時）、未宣言フィールド・メソッド・export、未初期化module変数 |
| 3 | IndexError | 実行時 | 可 | array/string index範囲外 |
| 4 | KeyError | 実行時 | 可 | `table.get_required`のkey欠落 |
| 5 | MatchError | 実行時 | 可 | `match`で一致なし |
| 6 | ArithmeticError | 実行時 | 可 | 0除算、int overflow |
| 7 | ImportError | 診断 | — | module未発見、循環、重複、lockfile不一致 |
| 8 | IOError | 実行時 | 可 | ファイル・標準入出力の失敗 |
| 9 | ConstError | 診断 | — | const/import/module関数束縛への代入 |
| 10 | AssertionError | 実行時 | 可 | `assert`の失敗 |
| 11 | RuntimeError | 実行時 | 可 | 反復中のtable構造変更、coroutine状態違反、`super()`の重複 |
| 12 | ParseError | 診断 | — | 構文エラー |
| 13 | （欠番） | — | — | 旧AsyncError。再利用しない |
| 14 | PermissionError | 実行時 | 可 | capability不足 |
| 15 | LexError | 診断 | — | 字句エラー |
| 16 | ValueError | 実行時 | 可 | 型は正しいが値が不正（不正な数値文字列、NaN key、不正JSON、step 0等） |
| 17 | OverrideError | 診断 | — | `override`規則違反 |
| 18 | LoadError | ロード | — | `.spc`の検証失敗 |
| 19 | MemoryError | 致命的 | 不可 | heap・stack・frame・defer領域等の上限超過 |
| 20 | TimeoutError | 致命的 | 不可 | `max_runtime_ms` / `max_instructions`超過 |
| 21 | Panic | 致命的 | 不可 | `panic`文（error値としては観測できない） |
| 100 | （ユーザー定義） | 実行時 | 可 | `error("MyKind", ...)` |

- 「診断」はコンパイル時（`check`/`run`の実行前）にだけ発生し、実行中のプログラムからは観測できない。
- 「致命的」はcatchできず、VMは直ちに停止する（§12.6）。

### 12.3 throw / try / catch

```sprint
try:
    risky()
catch e:
    if e.kind == "ValueError":
        print("bad value:", e.message)
    else:
        throw e
```

- `throw expr`: `expr`はerror値でなければならない。それ以外ならその`throw`の位置で**TypeError**を送出する（値を暗黙にerrorへ包まない、H4）。
- errorの生成は`error(kind, message, cause = nil, data = nil)`（§15.1）で行う。
- `try`ブロック内で送出されたcatch可能なerrorはすべて`catch`ブロックへ移る。`catch e`の`e`は`catch`ブロックのスコープの変数。`catch:`のように名前を省略してもよい。
- 種類による選別は`catch`ブロック内で行い、不要なら`throw e`で再送出する。
- `catch`ブロック内で起きたerrorは通常どおり外へ伝播する。`cause`は自動設定しない（H4）。原因を連鎖させたい場合は`error(kind, msg, e)`と明示する。
- `finally`は存在しない。cleanupは`defer`で書く。

### 12.4 defer

```sprint
import fs

func copy(src, dst, log):
    let data = fs.read_file(src)
    for i in range(3):
        defer log.write("iteration end")    # 各反復のブロック終了時に実行
    defer print("done")                     # copyの本体ブロック終了時に実行
    fs.write_file(dst, data)
```

#### 12.4.1 登録

- `defer CALL`は、`CALL`のcallee（メソッド呼出しならreceiverとメソッド検索結果）と全引数を**登録時に**左から右へ評価し、呼出しは行わない。
- 登録情報はVMのdefer領域（VM生成時に確保、A4）に置く。登録は割り当てをしない。上限`max_defer_records`/`max_defer_values`超過はMemoryError。
- 登録した呼出しは、`defer`文を直接含む**ブロック**に属する。

#### 12.4.2 実行

- ブロックを抜けるとき（末尾到達、`break`、`continue`、`return`、errorの伝播、panic）、そのブロックに属する登録済みのdeferをLIFOで実行する。
- 到達しなかった`defer`文は登録されていないので実行されない。
- deferred callの戻り値は捨てる。
- `return v`の`v`は、deferの実行**前**に評価・確定する。deferは戻り値を変更できない。
- deferred callの実行中（呼ばれた関数内を含む）に`yield`するとRuntimeError。

#### 12.4.3 deferred callが失敗した場合

| ブロックを抜けた理由 | deferred callでerror E2 | deferred callでpanic |
|---|---|---|
| 正常終了・break・continue・return | E2が新たに伝播する（残りのdeferは引き続き実行する）。元の移動はキャンセルされる | panicが始まる |
| error E1の伝播 | **E1が伝播を続ける**。E1の`suppressed`が空ならE2を記録する。2個目以降は捨てる | panicが始まる（E1は捨てる） |
| panic P1 | P1が続く。E2は捨てる（`--trace=error`の出力に注記する） | P1が続く。後のpanicメッセージは注記として出力する |

いずれの場合も、同じブロックの残りのdeferと外側のブロックのdeferは引き続き実行する。

### 12.5 panic

- `panic expr`は回復不能な停止を開始する。`expr`がstringでなければ`to_string`で文字列化する。
- panicは`catch`できない。
- panicは現在のcoroutineのすべてのframeのdeferを内側から順に実行し、さらにそのcoroutineをresumeしていたcoroutineへ（最終的にはmainまで）伝播して同様にdeferを実行する。その後、処理系は終了コード101で終了する。
- 停止時の出力（stderr）は`panic: MESSAGE`とtrace。

### 12.6 致命的エラー

MemoryError、TimeoutError、ユーザー割り込みは**deferを実行せず**、直ちにVMを停止する。stdoutバッファはflushする。埋め込み時はhostへ該当statusが返る（§20）。

### 12.7 assert

```sprint
assert x > 0, "x must be positive"
```

- 条件が偽なら、メッセージ式を評価し（stringでなければ`to_string`）AssertionErrorを送出する。メッセージ省略時は`"assertion failed"`。
- メッセージ式は条件が偽のときだけ評価する。
- assertは常に有効である（無効化オプションはない）。

### 12.8 未処理エラーの出力

エントリポイントまで伝播したerrorは、stderrへ次の形式（human）で出力し、終了コード1（PermissionErrorは3）で終了する。

```text
error[ValueError]: invalid literal "abc"
  --> main.sp:12:9
trace (most recent call last):
  main.sp:20:5 in <module main>
  main.sp:12:9 in parse_config
```

`--diagnostic-format=json`の場合は§22.2の形式。
