### 15.22 hash

`import hash`。バイト列のダイジェスト。

| 関数 | 割当 | 仕様 |
|---|---|---|
| `hash.sha256(data)` | A | `data`は string・0〜255のintのarray・`typed`の整数配列。SHA-256（32バイト）を`typed.u8`で返す。それ以外はTypeError、範囲外の要素はValueError |

ブートローダー（`os/boot/`）のイメージ検証と Authenticode 署名に使う。
