## 14. module・package

### 14.1 moduleとmodule名

- 1つの`.sp`ファイルが1つのmoduleである。`module`文はない。
- module名はsearch root（§14.3）からの相対pathの`/`を`.`に、拡張子を除いたもの。`src/net/http.sp` → `net.http`（rootが`src`の場合）。
- module名の各要素は識別子でなければならない。
- エントリファイルのmodule名は、そのファイルがsearch root内にあればその名前、なければbasename（拡張子除去）。

### 14.2 import

```sprint
import net.http              # 名前 http に束縛
import net.http as h         # 名前 h に束縛
from net.http import get, post as send
```

- importはファイル先頭の連続したimport群にだけ書ける（§4.3）。
- `import a.b.c`は最後の要素`c`に束縛する。名前が衝突すればコンパイルエラー（`as`で回避する）。
- `from M import x`は`M`のexport`x`への**読み取り専用のlive束縛**を作る。`M`側で`x`が再代入されれば、importした側からも新しい値が見える。
- importした名前（module束縛、`from`束縛）への代入はコンパイルエラー`ConstError`。
- module値のメンバ（`m.x`）は、`m`がimport束縛であればコンパイル時に存在を検査する（§5.3）。

### 14.3 検索順（正本）

`import a.b`は`a/b.sp`を次の順に探し、最初に見つかったものを使う。

1. **builtin module**（`math`, `str`, `table`, `coroutine`, `io`, `fs`, `time`, `sys`, `json`, `random`, `gc`, `gfx`, `typed`, `_ffi`）と**同梱module**（`gui`, `ffi`。Sprintソースで書かれ処理系のバイナリに埋め込まれる。module pathは`<std>/gui.sp`）。これらの名前で始まるユーザーmoduleは作れない（同名ファイルは無視され、`lint`がwarningを出す）。
2. **package source root**: エントリファイルのdirectoryから親方向へ`Sprint.toml`を探し、見つかればその`source_root`。見つからなければエントリファイルのdirectory。
3. **依存package**: `Sprint.toml`の`[dependencies]`に列挙した順に、各依存の`vendor/<name>/<source_root>`。
4. **`SPRINT_PATH`**: 環境変数の要素（POSIXは`:`区切り、Windowsは`;`区切り）を先頭から。

- `Sprint.toml`の`source_root`は、そのファイルがあるdirectory基準の相対path。キーがなければ`Sprint.toml`のdirectoryがrootになる。
- builtin module名で始まる**ドット付き**名（例: `math.extra`）はImportError。単独の名前（`math`）はbuiltinが常に優先される。
- カレントディレクトリは暗黙に追加しない。
- pathは正規化する。symlinkを解決した実体pathがそのsearch rootの外にあればImportError。
- 同じ実体ファイルが2つの異なるmodule名で到達された場合はImportError（重複module）。
- 未発見・循環・重複はすべて**実行前**に検出し、終了コード4で終了する。

### 14.4 export

- `export let` / `export const` / `export func` / `export class`だけがmodule外から見える。
- exportはlive・read-onlyの束縛である。`export let`の値をmodule内で更新すれば、importした側から新しい値が見える。

### 14.5 初期化順（H5）

1. module graphを構築し、すべてのmoduleをコンパイル・verifyする（ここまでで失敗すれば何も実行しない）。
2. 初期化順を決める: エントリmoduleから、import文の出現順に深さ優先で辿った**帰りがけ順**（依存先が先）。
3. 各moduleについて順に:
   1. module top-levelのすべての`func`宣言の関数値と`class`宣言のclass値を、宣言順に生成する（class値の生成は親classのclass値を必要とするため、同一module内では親を先に宣言しなければならない。違反はコンパイルエラー）。
   2. module本体を上から1回だけ実行する。
4. エントリmoduleの本体の終了がプログラムの終了である（`main`関数の規約はない）。

module初期化中のerrorは通常の未処理errorとして扱う（終了コード1）。

### 14.6 package manifest `Sprint.toml`

```toml
name = "example"
version = "0.1.0"          # semver
entry = "src/main.sp"
source_root = "src"

[dependencies]
jsonx = { version = "1.2.0", path = "vendor/jsonx" }
```

- 依存は`vendor/`以下に置かれたものだけを使う。ネットワークからの自動取得はしない。
- `Sprint.lock`がある場合、各依存の`version`と、依存の全`.sp`ファイルのSHA-256（path順に連結したもののSHA-256）を検証する。不一致は終了コード4。
