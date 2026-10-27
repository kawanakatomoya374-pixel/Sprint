### 15.2 math

| 名前 | 割当 | 仕様 |
|---|---|---|
| `pi`, `e`, `inf`, `nan` | — | float定数 |
| `int_max`, `int_min` | — | int定数 |
| `abs(x)` | — | int/float。`abs(int_min)`はArithmeticError |
| `min(a, ...rest)` / `max(a, ...rest)` | A | 1個以上。比較は`<`の規則。NaNを含めばNaN。（rest引数のため呼出しごとにarrayを割り当てる。2値専用の`min2`/`max2`は割り当てない） |
| `min2(a, b)` / `max2(a, b)` | — | 2値版 |
| `clamp(x, lo, hi)` | — | `lo > hi`はValueError |
| `floor(x)` / `ceil(x)` / `trunc(x)` | — | intを返す。NaN/inf/範囲外はValueError。intはそのまま |
| `round(x)` | — | 最近接偶数への丸め（banker's rounding）でint |
| `sqrt(x)` | — | float。`x < 0`はValueError |
| `exp`, `log(x, base = nil)`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2(y, x)` | — | C99 libmの結果。`log`の`x <= 0`はValueError |
| `is_nan(x)` / `is_inf(x)` / `is_finite(x)` | — | bool |
| `is_close(a, b, rel_tol = 1e-9, abs_tol = 0.0)` | — | `abs(a-b) <= max(rel_tol * max(abs(a), abs(b)), abs_tol)` |
