## 付録C サンプルと必須テスト例（v1.x例の書き換え）

### C.1 旧テストの書き換え

```sprint
import math
import table

# NaN比較（旧: 未定義の識別子 NaN を使っていた）
let nan = math.nan
assert (nan == nan) == false
assert (nan != nan) == true
assert (nan < 1) == false
assert (nan > 1) == false

# 結合性
assert 2 ** 3 ** 2 == 512
assert -2 ** 2 == -4
assert "a" .. "b" .. "c" == "abc"

# 数値literal
assert 0xFF == 255 and 0b1010 == 10 and 0o77 == 63 and 1_000_000 == 1000000

# int/floatの正確な比較
assert 9007199254740993 != 9007199254740992.0
assert 1 == 1.0

# table挿入順と削除・再挿入
let t = {a: 1, b: 2, c: 3}
delete(t, "a")
t.a = 4
assert deep_equal(table.keys(t), ["b", "c", "a"])

# 等値はidentity
assert [1, 2] != [1, 2]
assert deep_equal([1, 2], [1, 2])
```

旧テストのうち、コンパイルエラーになるべきもの（`eval`を使っていた比較連鎖、`const`再代入、`global`）は§22.4形式で書く。

```yaml
id: core.static.const-assign-001
source: |
  const X = 10
  X = 20
expect:
  exit: 12
  error: {kind: ConstError, code: 9, file: main.sp, line: 2, column: 3}
---
id: core.syntax.compare-chain-001
source: |
  let ok = 1 < 2 < 3
expect:
  exit: 12
  error: {kind: ParseError, code: 12, file: main.sp, line: 1, column: 16}
```

### C.2 panicとdefer（旧: `defer assert true`は文を遅延していたため無効）

```sprint
func cleanup(name):
    print("cleanup", name)

func work():
    defer cleanup("outer")
    if true:
        defer cleanup("inner")
        panic "fatal"
    print("unreachable")

work()
```

期待: stdout `cleanup inner\ncleanup outer\n`、終了コード101。

### C.3 deferとerrorの優先

```sprint
func fail_in_defer():
    throw error("CleanupError", "close failed")

func f():
    defer fail_in_defer()
    throw error("ValueError", "primary")

try:
    f()
catch e:
    print(e.kind, e.message)
    print(e.suppressed.kind)
```

期待stdout: `ValueError primary\nCleanupError\n`。

### C.4 default引数の評価点

```sprint
let calls = 0

func next_id():
    calls += 1
    return calls

func make(a, b = a * 2, c = next_id()):
    return [a, b, c]

assert deep_equal(make(1), [1, 2, 1])
assert deep_equal(make(1, 5), [1, 5, 2])
assert deep_equal(make(1, 5, 9), [1, 5, 9])    # c のdefaultは評価されない
assert calls == 2
```

### C.5 classとメソッド参照

```sprint
class Counter:
    let n = 0

    func inc(self, by = 1):
        self.n += by
        return self

let c = Counter()
c.inc().inc(5)
assert c.n == 6

let f = c.inc          # bound methodは作らない
f(c, 10)               # selfを明示して呼ぶ
assert c.n == 16
```

### C.6 単語数え（実用例）

```sprint
import io
import table

let counts = {}
while true:
    let line = io.read_line()
    if line == nil:
        break
    for word in line.split(" "):
        if word != "":
            counts[word] = table.get(counts, word, 0) + 1

let words = table.keys(counts)
words.sort(func(a, b): counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
for i, w in words:
    if i >= 10:
        break
    print(w, counts[w])
```
