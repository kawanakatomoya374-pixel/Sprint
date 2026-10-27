## 10. class

### 10.1 宣言

```sprint
class Point:
    let x = 0
    let y = 0

    func init(self, x, y):
        self.x = x
        self.y = y

    func length2(self):
        return self.x * self.x + self.y * self.y

class Point3 extends Point:
    let z = 0

    override func init(self, x, y, z):
        super(x, y)
        self.z = z

    override func length2(self):
        return super.length2() + self.z * self.z
```

- 単一継承。`extends`の対象は、**コンパイル時に**同一moduleのtop-level `class`宣言、またはimportしたmoduleがexportする`class`に解決できなければならない（それ以外はコンパイルエラー`NameError`）。2.4から、別moduleのclassを継承する場合の親のフィールド初期化式は、親を宣言したmoduleのscopeで評価される（そのclassがexportされると、コンパイラが初期化用の隠し関数を公開する）。
- class bodyに書けるのは`let`フィールド、メソッド（`func`）、`pass`だけ。
- メソッドの第1パラメータは`self`という名前でなければならない（コンパイルエラー`ParseError`）。lambdaや通常関数の`self`は普通の名前である。
- フィールドとメソッドの名前空間は共通である。親子を通じて同じ名前のフィールドとメソッドが共存するとコンパイルエラー。同名フィールドの再宣言（親子間を含む）もコンパイルエラー。
- `override`: 親classの連鎖に同名メソッドがある場合は`override`必須、ない場合は`override`禁止。違反はコンパイルエラー`OverrideError`。`init`にも同じ規則を適用する。
- class宣言の評価（class値の生成）はclass定義時に1回だけ行う（A）。

### 10.2 インスタンスのレイアウト

- インスタンスは**固定スロット**を持つ。スロットは親classのフィールド（宣言順）に続けて自classのフィールド（宣言順）。
- 宣言されていないフィールドへの読み書きは`NameError`。インスタンスに動的にフィールドを追加することはできない。
- フィールドの読み書きは割り当てをしない。

### 10.3 インスタンス生成

`C(args...)`は次の順で実行する。

1. インスタンスを1つ割り当てる（A）。全スロットを`nil`にする。
2. 最上位の祖先classから`C`まで順に、各classのフィールド初期化式を宣言順に評価してスロットに格納する。初期化式はmodule scopeで評価され、`self`を参照できない。初期化式のないフィールドは`nil`のまま。
3. `C`から祖先へ向かって最初に見つかった`init`を、`self`と`args`で呼ぶ。見つからなければ、`args`が空でない場合TypeError。
4. インスタンスを返す（`init`の戻り値は使わない。`init`内で値付き`return`はコンパイルエラー）。

（参照実装の注）全フィールド初期化式が定数で`init`が既定のclassは、上記と観測的に同一の結果を、`init`のframeを作らずに構築する高速パスで得る。それ以外の形は通常経路に戻る。

### 10.4 メンバアクセス

| 構文 | instance `o` | class `C` | table `t` | module `m` | string/array |
|---|---|---|---|---|---|
| `o.name` 読み | フィールド値。なければメソッド関数そのもの（束縛しない）。どちらもなければNameError | メソッド関数。なければNameError | `t["name"]` | exportの値。なければNameError | TypeError |
| `o.name = v` | フィールドへ格納。メソッド名ならTypeError、未宣言ならNameError | TypeError | `t["name"] = v` | ConstError（静的に判明すればコンパイルエラー） | TypeError |
| `o.name(args)` | フィールドなら値を`args`で呼ぶ。メソッドなら`self = o`を先頭に加えて呼ぶ | メソッド関数を`args`で呼ぶ（`self`は付けない） | `t["name"](args)` | export関数を呼ぶ | 組込みメソッド |

- **メソッド参照`o.m`はbound methodを生成しない**（割り当てなし）。`o.m`は関数そのものを返すので、後で呼ぶときは`f(o, args)`と`self`を明示する。
- `self`を自動で渡すのは`o.name(args)`という**呼出し構文**のときだけである。

### 10.5 super

- `super(args)`: `init`メソッド内でのみ使える（それ以外はコンパイルエラー）。宣言中のclassに`extends`がなければコンパイルエラー。親classから祖先へ向かって最初に見つかった`init`を`self`と`args`で呼ぶ。見つからない場合、`args`が空なら何もしない、空でなければTypeError。1回の`init`実行中に2回目の`super(...)`を実行するとRuntimeError。
- `super.m(args)`: メソッド内でのみ使える。**そのメソッドが宣言されたclass**の親から祖先へ`m`を検索し、`self`を付けて呼ぶ。見つからなければNameError（親がコンパイル時に既知のため、`m`が存在しないことが静的に判明する場合はコンパイルエラー）。
- `super`を値として読むこと（`let s = super`）は文法上できない。

### 10.6 class関連のprelude

- `classof(v)`: instanceならclass、それ以外は`nil`。
- `class_name(c)`: classの名前（string定数、—）。
- `is_instance(v, C)`: `v`が`C`またはその子孫のインスタンスならtrue。
