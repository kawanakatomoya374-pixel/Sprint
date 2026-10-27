## 22. 診断・エラー出力・コンフォーマンス

### 22.1 コンパイル診断

```json
{
  "severity": "error",
  "kind": "ParseError",
  "code": 12,
  "message": "expected ':' after condition",
  "file": "main.sp",
  "start": {"line": 3, "column": 7, "offset": 42},
  "end": {"line": 3, "column": 8, "offset": 43},
  "notes": [],
  "help": []
}
```

- `--diagnostic-format=json`では1行に1診断（JSON Lines）でstderrへ出力する。
- Parserはrecoveryして最大20件まで診断を集めてよい。1件でもerrorがあれば何も実行しない。recovery後のASTをコンパイルしてはならない。
- 診断の並び順: file（module初期化順）→ offset昇順。

### 22.2 実行時エラーのJSON

```json
{
  "severity": "error",
  "kind": "TypeError",
  "code": 1,
  "message": "unsupported operand types for +: int and string",
  "file": "main.sp", "line": 4, "column": 11,
  "trace": [
    {"module": "main", "function": "<module>", "file": "main.sp", "line": 9, "column": 1},
    {"module": "main", "function": "add", "file": "main.sp", "line": 4, "column": 11}
  ],
  "suppressed": null
}
```

panicは`"kind": "Panic", "code": 21`。nativeのframeは`{"native": "fs.read_file"}`。

### 22.3 エラー位置の規則（正本）

| 失敗した操作 | 位置 |
|---|---|
| 字句・構文エラー | 原因となったtoken（または文字）の開始位置 |
| 名前解決エラー | 該当識別子の開始位置 |
| 二項・単項演算 | 演算子tokenの開始位置 |
| 呼出し（arity、非callable、native内のerror） | 呼出しの`(` |
| 添字`a[i]` | `[` |
| メンバ`o.x` | `.` |
| `throw` / `assert` / `panic` / `match`の失敗 | そのキーワード |
| `for`の対象の型・反復中の変更 | `for`キーワード |
| `error(...)`で生成したerror | その呼出しの`(` |
| 代入（ConstErrorを含む） | 代入演算子（`=`、`+=`等） |

### 22.4 コンフォーマンステストの形式

```yaml
id: core.syntax.assignment-chain-001
source: |
  let a = 0
  a = 1 = 2
args: []
stdin: ""
capabilities: [stdio_write]
expect:
  exit: 12
  stdout: ""
  error: {kind: ParseError, code: 12, file: main.sp, line: 2, column: 7}
```

比較規則（MUST）:

1. 終了コード、stdoutのバイト列、errorの`kind`・`code`・`file`・`line`・`column`を比較する（errorは`--diagnostic-format=json`の出力から取る）。
2. **`message`・`notes`・`help`・traceの文字列・human形式のstderrは比較しない。** メッセージ本文は翻訳・改善してよい（`--locale`）。
3. ユーザーが`error(kind, message)`で与えたmessageは、プログラムが`print(e.message)`等で出力した場合にstdoutとして比較される（処理系の文言ではないため）。
4. 複数ファイルのテストは`files: {path: content}`で与え、`source`はエントリ`main.sp`とする。

### 22.5 必須テストカテゴリ

| カテゴリ | 内容 |
|---|---|
| 字句 | 全literal、escape、コメント、INDENT/DEDENT、不正UTF-8、tab、BOM、INT_MIN |
| 構文 | 全構文、優先順位・結合性（§4.2の全行）、比較連鎖・代入連鎖の禁止、エラー位置 |
| 値と演算 | 演算表（§7）の全セル、NaN、-0.0、int/float正確比較、overflow、ビット演算境界 |
| スコープ | shadowing、宣言前参照、module変数への代入、closure、forの反復ごとの束縛 |
| 制御 | if/while/for/match、ラベル、break/continue、range lowering |
| 関数 | default引数の評価点と順序、rest、spread、arity |
| class | フィールド初期化順、init探索、super、override、メソッド参照、未宣言フィールド |
| error | try/catch、throw非error、deferの全終了経路（§12.4.3の全セル）、panic、assert、suppressed |
| coroutine | resume/yield/status/close、forでの反復、errorの伝播、defer中のyield |
| module | 検索順、live export、循環、重複、初期化順 |
| stdlib | 全API・全エラー条件・境界値 |
| 割り当て | `--alloc-trace`（§23.4）で、割り当て点以外で割り当てが起きないこと |
| bytecode | 全opcodeのエンコード、verifierの全規則（不正imageの拒否） |
| 決定性 | 同一入力での出力一致、仮想時計、random |

### 22.6 準拠の定義

処理系がSprint 2.0準拠であるのは、次をすべて満たす場合に限る。

- 公式コンフォーマンステストに100%合格する。
- 本書のMUSTをすべて満たす。§0.4以外に実装定義の項目を持たない。
- 公式でない機能はMAY機能として`sprint features`に表示し、既定で無効である。
