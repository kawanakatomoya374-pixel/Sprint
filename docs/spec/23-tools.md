## 23. REPL・fmt・lint・観測ツール

### 23.1 REPL

参照実装: `sprint repl [--deterministic] [--allow-*] [--max-heap N] [--max-instr N]`。入力単位は増分コンパイルされ、1つのProgramに積まれる。以前の入力で宣言した名前・import・classは後続の入力から見える。式文の値は`_`にも束縛される。コマンドは`:help` `:names` `:reset` `:quit`（Ctrl-Dでも終了）。以下は規範の要求であり、コマンド綴りは実装定義とする。

- 入力単位は1つの完全な文。括弧が閉じていないとき、または`:`で終わる行の後は継続入力（プロンプト`...`）とし、ブロックは空行で終わる。
- 各入力単位はLexer→Parser→Resolver→Compiler→VMを通る。REPLのtop-levelは1つのmodule（`<repl>`）として保持する。
- REPLに限り: top-levelの名前の再宣言を許可する（新しい束縛で置き換える）。`import`をいつでも書ける。
- 式文の値が`nil`以外ならreprを表示する。
- errorは表示してREPLを継続する。panic・致命的エラーは表示してREPLの状態を破棄し、新しい状態で継続する。
- top-levelの`defer`は、その入力単位の終了時に実行する。
- コマンド: 終了、状態の破棄（reset）、ヘルプ。参照実装は`:quit` `:reset` `:help` `:names`（定義済みの名前の一覧）。`.disasm`は未対応。

### 23.2 fmt

参照実装: `sprint fmt [--check] [-w] FILE...`（`-`でstdin）。トークン駆動の空白整形で、整形後に再lexしてトークン列が同一であることを確認し、異なる場合は出力しない。

- インデント4 space、LF、ファイル末尾に改行1つ、行末空白なし。
- 二項演算子と代入演算子の前後に1 space、`,`と`:`（table literal）の後に1 space。
- 空行はtop-levelで最大2行、ブロック内で最大1行。
- 文字列の引用符、数値literalの表記、コメントの内容は変えない。
- 行の折り返しはしない。
- 冪等: `fmt(fmt(x)) == fmt(x)`。整形前後でASTが同一（位置を除く）。

### 23.3 lint

参照実装: `sprint lint [--json] FILE...`。規則コード: `L001` 未使用import / `L002` 未使用の変数・関数 / `L003` 到達不能コード / `L004` table literalの重複key / `L005` prelude名のshadowing / `L006` 空の`catch`。`--alloc`は未対応。

warningのみ（終了コードは0）。少なくとも: 未使用の変数・import、builtin名のshadowing、到達不能コード、builtin module名と同名のユーザーmodule、`catch`で何もしないブロック。

`lint --alloc`は、すべての割り当て点（付録A）を次の形式で列挙する。

```text
main.sp:12:13: A   array literal
main.sp:15:9:  A   closure
main.sp:15:20: A   cell (captured variable 'count')
main.sp:20:5:  A?  table insert (x[k] = v; if x is a table and k is new)
main.sp:22:7:  A   concat
main.sp:30:5:  A   call to allocating native 'fs.read_file'
```

### 23.4 `--alloc-trace`（テスト用）

`sprint run --alloc-trace`は、実行中のすべてのヒープ割り当てについて、割り当てを起こした命令のsource位置と区分をstderrに出力する。コンフォーマンステストはこれを使い、付録Aの割り当て点以外で割り当てが起きないことを検証する。

### 23.5 `sprint test`

- `PATH`（省略時はカレントディレクトリ）以下の`*_test.sp`をUTF-8バイト順のpath順に探す。
- 各ファイルを新しいVMでエントリmoduleとして初期化し、その後、top-levelの関数のうち名前が`test_`で始まり必須引数が0個のものを宣言順に1つずつ呼ぶ。
- 関数がerrorなく戻れば合格。catchされないerrorなら不合格。panic・致命的エラーならその関数を不合格とし、同じファイルの残りの関数は実行せず不合格（not run）とする。module初期化の失敗はファイル内の全関数を不合格とする。
- 出力（stdout）: 各関数について`PASS path::name`または`FAIL path::name: KIND: MESSAGE (file:line:column)`、最後に`N passed, M failed`。
- 全関数が合格なら終了コード0、そうでなければ1。capabilityとlimitsは`run`と同じオプションで指定する。
