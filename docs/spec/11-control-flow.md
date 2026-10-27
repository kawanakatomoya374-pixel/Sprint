## 11. 制御フロー

### 11.1 if / while

- `if`/`elif`/`while`の条件はtruthinessで判定する。
- `else`は同じインデントの直前の`if`/`elif`に結びつく。
- **`if let`・`while let`（2.3）**: `if let x = e:`は`e`を1回評価し、`nil`でなければ`x`を束縛して本体を実行する。`nil`のときは続く`elif`/`else`へ進む（`false`・`0`は`nil`ではないので本体を実行する）。`x`は本体の中だけで見える（`const`ではなく`let`と同じ）。`while let x = e:`は繰り返しのたびに`e`を評価し、`nil`になったらループを終える（`break`・`continue`・ラベルは通常の`while`と同じ）。`elif let`はない。展開は`{ let $l = e; if $l != nil: { let x = $l; 本体 } ... }`と`while true: { let $l = e; if $l == nil: break; let x = $l; 本体 }`。

### 11.2 for（反復プロトコル）

**分割代入のループ変数（2.3）**: `for [a, b] in xs:`と`for {x, y: z} in xs:`は、要素を隠れたループ変数で受け、本体の先頭で§5.2.1と同じ分割代入の宣言を行う（失敗の規則も同じ）。`for x in E if C:`のフィルタ`C`は束縛された名前を参照できる。内包表記の`for`節（§11.5）でも同じ形が書ける。`for a, b in E`（2変数）は従来どおり添字/keyと値である。

2.2: `for x in E if C:`は`for x in E:`の本体を`if C:`で包んだ糖衣である（`continue`・ラベルの意味は変わらない）。`E`の位置に`a if c else b`の条件式を**フィルタなしで**書くことも従来どおり可能で、同じ行に`else`があれば条件式として解釈する。

`for x in E:`および`for a, b in E:`は次のように実行する。

1. `E`を1回だけ評価する。
2. 評価結果の型で反復方法を決める（下表）。それ以外の型はTypeError。
3. 各反復で、変数を新しく束縛して本体を実行する。

| 対象 | 1変数 | 2変数 | 反復中の変更 | 割当 |
|---|---|---|---|---|
| array | 要素 | index, 要素 | 各反復の前に`i < len(a)`を再評価する（追加すれば延び、削除すれば縮む） | — |
| table | key | key, value | 既存keyの値の更新は可。keyの追加・削除をした場合、次の反復の開始時にRuntimeError | — |
| iterator | 値 | 2値 | iteratorごとの規定 | iteratorごと（§20.6の`allocates`） |

| coroutine | yieldされた値 | TypeError | — | — |
| string | TypeError（`s.codepoints()`を使う） | | | |

iteratorは1ステップあたり1値または2値を返す（arity、§20.6）。`for`の変数の数とarityが違えばTypeError（最初のステップの前に検査する）。

- **range lowering（MUST）**: `for i in range(...)`で、`range`がbuiltinの`range`に解決される場合（shadowされていない場合）、Compilerはiteratorを生成せず、専用の数え上げループ（`RANGE_PREP`/`RANGE_NEXT`）にloweringしなければならない。このときrangeは割り当てをしない。`range`を`for`ヘッダ以外で呼ぶとiteratorを割り当てる（A）。
- range引数はintのみ（floatはTypeError）。`step == 0`はValueError。`range(stop)`, `range(start, stop)`, `range(start, stop, step)`。`stop`を含まない。内部計算はoverflowしない（最後の値の次を計算せずに終了判定する）。
- iteratorの終了後は、同じiteratorを再び`for`に渡しても即座に終了する。
- coroutineの反復: 各ステップで、状態が`dead`なら終了。そうでなければ`coroutine.resume(co, nil)`相当を行い、yieldされたらその値を変数に束縛し、returnしたら（戻り値は捨てて）終了する。coroutine内のエラーは`for`の位置へ伝播する。

### 11.3 ラベル・break・continue

- `name: while ...` / `name: for ...` でループにラベルを付ける。
- `break` / `continue`は最内ループ、`break name` / `continue name`はそのラベルのループを対象にする。
- 対象ループまでの間にあるすべてのブロックの`defer`を内側から順に実行してから移動する。
- ラベルの重複（同一関数内）、存在しないラベル、関数境界の越境はコンパイルエラー。

### 11.4 match

```sprint
match value:
    case 0:
        print("zero")
    case [x, y] if x == y:
        print("pair of", x)
    case {kind: "circle", r: r}:
        print("circle", r)
    case _:
        print("other")
```

1. subjectを1回だけ評価する。
2. caseを上から順に試す。パターンが一致したら束縛を行い、ガードがあれば評価する。ガードが偽なら次のcaseへ進む。
3. 最初に（ガードを含め）成功したcaseの本体だけを実行する。fallthroughはない。
4. どのcaseにも一致しなければ`MatchError`。

| パターン | 一致条件 | 束縛 |
|---|---|---|
| リテラル | `subject == literal`（§7.6の等値） | なし |
| `_` | 常に一致 | なし |
| 識別子`x` | 常に一致 | case本体スコープに新しい変数`x` |
| `[p1, ..., pn]` | arrayであり`len == n`で、各要素が左から順に一致 | 各サブパターン |
| `{k1: p1, ...}` | tableでkey`ki`が存在する、またはinstanceでフィールド`ki`が宣言されている。各値が左から順に一致。余分なkey/フィールドは無視 | 各サブパターン |

- 識別子パターンは常に新しい変数を束縛する。既存変数の値との比較はガードで書く（`case x if x == limit:`）。
- **match式と`=>`の腕（2.2）**: `case p => e`は`case p:`＋本体`e`（式文）の糖衣。`match`を値として使う形 `let v = match x:` ＋ インデントされた`case p => e`の列 は、どの腕にも`=>`を要し、一致した腕の`e`が値になる（`$m = e`を代入する展開）。どの腕にも一致しなければ文の`match`と同じくMatchError。match式は括弧・角括弧の外（文の右辺・`return`の後）にだけ書ける（括弧の中では改行とインデントが無視されるため）。
- パターンの照合は割り当てをしない（captureされる束縛のcellを除く、§9.4）。
- 照合中にエラーは起きない（型が合わなければ単に不一致）。

### 11.5 内包表記（2.2）

- `[e for x in xs if c]`は新しいarrayを作り、`xs`の各要素について（`if`が真なら）`e`の値を追加する。`{k: v for x in xs}`は新しいtableを作り`t[k] = v`で挿入する。`for`節は`for x in E`または`for a, b in E`（§11.2と同じ反復プロトコル）で、`for`・`if`節は何個でも、左から右へ入れ子になる。
- 展開: `{ let $c = []; for x in xs: if c: $c.append(e); $c }`（`$c`は衝突しない隠れた名前）。ループ変数は内包表記の中だけで見える。`e`は節の変数・外側の変数を参照できる。
- tableの内包表記では**キーは式**であり、裸の名前は変数として評価する（リテラル`{k: 1}`の`k`は文字列キー）。文字列キーは`{"k": v for ...}`または`(…)`で書く。
- 割り当て（付録A）: array/tableを1つ割り当て（A）、要素の追加は`append`・table挿入と同じ条件で容量を増やす（A?）。ユーザーコードが実行される点は`xs`の反復と式`e`・条件`c`のみ（付録B）。
