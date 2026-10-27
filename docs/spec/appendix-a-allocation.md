## 付録A 割り当て点一覧（正本）

実行中のヒープ割り当ては、ここに列挙した箇所でだけ起きる（§1.3）。

### A.1 必ず割り当てる（A）

| 構文・操作 | 内容 |
|---|---|
| array literal `[...]` | array 1個 |
| table literal `{...}` | table 1個 |
| `func`宣言・lambdaの評価 | closure 1個 |
| captured変数の宣言（let/const/パラメータ/for変数/catch変数/パターン束縛） | cell 1個 |
| class宣言の評価 | class 1個 |
| classの呼出し`C(...)` | instance 1個（+ フィールド初期化式・`init`内の割り当て点） |
| rest引数を持つ関数の呼出し | rest array 1個（宣言の`...rest`が割り当て点） |
| `..`（CONCAT） | string 1個 |
| `range(...)`（`for`ヘッダ以外）、`s.codepoints()` | iterator 1個 |
| `a.map(f)` / `a.filter(f)` | 結果array 1個（成長時に再割り当て）＋`f`内の割り当て点 |
| 割当Aのstdlib関数・メソッド | 各表（§8、§15） |
| `SP_NATIVE_ALLOCATES`付きnative関数の呼出し | host定義 |
| f-string `f"..."` | 結果string 1個（式の`to_string`変換の割り当て点を含む） |
| 分割代入`let [a, ...r] = v` | `...r`がある場合のrest array 1個 |
| スライス`a[i:j]` | `.slice()`の結果1個 |
| `gfx.canvas(w, h)` | native object 1個（ピクセル領域を含む） |
| 内包表記`[e for ...]` / `{k: v for ...}` | array / table 1個（§11.5。要素の追加は`append`・挿入と同じA?） |
| アロー関数`x => e` | closure 1個（`func`・lambdaと同じ） |
| パイプ`x \|> f` | なし（通常の呼出しと同じ。`f`が割り当てる点のみ） |

### A.2 条件付きで割り当てる（A?）

| 操作 | 条件 |
|---|---|
| `x[k] = v`, `x.name = v` | `x`がtableで、`k`が新規key、かつ容量不足 |
| `a.append` / `extend` / `insert` / `reserve`、`table.merge` / `reserve` | 容量不足 |
| `to_string(v)` | `v`がstringでない |
| `s.trim*` / `upper` / `lower` / `replace` | 結果が`s`と異なる |
| `for`による`allocates = 1`のiteratorの反復 | iteratorの定義による |

### A.3 失敗経路（A5）

VMが演算失敗を検出したときのerrorオブジェクト（と`data` table）。

### A.4 実行前（§1.3の対象外）

image/sourceのロード時の文字列定数・module値、`sys.args`、VM生成時の一括確保（§18.3）。

### A.5 割り当てないもの（抜粋）

（参照実装の注）class生成の高速パスでは、コンストラクタ（`init`の暗黙の既定または定数初期化のみ）はrest配列を割り当てず、コンストラクタframeはtraceに現れない。観測可能な結果は変わらない。

関数呼出し・return、算術・比較・等値・ビット演算・`not`・`and`/`or`、local/upval/module変数の読み書き、既存要素の添字読み書き、メンバ読み書き（instanceのフィールド、tableの既存key）、メソッド参照、`len`、`type`、`print`、`io.write`、`has`、`delete`、`deep_equal`、array/tableの`for`、rangeの`for`、`match`、`defer`の登録と実行、`try`/`catch`、`throw`、`yield`、`coroutine.resume`、errorフィールドの読み出し、GC。
