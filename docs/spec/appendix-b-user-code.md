## 付録B ユーザーコード実行点と制御移動点（正本）

### B.1 Sprintのユーザーコードが実行される地点

| 地点 | ソース上の見え方 |
|---|---|
| 関数・メソッド・`super`の呼出し、default引数式（callee側） | 呼出し構文`f(...)` |
| classの呼出し（フィールド初期化式と`init`） | 呼出し構文`C(...)` |
| `a.sort(cmp)`の`cmp`、`a.each/map/filter/reduce/any/all/find(f)`の`f` | 呼出し構文。関数を引数として渡している |
| `for`によるcoroutineの反復 | `for` |
| `coroutine.resume` / `coroutine.close`（defer） | 呼出し構文 |
| deferred callの実行 | `defer`文（登録時に視認できる）とブロックの終端 |
| module初期化 | `import`文（プログラム開始時、§14.5の順） |
| `sp_call`（`SP_NATIVE_CALLS_BACK`付きnative関数内） | そのnative関数の呼出し構文 |

これ以外の地点（演算子、添字、メンバアクセス、`len`/`type`/`to_string`/`print`、hash、等値、GC、errorの生成・送出・catch、パターン照合、array/table/iteratorの反復）でユーザーコードが実行されることはない。

### B.2 制御が移動し得る地点

| 構文・操作 | 送出し得るもの |
|---|---|
| `return`/`break`/`continue` | （移動前にdeferを実行） |
| `throw` | 指定したerror、または非errorでTypeError |
| `panic` | panic |
| `yield` | coroutineの中断（coroutine外ではRuntimeError） |
| 算術・ビット演算 | TypeError、ArithmeticError、ValueError（シフト量） |
| 比較 | TypeError |
| `..` / 割り当て点全般 | MemoryError（致命的） |
| 添字 | TypeError、IndexError、ValueError（NaN key） |
| メンバ | NameError、TypeError |
| 呼出し | TypeError + calleeの送出するもの |
| `for` | TypeError、RuntimeError + coroutine/iteratorの送出するもの |
| `match` | MatchError |
| `assert` | AssertionError |
| module変数・importの読み出し | NameError（未初期化） |
| すべての命令 | TimeoutError、割り込み（致命的） |

等値（`==`/`!=`）、論理演算、変数の読み書き、`defer`の登録（上限超過のMemoryErrorを除く）はerrorを送出しない。
