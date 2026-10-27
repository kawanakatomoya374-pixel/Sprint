### 15.8 time

| 関数 | 割当 | capability | 仕様 |
|---|---|---|---|
| `time.now()` | — | clock | Unix epoch秒（float） |
| `time.monotonic()` | — | clock | 単調増加する秒（float、起点は未規定だがプロセス内で一定） |
| `time.sleep(sec)` | — | clock | `sec < 0`はValueError |

決定性モードでは§19.3の仮想時計を使う。
