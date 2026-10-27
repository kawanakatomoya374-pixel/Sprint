## 6. 値と型

### 6.1 型一覧（正本）

`type(v)`は次のいずれかの文字列を返す。これ以外の型は存在しない。

| type | 種別 | ヒープ | 等値 | table key |
|---|---|---|---|---|
| `nil` | 即値 | なし | 値 | 不可（TypeError） |
| `bool` | 即値 | なし | 値 | 可 |
| `int` | 即値 | なし | 数値 | 可 |
| `float` | 即値 | なし | 数値 | 可（NaNはValueError） |
| `string` | 参照・不変 | あり | バイト列 | 可 |
| `array` | 参照・可変 | あり | identity | 可（identity） |
| `table` | 参照・可変 | あり | identity | 可（identity） |
| `function` | 参照・不変 | あり | identity | 可 |
| `class` | 参照・不変 | あり | identity | 可 |
| `instance` | 参照・可変 | あり | identity | 可 |
| `module` | 参照・不変 | あり | identity | 可 |
| `iterator` | 参照・内部状態 | あり | identity | 可 |
| `coroutine` | 参照・内部状態 | あり | identity | 可 |
| `error` | 参照・不変 | あり | identity | 可 |
| `native` | 参照（host定義） | あり | identity | 可 |

v1.xの`promise`型は削除した。`undefined`, `void`, `object`, `number`という型はない。戻り値のない関数は`nil`を返す。

### 6.2 値表現（MUST）

VMの値は16バイトのtagged unionとする。これはC API（§20.2）の公開ABIでもある。

```c
typedef struct SpValue {
    uint8_t  type;      /* SpType */
    uint8_t  _pad[7];   /* 常に0 */
    union { int64_t i; double f; int b; struct SpObj *o; } as;
} SpValue;
```

- `nil`, `bool`, `int`, `float`はヒープを使わない（A2）。
- 参照型は`SpObj*`を持つ。オブジェクトは移動しない（non-moving GC、§18.1）。
- NaN-boxingは使わない（`int`が64bit全域を持つため）。

### 6.3 オブジェクトID

string以外の値型のヒープオブジェクト（array, table, function, class, instance, module, iterator, coroutine, error, native）は、生成時にVM内で単調増加する64bit整数の**オブジェクトID**（1始まり）を受け取る。IDは再利用しない。stringとVM内部オブジェクト（cell、作業領域など）はIDを消費しない（したがって文字列のinterning有無はIDに影響しない）。

- `to_string`/`print`での参照型表示、identity hashに使う。
- 同一プログラム・同一入力・同一limitsでは、IDの割り当て順は決定的である（GC方式に依存しない）。
- ロード時に生成されるmodule値もIDを持つ。生成順は§16.4のとおり。

### 6.4 truthiness

偽は`false`と`nil`だけである。`0`, `0.0`, `""`, `[]`, `{}`を含む他のすべての値は真。

### 6.5 文字列化（`to_string`と`print`）

`to_string(v)`の結果は次のとおり固定する。ユーザー定義の文字列化は存在しない（H1）。

| 値 | 結果 |
|---|---|
| `nil` / `true` / `false` | `nil` / `true` / `false` |
| int | 10進。負数は`-`付き |
| float | §6.6 |
| string | その文字列自身（同じオブジェクトを返し、割り当てない） |
| array | `[` + 各要素のrepr を`, `で連結 + `]` |
| table | `{` + `repr(k): repr(v)` を`, `で連結 + `}`（挿入順） |
| function | `<function NAME #ID>`（無名は`<function #ID>`） |
| class | `<class NAME>` |
| instance | `<NAME #ID>`（NAMEはclass名） |
| module | `<module DOTTED.NAME>` |
| iterator | `<iterator KIND #ID>` |
| coroutine | `<coroutine #ID>` |
| error | `<KIND: MESSAGE>` |
| native | `<native CLASSNAME #ID>` |

**repr**: 文字列は`"`で囲み、`"` `\` を`\"` `\\`に、U+0000–U+001Fと U+007F を`\n` `\r` `\t` または`\xHH`に置換する。その他の値は`to_string`と同じ。

**入れ子の深さ**: array/tableの表示は深さ8まで展開し、それより深い要素は`[...]`または`{...}`と表示する。循環構造もこの規則で必ず停止する（visited集合を使わないため割り当てが不要）。

### 6.6 floatの文字列化

1. NaNは`nan`、正の無限大は`inf`、負の無限大は`-inf`。
2. それ以外は、`p = 1, 2, ..., 17`の順に、C99の`"%.{p}g"`（Cロケール、正しく丸める）で整形し、strtodで読み戻して元の値とビット一致する最初の`p`の結果を採る。
3. 規則2の結果が指数形式（`e`を含む）で、その10進指数が`0`以上`16`未満なら、指数形式を使わず、値の整数部を全桁の10進数（`"%.0f"`）で書く。`%.{p}g`は10進指数が精度`p`以上のとき指数形式を選ぶため（`100.0`は`p = 1`で`1e+02`になる）、この規則で`100.0`・`1500000.0`のような整数値を読める形に保つ。指数が負、または`16`以上のものは指数形式のまま（`1e20`→`1e+20`、`1.5e-7`→`1.5e-07`）。
4. 結果に`.`、`e`、`n`（nan/inf）が含まれなければ末尾に`.0`を付ける。`-0.0`は`-0.0`。

例: `1.0`→`1.0`、`0.1`→`0.1`、`1e20`→`1e+20`、`1.5e-7`→`1.5e-07`、`100.0`→`100.0`、`1e15`→`1000000000000000.0`、`1e16`→`1e+16`、`2.5 * 4`→`10.0`。
