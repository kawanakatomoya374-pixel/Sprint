## 17. bytecode・VM実行契約

### 17.1 命令エンコーディング

- 命令は`opcode: u8`に続いてoperandを並べる。operand型は`u8`, `u16`, `i16`, `i32`（すべてlittle endian、アラインメントなし）。
- pcはprototypeのcode先頭からのバイトoffset。
- jump offset（i32）は**その命令の直後のpc**を基準とする相対バイト数。
- 本節の表（§17.4）が**opcodeの唯一の正本**である。v1.4・v1.6を含むv1.x系のopcode表はすべて無効である。

### 17.2 frame

各frameは少なくとも次を持つ: prototype、pc、slot base（operand stack上のlocal先頭）、stack top、handler stackの基準位置、defer stackの基準深さ、`super()`実行済みflag、所属coroutine。

- localはslot base以降に`nlocals`個並び、その上がoperand領域である。frameはslot baseより下を読み書きしてはならない。
- frame・operand stack・handler stack・defer領域はcoroutineごと（mainはVM生成時、coroutineは`coroutine.create`時）に一括確保された領域を使い、実行中に伸長しない（A4）。

### 17.3 呼出し規約

`CALL argc`（stack: `f a1 ... an`）:

1. `f`がclassならインスタンス生成（§10.3）、native関数なら§20.5、functionでなければTypeError。
2. functionの場合: `argc < nrequired`、またはrest引数なしで`argc > nparams`ならTypeError。
3. 新しいframeを作り、`a1..an`をlocal 0..に置く（`f`の位置がslot baseになる実装でもよいが、`f`はlocalとして観測できない）。
4. rest引数があれば、`nparams`を超える実引数でarrayを作り（A）local `nparams`に置く。
5. 不足したdefault引数がある場合、`default_pcs[argc - nrequired]`から実行を始める。default評価コードは残りのdefault式を順に評価してlocalへ格納し、本体の先頭へfallthroughする。それ以外はpc 0から実行する。
6. 呼出し深さが`max_call_depth`を超えたらMemoryError（致命的）。
7. `RETURN`でframeを破棄し、戻り値1個をcallerのstackへpushする。

`INVOKE name argc`（stack: `o a1 ... an`）は§10.4の`o.name(args)`の規則でcalleeを決め、メソッドなら`o`を第1引数として渡す。メソッド検索はbound methodを生成しない。

### 17.4 opcode表（正本）

stack列は「実行前 → 実行後」（右がtop）。「A」は割り当て点。jump offsetはi32で、**その命令の次のpc**を基準にする（`target = 次のpc + off`）。

