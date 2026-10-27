## 9. 関数・closure・呼出し

### 9.1 関数値

- 関数はfirst-class値。`func`宣言とlambdaは関数値を生成する（**A**、closure生成）。
- lambdaには2つの書き方がある（同じ意味）: `func(x): e` と、2.2のアロー関数 `x => e` / `(a, b = 1) => e` / `() => e`。本体は式1つで、その値を返す。アロー関数は`=>`の右側の式全体を本体とする（`x => y => x + y`は右結合）。
- module top-levelの`func`宣言の関数値はmodule初期化前に生成される（§14.5）。

### 9.2 引数

```sprint
func f(a, b = 10, ...rest):
    pass
```

- 引数は「必須引数」「default付き引数」「rest引数（最大1個、最後）」の順に並ぶ。default付き引数の後に必須引数を置くとコンパイルエラー。
- 呼出しの実引数は位置引数のみ（キーワード引数はない）。
- 実引数が必須引数の数より少なければTypeError（default付き引数はその分を補う）。rest引数がなく、実引数がパラメータ数より多ければTypeError。
- **default引数の評価点（正本）: default式は、呼出しのたびに、callee frameの中で、未指定のパラメータについてだけ、左から右へ、それより前のパラメータが束縛された後に評価する。** default式のスコープは関数本体の先頭と同じであり、それより前のパラメータ、closureで捕捉した変数、module束縛、builtinを参照できる。後続のパラメータの参照はコンパイルエラー`NameError`。default式内で発生したエラーのtraceはcallee frameを指す。
- default式がarray/table literalなら、評価のたびに新しいオブジェクトを割り当てる（A、literalが割り当て点）。
- rest引数`...rest`は、余剰実引数を格納した新しいarrayを**呼出しのたびに割り当てる**（A、余剰が0個でも空arrayを割り当てる）。この割り当て点は関数宣言の`...rest`である。
- 実引数の個数上限は255。spread展開後に255を超えたらTypeError。

### 9.3 spread呼出し

`f(a, ...xs)`は`xs`（arrayでなければTypeError）の要素を呼出し時点の順で位置引数として渡す。spread自体は割り当てない。

### 9.4 closureとcell

- 内側の関数から参照される局所変数（**captured変数**）はResolverが静的に判定する。
- captured変数は、その宣言（`let`/`const`/パラメータ/`for`変数/`catch`変数/パターン束縛）の実行時に**cell**を1つ割り当てる（A）。cellの割り当て点はその宣言である（`lint --alloc`が報告する）。captureされない変数はcellを使わない。
- closure生成（`func`式・宣言の評価）はclosureオブジェクトを1つ割り当てる（A）。cellは割り当て済みなので、closure生成時に追加の割り当てはない。
- captured変数への代入はそのcellを共有するすべてのclosureから観測できる。
- **`for`の変数は反復ごとに新しい束縛**である。captureされている場合は反復ごとに新しいcellを割り当てる。

### 9.5 呼出し可能な値

| callee | 動作 |
|---|---|
| function | 新しいframeで実行 |
| class | インスタンス生成（§10.3） |
| native関数 | host関数を呼ぶ（§20.5） |
| その他 | TypeError |

呼出しそのもの（frame生成、引数受け渡し、return）は割り当てをしない（A1）。frameはVM生成時に確保した領域を使う（A4）。

### 9.6 return

- `return`は値を1つ返す。省略時は`nil`。複数の値を返すにはarrayを使う。
- `return`は、それを囲むすべてのブロックの`defer`を内側から順に実行してから関数を抜ける（§12.4）。

### 9.7 末尾呼出し

末尾呼出し最適化はしない（MUST NOT）。traceと`defer`の観測結果が変わるためである。
