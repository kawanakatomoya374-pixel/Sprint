## 16. program image（`.spc`）形式

### 16.1 概要

- `sprint compile`は、エントリmoduleとそれが（推移的に）importするすべての非builtin moduleを1つの**program image**に格納する。
- 多バイト整数はすべて**little endian**。floatはIEEE-754 binary64のビット列をu64として格納する。
- 文字列は`u32 長さ + UTF-8バイト列`（NUL終端なし）。
- Compilerの出力は同一入力・同一オプションでバイト単位で同一でなければならない（タイムスタンプ・絶対pathを含めない。module pathはsearch rootからの相対path）。

### 16.2 ヘッダ（64バイト）

| offset | size | field | 値 |
|---:|---:|---|---|
| 0 | 4 | magic | `53 50 52 43`（"SPRC"） |
| 4 | 2 | format_major | `2` |
| 6 | 2 | format_minor | `0` |
| 8 | 4 | flags | bit0: debug info あり。他は0 |
| 12 | 4 | required_features | MAY機能bit集合（§16.6）。2.0では0 |
| 16 | 4 | header_size | `64` |
| 20 | 4 | reserved | `0` |
| 24 | 8 | payload_size | payloadのバイト数 |
| 32 | 32 | source_hash | 各moduleについてmodule表の順に「module名 + `00` + 正規化後source + `00`」を連結したもののSHA-256 |
| 64 | payload_size | payload | §16.3 |
| 64+payload_size | 32 | checksum | SHA-256(payload) |

- ファイル長が`64 + payload_size + 32`と一致しなければLoadError。
- **checksumを検証する前にpayloadを解釈してはならない。**
- reserved・未定義のflag bitが0でなければLoadError。

### 16.3 payload

payloadは次のsectionを**この順で1回ずつ**並べたものである（DEBUGはflags bit0が1のときだけ存在）。各sectionは`tag: u8, size: u32, 内容`。未知のtag、順序違反、sizeと内容の不一致、余剰バイトはLoadError。

| tag | section | 内容 |
|---:|---|---|
| 1 | STRINGS | `count: u32`、文字列×count。全プログラムの名前・文字列定数。重複なし、初出順（初出順はMODULES→PROTOS→CLASSES→LINKSの符号化順） |
| 2 | MODULES | `nslots: u32`、`slot_names: u32(str)×nslots`（全moduleで共有する**module変数slot空間**）、`count: u16`、module記述×count（初期化順 = §14.5） |
| 3 | PROTOS | `count: u32`、function prototype×count |
| 4 | CLASSES | `count: u32`、class記述×count |
| 5 | LINKS | `count: u32`、外部参照×count |
| 6 | DEBUG | prototypeごとの位置表 |

**module記述**: `name: u32(str)`, `path: u32(str)`（search rootからの相対path。entry moduleはファイル名）, `source_sha256: [32]`（正規化後sourceのSHA-256）, `entry_proto: u32`, `export_count: u16`, `exports: (name: u32(str), slot: u32)×export_count`。

**header source_hash**: 各moduleについて、module表の順に「module名のUTF-8バイト列 + `00` + `source_sha256`（32バイト）」を連結したもののSHA-256。

**prototype**:

```text
name          u32 (str, 無名は0xFFFFFFFF)
module        u16
flags         u8  (bit0: has_rest, bit1: is_module。他は0)
nparams       u8  (rest引数を含まない)
nrequired     u8
nlocals       u16 (パラメータ・rest・隠しスロットを含む)
max_stack     u16
nupvals       u16
upvals        (from_parent_local: u8, index: u16) × nupvals
nconsts       u16
consts        定数 × nconsts
ndefaults     u8  (= nparams - nrequired)
default_pcs   u32 × (ndefaults + 1)   最後の1つは本体の開始pc
code_len      u32
code          u8 × code_len
```

**定数**: `tag: u8`に続けて、`0`=nil、`1`=false、`2`=true、`3`=int（i64）、`4`=float（u64ビット列）、`5`=string（u32 str index）。

**class記述**: `name: u32(str)`, `method_count: u16`, `method_names: u32(str)×method_count`（CLASS命令がstackから受け取る関数と同じ順）, `field_count: u16`, `field_names: u32(str)×field_count`（自classの分のみ）, `ctor_proto: u32`（コンパイラが生成するコンストラクタ。upvalueを持たない）。親classは実行時にstackの値から決まる（`nil`または`class`）。

**外部参照（LINK）**: `kind: u8`（0=prelude関数、1=builtin moduleのexport、2=builtin module値）, `module: u32(str)`（kind 0では0xFFFFFFFF）, `member: u32(str)`（kind 2では0xFFFFFFFF）。ロード時に解決し、解決できなければLoadError。ユーザーmoduleへの参照はLINKではなく、共有module変数slotへの`LOAD_MODULE`/`STORE_MODULE`で表す。

**DEBUG**: 各prototypeについてprototype順に`count: u32`、`(pc: u32, line: u32, column: u32) × count`（pc昇順）。各命令の位置は「pc以下で最大のentry」とする。

### 16.4 ロード時の生成

ロードは割り当てを行う（実行前のため§1.3の対象外）。生成順は決定的でなければならない: STRINGSの文字列オブジェクトを表の順、次にmodule値をMODULESの順に生成する（module値のオブジェクトIDはこの順に割り当てる、§6.3）。`sprint run`（imageを経由しない実行）も、同じ入力から`compile`した場合と同じ順で生成しなければならない。

### 16.5 source mismatch

traceを表示する際、`debug-info`を持つimageのsource fileがディスク上に存在し、そのSHA-256が`source_sha256`と異なれば、trace行に`(source changed)`を付ける。実行は妨げない。

### 16.6 版の規則（MAY機能を含む）

1. **format_major**: 既存opcodeの番号・operand・意味の変更、opcodeの削除、header・section・prototype・定数形式の変更、Value tagの変更、検証規則の緩和以外の変更は、すべてmajorを上げる。loaderは自分と異なるmajorを拒否する（LoadError）。
2. **format_minor**: 未使用番号への新opcodeの追加、新しいMAY機能bitの定義だけを含む変更はminorを上げる。loaderは自分の対応minorより大きいminorを拒否する。小さいか等しいminorは受理する。
3. **MAY機能**:
   - bytecodeに影響するMAY機能は、仕様で`required_features`のbitと、opcode番号の範囲**0xE0–0xEF**内の番号を割り当てられる。新しい割り当てはminorを上げる。
   - Compilerは`--enable=FEATURE`が指定されたときだけ、その機能のbitを立て、その機能のopcodeを出力してよい。指定がなければ機能bitは0で、該当opcodeは出力しない。
   - loaderは、未対応の機能bitが立っていればLoadErrorとする。bitが立っていない機能のopcodeが現れたらLoadError。
   - MAY機能を必須に格上げする、または既存の機能opcodeの意味を変える場合はmajorを上げる。
4. **実装独自拡張**: opcode **0xF0–0xFE**を使える。これを含むimageは`required_features`のbit31を立てなければならず、他の実装はLoadErrorとする。`sprint compile`は既定で実装独自opcodeを出力してはならない。
5. **0xFF**は永久に無効なopcodeである。
6. Sprint 2.0（format 2.0）で定義されたMAY機能はない。`required_features`は0、`sprint features`は空の一覧を表示する。
