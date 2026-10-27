## 付録D v1.x系からの変更と矛盾の解消（非規範）

### D.1 改善提案への対応

| # | 提案 | 対応 |
|---|---|---|
| 1 | 最新版を1ファイルに分離 | 本書が唯一の正本。v1.4〜v1.6の本文は収録しない（冒頭、§0） |
| 2 | メタメソッド方針を最終決定 | `__index`/`__next`/`__iter`/`__gc`/`setmetatable`・演算子オーバーロードを**削除で確定**（§1.2 H1、§1.4）。旧`__next`サンプルはcoroutine版に書き換え（§13.4）、旧テストも書き換え（付録C） |
| 3 | native iterator ABIの明記 | §20.6に`SpIterClass`のABIを正本として規定し、VM側の契約を§17.6（FOR_NEXT）に記載（旧§12 VM実行契約→本書§17、旧§14 host API→本書§20） |
| 4 | エラーメッセージのテスト可能性 | コンフォーマンスはkind・code・位置・終了コード・stdoutのみ比較し、messageは比較しない（§22.4）。位置の規則を§22.3で固定 |
| 5 | default引数の評価点 | 「callee frameで、呼出しごとに、未指定分だけ、左から右へ」を1文で固定（§9.2）。bytecode上の実現も規定（§17.3 `default_pcs`） |
| 6 | MAY機能とbytecode版の規則 | §16.6（旧§11相当）に追加。MAY機能はfeature bitと0xE0–0xEFを使い、追加はminor、必須化・意味変更はmajor |
| 7 | opcode表の正規化 | §17.4を唯一の正本と宣言。v1.4（0x09 DUP / 0x0A SWAP）・v1.6（0x09 POP / 0x0A DUP）の表は無効。SWAPは不要（§17.5のloweringで使わない）なので存在しない |

### D.2 矛盾・欠落の解消一覧

