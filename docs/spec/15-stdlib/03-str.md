### 15.3 str

| 関数 | 割当 | 仕様 |
|---|---|---|
| `str.format(template, ...args)` | A | `{}`を引数の`to_string`で順に置換。`{{`と`}}`はリテラル。`{}`の数と引数の数が違えばValueError。`{`の後に`}`以外が続けばValueError |
| `str.from_codepoint(cp)` | A | Unicode scalar valueでなければValueError |
| `str.from_bytes(arr)` | A | 0–255のintのarray。不正UTF-8はValueError |
| `str.to_bytes(s)` | A | バイト値のarray |
| `str.join(arr, sep)` | A | `arr.join(sep)`と同じ |

文字列メソッドは§8.2。