| hex | 名前 | operand | stack | 意味 |
|---|---|---|---|---|
| 0x00 | NOP | — | → | 何もしない |
| 0x01 | CONST | u16 k | → v | 定数k |
| 0x02 | NIL | — | → nil | |
| 0x03 | TRUE | — | → true | |
| 0x04 | FALSE | — | → false | |
| 0x05 | SMALLINT | i16 n | → n | int |
| 0x06 | POP | — | v → | |
| 0x07 | DUP | — | v → v v | |
| 0x08 | DUP2 | — | a b → a b a b | 複合代入用 |
| 0x10 | LOAD_LOCAL | u16 i | → v | |
| 0x11 | STORE_LOCAL | u16 i | v → | |
| 0x12 | MAKE_CELL | u16 i | → | local iの値をcellに包む（A） |
| 0x13 | LOAD_CELL | u16 i | → v | local iのcellの中身。cellでなければRuntimeError |
| 0x14 | STORE_CELL | u16 i | v → | 同上 |
| 0x15 | LOAD_UPVAL | u16 i | → v | |
| 0x16 | STORE_UPVAL | u16 i | v → | |
| 0x17 | LOAD_MODULE | u16 i | → v | module変数slot（全module共通）。未初期化ならNameError |
| 0x18 | STORE_MODULE | u16 i | v → | |
| 0x19 | LOAD_LINK | u16 i | → v | LINK解決結果 |
| 0x20–0x26 | ADD SUB MUL DIV FLOOR_DIV MOD POW | — | a b → r | §7.1, §7.2 |
| 0x27 | NEG | — | a → r | |
| 0x28–0x2A | BAND BOR BXOR | — | a b → r | §7.3 |
| 0x2B | BNOT | — | a → r | |
| 0x2C–0x2D | SHL SHR | — | a b → r | |
| 0x2E | NOT | — | a → bool | |
| 0x2F | CONCAT | u8 n (≥2) | v1..vn → s | §7.4（A） |
| 0x30–0x31 | EQ NE | — | a b → bool | §7.6 |
| 0x32–0x35 | LT LE GT GE | — | a b → bool | §7.5 |
| 0x38 | JUMP | i32 off | → | |
| 0x39 | JUMP_IF_FALSE | i32 off | v → | 偽ならjump |
| 0x3A | JUMP_IF_TRUE | i32 off | v → | 真ならjump |
| 0x3B | JUMP_IF_FALSE_OR_POP | i32 off | v → v（jump時）/ →（非jump時） | `and` |
| 0x3C | JUMP_IF_TRUE_OR_POP | i32 off | v → v（jump時）/ →（非jump時） | `or` |
| 0x40 | GET_INDEX | — | o k → v | §8 |
| 0x41 | SET_INDEX | — | o k v → | tableの新規keyはA? |
| 0x42 | GET_MEMBER | u16 c | o → v | 定数cはstring。§10.4 |
| 0x43 | SET_MEMBER | u16 c | o v → | 定数cはstring |
| 0x44 | NEW_ARRAY | u16 n | v1..vn → a | A |
| 0x45 | NEW_TABLE | u16 n | k1 v1..kn vn → t | A |
| 0x46 | CLOSURE | i32 p | → f | A。prototype p。upvalは**prototypeのupvals記述**に従い、現frameのcell（from_local）または現closureのupvalから取る |
| 0x48 | TEST_ARRAY | u16 n | v → bool | vが長さnのarrayか（patternの先頭検査） |
| 0x49 | TEST_HAS | u16 c | v → bool | 定数c（string）のkeyをtableが、またはフィールドをinstanceが持つか |
| 0x4A | NEW_INSTANCE | — | C → inst | classからinstanceを生成（A）。class以外はRuntimeError |
| 0x4B | CLASS | u16 ci | parent m1..mn → C | CLASSES[ci]に従いclassを生成（A）。mnはメソッド（classの`method_names`の順）。parentはclassまたはnil |
| 0x4C | SET_SLOT | u16 i | inst v → | instanceのフィールドslot i。範囲外はRuntimeError |
| 0x4D | CTOR_CHECK | u16 s | → | rest arrayが空でなければTypeError（引数を取らないclass） |
| 0x50 | CALL | u8 n | f a1..an → r | §17.3 |
| 0x51 | CALL_SPREAD | u8 n | f a1..an arr → r | §9.3 |
| 0x52 | INVOKE | u16 c, u8 n | o a1..an → r | |
| 0x53 | INVOKE_SPREAD | u16 c, u8 n | o a1..an arr → r | |
| 0x56 | RETURN | — | v → | |
| 0x57 | RETURN_NIL | — | → | |
| 0x60 | FOR_PREP | u16 s | it → | local s, s+1, s+2を反復状態に使う |
| 0x61 | FOR_NEXT | u16 s, u8 n, i32 off | → v1..vn（継続）/ →（終了時jump） | §17.6。nは1または2 |
| 0x62 | RANGE_PREP | u16 s | start stop step → | 検査してlocal s..s+2へ |
| 0x63 | RANGE_NEXT | u16 s, i32 off | → i（継続）/ →（終了時jump） | |
| 0x68 | THROW | — | e → | errorでなければTypeError |
| 0x69 | TRY_BEGIN | i32 off | → | handlerを登録（handler pc = 次のpc + off）。handlerはerror値を1個積んだ状態で始まる |
| 0x6A | TRY_END | — | → | 最内handlerを除去 |
| 0x70 | PANIC | — | v → | §12.5 |
| 0x71 | ASSERT_FAIL | — | msg → | msgがnilなら既定メッセージ |
| 0x72 | MATCH_FAIL | — | v → | MatchError |
| 0x74 | DEFER_SCOPE | u16 s | → | local sに現在のdefer深さを記録 |
| 0x75 | RUN_DEFERS | u16 s | → | §17.7 |
| 0x76 | DEFER | u8 n | f a1..an → | defer登録 |
| 0x77 | DEFER_INVOKE | u16 c, u8 n | o a1..an → | メソッド検索を登録時に行って登録 |
| 0x78 | RAISE_ERR | u8 code, u16 c | → | 定数c（string）を本文にcodeのerrorを送出（コンパイラが静的に分かる実行時エラー用） |
| 0x79 | YIELD | — | v → | coroutineを中断し`v`を渡す。再開値は捨てる（statementである） |

- **実行時専用opcode（quickening）**: 処理系は実行時に命令列を融合した`OP_Q_*`へ書き換えてよい。これらはメモリ上の複製にだけ現れ、`.spc`イメージには決して書き出されず、イメージ中に現れればLoadErrorである。観測可能な挙動は元の命令列と同一でなければならない（`--no-quicken`との差分テストで検証する）。
- 上表にない番号（0xE0–0xEF・0xF0–0xFE・0xFFを含む）はLoadError。未実装opcodeをNOPとして扱ってはならない。
- `u16 c`の定数はstringでなければならない（verifierが検査）。
- 継承・`super`は専用opcodeを持たない。コンパイラが生成するコンストラクタと隠しlocalで表現し、`super(...)`は親classの`init`メンバの通常呼出し、`super.m()`は静的に解決した祖先メソッドの呼出しにloweringされる。
- 実行時型検査: internalな状態を前提とする命令（LOAD_CELL / STORE_CELL / CLOSURE / NEW_INSTANCE / SET_SLOT / FOR_NEXT / RANGE_NEXT）は、前提が崩れていればRuntimeError（"corrupt bytecode"）で止まる。verifierが通るimageでもメモリ破壊は起きない。

