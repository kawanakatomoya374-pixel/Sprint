## 19. 決定性とcapability

### 19.1 決定性の保証

同一処理系・同一入力（source、引数、stdin、ファイル）・同一limits・同一オプションでは、stdout、終了コード、error（kind/code/位置）、ファイルへの変更は同一でなければならない。ただし次は除く:

- capability `clock` / `random`（エントロピーseed）を使う値
- `max_runtime_ms`による停止の時点
- `math`のlibm関数のプラットフォーム差（同一ビルドなら同一）
- `sys.platform`

### 19.2 capability

| capability | 対象API | CLI既定 | 埋め込み既定 |
|---|---|---|---|
| `stdio_read` | `io.read_line`, `io.read_all` | 許可 | 不許可 |
| `stdio_write` | `print`, `io.write`, `io.eprint`, `io.flush` | 許可 | 不許可 |
| `filesystem_read` | `fs`の読み取り系（許可directory内） | 不許可（`--allow-read=DIR`） | 不許可 |
| `filesystem_write` | `fs`の書き込み系（許可directory内） | 不許可（`--allow-write=DIR`） | 不許可 |
| `clock` | `time.*` | 許可（`--deny-clock`で不許可） | 不許可 |
| `random` | `random`のエントロピーseed | 不許可（`--allow-random`） | 不許可 |
| `ffi` | module `ffi`（§15.15）のすべて。生メモリ・関数pointerの呼出しを含むため**型安全でも決定的でもない** | 不許可（`--allow-ffi`。`--deterministic`では常に不許可） | 不許可（`SP_CAP_FFI`） |

- capabilityの不足はPermissionError（終了コード3）。
- Sprintコードから環境変数、プロセス起動、socketへアクセスする手段はない。生pointerへのアクセスは`ffi` capabilityがあるときの`ffi`（§15.15）だけである。`network`, `process_spawn`はhost拡張のための予約名である。
- `--allow-all`は上表のうち`ffi`を除く全capabilityを許可し、filesystemの許可directoryをカレントディレクトリとする。`ffi`は明示的な`--allow-ffi`だけが許可する。

### 19.3 決定性モード（`--deterministic`）

- `time.now()`と`time.monotonic()`は仮想時計を返す。仮想時計は`0.0`から始まり、`time.sleep(sec)`で`sec`だけ進む（実際には待たない）。
- `random`はエントロピーseedを使わない（seedなしの使用はPermissionError）。
- `gc.stats()`の数値はすべて0。
- `sys.platform`は`"other"`。
- `max_runtime_ms`を0以外にするとCLIエラー（終了コード2）。代わりに`max_instructions`を使う。
