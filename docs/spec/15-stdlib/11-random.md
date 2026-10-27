### 15.11 random

| 関数 | 割当 | 仕様 |
|---|---|---|
| `random.seed(n)` | — | intで状態を初期化する。capability不要 |
| `random.int(lo, hi)` | — | `lo <= x <= hi`の一様整数。`lo > hi`はValueError |
| `random.float()` | — | `[0, 1)` |
| `random.shuffle(arr)` | — | Fisher–Yates（`i = len-1`から`1`へ、`j = random.int(0, i)`） |
| `random.choice(arr)` | — | 空ならIndexError |

- アルゴリズム（MUST、実装間で結果を一致させる）: 状態はxoshiro256\*\*。`seed(n)`はSplitMix64を`n`（2の補数でu64とみなす）から4回回して状態を埋める。
- `random.float()`: `(next() >> 11) * 2^-53`。
- `random.int(lo, hi)`: `range = hi - lo`をu64で計算し、`range == 2^64-1`なら`next()`をそのまま使う。それ以外は`limit = 2^64 - (2^64 mod (range+1))`とし、`x = next()`を`x < limit`になるまで引き直し、`lo + x mod (range+1)`。
- seedされていない状態で`random.int`/`float`/`shuffle`/`choice`を呼んだ場合: capability `random`があり決定性モードでなければOSのエントロピーでseedする。そうでなければPermissionError。