### 17.5 必須lowering

| 構文 | lowering |
|---|---|
| `a and b` | `a; JUMP_IF_FALSE_OR_POP L; b; L:` |
| `a or b` | `a; JUMP_IF_TRUE_OR_POP L; b; L:` |
| `x if c else y` | `c; JUMP_IF_FALSE L1; x; JUMP L2; L1: y; L2:` |
| `a[i] += v` | `a; i; DUP2; GET_INDEX; v; ADD; SET_INDEX` |
| `o.k += v` | `o; DUP; GET_MEMBER k; v; ADD; SET_MEMBER k` |
| `a .. b .. c` | `a; b; c; CONCAT 3` |
| `for x in range(...)` | `RANGE_PREP` / `RANGE_NEXT`（§11.2） |
| `assert c, m` | `c; JUMP_IF_TRUE L; m（またはNIL）; ASSERT_FAIL; L:` |
| deferを直接含むブロック | 入口で`DEFER_SCOPE s`、すべての出口（末尾・break・continue・return）の前に`RUN_DEFERS s` |
| `return e`（deferを持つブロック内） | `e; STORE_LOCAL r; RUN_DEFERS s_outermost; LOAD_LOCAL r; RETURN` |
| `match` | caseを上から順に条件jump。各パターンはTEST_ARRAY / TEST_HAS / GET_INDEX / GET_MEMBER / EQで照合し、束縛は隠しlocalに保存する。失敗時はstackを空にして次のcaseへjump |

### 17.6 反復（FOR_PREP / FOR_NEXT）

- `FOR_PREP s`: 反復対象をpopし、型に応じて状態をlocal s..s+2に置く。array/table/iterator/coroutine以外はTypeError。iteratorで変数の数（後続FOR_NEXTのn）とarityが違う場合はFOR_NEXTの最初の実行でTypeError。
- `FOR_NEXT s n off`:
  - array: `cursor < len(a)`なら値（n=2ならindexと値）をpushしてcursorを進める。そうでなければjump。
  - table: 構造変更カウンタがFOR_PREP時と違えばRuntimeError。次の有効entryがあればpush、なければjump。
  - iterator: 終了済みならjump。そうでなければ`next`（§20.6）を呼ぶ。ITEMならpush、ENDなら終了済みにしてjump、FAILなら終了済みにしてそのerrorを送出。
  - coroutine: §11.2。resume中は呼出し元frameのFOR_NEXTで待機し、yieldで戻ったらpushする。
- FOR_NEXTはユーザーコードを直接実行しない（coroutineの場合を除く）。

### 17.7 例外処理とdeferの実行

**defer領域**: 各coroutineはdefer record stackとdefer値stackを持つ。DEFER/DEFER_INVOKEはcalleeと引数をdefer値stackへ移し、recordを積む。

**RUN_DEFERS s**（再実行可能な命令）: local sに記録された深さより上にrecordがあれば、最上位のrecordを1つ取り出してその呼出しを開始し、呼出しの完了後に**同じRUN_DEFERS命令を再実行**する。深さが記録値に戻ったらpcを進める。deferred callの戻り値は捨てる。

**throwの処理**: errorが送出されたら:

1. 現frameで最内のhandlerを探す。handlerがあれば、handler登録時のdefer深さより上のdeferを（RUN_DEFERSと同じ方法で）すべて実行し、operand stackをhandler登録時の高さに戻し、errorをpushしてhandler pcへ移る。
2. handlerがなければ、frame開始時のdefer深さより上のdeferをすべて実行し、frameを破棄して呼出し元で1から繰り返す。
3. coroutineの最下frameを抜けたら§13.2のとおりresume元へ送出する。mainの最下frameを抜けたら未処理エラーとして終了する（§12.8）。
4. defer実行中のerrorは§12.4.3に従う。

**C再帰の禁止**: VMはSprintの関数呼出し、deferの実行、例外伝播、coroutine切替をCの再帰呼出しで実装してはならない。C再帰が生じるのはnative関数からの`sp_call`（§20.5）だけであり、その深さは`max_native_reentry`で制限する。

### 17.8 実行時検査の契機

- `max_instructions`（0以外）: 実行**ステップ数**が上限を超えた時点でTimeoutError。決定的である。1ステップは「後方へのjump（ループの反復）」「関数・メソッド・native関数の呼出し」のいずれか1回である。これらの間の直線的な命令列はプログラムの大きさで有界なので、ステップ上限はあらゆる無限ループ・無限再帰を停止させる。個々の命令を数えないのは、1命令ごとの計数が実行速度を大きく損なうためである（最適化後の実装が命令を融合してもステップ数は変わらない）。
- `max_runtime_ms`（0以外）: 少なくとも後方jumpと呼出しのたびに経過時間を確認する（間引きは実装定義、ただし確認間隔は10ms相当以下）。
- 割り込み（`sp_interrupt`、SIGINT）: 同じ契機で確認し、検出したら終了コード130で停止する。

