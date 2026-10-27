### 15.10 json

| 関数 | 割当 | 仕様 |
|---|---|---|
| `json.parse(s)` | A | RFC 8259。下記 |
| `json.stringify(v, indent = 0)` | A | 下記 |

**parse**:
- `null`→nil、`true`/`false`→bool、object→table（出現順。重複keyは後の値で更新し、位置は最初の出現）、array→array、string→string。
- 数値: 小数点も指数もなく、int範囲に収まるものはint。それ以外はfloat（overflowして無限大になる数値はValueError）。
- 入れ子の深さ上限512。不正な入力、BOM、末尾の余分な文字（空白以外）はValueError。`data`に`{line: int, column: int}`を入れる。

**stringify**:
- nil→`null`、bool、int、有限float（§6.6の表記）、string、array、table（keyはstringのみ。それ以外はTypeError）。
- NaN/inf→ValueError。function/class/instance/module/iterator/coroutine/error/native→TypeError。
- 深さが512を超えたらValueError（循環参照もこれで検出する）。
- string出力: `"`→`\"`、`\`→`\\`、U+0008/09/0A/0C/0D→`\b \t \n \f \r`、その他U+0000–U+001Fは`\u00XX`（小文字hex）。それ以外（非ASCII含む）はそのまま。`/`はescapeしない。
- `indent == 0`は空白なし。`1..8`は改行と指定数のspaceで整形（`": "`の後にspace 1個）。それ以外はValueError。
