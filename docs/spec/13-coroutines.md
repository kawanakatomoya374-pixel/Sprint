## 13. coroutine

Sprintの非同期・generatorの手段は**stackful coroutine**だけである。`async`/`await`/promise/event loopはない。

### 13.1 API（`coroutine` module）

| 関数 | 割当 | 仕様 |
|---|---|---|
| `coroutine.create(f, stack_slots = 4096)` | A | 関数`f`を本体とするcoroutineを`suspended`状態で生成する。stackを**生成時に一括確保**する（§13.3）。`stack_slots`は64以上`max_operand_stack`以下のint |
| `coroutine.resume(co, value = nil)` | — | 下記 |
| `coroutine.status(co)` | — | `"suspended"` / `"running"` / `"normal"` / `"dead"` |
| `coroutine.close(co)` | — | `suspended`なら、そのcoroutine内の全frameのdeferを内側から実行して`dead`にする。`dead`なら何もしない。`running`/`normal`ならRuntimeError |
| `coroutine.current()` | — | 実行中のcoroutine。mainなら`nil` |

### 13.2 意味

- `resume(co, v)`:
  - `co`が`suspended`でなければRuntimeError。
  - 初回は`f()`を引数なしで開始する（`v`は捨てる）。2回目以降は、中断している`yield`式の値が`v`になる。
  - `co`の中で`yield x`が実行されると、`co`は`suspended`になり、`resume`は`x`を返す。
  - `f`がreturnすると`co`は`dead`になり、`resume`は戻り値を返す。
  - `co`の中でcatchされないerrorが起きると、`co`の全frameのdeferを実行して`dead`になり、そのerror（同じオブジェクト）が`resume`の呼出し位置から送出される。
- `yield x`（`x`省略時`nil`）: coroutine外（main）で実行するとRuntimeError。`yield`はnative関数の呼出しをまたげない（`a.sort(cmp)`の`cmp`内などで`yield`するとRuntimeError）。
- 状態: resume中のcoroutineは`running`、そこから別のcoroutineをresumeすると元は`normal`。
- 放置された`suspended` coroutineがGCで回収されても、そのdeferは実行**されない**（GCはユーザーコードを呼ばない、H1）。確実にcleanupするには`coroutine.close`を呼ぶ。

### 13.3 stackの確保

`coroutine.create`は1つのメモリブロックに次を確保する。

- 値スロット: `stack_slots`個
- frame: `max(16, stack_slots / 8)`個、try handler: `max(16, stack_slots / 16)`個
- defer record: `max(8, stack_slots / 16)`個、defer値スロット: `max(32, stack_slots / 4)`個

実行中にこれらは伸長しない。超過はMemoryError（致命的）。

### 13.4 generatorの書き方（旧`__next`例の書き換え）

```sprint
import coroutine

func counter(limit):
    return coroutine.create(func(): count_up(limit))

func count_up(limit):
    let i = 1
    while i <= limit:
        yield i
        i += 1

let result = []
for x in counter(3):
    result.append(x)
assert deep_equal(result, [1, 2, 3])
```

（`yield`は式ではなく文の一種なので、lambda本体に直接書けない。上のように通常の関数に書く。）