### 17.9 verifier（MUST）

ロード時、実行前に全prototypeについて次を検証する。1つでも違反があればLoadError（終了コード13）で、1命令も実行しない。

1. ヘッダ・checksum・section構造（§16.2–16.3）。全string indexの範囲とUTF-8妥当性。
2. codeが命令列としてちょうど分割でき、operandが途中で切れていない。全opcodeが§17.4に存在する。
3. jump先・handler pc・`default_pcs`が命令境界かつcode範囲内。
4. **stack高さ**: 抽象解釈により各pcのstack高さが一意に定まり、`0 <= height <= max_stack`。分岐の合流点で高さが一致する。FOR_NEXT/RANGE_NEXT/JUMP_IF_*_OR_POPは分岐ごとの効果で計算する。handler pcの高さは「TRY_BEGIN時の高さ + 1」。
5. **handler深さ**: TRY_BEGIN/TRY_ENDの入れ子の深さが各pcで一意で、TRY_ENDが対応するTRY_BEGINを持つ。
6. local / upval / 定数 / prototype / class / link indexが範囲内。`u16 c`の定数がstring。
7. codeの末尾から先へfallthroughしない。最後の命令は終端命令（`RETURN`, `RETURN_NIL`, `THROW`, `JUMP`, `PANIC`, `ASSERT_FAIL`, `MATCH_FAIL`）でなければならない。終端命令の直後の命令はjump先でなければ到達不能であり、到達不能な命令が存在してもよいが、stack高さの検査対象外とする。
8. `CONCAT n`は`n >= 2`。`max_stack`が`max_operand_stack`以下。
9. `nrequired <= nparams`、`ndefaults == nparams - nrequired`、`nlocals >= nparams + (rest ? 1 : 0)`、`module`が有効。module本体とclassのコンストラクタprototypeは`nupvals == 0`。`CLOSURE`が指すprototypeの各upval記述は、現prototypeのlocal数（from_local）または現prototypeのupval数の範囲内。
10. class記述: `ctor_proto`が有効。フィールド名・メソッド名がclass内で一意。（継承関係は実行時に`CLASS`命令へ渡される値で決まるため、静的には検査しない。override規則はコンパイラが保証し、実行時は型検査だけを行う。）
11. 各moduleの`entry_proto`・exportのslotが範囲内で、export名が一意。LINKSはすべて解決できる（preludeに存在する関数、存在するbuiltin moduleとそのexport）。
12. DEBUG表のpcがcode範囲内で昇順。
13. （実行時の補完）値の型に依存する内部命令は§17.4のとおり実行時にも検査する。verifierは構造と静的な数値だけを保証し、値の型は保証しない。

### 17.10 JIT（ループと関数、実行時専用、省略可能）

x86-64 Linuxの処理系は、熱いループを機械語にコンパイルしてよい。これは§17.4の実行時専用opcodeと同じく**観測可能な挙動を変えてはならない最適化**であり、イメージ・verifier・エラーメッセージ・step budget・`max_instructions`の計数に影響しない。

