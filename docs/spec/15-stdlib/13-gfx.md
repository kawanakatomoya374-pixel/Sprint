### 15.13 gfx（2.1）

ソフトウェア描画のcanvasと、PNG / PPM / BMPへの書き出し。ウィンドウ・入力・時計には触れない（GUIを表示するのではなく、**画像を生成する**moduleである）。描画はすべて整数演算で、同一の呼出し列は**どの処理系・どの環境でも同一のピクセル・同一のファイルバイト列**を生む（§19.1の決定性の対象）。

`import gfx` で使う。canvasは`native`型（§6.1）の値で、型名は`native`、`to_string`は`<native canvas #ID>`（§6.5）。メソッドは呼出し形式（`c.line(...)`）でのみ使え、存在しないメソッドは`NameError`。

**数値の規則**（すべてのAPI共通）:
- 座標・サイズ・半径・scale・alphaは**int**でなければならない。floatは`TypeError`（`3.0`も不可。整数除算には`//`を使う、というヒントが付く）。座標の絶対値は2<sup>28</sup>以下（超過は`ValueError`）。範囲外へのはみ出しは**クリップ**され、エラーにならない。
- 色は`0x000000`〜`0xFFFFFF`の**int**（`0xRRGGBB`）。範囲外は`ValueError`。
- 原点は左上、xは右、yは下へ増える。

**module関数**:

| 関数 | 割当 | 仕様 |
|---|---|---|
| `gfx.canvas(width, height, background = 0)` | A | 新しいcanvas。1辺は`1..16384`、画素数は`16777216`以下（超過は`ValueError`）。ピクセルは`4 * width * height`バイトのブロックとして**ヒープに計上**される（`max_heap_bytes`、§18.2） |
| `gfx.rgb(r, g, b)` | — | 各成分`0..255`（範囲外は`ValueError`）から`(r << 16) \| (g << 8) \| b` |
| `gfx.hsv(h, s, v)` | — | `h`は度（任意のintを`0..359`へ折り返す）、`s`・`v`は`0..100`のint（範囲外は`ValueError`）。結果の定義は整数演算で次のとおり（実装間で一致させる）: `V = v*255/100`、`region = h/60`、`rem = (h%60)*255/60`、`p = V*(100-s)/100`、`q = V*(100-s*rem/255)/100`、`t = V*(100-s*(255-rem)/255)/100`、`(r,g,b)`は`region`が0..5で順に `(V,t,p) (q,V,p) (p,V,t) (p,q,V) (t,p,V) (V,p,q)`（`/`は切り捨て整数除算） |

**canvasのメソッド**（`c`はcanvas。割当はすべて「—」）:

