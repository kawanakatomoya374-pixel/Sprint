### 15.0 共通規則

- 各関数の引数型違反はTypeError、値域違反はValueError、capability不足はPermissionErrorとする（表で別に定めた場合を除く）。
- 各表の「割当」列は§8.1の記号。
- stdlib関数は、表で明示した関数引数（`sort`の`cmp`など）以外のユーザーコードを呼ばない。
- builtin moduleは`import`しなければ使えない（preludeを除く）。`--no-stdlib`ではprelude以外のbuiltin module をimportするとImportError（実行前）。
