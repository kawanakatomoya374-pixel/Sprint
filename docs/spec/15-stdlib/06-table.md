### 15.6 table

| 関数 | 割当 | 仕様 |
|---|---|---|
| `table.keys(t)` / `table.values(t)` | A | 挿入順のarray |
| `table.items(t)` | A | `[[k, v], ...]` |
| `table.copy(t)` | A | 浅いコピー（順序維持） |
| `table.merge(dst, src)` | A? | `src`の各entryを挿入順に`dst`へ代入。`dst`を返す |
| `table.clear(t)` | — | 全entryを削除。容量は保持 |
| `table.reserve(t, n)` | A? | §8.4 |
| `table.get(t, k, default)` | — | 存在すれば値、なければ`default` |
| `table.get_required(t, k)` | — | なければKeyError |
