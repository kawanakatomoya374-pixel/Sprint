### 15.23 image（BMP / PNG / JPEG デコーダー）

`import image`。Sprint だけで書かれた画像デコーダー（同梱 module、capability 不要）。

| 関数 | 割当 | 仕様 |
|---|---|---|
| `image.decode(data)` | A | `data`は string・0〜255のintのarray・`typed.u8`（`fs.read_bytes`の結果など）。形式は先頭のバイトで判定する。`{width, height, rgba}`を返す。`rgba`は`typed.u8`で、上の行から順に`R, G, B, A`（`width * height * 4`バイト）。壊れた・未対応のデータはValueError |
| `image.format(data)` | — | `"png"` / `"jpeg"` / `"bmp"` / `nil` |

**BMP**: 1・4・8ビット（パレット、RLE4 / RLE8 も）、16ビット（555 とビットフィールド）、24ビット、32ビット（ビットフィールド）、上下どちら向きも。OS/2 の 12 バイトヘッダも読む。
**PNG**: 全カラータイプ・ビット深度（1・2・4・8・16）、`tRNS`、Adam7 インターレース。zlib（inflate）は内蔵（`image.inflate(data, start, zlib)`も公開）。
**JPEG**: ベースライン、拡張シーケンシャル、プログレッシブ（Huffman、8ビット）、任意のサンプリング比、リスタート間隔、グレースケール・YCbCr・RGB・Adobe CMYK / YCCK（CMYK は近似）。逆DCT・色差の「fancy」アップサンプリング・色変換は libjpeg（`jidctint.c`・`jdsample.c`・`jdcolor.c`）と同じ整数演算なので、**libjpeg-turbo と同じ画素**になる。算術符号化と可逆 JPEG は未対応。

検証: `python3 tools/image/check.py`（PIL が必要）が、PNG 38 枚・BMP 20 枚・JPEG 74 枚（ベースライン / プログレッシブ、4:4:4 / 4:2:2 / 4:2:0、グレー、リスタート、最適化 Huffman）を PIL の出力と画素単位で比較する（全件一致）。`tests/cases/stdlib/image_basic.sp` は小さな画像で同じことを`make test`で確かめる。
