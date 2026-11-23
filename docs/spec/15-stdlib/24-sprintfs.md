### 15.24 sprintfs（SprintFS）

`import sprintfs`。Sprint だけで設計・実装した、ジャーナル付きの独自ファイルシステム（同梱 module、capability 不要。デバイスはブロックデバイスを模したオブジェクト）。

```sprint
import sprintfs
let dev = sprintfs.MemDevice(2048, 4096)       # 2048ブロック x 4096バイト
sprintfs.mkfs(dev, {label: "data"})
let fs = sprintfs.mount(dev)
fs.mkdir("/docs")
fs.write_file("/docs/hello.txt", "hello")
print(fs.read_file("/docs/hello.txt"), fs.listdir("/docs"))
fs.unmount()
print(sprintfs.fsck(dev).ok)                    # true
```

**ディスク形式**（リトルエンディアン、ブロックサイズ 1024〜65536、既定 4096）
- ブロック 0 がスーパーブロック（最後のブロックにバックアップ。CRC32C 付き）。続いてブロックビットマップ、inode ビットマップ、inode 表、ジャーナル、データ領域。
- inode は 256 バイト（モード、uid / gid、リンク数、サイズ、atime / mtime / ctime、CRC32C）。ファイルは**エクステント**（論理ブロック・長さ・物理ブロック）の列で、inode 内に 6 個、拡張ブロックにさらに 255 個。穴（スパース）を持てる。短いシンボリックリンクは inode の中に入る。拡張属性（xattr）は 1 ブロック。
- ディレクトリは `{inode, レコード長, 名前長, 種類, 名前}` の並びのブロックで、各ブロックの末尾に CRC32C。名前は 255 バイトまで。
- **ジャーナル**: メタデータの先行書き込みログ（記述ブロック、ブロックイメージ、CRC32C 付きのコミット）。データは先に書く（ordered）ので、クラッシュ後は各操作の前か後のどちらかの状態になる。`mount` がコミット済みの未反映トランザクションを再生する。

**デバイス**: `MemDevice(ブロック数, ブロックサイズ)`（`to_bytes()`、`device_from_bytes(bytes)`でイメージファイルとやり取り）、`FaultyDevice(inner, 書き込み回数)`（その回数のあとの書き込みが消える。クラッシュ試験用）。独自のデバイスは `read(n)`（`typed.u8`）・`write(n, data)`・`flush()`・`blocks()`・`block_size()` を持てばよい。

| 関数 | 仕様 |
|---|---|
| `mkfs(dev, opts)` | `opts`: `label`、`inode_ratio`（既定 16384 バイトに1 inode）、`journal_blocks`、`time` |
| `mount(dev, opts)` | `opts`: `clock`（秒を返す関数）、`readonly`。`Fs` を返す。主スーパーブロックが壊れていればバックアップを使う |
| `fsck(dev, repair = false)` | 全構造を検査する。`{ok, errors, fixed, inodes, blocks_used, files, dirs, symlinks, replayed}`。`repair`でリンク数・リークしたブロック・孤立 inode・空き数を直す |

`Fs`: `mkdir` `makedirs` `open(path, "r" / "r+" / "w" / "w+" / "a" / "x")`（`File`: `read` `write` `seek` `tell` `size` `truncate` `close`）`create` `read_file` `read_bytes` `write_file` `append_file` `truncate` `unlink` `rmdir` `rename` `link` `symlink` `readlink` `stat` `lstat` `exists` `is_dir` `is_file` `listdir` `chmod` `chown` `utime` `setxattr` `getxattr` `listxattr` `removexattr` `statfs` `sync` `unmount`。データには string・`typed.u8`・0〜255の整数の array を渡せる。エラーは種類 `ENOENT` `EEXIST` `ENOTDIR` `EISDIR` `ENOTEMPTY` `ENOSPC` `EINVAL` `ELOOP` `ENAMETOOLONG` `EBUSY` `EIO` `EFBIG` のerrorを送出する。操作は途中で失敗するとメタデータの変更を取り消す。

**制約**: 開いているファイルを `unlink` すると、その`File`は使えなくなる（遅延削除はない）。1 ファイルのエクステントは 261 個まで（断片化しすぎると`ENOSPC`）。ディレクトリは線形探索（大きなディレクトリは遅い）。1 回の操作が触れるメタデータブロックがジャーナルの容量（既定は 64 ブロック以上）を超えると、複数のトランザクションに分かれて原子性が弱まる。ハッシュインデックス・遅延割り当て・スナップショットはない。

**検証**: `tests/cases/stdlib/sprintfs.sp`（操作・エラー・スパース・断片化・永続性）、`sprintfs_crash.sp`（**ワークロードの途中で電源を切る**: 書き込み 184 通りの切断点のすべてで、再マウント後の`fsck`が clean でファイルの内容が前か後のどちらか）、`sprintfs_fsck.sp`（損傷の検出と修復、ビット反転、バックアップスーパーブロック）。`tools/sprintfs.sp` はイメージファイルを操作するコマンド（`mkfs` `ls` `cat` `put` `get` `mkdir` `rm` `mv` `ln-s` `stat` `info` `fsck [--repair]`）。