- **対象**: 後方jumpの先（ループ先頭）が一定回数（既定40）実行されたloop。コンパイルは**元の（quickening前の）命令列**から行う（処理系はquickening前の複製を保持する）。ループ内の命令が次のものだけのとき対象になる: 定数・ローカル・モジュール変数の読み書き、`+ - * / // %`、単項`-`、比較と条件分岐（`and` / `or` / `not` を含む）、`JUMP`、`GET_INDEX` / `SET_INDEX`（array）、`RANGE_PREP` / `RANGE_NEXT`、`FOR_NEXT`（array）、`array.append`、`len(array)`、`math.sqrt/sin/cos/exp/tan/atan`。`LOAD_UPVAL` / `STORE_UPVAL`、`GET_MEMBER` / `SET_MEMBER`（instanceのフィールド）、Sprint関数・メソッド・クラスの`CALL` / `INVOKE`（下記）も含められる。それ以外（組込み関数の呼出し・割当て・例外・member参照など）を含むloopはコンパイルせず、インタプリタが実行する。
- **型の仮定**: ループ入口で、ループ内で先に読まれる変数の型（int / float / bool / array）を検査する。外れれば入口で何も実行せずインタプリタへ戻る。
- **出口**: コンパイル済みコードは本物のframeとoperand stackの上で動く。ループを出るとき、および次のいずれかが起きるときは、**その命令が効果を持つ前に**（pcとstack高さを指定して）インタプリタへ戻り、インタプリタが同じ命令を実行する: 整数オーバーフロー、0除算、`sqrt`の負数・NaN、範囲外のindex、型の不一致、`array.append`の容量不足、step budgetの枯渇。したがってエラーの種類・位置・メッセージ・トレースはインタプリタと同一になる。
- **step budget**: 後方jumpと`len` / `math`の呼出しごとに§17.8の1ステップを消費する。
- **関数のコンパイル**: 約40回呼ばれた関数（引数の個数が固定、デフォルト値・可変長なし）は関数全体をコンパイルし、`RETURN` / `RETURN_NIL`も含められる。コンパイル済みコードからの`CALL`は、呼出し先がコンパイル済みの通常のSprint関数で、引数の個数・step budget・フレーム数・stackの余裕が足りるときに、インタプリタの`OP_CALL`と同じ`Frame`（`fn` / `base` / `kind = FK_NORMAL` / `dbase`、呼出し元の`pc`は`CALL`の次）を積んでネイティブに呼ぶ。条件を満たさなければ**`CALL`の効果が起きる前に**出口を取り、インタプリタが実行する。出口はネイティブ呼出しの階層全体を巻き戻し、最も内側のフレームのpcとstack高さを指す（フレームはすべて本物なのでトレース・例外・`RETURN`はインタプリタのものと同一）。呼出しの後はモジュール変数の型の仮定を捨てる。
- **オブジェクト**: instanceのフィールド参照・代入は、受け手のクラスが想定と同じことを検査（クラスのポインタ比較）したうえで固定のスロットを読み書きする。メソッド呼出しも受け手のクラスを検査し、メソッドと受け手を一つ上に詰めてからネイティブ呼出しする（インタプリタの`INVOKE`と同じ並び）。`Class(args)`はインタプリタの構築fast path（§10.3）と同じ手順で、`init`を`FK_CTOR`のフレームで呼び、そのフレームは戻り値の代わりに新しいinstanceを返す。コンパイル済みコードが参照するclassとmethodはGCの根として保持される。割当てはCのヘルパを呼ぶので、その前にoperand stackを実際のスタックに揃える。
- **無効化**: `--no-jit`、環境変数`SPRINT_JIT=0`。`SPRINT_JIT_THRESHOLD=N`はしきい値、`SPRINT_JIT_DEBUG=1|2`は経過の出力、`SPRINT_JIT_DUMP=FILE`はコンパイルした機械語の書き出し（開発用）。`SPRINT_GC_STRESS=1`は割当て点ごとにGCを走らせる開発用の指定。`-DSP_NO_JIT`、x86-64でない環境、Sprint OSではJITなしでビルドされる。
- **検証**: `make test-jit`は全テストをしきい値1（最初の後方jumpで即コンパイル）で実行し、出力・終了コードがインタプリタと一致することを確かめる。`tools/jitfuzz.py`は乱数生成した数値ループ（算術・配列・分岐・入れ子・break/continue）と、関数呼出し・再帰・クロージャ・モジュール変数の書換え・例外を混ぜたプログラム（`calls`モード）、クラス・継承・メソッド呼出し・構築を混ぜたプログラム（`oop`モード、GCを毎回走らせる実行も比較）を`SPRINT_JIT=0`としきい値1/3のJITで実行して比較する。
- **実装**: `src/runtime/jit.c`（領域コンパイラ）と`src/runtime/jit/stencils.S`（ステンシル）。`make jit-regen`が`tools/jitgen.c`で`stencils.S`のオブジェクトを読み、再配置から穴の位置を取り出して`src/runtime/jit/stencils.h`を生成する（生成物はリポジトリに含める）。

### 17.11 ディスパッチ（2.13.0）

`run_loop` は `switch` に加え、頻出命令の末尾に「次の命令へ直接ジャンプ」する `NEXT()`（GNU拡張のラベルアドレスによる間接ジャンプ表 `dtab`）を持ちます。表に載っていない命令は従来どおり `switch` に戻ります（`L_slow`）。命令の意味・エラー・命令数の勘定（`TICK`）は変わりません。ラベルアドレスは `-pedantic` では警告になるため、該当箇所だけ `#pragma GCC diagnostic ignored "-Wpedantic"` で囲んでいます。

### 17.12 インライン展開（2.14.0）

JITは、分岐・呼出し・アロケーション・モジュール変数アクセスを持たない短い関数を、呼出し元の領域に直接展開します（`inl_candidate`）。展開した本体のオフセットは `bias`（呼出し先フレームの基底）を足して表され、引数のスロットがそのまま呼出し先のローカルになります。本体内のガード失敗は `JExit.ictx`（展開した呼出しの番号）を持つ出口になり、`jit_finish` が `Frame` を積み直し（呼出し元の `pc` は呼出しの次の命令、`sp` は呼出し先のスタック深さ）、インタプリタが呼出し先の途中の命令から続行します。展開できない場合は従来の `ucall` / `uinvoke` に戻ります。

### 17.13 レジスタ一時値とローカルのミラー（2.17.0）

JITは、型が分かっている純粋な値（インスタンスのフィールド、配列の要素、`+ - * /` と `math.sqrt` の結果）を、16バイトのスタックスロットではなくマシンレジスタ（整数・配列ポインタは `rsi rdi r8-r11`、浮動小数点は `xmm1-xmm7`）に置きます（スタックの項目種別 `EK_REG`）。`EK_REG` は定数やローカル読み出しと同じ「保留中の値」として扱われ、ガードが外れたときの再開点は保留中の最も古い項目の `pc` になります（その後の純粋な命令は全部インタプリタが再実行する）ので、出口の側はレジスタを知る必要がありません。`EK_REG` を理解するのは `GET_MEMBER`・`GET_INDEX`・`SET_MEMBER`・`SET_INDEX`・四則演算・比較分岐・`STORE_LOCAL`・`math.sqrt` の処理だけで、それ以外の命令の前では必ず値をスロットに書き戻します（`flush_regs`）。結果をレジスタに残せるのは、最も下の入力が保留中の項目のとき（再実行で作り直せるとき）に限ります。

