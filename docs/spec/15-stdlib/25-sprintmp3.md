### 15.25 sprintmp3（MP3 デコーダー）

`import sprintmp3`。minimp3（CC0）をベースに、Sprint だけで書いた MPEG Audio Layer III デコーダー（同梱 module、capability 不要）。定数表は `tools/mp3/gen_tables.py` が minimp3 のソースから機械的に抽出して `stdlib/mp3tab.sp` を作る。

| 関数 | 割当 | 仕様 |
|---|---|---|
| `sprintmp3.decode(data)` | A | `data`は string・0〜255のintのarray・`typed.u8`。`{sample_rate, channels, frames, samples}`を返す。`samples`はインターリーブされた`typed.i16`（`frames * channels`個）。MP3 フレームが 1 つも無ければ ValueError |
| `sprintmp3.info(data)` | A | ヘッダだけを走査する（デコードしない）。`{sample_rate, channels, bitrate_kbps, layer, frames, samples}` |
| `sprintmp3.Decoder()` | A | ストリーム用。`d.decode_frame(buf, offset, bytes_left, pcm, pcm_offset)`が 1 フレーム分を`pcm`（`typed.i16`、`nil`ならヘッダだけ）へ書き、`{samples, frame_bytes, frame_offset, channels, hz, layer, bitrate_kbps}`を返す。`d.reset()` |

対応: MPEG-1 / 2 / 2.5 Layer III、モノラル・ステレオ・ジョイントステレオ（MS・インテンシティ）、ロング / ショート / ミックスブロック、ビットリザーバ、フリーフォーマット、CRC。先頭の ID3v2、末尾の ID3v1、Xing / Info / VBRI フレームは読み飛ばす。**Layer I / II は未対応**（そのフレームは無音扱いで読み飛ばす）。LAME のエンコーダー遅延は取り除かない（ffmpeg は既定で取り除く。先頭 1105 サンプルを捨てれば一致する）。

演算は倍精度で、出力は minimp3 と同じく 0.5 を足して 0 から遠い向きへ丸め、int16 に飽和させる。float32 のデコーダー（ffmpeg の `mp3float`）との差は最大 1.5 LSB（=丸めだけの差）。

検証: `python3 tools/mp3/check.py`（ffmpeg + libmp3lame と numpy が必要）が、44.1 / 48 / 32 / 22.05 / 16 / 8 kHz、ステレオ・ジョイント・モノラル・VBR の 10 通りを ffmpeg の出力と比較する（全件が 2 LSB 以内、ショートブロックを含む）。インテンシティステレオとミックスブロックは LAME が作らないため、移植のみで実ファイルでは未検証。`tests/cases/stdlib/sprintmp3.sp` は小さな 2 本の MP3 を埋め込み、`make test`でチェックサムを確かめる。
