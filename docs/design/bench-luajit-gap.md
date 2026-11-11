# LuaJIT 比較ベンチ(2026-11、追加 25 本)

`ONLY="..." NOJIT=0 sh tools/bench/cmp.sh` で測定(best of 3、jit/lj < 1 なら Sprint が速い)。
新規 `.sp` と `lua/*.lua` はアルゴリズム同一で、出力が一致することを確認済み(Lua は 1 始まりの慣用形で記述)。

| bench | 内容 | jit(s) | luajit(s) | jit/lj |
|---|---|---|---|---|
| nsievebit | ビット配列の篩 | 1.84 | 0.07 | 25.3 |
| bitops | xorshift + popcount + CRC32 | 1.24 | 0.14 | 8.6 |
| spectral | spectral-norm(整数→float 混在) | 0.87 | 0.16 | 5.5 |
| knuc | 部分文字列を key にした表の集計 | 0.29 | 0.06 | 4.5 |
| base64 | 文字列→バイト→ビット操作 | 0.64 | 0.16 | 3.9 |
| heapsort | float 配列のヒープソート | 0.71 | 0.19 | 3.7 |
| fannkuch | 配列の置換 | 1.86 | 0.51 | 3.7 |
| hashint | 整数キーの表 | 0.30 | 0.09 | 3.5 |
| fft | float 配列、ビット操作 | 0.47 | 0.14 | 3.5 |
| poly | 3 クラスの多態メソッド呼び出し | 0.21 | 0.07 | 2.9 |
| mathfn | math.sin/cos/sqrt/log/exp | 0.21 | 0.08 | 2.7 |
| coro | coroutine の generator 連鎖 | 0.27 | 0.11 | 2.4 |
| mandel | float 反復 | 0.52 | 0.26 | 2.1 |
| serialize | 再帰的な入れ子の直列化 | 0.12 | 0.08 | 1.5 |
| ray | クラスの Vec 演算 | 0.54 | 0.40 | 1.4 |
| bintrees, strfind, bfs, msort, life | | | | 1.0〜1.2 |
| lcs, bignum, montecarlo, queens | | | | 0.7〜0.9(勝ち) |

## 遅い原因(SPRINT_TRACE_JIT_DEBUG=1 の拒否理由)

1. **ビット演算 `& | ^ ~ << >>` が両 JIT で未対応**("unsupported bytecode")。nsievebit・bitops・base64・fft が該当。
2. **int と float の混在算術**("mixed or non-numeric operands")。spectral・mandel・heapsort。
3. **ネイティブ関数呼び出し**("call did not enter a function"): `len`、`a.append`、`s.slice`、`math.*`。knuc・mathfn・fill 系。
4. **表(table)の操作と `for k, v in t`**: hashint・knuc。
5. 外側ループの後方ジャンプ・"no sinkable object" で内側ループの連鎖が切れる(fannkuch・heapsort)。
6. coroutine の `yield` は未対応(coro)。
