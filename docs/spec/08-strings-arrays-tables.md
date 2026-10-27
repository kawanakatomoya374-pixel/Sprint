## 8. 文字列・array・table

### 8.1 割り当て区分の表記

本書のAPI表で、各操作の割り当て区分を次のように示す（§1.3）。

| 記号 | 意味 |
|---|---|
| — | ヒープ割り当てをしない |
| A | 必ず割り当てる（成功時） |
| A? | 条件付きで割り当てる。条件は各APIに記載する。コンテナへの追加系操作は「容量不足の場合だけ」割り当て、`reserve`で事前確保すれば割り当てない |

いずれの操作も、割り当ての結果`max_heap_bytes`等を超える場合はMemoryError（致命的）である。上限を超えることが操作開始前に分かる場合は、何も変更せずに失敗する。

### 8.2 string

- 不変のUTF-8バイト列。常に正しいUTF-8である。
- `len(s)`は**バイト数**（O(1)）。
- `s[i]`は`i`番目のバイトをint（0–255）で返す（—）。`i`はintで`0 <= i < len(s)`。範囲外はIndexError、非intはTypeError。負のindexはない。
- 文字列への添字代入はTypeError。
- **スライス糖衣（2.1）**: `s[i:j]`は`s.slice(i, j)`、`s[i:]`は`s.slice(i)`、`s[:j]`は`s.slice(0, j)`、`s[:]`は`s.slice(0)`の構文糖衣であり、意味・割り当て（A）・エラーは`slice`と同じ（負のindexはない）。
- メソッドは呼出し形式（`s.name(...)`）でのみ使える。`s.name`を呼ばずに読むとTypeError。

| メソッド | 割当 | 仕様 |
|---|---|---|
| `s.slice(start, end=len(s))` | A | バイト範囲`[start, end)`。範囲外はIndexError、`start > end`はValueError、境界がcode point途中ならValueError |
| `s.find(sub, start=0)` | — | 最初の出現のバイトoffset。なければ`-1` |
| `s.contains(sub)` | — | bool |
| `s.starts_with(p)` / `s.ends_with(p)` | — | bool |
| `s.count(sub)` | — | 重ならない出現回数。`sub == ""`はValueError |
| `s.split(sep)` | A | arrayを返す。`sep == ""`はValueError。`"".split(",") == [""]` |
| `s.split_lines()` | A | `\n`で分割。末尾の`\n`は空要素を作らない |
| `s.trim()` / `s.trim_start()` / `s.trim_end()` | A? | ASCII空白（space, \t, \n, \r, \v, \f）を除去。変化がなければ`s`自身を返し割り当てない |
| `s.upper()` / `s.lower()` | A? | ASCII英字のみ変換。変化がなければ`s`自身 |
| `s.replace(old, new)` | A? | 全置換。`old == ""`はValueError。出現がなければ`s`自身 |
| `s.repeat(n)` | A | `n < 0`はValueError。`n == 0`は`""` |
| `s.char_count()` | — | code point数（O(n)） |
| `s.codepoints()` | A | code point（int）を順に返すiterator |
| `s.char_at(i)` | — | バイトoffset`i`から始まるcode point（int）。`i`が境界でなければValueError |
| `s.is_boundary(i)` | — | `i`がcode point境界（`0`と`len(s)`を含む）ならtrue |

### 8.3 array

- 0始まりの可変長配列。要素数`len(a)`はO(1)。
- `a[i]`と`a[i] = v`は`0 <= i < len(a)`のintのみ（—）。範囲外はIndexError、非intはTypeError（`1.0`も不可）。
- `a[i] = nil`は要素削除ではなく`nil`を格納する。
- array literal `[e1, ..., en]`は**A**（容量`n`で1回割り当てる）。
- **スライス糖衣（2.1）**: `a[i:j]`は`a.slice(i, j)`、`a[i:]`は`a.slice(i)`、`a[:j]`は`a.slice(0, j)`、`a[:]`は`a.slice(0)`の構文糖衣（新しいarrayを割り当てる、A）。意味とエラーは`slice`メソッドの規則に従う。
- メソッドは呼出し形式でのみ使える。

