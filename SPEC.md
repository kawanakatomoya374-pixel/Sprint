# Sprint Language Specification 2.4
## 正本（Single Source of Truth）

> **本書はSprint言語の唯一の規範文書である。** v1.4 / v1.4.1 / v1.5 / v1.6 の各文書は本書によって全面的に置き換えられ、規範性を失う。旧版の本文は本書に収録しない。旧版からの変更点・矛盾の解消結果は非規範の付録Dにのみ記載する。
>
> 本書に記載のない挙動は「実装定義」ではなく**仕様の欠落**である。実装者は独自判断で補ってはならず、仕様の改訂を要求する。本書でMUSTとした事項を1つでも満たさない処理系はSprint 2.0処理系と名乗れない。

---

## 目次

本書は章ごとのファイルに分割されている（`docs/spec/`）。章番号・節番号（§）は分割前と同じで、他の章への参照はそのまま通用する。

- [0. 本書について](docs/spec/00-overview.md)
- [1. 設計原則](docs/spec/01-principles.md)
- [2. 処理系の構成とCLI](docs/spec/02-toolchain.md)
- [3. ソースと字句](docs/spec/03-lexical.md)
- [4. 構文](docs/spec/04-syntax.md)
- [5. 宣言・スコープ・名前解決・評価順](docs/spec/05-scopes.md)
- [6. 値と型](docs/spec/06-values.md)
- [7. 演算](docs/spec/07-operators.md)
- [8. 文字列・array・table](docs/spec/08-strings-arrays-tables.md)
- [9. 関数・closure・呼出し](docs/spec/09-functions.md)
- [10. class](docs/spec/10-classes.md)
- [11. 制御フロー](docs/spec/11-control-flow.md)
- [12. エラー・try・defer・panic・assert](docs/spec/12-errors.md)
- [13. coroutine](docs/spec/13-coroutines.md)
- [14. module・package](docs/spec/14-modules.md)
- [15. 標準ライブラリ](docs/spec/15-stdlib.md)
- [16. program image（`.spc`）形式](docs/spec/16-image-format.md)
- [17. bytecode・VM実行契約](docs/spec/17-bytecode-vm.md)
- [18. メモリ・GC・資源上限](docs/spec/18-memory-gc.md)
- [19. 決定性とcapability](docs/spec/19-determinism.md)
- [20. C埋め込みAPI](docs/spec/20-c-api.md)
- [21. C実装要件](docs/spec/21-c-requirements.md)
- [22. 診断・エラー出力・コンフォーマンス](docs/spec/22-diagnostics.md)
- [23. REPL・fmt・lint・観測ツール](docs/spec/23-tools.md)
- [付録A 割り当て点一覧（正本）](docs/spec/appendix-a-allocation.md)
- [付録B ユーザーコード実行点と制御移動点（正本）](docs/spec/appendix-b-user-code.md)
- [付録C サンプルと必須テスト例（v1.x例の書き換え）](docs/spec/appendix-c-examples.md)
- [付録D v1.x系からの変更と矛盾の解消（非規範）](docs/spec/appendix-d-changes.md)

各章の先頭見出しは `## 章番号. 題名`、節は `### 章.節` のまま。全文を1ファイルで読みたいときは `cat docs/spec/*.md` で結合できる。
