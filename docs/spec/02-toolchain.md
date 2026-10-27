## 2. 処理系の構成とCLI

### 2.1 6層構成

公式処理系は次の6層に分かれ、層を飛ばしてはならない。各層は独立にテスト可能な公開インターフェースを持つ（Cでの対応ファイルは§21.3）。

```text
1. Source      : UTF-8検証・改行正規化
2. Lexer       : token列、INDENT/DEDENT生成
3. Parser      : AST生成、構文診断
4. Resolver    : scope解決、module graph、静的診断
5. Compiler    : bytecode生成、verifier、serializer
6. VM          : 実行、GC、stdlib、host境界
```

- Parser・ResolverはVMを呼ばない。CompilerはファイルI/Oをしない（module sourceの読込はResolverがhost経由で行う）。
- ランタイムの副作用（出力、ファイル変更など）を起こすのはVMだけである。
- Compilerの出力は同一入力・同一オプションに対してバイト単位で同一でなければならない。

### 2.2 コマンド

```text
sprint check   [OPTIONS] FILE...
sprint run     [OPTIONS] FILE [-- ARGS...]
sprint compile [OPTIONS] FILE -o OUTPUT.spc
sprint exec    [OPTIONS] FILE.spc [-- ARGS...]
sprint repl    [OPTIONS]
sprint test    [OPTIONS] [PATH]
sprint fmt     [--check] FILE...
sprint lint    [--alloc] FILE...
sprint disasm  FILE.spc
sprint inspect FILE.spc
sprint version
sprint features
```

| コマンド | 契約 |
|---|---|
| `check` | module graph全体をlex・parse・resolve・compile・verifyする。実行しない。 |
| `run` | `check`相当が成功した場合だけVMを起動し、実行する。コンパイル結果をキャッシュしてよいが、キャッシュの有無は観測できてはならない。 |
| `compile` | `check`相当の後、program image（§16）を一時ファイルに書き、atomic renameで出力する。 |
| `exec` | ヘッダ・checksum・format版・required features・limitsを検証し、全関数をverifyしてから実行する。検証前に1命令も実行しない。 |
| `repl` | §23.1。 |
| `test` | §23.5。 |
| `fmt` | 意味を変えずcanonical形式に整形。`--check`は差分があれば終了コード1。 |
| `lint` | warningのみ。warningは終了コードを失敗にしない。`--alloc`は割り当て点一覧。 |
| `disasm` / `inspect` | 副作用なし。capabilityを初期化しない。 |
| `features` | 処理系が対応するMAY機能の一覧と有効/無効を表示。 |

### 2.3 共通オプション

```text
--color=auto|always|never
--diagnostic-format=human|short|json
--limits=FILE                 limits設定（TOML、§18.4）
--deterministic               決定性モード（§19）
--locale=LOCALE               診断メッセージ本文の言語（class・code・位置には影響しない）
--trace=none|error|calls|bytecode
--debug-info=none|line|full   既定: line
--enable=FEATURE              MAY機能の有効化（複数指定可）
--allow-read=DIR              filesystem_read capability（複数指定可）
--allow-write=DIR             filesystem_write capability（複数指定可）
--allow-clock / --deny-clock
--allow-random
--allow-ffi                   ffi capability（§15.15。`--allow-all`には含まれない）
--allow-all                   ffiを除く全capability（開発用、§19.2）
--alloc-trace                 ヒープ割り当てをすべてstderrへ記録（§23.4）
--no-stdlib                   prelude以外のbuiltin moduleを無効化
--no-quicken                  実行時の命令融合を無効にする（差分テスト用。観測可能な挙動は変わらない）
--no-jit                      ループJIT（§17.10）を無効にする（環境変数 SPRINT_JIT=0 でも可。観測可能な挙動は変わらない）
--max-instr N                 step budgetの上限（§17.8、超過は終了コード124）
```

- 未知のオプション、値の不正は終了コード2。
- オプションの順序は意味に影響しない。`--`以降はプログラム引数（`sys.args`）。
- `run`/`exec`/`repl`/`test`の既定capabilityは`stdio_read`, `stdio_write`, `clock`のみ。filesystemは`--allow-read`/`--allow-write`で明示しない限り与えない。
- `--trace=error`は未処理エラー時にtraceを表示する（既定）。`--debug-info=full`でコンパイルされている場合に限り、traceに各frameのlocal値を表示する。

### 2.4 終了コード

| code | 意味 |
|---:|---|
| 0 | 成功 |
| 1 | 未処理のcatch可能エラー（PermissionErrorを除く）、`test`の失敗、`fmt --check`の差分 |
| 2 | CLI・設定・環境エラー |
| 3 | 未処理のPermissionError |
| 4 | module/package解決失敗（未発見、循環、lockfile不一致） |
| 12 | コンパイルエラー（Lex/Parse/Name/Const/静的Import等の診断） |
| 13 | bytecode load/verify エラー（LoadError） |
| 14 | 資源上限超過（MemoryError） |
| 101 | panic |
| 124 | 実行時間上限超過（TimeoutError） |
| 130 | ユーザー割り込み（SIGINT等） |
| 0–255 | `sys.exit(code)`で指定した値 |

**終了コードとError objectの`code`は別物である。** Error classのcodeは§12.2の表で定義する。
