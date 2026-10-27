### 15.1 prelude（importなしで使える）

| 関数 | 割当 | 仕様 |
|---|---|---|
| `print(...values)` | — | 各値を`to_string`規則で書き、間に1個のspace、最後に`\n`を出力する。出力バッファ（A4）へ直接書くためヒープ割り当てをしない。capability `stdio_write`が必要 |
| `len(v)` | — | string（バイト数）、array、table。その他はTypeError |
| `type(v)` | — | §6.1の型名（定数文字列） |
| `to_string(v)` | A? | §6.5。stringはそのまま返す |
| `to_int(v)` | — | intはそのまま。floatは0方向へ切り捨て（NaN/inf/範囲外はValueError）。stringは前後空白なしの`[+-]`付き整数literal構文（`_`, `0x`等を含む）。boolなどはTypeError |
| `to_float(v)` | — | int→float、floatはそのまま、stringは数値literal構文または`inf` / `-inf` / `nan` |
| `range(...)` | A | §11.2。`for`ヘッダでは割り当てない |
| `error(kind, message, cause = nil, data = nil)` | A | error値を生成（§12）。`kind`は識別子構文のstring。§12.2の実行時kind名ならそのcode、それ以外の名前は100。診断・致命的のkind名（ParseError, MemoryError等）はValueError |
| `error_trace(e)` | A | traceを§12.8形式の文字列で返す |
| `has(t, k)` | — | tableにkeyが存在すればtrue |
| `delete(t, k)` | — | keyを削除し、削除前の値（なければ`nil`）を返す |
| `deep_equal(a, b)` | — | array/tableを再帰的に、その他は`==`で比較。深さ256を超えたらValueError（循環構造の検出を兼ねる） |
| `classof(v)` / `class_name(c)` / `is_instance(v, C)` | — | §10.6 |

`assert`と`panic`は文であり、関数ではない。

preludeにはパーサ専用の隠れた関数`$in`（`x in c`の展開先、§7.12）もある。名前が識別子でないため、プログラムから名前で参照することはできない。