`STORE_LOCAL` したレジスタ値は、ローカルのメモリ（常に正本。タグは既に正しければ書かない）に書き込んだ上で、そのレジスタをローカルのミラーとして持ち続けます（write-through）。同じ基本ブロック内で後続の命令がそのローカルを読むとき、メモリを読み直さずにミラーを使います。ミラーはラベル、レジスタを理解しない命令、そのローカルへの別の書き込みで捨てます。メモリが常に正しいので、出口で書き戻す処理はありません。`SPRINT_JIT_REGS=0` で無効化できます。検証用に `tools/jitfuzz_reg.py`（配列・フィールド・比較・格納をランダムに組み合わせ、途中で型を変えて出口を起こす）があります。

### 17.14 コンストラクタ展開・upvalueレジスタ化・range特化（2.18.0〜2.20.0）

- **コンストラクタ展開（2.19.0）。** `Class(args)` の `init` が直線コード（フィールド代入・算術・upvalueのみ）なら呼び出し元に展開します。割り当てはスロット数と既定値をコンパイル時に埋め込んだヘッダ初期化で行います。`init` の途中でガードが外れた場合、インタプリタ側に構築フレーム（`FK_CTOR`）を作り、`jit_finish` が続きから再開します。展開できなければ呼出しと引数を元の位置に戻し、従来の経路を使います。意味はインタプリタと同一でなければなりません（MUST）。
- **upvalueのレジスタ化（2.18.0）。** 領域内で繰り返し読み書きされるupvalueの値をレジスタに写します。メモリ（セル）が正本で、書込みは常にセルへ通します（write-through）。
- **range特化（2.20.0）。** `RANGE_PREP` のステップが即値の整数定数（0以外、int32に収まる）で、同じ領域内の `RANGE_NEXT`（インライン本体の外）がそれを使うときだけ、符号別ステンシル `range_up` / `range_dn` を使います。ステップが不明な場合は `range_next`（符号判定あり）です。どちらも、前進が整数オーバーフローするときは stop に丸めて終了します（MUST）。
- **インライン本体のミラー（2.21.0）。** 展開した本体でも、2回以上読まれるローカルを `lc_*` でレジスタに写します。メモリが正本（write-through）である点、非reg-awareな命令の前に全ミラーを捨てる点は本体の外と同じです。ミラーのキーは呼び出し文脈ごとに分け、本体の終端（`RETURN`）で必ず解放します（MUST）。
- **入れ子のインライン展開（2.22.0）。** 展開した本体の `LOAD_MODULE`（現在クラスを保持するモジュール変数のみ）＋ `CALL` は、`do_construct` によりコンストラクタを展開します。条件: 本体の外側がコンストラクタでないこと、クラスのエントリが本体のスタック底にあること、入れ子は1段まで。展開できなければ本体全体を展開せず通常呼び出しに戻します（MUST: 入れ子の中で `uctor` 経路には落とさない）。出口は `JIctx.parent` の連鎖をたどり、外側から順にフレームを積んで、最内のフレームだけに出口の pc と深さを与えます。インタプリタが同じ呼び出しを実行した場合と、フレームの並び（トレース）が一致しなければなりません（MUST）。
- **インライン呼び出しの資源検査（2.23.0）。** ループ領域では、インライン呼び出しが必要とするフレームとスタックの余裕を領域に入るときに一度だけ検査します（領域内のどのインライン箇所も、領域のフレームの上でしか実行されないため、`nframes` と `r12` は領域の実行中に変わりません）。検査に落ちた場合は領域に入らず、インタプリタがそのまま実行します（MUST: 領域内で個別に出口を作ってはならない）。関数ユニットは再帰で `nframes` が変わるため、各インライン箇所で検査します。命令数の予算の計上（`decq ILEFT`）はインライン呼び出しごとに残します（MUST）。
- **upvalueのミラー（2.24.0）。** 値の写し（型付き、`lc` の `up == 1`）はどのupvalueへの書き込みでも捨てます。セルのアドレスの写し（`up == 2`）はセルが差し替わらない限り有効で、インライン本体への出入り（別のクロージャ）で捨てます。どちらもメモリが正本です（MUST: 書込みは常にセルへ通す）。
- **rangeの刻みの入口検査（2.24.0）。** 領域が `RANGE_PREP` より後から始まる場合、領域のコンパイル時の刻み（0以外・int32）を即値にし、入口で一致を検査します。一致しなければ領域に入りません（MUST）。`walk` のたびに刻みの記録を捨てます。
- **モジュール変数の型（2.24.0）。** インスタンスを持つモジュール変数は `TY_INST` とクラスを持ち、領域の入口で `gcls_mod` により検査します。変数は領域の間ひとつのクラスしか持てません（別クラスの保存で型は不明に戻る）。呼び出しの後は型を捨てます（MUST）。
- **Cヘルパー呼び出し: 表・文字列連結（2.25.0）。** `GET_INDEX`（表・文字列。配列は従来のインライン経路）、`SET_INDEX`（表）、`CONCAT` を、ステンシル `hget` / `hset` / `hconcat` から C ヘルパー（`jh_getidx` / `jh_setidx` / `jh_concat`）を呼んで処理します。ステンシルは呼ぶ前に `vm->sp` を公開します（GC がスタックを走査できるように。MUST）。ヘルパーは扱えない場合（レシーバーが表でない、キーが nil/NaN、欠けたキー、連結のオペランドが int/string 以外、エラーになる場合）には何も変更せず 0 を返し、ステンシルは `JIT_X` へ飛んでインタプリタが同じ命令を実行します（MUST: 0 を返す前にスロットを書き換えない）。GC の確認はヘルパーの先頭で行い、確認の後に古いポインタをスロットへ残しません。
- **文字列実行時の軽量化（2.25.1）。** (1) `sp_fmt_int` は2桁テーブルで末尾から書く。(2) `concat_fast` は先に桁数を数えて文字列を確保し、整数を結果へ直接書く（一時バッファと長さ配列を廃止。整数オペランド数の上限16も廃止）。`int_len` と `sp_fmt_int` の桁数は常に一致しなければならない（MUST: 境界値は `tests/cases/lang/int_concat.sp`）。(3) 文字列ハッシュは FNV-1a（1バイトずつ）のまま。8バイト単位版は命令数が減ったが tbl で約6%遅かった（直前に狭いストアで書いたバイト列を広いロードで読むと store-forwarding できないため）。命令数でなく時間で判断すること（MUST: 変更時は `tools/bench/tbl.sp` を新旧交互で測る）。ハッシュ値はメモリ内でのみ使い、イメージには保存しない。
- **純粋なネイティブ関数のヘルパー呼び出し（2.26.0）。** `math.abs / min / max / clamp / floor / ceil / trunc / round / log / asin / acos / atan2 / is_nan / is_inf / is_finite / is_close`（`math_pure_native`）と、配列以外に対する組み込みの `len` を、ステンシル `hnat` から C ヘルパー `jh_nat` 経由で呼びます。呼び出し前に `vm->sp` を公開し（MUST）、スタックの項目を全てメモリへ書き戻します。ネイティブがエラーを返した場合、または結果の型が予測（H4。`nat_result_ty` が引数の型と名前から決める）と違う場合は、保留中のエラーを元に戻し（`pend_code` / `pend_obj`）、何も書かずに 0 を返して、インタプリタに同じ呼び出しを再実行させます。このため対象は副作用も確保もない関数に限ります（MUST NOT: 出力・確保・状態変更のある関数を追加しない）。
- **テーブルの for-in（2.27.0）。** `for k, v in table` / `for k in table` を、ステンシル `tnext` から C ヘルパー `jh_tnext` を呼んで処理します。ヘルパーはインタプリタと同じループ状態（テーブル・カーソル・版）を直接進めます。状態が不正、または版が変わっている（反復中の変更）ときは 0 を返し、何も書かずにインタプリタへ戻って同じ `FOR_NEXT` を実行します（エラーはインタプリタが出す。MUST）。終了は 2（`JIT_T`）。反復の途中でテーブルが別の型に変わっても、ヘルパーが毎回型を検査するので安全です。
- **モジュール変数のレジスタ入出力（2.28.0）。** 型が分かっている（`TY_INT` / `TY_FLT` / `TY_INST`）モジュール変数の `LOAD_MODULE` は、スタックのスロットへ16バイトを写す代わりに、値を直接レジスタへ読み（`EK_REG`、再実行可能な保留中の値）、`STORE_MODULE` はレジスタからモジュールスロット（`r14`）へ直接書きます。両命令は `reg_aware` です。`STORE_MODULE` は、その前にスタックに残っている他のレジスタ項目を先にメモリへ書き戻します（保留中の鎖が古い値を再読み出ししないため。MUST）。タグは、変数の型が変わるとき、または入口で検査されていないときだけ書きます。型が不明な変数は従来どおりスロット経由（未初期化の検査があるため）。ゲートは `jit_modreg.sp`。
- **インライン化コンストラクタの下の保留項目（2.28.1）。** インライン本体内のガード出口は、呼び出し元のスタックを「メモリ上にある状態」としてその上でインタプリタを再開します。したがって `do_construct` は、クラス（`pf`）より下に保留中の項目があるとき（`pf > pos0`）、インライン化の前に `flush_from(c, c->pos0, pf)` で必ずメモリへ書き戻さなければなりません（MUST）。これを欠くと `a + P(x).v` で `a` の古いスロットが読まれました。`do_call` と `do_invoke_inst` は従来から `d0..dep` を書き戻しており、入れ子の呼び出し/コンストラクタは `pos0` 直上に限定されるため安全です。ゲートは `jit_pending_ctor.sp`。
- **型付き配列の添字（2.29.0）。** `a[i]` / `a[i] = v` の `a` が、コンパイル時に見た値で `typed` の配列（`T_NATIVE`で、クラスが`typed_classes`の中）なら、`do_get_index_ta` / `do_set_index_ta` が機械語を出す: ①スロットのタグが`T_NATIVE`、②オブジェクトの`cls`がその種類のクラスと同じ、③添字が`len`未満（符号なし比較）、のガードのあと、`data + 16 + (i << shift)`の要素を符号/ゼロ拡張（`movsx` `movzx` `movsxd`）または`cvtss2sd` / `movsd`でレジスタへ読む（結果は`EK_REG`、`TY_INT` / `TY_FLT`）。書き込みは値を`rdx`（整数）か`xmm0`（浮動小数点。intの値は`cvtsi2sd`、`f32`は`cvtsd2ss`）に置き、幅に合わせて切り詰めて書く。ガードのどれかが外れる（別の種類、範囲外、非intの添字）と、通常の出口（`gexit`）でインタプリタが同じ命令を再実行し、エラーを出す。書き込みの値が決して保存できない型（intの配列へのfloatなど）のときと、配列がスロットにない（`EK_REG` / `EK_MOD`）ときは、`hget` / `hset`のヘルパ経由になる。書き込みの前に、配列より下の保留項目をメモリへ書き戻す（`flush_from`、通常のarrayの書き込みと同じ理由。MUST）。`for x in a` は、`OP_FOR_PREP`が配列そのものをループ状態（配列、カーソル、0）に置き、`OP_FOR_NEXT`が`typed_peek`で要素を取る（arrayと同じ形）。JITは`jh_anext`（tableの`tnext`ステンシルと同じ形のヘルパ。0 = インタプリタへ、1 = 次の要素、2 = 終わり）で翻訳する。（2.30.0）添字命令（`OP_GET_INDEX` / `OP_SET_INDEX`）はインライン化できる本体にも許される（`inl_candidate`、`inl_body`）。本体の中では`c->d0 == c->pos0`で、呼び出し元の保留項目は呼び出し前にメモリへ書き戻されている（`do_call` / `do_invoke_inst`）ので、ガードが外れたときの再開はこれまでの`OP_GET_MEMBER`と同じ規則で成り立つ。ファザー`tools/jitfuzz_inlidx.py`がこの組み合わせを検証する。インタプリタ側も`OP_GET_INDEX` / `OP_SET_INDEX` / `OP_Q_LL_IDX`に専用の分岐を持つ。ゲートは`jit_typed.sp`、ファザーは`tools/jitfuzz_typed.py`。
- **値としての比較・`and` / `or`・nil 比較（2.31.0）。** ①`OP_LT..OP_NE`の直後に融合できる条件分岐がない（または`NOT`を挟んだ）場合、`do_cmp_value`が両辺（整数どうし、または浮動小数点どうしで`< <= > >=`）をレジスタで比べ、`setcc al`＋`movzx`でbool（`EK_REG`、`TY_BOOL`）を作る。`NOT`が続くときは条件コードの最下位ビットを反転する（`cc ^= 1`。整数でも、`ucomisd`の非順序（NaN）でも正しい。`a`→`be`、`ae`→`b`はNaNで真になり、`not (n < 1.0)`と一致する）。②`OP_JUMP_IF_{TRUE,FALSE}_OR_POP`は`do_orpop`が処理する: レジスタとスタックを全部メモリへ書き戻してから`set_target`を呼び（その時点のモデルが合流点の状態）、値のスロットを`bbr_*` / `tbr_*`で調べて分岐し、フォールスルー側で`dep--`する。値の型が`INT / FLT / ARR / INST`なら常に真なので分岐を出さない（OR_POPが真で飛ぶ場合は無条件ジャンプ）。③合流点（リーダー）では`merge_to`が、`[d0, dep)`の全項目が`EK_MEM`であること（MUST。値は必ずメモリにある）と、リーダーごとの深さ`ldep`が一致することを検査する。フォールスルーで到達するときは、`flush_regs`と`flush_from`のあとに`merge_to`を呼び、復元した状態に`ldep`個の`EK_MEM / TY_UNK`を積む。④`x == nil` / `x != nil`の後に融合できる分岐が続くとき（`??`は`DUP; NIL; NE; JUMP_IF_TRUE; POP`）、`do_nil_branch`が、型が`INT / FLT / BOOL / ARR / INST`なら静的に分岐を決め、そうでなければスロットのタグが0（nil）かを調べるステンシル`nilbr_t` / `nilbr_f`を出す（`value_eq`は演算子の再定義を持たないのでタグ比較で足りる）。`NOT`を挟むときは`jop`を反転する。ゲートは`jit_boolval.sp` / `jit_nilbr.sp`、ファザーは`tools/jitfuzz_bool.py`。