| メソッド | 仕様 |
|---|---|
| `c.width()` / `c.height()` | 寸法 |
| `c.clear(color)` | 全画素を`color`にする。**alphaの影響を受けない** |
| `c.set_alpha(a)` / `c.alpha()` | 以後の描画に適用する不透明度`0..255`（範囲外は`ValueError`。既定255）。canvasごとの状態である（もう1つの隠れた状態はclip矩形） |
| `c.pixel(x, y, color)` | 1画素を描く（範囲外は無視） |
| `c.get(x, y)` | 画素の色（int）。範囲外は`IndexError` |
| `c.line(x0, y0, x1, y1, color)` | 端点を含む線分（Bresenham、誤差項は`dx + dy`の標準形） |
| `c.rect(x, y, w, h, color)` / `c.fill_rect(...)` | 枠 / 塗りつぶし。`w <= 0`または`h <= 0`なら何も描かない |
| `c.circle(cx, cy, r, color)` / `c.fill_circle(...)` | 中点法の円周 / 円板。`r < 0`は`ValueError` |
| `c.fill_triangle(x0, y0, x1, y1, x2, y2, color)` | 辺関数による塗りつぶし（辺上の画素を含む）。面積0の三角形は何も描かない |
| `c.text(x, y, s, color, scale = 1)` | 組込みの5×7ビットマップフォントで`s`を描く。`(x, y)`は文字列の左上。1文字の送りは`6 * scale`画素、改行（`\n`）は`8 * scale`画素下で`x`へ戻る。`scale`は`1..64`。ASCII `0x20`〜`0x7E`は5×7字形（送り6画素）、日本語（ひらがな・カタカナ・記号・JIS第1/2水準漢字など6726字）は12×12字形（送り`12 * scale`画素、IPAゴシック由来、ライセンスは`licenses/IPA-Font-License-v1.0.txt`）で描かれる。字形表に無いcode point（半角カナ・絵文字・一部のラテン文字など）は`?`になる。行の高さは`8 * scale`のままなので、日本語を複数行で描くときは行間を`12 * scale`以上にすること |
| `gfx.text_advance(s, scale = 1)` | 1行の文字列の送り幅の合計（最後の字間を含む）。ASCIIは`6 * scale`、日本語は`12 * scale`。レイアウト計算用でCanvasを必要としない |
| `c.text_width(s, scale = 1)` | `text`が使う幅（最長行、最後の字間を除く）。空文字列は`0` |
| `c.blit(src, x, y)` | canvas `src`の全画素を`(x, y)`へ複写する（クリップあり）。**描画先**のalphaが適用され、`src`のalphaは無視される。`src`がcanvasでなければ`TypeError` |
| `c.set_clip(x, y, w, h)` / `c.clear_clip()` | 以後の描画（`clear`を除く）を矩形`[x, x+w) × [y, y+h)`（canvas内へ丸める）に制限する / 解除する。canvasごとの状態で、`alpha`とともに隠れた状態である |
| `c.line_aa(x0, y0, x1, y1, color)` | anti-alias線（Wuの方法、16.16固定小数点の整数演算）。被覆率`0..255`を`alpha`に掛けて合成する |
| `c.round_rect(x, y, w, h, r, color)` / `c.fill_round_rect(...)` | 角丸の枠 / 塗りつぶし。`r`は`min(w, h) // 2`に丸められ、`r < 0`は`ValueError`。角の弧は整数の平方根で決まる |
| `c.gradient_rect(x, y, w, h, c0, c1, vertical = true)` | `c0`から`c1`への線形グラデーション（各チャンネルを整数で補間、四捨五入）。`vertical`が偽なら左から右 |
| `c.blit_part(src, sx, sy, w, h, x, y)` | `src`の矩形部分を`(x, y)`へ複写（範囲外の元画素は無視） |
| `c.blit_scaled(src, x, y, scale = 1)` | `src`を整数倍`1..64`（最近傍）に拡大して複写 |
| `c.hash()` | 寸法と全画素のFNV-1a 64bit（上位62bitを非負intで返す）。同一画像なら同一値 |
| `c.diff(other)` | 同寸法の2枚で異なる画素の数（寸法が違えば`ValueError`） |
| `c.save_png(path)` / `c.save_ppm(path)` / `c.save_bmp(path)` | ファイルへ保存する（下記） |

**alphaの合成**: alphaが255のときは上書き。それ以外は、描く色の各チャンネル`s`と下地の`d`について `(s*a + d*(255-a) + 127) / 255`（整数、切り捨て除算）を新しい値とする。

**保存**:
- capability `filesystem_write` が必要で、`path`は許可directory（`--allow-write`、§19.2）の下でなければならない（さもなくば`PermissionError`）。書込みは§15.7の`fs.write_file`と同様に、同じdirectoryの一時ファイルへ書いてからrenameする（atomic）。失敗は`IOError`（`data`は§15.7と同じ）。`path`が文字列でなければ`TypeError`。
- **PNG**: 8bit RGB（colour type 2）、インターレースなし。行ごとにフィルタ（none / sub / up）を、符号付きバイトの絶対値和が最小のものに選ぶ（同点はnone、sub、upの順）。圧縮はzlib形式の**固定Huffman符号**のdeflate（LZ77、窓32768、ハッシュ連鎖24）で、IDATは1チャンク。出力は完全に決定的（実装間でバイト一致）。
- **PPM**: バイナリ`P6`、`255`。**BMP**: 24bit、BI_RGB、下から上の行順、行は4バイト境界へ0詰め。
- 符号化中のバッファは一時的なC側の割り当てであり、`max_heap_bytes`には計上されない（画像の大きさの高々数倍）。

例（`examples/gfx/gfx_demo.sp`）:

```sprint
import gfx
let img = gfx.canvas(320, 200, gfx.rgb(135, 206, 235))
img.fill_circle(260, 50, 24, gfx.rgb(255, 220, 0))
img.fill_rect(60, 100, 120, 80, gfx.rgb(180, 90, 60))
img.text(10, 10, "Hello, Sprint!", gfx.rgb(0, 0, 0), 2)
img.save_png("scene.png")          # sprint run --allow-write=. demo.sp
```
