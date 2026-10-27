### 15.9 sys

| 名前 | 割当 | 仕様 |
|---|---|---|
| `sys.args` | — | プログラム引数（`--`以降）のarray。各要素はstring |
| `sys.exit(code = 0)` | — | `0 <= code <= 255`のint（それ以外はValueError）。stdoutをflushし、**deferを実行せずに**直ちに終了する |
| `sys.platform` | — | `"linux"` / `"macos"` / `"windows"` / `"other"` |
| `sys.version` | — | `"2.0.0"`形式の処理系版 |

`sys.args`はプログラム開始時に1回だけ生成される配列で、読み出しは割り当てない。