| メソッド | 割当 | 仕様 |
|---|---|---|
| `a.append(v)` | A? | 末尾に追加。容量は不足時に少なくとも1.5倍に拡張 |
| `a.extend(b)` | A? | arrayの全要素を末尾に追加。`a.extend(a)`は呼出し時点の要素を1回だけ追加 |
| `a.insert(i, v)` | A? | `0 <= i <= len(a)`。それ以外はIndexError |
| `a.pop()` | — | 末尾を削除して返す。空ならIndexError |
| `a.remove_at(i)` | — | 削除して返す。後続要素を詰める |
| `a.clear()` | — | 要素数を0にする。容量は保持 |
| `a.reserve(n)` | A? | 容量を少なくとも`n`にする。以後`len(a) <= n`である限りappend/insert/extendは割り当てない |
| `a.capacity()` | — | 現在の容量 |
| `a.slice(start, end=len(a))` | A | 新しいarray |
| `a.copy()` | A | 浅いコピー |
| `a.index_of(v)` | — | `==`で最初に一致した位置、なければ`-1` |
| `a.contains(v)` | — | bool |
| `a.reverse()` | — | その場で反転 |
| `a.sort(cmp=nil)` | A | 安定ソート、その場で並べ替え。一時領域として最大`len(a)`要素分を割り当てる。`cmp`がnilなら`<`で比較（比較不能な要素があればTypeError）。`cmp(x, y)`は「`x`を`y`より前に置くべきならtrue」を返す関数 |
| `a.join(sep)` | A | 全要素がstringでなければTypeError |
| `a.each(f)` | — | 各要素に`f(x)`を呼ぶ。戻り値は`nil` |
| `a.map(f)` | A | `f(x)`の結果を集めた新しいarray |
| `a.filter(f)` | A | `f(x)`が真の要素だけを集めた新しいarray |
| `a.reduce(f, init)` | — | `acc = init`から`acc = f(acc, x)`を順に適用した最終値。空なら`init` |
| `a.any(f)` / `a.all(f)` | — | 短絡評価。空配列では`any`は`false`、`all`は`true` |
| `a.find(f)` | — | `f(x)`が真になる最初の要素、なければ`nil` |

高階メソッド（`each` `map` `filter` `reduce` `any` `all` `find`）は`for`と同じ規則で反復する: 各ステップの前に`i < len(a)`を再評価し、コールバック内の追加・削除が以後の反復に反映される。コールバックが送出したerrorはそのまま伝播し、途中までの結果は捨てられる。コールバックが関数またはclassでなければTypeError。コールバック内の`yield`はRuntimeError。

`a.sort(cmp)`は`cmp`を呼ぶ（ユーザーコード実行点、付録B）。`sort`は作業用の一時領域上で並べ替え、最後に`a`へ書き戻す。`cmp`の実行中に`a`が変更された場合（長さまたは要素の変更）、書き戻しを行わずにRuntimeErrorを送出する。このとき`a`は`cmp`による変更後の状態のままである。`cmp`が送出したerrorはそのまま伝播し、`a`は`sort`開始時の状態のままである。

### 8.4 table

- 挿入順を保持するhash map。`len(t)`は現在のentry数（O(1)）。
- `t[k]`: 存在しなければ`nil`（—）。
- `t[k] = v`: 既存keyの更新は位置を変えない（—）。新規keyは末尾に追加（A?）。
- `t[k] = nil`: keyを削除する（—）。削除後に再挿入すると末尾に入る。
- **省略形（2.3）**: `{x, y}`は`{x: x, y: y}`（識別子だけのentryは同名の変数の値）。`{x, y: 2}`のように通常のentryと混ぜられる。内包表記と組み合わせることはできない。
- `t.name`は`t["name"]`と同じ。tableはメソッドを持たない。table操作は§15.1のprelude関数と`table` module（§15.6）で行う。
- table literal `{...}`は**A**（容量=entry数で1回割り当て）。
- `table.reserve(t, n)`（A?）を呼んだ後、その呼出し時点の`len(t)`を`L`として、新規keyの挿入回数が`n - L`以下である間は割り当てない。
