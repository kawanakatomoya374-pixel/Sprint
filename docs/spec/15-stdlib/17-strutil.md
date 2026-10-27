### 15.17 strutil（2.3、同梱module）

`import strutil`。Sprintで書かれた同梱module（予約名）。幅は**code point数**（`char_count()`）で数える。

| 関数 | 仕様 |
|---|---|
| `pad_left(s, n, ch=" ")` / `pad_right(...)` / `center(s, n, ch=" ")` | 幅`n`まで`ch`で埋める（`s`が長ければそのまま）。`center`は余りを右へ |
| `capitalize(s)` / `title(s)` | 先頭を大文字・残りを小文字（ASCII）/ 各単語に`capitalize`（空白は1個に詰める） |
| `words(s)` / `lines(s)` | 空白で分割して空要素を除く / `s.split_lines()` |
| `is_digits(s)` / `is_alpha(s)` / `is_space(s)` | 非空で全バイトがASCIIの数字 / 英字 / 空白 |
| `truncate(s, n, ellipsis="...")` | 幅が`n`を超えるときcode point境界で切って`ellipsis`を付け、幅を`n`にする |
| `indent(s, prefix="    ")` | 空でない各行の前に`prefix` |
| `wrap(s, width)` | 単語を詰めた行のarray（1語が`width`を超えてもその行に置く） |
| `reverse(s)` | code point単位で反転 |