| 領域 | 旧版の状態 | 本書の決定 |
|---|---|---|
| ブロック | v1.4は`{}`、v1.4.1以降はインデント | インデントのみ |
| 添字の起点 | v1.4は1始まり、v1.4.1以降は0始まり | 0始まり |
| 文字列の`len`・添字 | code point単位（O(n)） | バイト単位（O(1)）。`s[i]`はバイト値int。code pointは明示メソッド |
| tableの順序 | v1.4「`keys()`は順序不定」「再挿入は実装依存」 | 挿入順で固定、再挿入は末尾 |
| `+`と文字列 | v1.4は暗黙変換で連結、v1.5はTypeError | TypeError。連結は`..`のみ |
| `string * int` | v1.5で許可 | 削除（`s.repeat(n)`）。演算子が割り当てを隠すため |
| array/tableの`==` | 構造比較だが循環時の扱いがv1.5（identityへ切替）とv1.6（visited pairでtrue）で矛盾 | identity比較。構造比較は`deep_equal`（深さ上限で停止、割り当てなし） |
| hash可能性 | v1.6はarray/tableをhash不能とした | identityでhash可能 |
| NaN key | TypeError | ValueError |
| 不正UTF-8・NUL・tab | ParseError | LexError（code 15） |
| 範囲外整数literal | v1.4.1 ArithmeticError、v1.5 ParseError | LexError。`-9223372036854775808`の扱いを規定 |
| `1.` / `.5` | 許可 | 禁止（`..`との曖昧さ回避） |
| ブロックコメント | 改行の扱いが不明確 | 行単位で占有 |
| 識別子 | Unicode文字を許可 | ASCIIのみ |
| キーワード | 版ごとに不一致（`default`, `finally`, `global`, `async`, `await`, `init`） | §3.4で確定。`init`はキーワードでない。キーワードはメンバ名・table keyに使用可 |
| 複合代入 | v1.6で禁止 | `+=`等を追加（評価は1回） |
| 代入の評価順 | v1.4.1/v1.5は右辺先行、v1.6は別の順序 | すべて左から右（§5.4） |
| `global` | v1.4〜v1.5で存在、v1.6で言及なし | 削除。module変数は関数内から直接代入できる |
| 関数のhoist | v1.5はスコープ先頭へhoist | module top-levelの`func`/`class`のみ |
| ループ変数 | v1.5は単一cell | 反復ごとに新しい束縛 |
| 2変数`for`とarray | v1.4.1はTypeErrorだが付録が`for i, arg in args`を使用 | index, 値として許可 |
| iterator | `__next`（v1.4.1）とnative限定（v1.6）が混在 | native iterator（§20.6）とcoroutineのみ |
| メタメソッド | v1.4で継承規則まで定義、v1.5/v1.6で非提供 | 完全削除 |
| `finally` | v1.4〜v1.6で混在 | 削除。cleanupは`defer` |
| deferの範囲 | 関数単位 | ブロック単位 |
| defer中のerror | v1.4「最後のerrorが伝播」、v1.4.1「新errorが主」 | 最初のerrorが優先、後続は`suppressed` |
| 重複panic | 後発が優先 | 先発が優先、後発は注記 |
| 非error値の`throw` | RuntimeErrorへ暗黙に包む | その場でTypeError（暗黙変換なし） |
| `panic`・`assert` | v1.5はpreludeに`panic`、v1.6は`assert`を関数として定義 | どちらも文。`panic(expr)`の旧表記はそのまま有効 |
| async/await・promise | v1.4で導入、v1.4.1で任意、v1.6でAWAIT必須opcode | 削除。stackful coroutineに統一 |
| error code | v1.4は1〜13、v1.5で14追加、v1.6はcodeなしのclassを追加 | §12.2で全classのcodeを確定。13は欠番 |
| errorのフィールド | `class`（v1.6）、`message/code/cause`（v1.4） | `kind/code/message/cause/data/位置/suppressed` |
| 終了コード | memoryが137（v1.5）と14（v1.6） | 14 |
| `json.parse`の不正入力 | ParseError（コンパイル時classと衝突） | ValueError |
| json循環 | TypeError | ValueError（深さ上限で検出） |
| jsonとtableの数値key | v1.4はarray化、v1.4.1はしない | arrayは独立型。tableのkeyはstringのみ |
| `range`のstep 0 | ArithmeticError | ValueError |
| `iter.map/filter/zip` | stdlibに存在 | 削除（nativeからユーザーコードを呼び、割り当てを隠すため）。ループかcoroutineで書く |
| `printf` | C風、書式未定義 | 削除。`str.format`（`{}`のみ） |
| `sys.argv` | v1.4 | `sys.args` |
| match | 重複束縛を許可、入れ子超過は実行時MatchError、`default`節 | 重複束縛と入れ子超過はコンパイルエラー、`case _` |
| super | 親なしは実行時RuntimeError | コンパイルエラー |
| instance | フィールドの動的追加が未規定 | 固定スロット |
| メソッド参照 | 未規定 | bound methodなし（関数そのもの） |
| lambda | ブロック本体（括弧内で改行が無視される規則と両立しない） | 単一式本体 |
| import束縛名 | 未規定 | 最後の要素 |
| module検索 | 実装定義の標準path（v1.4） | §14.3で固定。実装定義pathなし |
| bytecode | big endian、i16 jump、magic不一致（`SPC1` / `SPC\0`）、HALT、AWAIT | little endian、i32 jump、`SPRC`、format major 2 |
| verifier失敗 | v1.4.1 RuntimeError、v1.5/v1.6 LoadError | LoadError（終了コード13） |
| `exec`の署名・`abi_hash` | 言及のみで形式なし | 削除（checksumのみ。署名は将来の別仕様） |
| `--trace=full` | オプション値に存在しない | `--debug-info=full`でlocal表示 |
| native descriptorの`may_suspend` | 意味が未定義 | 削除。`flags`で割り当て・コールバックを宣言 |
| hostからの再入 | v1.5「禁止、Promise APIを使う」 | `SP_NATIVE_CALLS_BACK`を宣言した場合のみ`sp_call`で許可 |
| limits名 | `max_stack_frames`（v1.5）と`max_call_depth`（v1.6） | §18.4の表で確定。`0`の意味をkeyごとに規定 |
| 準拠レベル | v1.4のCore/Stdlib/VM/Sandbox、v1.4.1のAST評価許可 | 単一の準拠。bytecode経路が必須 |
| `__gc`・GC倍率 | v1.4で規定 | ファイナライザなし。GCトリガは実装定義（観測不能） |
| テストでの`eval` | v1.4の必須テストが使用 | `eval`は存在しない。§22.4形式で書く |
