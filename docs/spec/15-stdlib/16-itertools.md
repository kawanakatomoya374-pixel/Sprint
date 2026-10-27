### 15.16 itertools（2.3、同梱module）

`import itertools`。Sprintで書かれ、バイナリに埋め込まれる（同梱module。`itertools`は予約名）。**すべて先行評価**で、引数を変更せず新しいarray/tableを返す（割り当て点A）。コールバックは通常のユーザーコード実行点（付録B）。

| 関数 | 仕様 |
|---|---|
| `enumerate(a, start=0)` | `[[start+i, a[i]], ...]` |
| `zip(a, b, ...more)` | 最短の長さまで。`[[a[i], b[i], ...], ...]` |
| `take(a, n)` / `drop(a, n)` | 先頭`n`個 / 先頭`n`個を除いた残り（`n`が長さ以上でも可） |
| `take_while(a, f)` / `drop_while(a, f)` | `f(x)`が真の間の先頭部分 / その残り |
| `chunks(a, n)` / `windows(a, n)` / `pairwise(a)` | `n`個ずつ（最後は短い）/ 長さ`n`の連続部分（`pairwise`は`n=2`）。`n <= 0`はValueError |
| `flatten(a)` / `flat_map(a, f)` / `chain(...arrays)` | 1段平坦化 / `f(x)`の結果を連結 / 連結 |
| `unique(a, key=nil)` | 最初に現れた順で重複を除く。`key(x)`（またはx自身）はtableのkeyにできる値（§7.7） |
| `group_by(a, f)` / `count_by(a, f)` / `index_by(a, f)` | `f(x)`をkeyとするtable（要素の配列 / 個数 / 最後の要素） |
| `partition(a, f)` | `[真の要素, 偽の要素]` |
| `sum(a, init=0)` / `product(a, init=1)` | `+` / `*`で畳み込む |
| `min_by(a, f)` / `max_by(a, f)` | `f(x)`が最小/最大の最初の要素。空は`nil` |
| `sorted(a, cmp=nil)` / `sort_by(a, f)` / `reversed(a)` | コピーを返す。`sort_by`は`f(x)`を1要素1回だけ計算する安定ソート |
| `first(a, default=nil)` / `last(a, default=nil)` | 空なら`default` |
| `repeat(v, n)` / `range_list(a, b=nil, step=1)` | `[v]*n` / `range`をarrayにしたもの |
