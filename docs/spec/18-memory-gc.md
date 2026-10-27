## 18. メモリ・GC・資源上限

### 18.1 GC

- 正確（precise）・非移動（non-moving）のGCを使う。アルゴリズム（mark-sweep、インクリメンタル、世代別等）は実装定義。
- 循環参照は回収できなければならない。
- **GCは割り当て点（または`gc.collect()`）でだけ起動する**（A6）。GCはユーザーコードを呼ばない（H1）。Sprintレベルのファイナライザ・弱参照はない。
- rootは少なくとも: 全coroutineのstack・frame・defer領域・handler、module slot、解決済みLINK、builtin module、定数、native rootスタック（§20.4）、hostの`SpRef`、伝播中のerror、VM内部の一時値。
- mark処理はC再帰を使わない。mark stackの確保に失敗しても正しく完了しなければならない（例: overflow時にheapを再走査する）。
- MemoryErrorとする前に、VMは必ず完全なGCを1回行って割り当てを再試行する。
- GCは観測可能な挙動（出力、table順、オブジェクトID、乱数、trace）を変えてはならない。

### 18.2 heapの計上

`max_heap_bytes`は、VMが`SpAllocFn`から現在確保しているバイト数の合計（VM生成時の一括確保領域を含む）に適用する。

### 18.3 VM生成時の一括確保

`sp_vm_new`は次を一括確保する。これらはプログラムの実行中に伸長しない。

- main coroutineの値スロット`max_operand_stack`個、frame `max_call_depth`個、try handler `max_handlers`個、defer record `max_defer_records`個、defer値スロット`max_defer_values`個
- stdoutバッファ`stdout_buffer_bytes`
- native rootスタック`max_native_roots × max_native_reentry`個

### 18.4 limits（正本）

`--limits=FILE`はTOMLで、次のkeyだけを受け付ける（未知のkey、範囲外、型違いは終了コード2）。

| key | 既定 | 0の意味 | 超過時 |
|---|---:|---|---|
| `max_source_bytes` | 16777216 | 不可 | LexError（診断） |
| `max_module_count` | 1024 | 不可 | ImportError（診断） |
| `max_call_depth` | 1024 | 不可 | MemoryError |
| `max_operand_stack` | 65536 | 不可 | MemoryError（verifierは`max_stack`超過をLoadError） |
| `max_handlers` | 1024 | 不可 | MemoryError（実行中のtryの入れ子総数） |
| `max_defer_records` | 1024 | 不可 | MemoryError |
| `max_defer_values` | 8192 | 不可 | MemoryError |
| `max_heap_bytes` | 268435456 | 無制限 | MemoryError |
| `max_string_bytes` | 67108864 | 不可 | MemoryError |
| `max_array_length` | 16777216 | 不可 | MemoryError |
| `max_table_entries` | 16777216 | 不可 | MemoryError |
| `max_trace_frames` | 64 | 不可 | 中央を省略 |
| `max_native_reentry` | 32 | 不可 | MemoryError |
| `max_native_roots` | 256 | 不可 | MemoryError |
| `stdout_buffer_bytes` | 65536 | 不可（最小256） | flush |
| `max_runtime_ms` | 0 | 無制限 | TimeoutError |
| `max_instructions` | 0 | 無制限 | TimeoutError |

- 上限超過が操作開始前に分かる場合は、何も変更せずに失敗する（部分更新を残さない）。
- `sprint run --limits=FILE`は`--trace=calls`以上のとき、適用したlimitsを起動時にstderrへ表示する。
- 固定上限（設定不可）: 1関数のlocal 65535、定数65535、upval 65535、program全体のLINK 65535、実引数255、`CONCAT` 255、パターン入れ子16、Parserの入れ子（括弧・ブロック・式）256（超過はParseError）。超過はコンパイル時の診断`ParseError`として該当構文の位置で報告する（spread展開による実引数255超過だけは実行時のTypeError、§9.2）。
