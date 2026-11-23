# 24. Sprint OS (ブート可能なOS)

起動方法は2通り（どちらも同じカーネルで、`make os-test` / `make os-img-test` が同じ検査を行う）:

- `make os`（または `make os-iso`）で `build/os/sprintos.iso`（GRUB / Multiboot2、x86-64）を作る。必要: `musl-tools`, `grub-pc-bin`, `xorriso`, `mtools`、テストに `qemu-system-x86`。
- `make os-img` で `build/os/sprintos.img` を作る。**ブートローダーも Sprint 製**（`os/boot/sprintboot.sp`。GRUB・外部アセンブラ・Cのブート処理は使わない）。生のディスクイメージで、`make os-img-run`（QEMU、`-drive format=raw`）で起動する。必要なのは `musl-tools` と `qemu-system-x86` だけ。

## Sprint 製ブートローダー（os/boot/sprintboot.sp）

`import asm`（§15.21）で組む。構成は2段:

1. **ステージ1**（MBR、512バイト）: INT 13h 拡張でステージ2を 0x8000 へ読む。
2. **ステージ2**（リアルモード）: A20 を有効にし、VBE で 1024x768x32 のリニアフレームバッファを設定し、ACPI RSDP を探し（EBDA、0xE0000〜0xFFFFF）、E820 のメモリマップを集め、Multiboot2 の情報構造（コマンドライン・メモリマップ・フレームバッファ・RSDP タグ）を 0x30000 に作る。続いてカーネルの `PT_LOAD` セグメントを、ディスクから 1 MiB 以上へ読み込む（バウンスバッファ経由。コピーの間だけ unreal モードで ES を 4 GiB 幅にする）。最後に 32 ビット保護モードへ移り、GRUB と同じ規約（`eax = 0x36d76289`、`ebx` = 情報構造）でカーネルの Multiboot2 入口へ飛ぶ。

カーネルの ELF は**イメージ生成時に Sprint が解析**する（`fs.read_bytes`）。各セグメントをセクタ境界に置き、(LBA, 配置先, ファイルサイズ, メモリサイズ) の表をステージ2に埋めるので、16ビットのローダーは ELF を理解しなくてよい。カーネルのコマンドライン（`init=...`）もイメージ生成時の引数である。

## UEFI（os/boot/uefiboot.sp、`make os-uefi`）

`build/os/sprintos-uefi.img` は GPT のディスクイメージで、FAT32 の EFI System Partition を持つ（`\EFI\BOOT\BOOTX64.EFI` と `\SPRINTOS.BIN`）。**イメージ生成からローダーまで全部 Sprint**: ローダーは `asm` モジュールで組んだ x86-64 の EFI アプリ（Microsoft ABI）で、`os/boot/uefi_pe.sp` が PE32+ に包み、`os/boot/diskimg.sp` が GPT（CRC32 付き）と FAT32 を書く。QEMU では OVMF（`apt install ovmf`）で起動する（`make os-uefi-run`、`make os-uefi-test`）。

ローダーは次を行う: GOP で 1024x768 のモードを選び、構成テーブルから ACPI RSDP を探し、`SPRINTOS.BIN`（カーネルの `PT_LOAD` セグメントを連結したもの。アドレスと大きさの表はローダーが持つ）を起動元のボリュームから読み、Multiboot2 の情報構造（コマンドライン・フレームバッファ・RSDP・メモリマップ）を 1 MiB 未満に作り、`ExitBootServices` を呼ぶ。その後、低メモリに置いた小さなトランポリンが、32 ビット保護モードへ降りてページングとロングモードを切り、カーネルのセグメントを所定のアドレスへコピーして（bss をゼロ埋めし、UEFI のページテーブルを壊す心配がない）、`eax = 0x36d76289`、`ebx` = 情報構造でカーネルの Multiboot2 入口へ飛ぶ。カーネルは BIOS / GRUB と同じものを使う。

**カーネルは再配置可能**: ファームウェアは自分の領域（OVMF は ACPI NVS を 8 MiB に置く）を持つので、カーネルを 1 MiB 固定には置けない。カーネルは `-Wl,-q`（`--emit-relocs`）でリンクされ、64 ビットの `kernel.elf` が再配置情報を保つ（`kernel32.elf` は `objcopy` で再配置セクションを除いた変換）。イメージ生成時に Sprint（`elf32.relocs`）が、イメージ内のアドレスを持つスロット（`R_X86_64_64` は 8 バイト、`R_X86_64_32/32S` は 4 バイト。PC 相対・TLS・絶対シンボルは対象外。約 9000 件）を表にして `SPRINTOS.BIN` の末尾に付ける。ローダーは `AllocatePages(AllocateMaxAddress, 4 GiB 未満)` でファームウェアが確保した空きブロックへセグメントを置き、トランポリン（ページングを切った 32 ビット）が表の全スロットに「新しい基点 − リンク基点」を足してから、新しい入口へ飛ぶ。カーネルの空きメモリ計算は、配置場所に依存しないよう、カーネルのイメージ（`__image_start`〜`_end`）と Multiboot2 情報だけを除外し、1 MiB 以上の残りを全部使う（以前は `_end` より上だけだった）。QEMU/OVMF（256 MiB）では約 192 MiB 付近に置かれて動く。

制約: 位置はファームウェア任せだが、4 GiB 未満の連続した空きブロック（約 24 MiB）が要る。Secure Boot 未対応。実機では未検証。

## ブートメニュー（os/boot/boot_menu.sp）

BIOS ローダーも UEFI ローダーも、カーネルを起動する前にメニューを出す（画面とシリアルポートの両方。画面は BIOS ではテキストモード、UEFI では ConOut）。メニューの内容はイメージ生成時の文字列で決める: `"TIMEOUT[/DEFAULT];ラベル|コマンドライン;..."`（`;` を含まない文字列は固定のコマンドラインで、メニューを出さずに起動する。テスト用イメージはこれ）。`make os-img` / `os-uefi` / `os-hybrid` のイメージは `OS_MENU`（既定: デスクトップ、セルフテスト、シリアルを止めたデスクトップの3項目、3秒）を使う。

キー（キーボードとシリアルの両方）: ↑↓（または `k` `j`）で選択、`1`〜`9` で選んで即起動、Enter で起動、`e` でコマンドラインを編集（Enter で起動、Esc で戻る。BackSpace、印字可能文字、最大127文字）。カウントダウン中に何かキーを押すと止まる。時間切れで既定の項目が起動する。

カーネルが解釈するコマンドライン: `init=NAME`（最初のユーザープログラム。既定 `boot`）と `quiet`（シリアルポートへの出力を止める。パニックと例外は出る）。シリアルコンソールの切り替えは、この `quiet` を含む項目と含まない項目をメニューに並べることで行う（メニュー自体は常に画面とシリアルの両方に出る）。`make os-menu-test` が、BIOS・UEFI・ハイブリッド（両方のファームウェア）で、数字キーによる選択、`quiet`、編集、カウントダウンを QEMU モニターのキー入力で確かめる。

## Secure Boot（UEFI）

UEFI ローダー（`BOOTX64.EFI`）は **Sprint 製の署名ツール**（`os/boot/authenticode.sp`、`os/boot/sbsign.sp`）で Authenticode 署名できる。鍵と証明書は外部で用意する（`openssl req -x509 -newkey rsa:2048 -nodes ...`）。署名は SHA-256 + RSA（PKCS#1 v1.5）の PKCS#7 SignedData で、イメージのハッシュ（チェックサム・証明書テーブルの項目・証明書データを除く）を `SpcIndirectDataContent` に入れ、`WIN_CERTIFICATE` として PE に付ける。RSA は `os/boot/bn.sp`（24 ビットの足、モンゴメリ乗算、中国人剰余定理）、ASN.1 / PEM は `os/boot/der.sp` で Sprint から実装し、署名の直後に公開指数で自己検証する。OpenSSL を使う `sbverify` が Sprint 製の署名を受け付けることを `make os-secureboot-test` が確かめる。

信頼の連鎖: (1) ファームウェアが `db` の証明書でローダーの署名を検証する（未署名・別の鍵は `Access Denied`）。(2) ローダーはカーネルのファイル `SPRINTOS.BIN` の **SHA-256 を自分で計算**し（x86-64 アセンブリ、`os/boot/sha256_asm.sp`。ホストで `os/boot/test_sha256.sp` がネイティブの `hash.sha256` と突き合わせる）、**署名されたローダーイメージの中に埋め込んだハッシュ**と比べ、違えば起動を拒否する（署名されたローダーが、そのカーネルだけを起動する）。(3) `SecureBoot` 変数が 1 のとき、メニューはコマンドラインの編集を許さない（選べるのはイメージ生成時に署名の中へ入れた項目だけ）。

`make os-secureboot-test`（要: OVMF の Secure Boot 版、`openssl`、`virt-fw-vars`（`pip install virt-firmware`）、`sbverify`（`sbsigntool`）、q35 + SMM の QEMU）は、鍵を作って OVMF の PK / KEK / db に登録し、次を確かめる: 署名したローダーが起動する、未署名と別の鍵はファームウェアが拒否する、カーネルを1バイト変えると署名済みローダーが拒否する、Secure Boot が有効ならメニューの編集ができず無効なら編集できる。`make os-secureboot-image` は、使い捨ての鍵で署名したハイブリッドイメージを作る（**テスト用の鍵**。実用には自分の鍵を使うこと。鍵の登録はファームウェアの設定か `virt-fw-vars` で行う）。

制約: BIOS 経路には Secure Boot はない。鍵の生成と登録は外部ツール任せ（Sprint が行うのは署名と検証）。署名アルゴリズムは SHA-256 + RSA のみ。Microsoft の証明書による署名（shim 経由）や、カーネル自体の署名は扱わない（カーネルはローダーに埋め込んだハッシュで守る）。実機では未検証。

## ハイブリッドイメージ（os/boot/hybridboot.sp、`make os-hybrid`）

`build/os/sprintos-hybrid.img` は **1本のディスクで BIOS と UEFI の両方から起動する**（イメージ生成・両方のローダーとも Sprint 製）。

| 場所 | 中身 | 使うのは |
|---|---|---|
| LBA 0 | 保護 MBR。ブートコードは BIOS ステージ1（446バイト以内）、パーティション表は 0xEE の1件（起動可フラグ付き） | BIOS が実行する。UEFI はコードを無視する |
| LBA 1〜33 | GPT ヘッダとパーティション表 | UEFI |
| パーティション1 | GPT の「BIOS boot」領域（LBA 2048〜）: BIOS ステージ2とカーネルのセグメント | ステージ1が読む |
| パーティション2 | ESP（FAT32）: `\EFI\BOOT\BOOTX64.EFI` と `\SPRINTOS.BIN` | UEFI ファームウェアが起動する |

どちらのローダーも同じカーネルの Multiboot2 入口に入る。カーネルは両方で同じもの（BIOS 側は 1 MiB に置き、UEFI 側は再配置して置く）で、カーネルのビルドは1つで済む。`os/boot/bios_loader.sp` / `uefi_loader.sp` / `elf32.sp` / `diskimg.sp` は、単独の BIOS イメージ（`sprintboot.sp`）・単独の UEFI イメージ（`uefiboot.sp`）・ハイブリッド（`hybridboot.sp`）が共有するモジュールで、単独イメージの出力はモジュール化の前後でバイト単位で変わらない。`make os-hybrid-test` は同じイメージを SeaBIOS で、続いて OVMF で起動して同じ検査を行う（`os-hybrid-run` / `os-hybrid-uefi-run` で手動起動）。

## JIT

カーネル（Ring 0）の Sprint VM も、ユーザープロセス（Ring 3）の Sprint VM も、x86-64 の JIT（領域 JIT・TraceJIT・純関数 JIT）付きでビルドされる。JIT コードは匿名 `mmap` のページに置く: ユーザー側は `mmap` が常に実行可能なページを返し（NX は使わない）、`mprotect` は成功を返す。コンテキストスイッチは `fxsave`/`fxrstor` で SSE の状態を保存するので、float を使う JIT コードも切り替えをまたいで壊れない。`make os-test` / `os-img-test` は、CPU バウンドのジョブ（4本）が 1 CPU で 4.5 秒未満で終わること（インタプリタだけだと約 7.8 秒、JIT で約 1.8 秒）を検査する。

## カーネルの mmap（修正）

`mmap` のエミュレーションは、要求サイズではなく**ページに切り上げた全体**をゼロで埋める。musl の malloc は mmap した領域の末尾（要求サイズの後ろ）のガードバイトを読むため、以前は前の持ち主のデータが残っていると、メモリ量が大きい環境（256 MiB 以上）で `free()` の整合性検査に失敗して止まっていた。

## 構成

- **薄いC/asm** (`os/boot`, `os/kernel`): 起動(32→64bit)、GDT/TSS/IDT、SYSCALL入口、トラップの保存/復帰、`hw` モジュール(ポートI/O、物理メモリpeek/poke、framebuffer、ctx切替)。
- **ポリシーは全てSprint** (`os/sprint`): `kmem`(物理ページ)、`vmm`(4段ページテーブルの構築/走査/解放)、`kelf`(ELFローダ)、`kproc`(プロセス/メモリ領域/要求時ページング)、`ksys`(Linux互換syscall表)、`osmain`(カーネル本体ループ)、`ps2`/`rtc`(ドライバ)。
- **Ring 3**: `os/user/umain.c` は同じSprintインタプリタを静的PIEでビルドしたもの（リンクは `os/tools/link_userland.sh`。`musl-gcc -static-pie` の結果が ET_DYN・PT_INTERP なし・DT_NEEDED なしの静的PIEであることを検査し、古い `musl-gcc.specs` で動的PIEになったときは `rcrt1.o` を明示して作り直す）。`os/user/*.sp` が各プロセスの中身で、**各ユーザプロセスは独立したSprint VM**。カーネルは `initrd.S` で組み込んだ ELF を `kelf` でロードする。
- **トラップモデル**: `hw.enter(ctx)` はユーザ空間へ入り、トラップ/syscall でベクタ番号(256=syscall)を返してカーネルのSprintループに戻る。

## 現状 (2.8.0)

動作 (すべて `make os-test` がQEMUで検証する):

- **プリエンプション**: LAPICタイマ (ベクタ0x20、10msスライス、TSCで校正) で `sched.sp` がラウンドロビン。状態は run/on/sleep/wait/zombie。
- **プロセス**: syscall 1000=spawn、1001=wait、35=nanosleep。`init=NAME` カーネルコマンドラインで最初のユーザプログラムを選ぶ (既定 `boot`)。
- **SMP**: ACPI MADTをSprintで解析し、INIT+SIPI(2回)でAPを起動 (`ap_tramp.S`)。大カーネルロック(BKL)の下でSprint VMへ1CPUずつ入る。ユーザ空間の計算は並列に走り、4本のCPU負荷ジョブは1CPU比で約半分の時間 (2CPU)。再スケジュールIPIはベクタ0x21。
- **Ring 3 デスクトップ**: `os/user/desktop.sp` が独立したSprint VMで、syscall 1002でフレームバッファを自分のアドレス空間にマップ (DEVICEビット: 解放対象外)、1003でPS/2入力、1005 poweroff、1006 meminfo、1008 rtc、1009 reboot。特権syscallは `p.gui` のプロセスだけ。描画は `gui` / `wm` / `proc` / `vfs` を使い、カーソルはハードウェア風に別描画。
- **IPC / 共有メモリ**: syscall 1010 shm_create、1011 shm_open、1012 shm_close (共有ページはDEVICEビットで解放対象外にし、`shm.sp` が参照を数えて最後のunmapで返却)。1013 msg_send(pid, buf, len)、1014 msg_recv(buf, cap, nonblock) (受信側は空なら `msgwait` でブロック、送信が直接起こす)。ユーザ側は `ipc` モジュール (`shm_create/open/close/read/write/get/set`, `send`, `recv`)。1CPU/2CPUの両方で往復200回が通る。
- 終了時に全物理ページが返却される。

テスト: `make os-test` は1CPU/2CPUで起動し、プリエンプション・待ち合わせ・ページ返却・2CPUの高速化を確認し、デスクトップISOでは起動・描画・マウスのダブルクリック・キーボード入力を確認する。実機では未検証。

未実装: AP側タイマの高精度化、細粒度ロック。旧Ring 0デスクトップは `os/legacy/` に退避してある。

## サーバ分離（マイクロカーネルへ）

カーネルに残すのは、メモリ（物理ページ・アドレス空間・共有メモリ）、スケジューラ、プロセス、メッセージ、そしてごく小さな「権限」だけ。ファイルシステムも GUI も、カーネルの外（Ring 3 のサーバプロセス）にある。

カーネルが持つ機構（どれも `os/sprint/sched.sp` / `ksys.sp` / `hw.c`、合わせて数十行）:

- **メッセージの送信元**: `msg_recv` は受信したメッセージと一緒に**カーネルが記録した送信元 pid** を返す（`ipc.recv_from()`）。サーバは要求の送り主を偽装されない。
- **名前登録**: syscall 1015 `ns_register(name)` / 1016 `ns_lookup(name)`。クライアントは `ipc.lookup("fs")`、`ipc.lookup("gui")` でサーバの pid を得る（登録済みの名前は取れない。死んだサーバの名前は取り直せる）。
- **I/O ポートの権限**: プログラム名ごとの表（`sched.sp` の `PORTS`）で、そのプロセスにだけ I/O ポート範囲を許す。TSS の I/O 許可ビットマップを、スケジュールするたびに CPU ごとに合わせる（`hw.iopb_set`）。ドライバプロセスは Ring 3 で `in`/`out` を実行する（`uio` モジュール）。それ以外のプロセスが触ると #GP で終了する。
- フレームバッファと入力は `p.gui` を持つプロセス（`guid`）だけ。

**ファイルシステムサーバ `fsd`**（`os/user/fsd.sp`）: ATA の PIO ドライバ（`uata.sp`、Sprint）と SprintFS をカーネルの外で動かす。起動時に 2 本の IDE チャネルを調べ、SprintFS として開ける最初のディスクを取り付け、`"fs"` として登録する。要求は 1 メッセージ 1 操作（タブ区切り、`stat/exists/list/read/write/truncate/mkdir/unlink/rmdir/rename/sync/statfs`、応答は `ok…` か `err<TAB>種別<TAB>メッセージ`）。ファイルの中身はクライアントが `attach` で渡した共有メモリ（64 KiB）を通す。クライアント側のライブラリは `fsclient.sp`（`connect()` / `read_file` / `write_file` / `listdir` / …）。カーネルは以前ディスクを自分で取り付けていたが、それは取り除いた。

**GUI サーバ `guid`**（`os/user/guid.sp`、旧 `desktop`）: フレームバッファと入力を持ち、`wm` のウィンドウシステムと内蔵アプリを動かし、`"gui"` として登録して他のプロセスのウィンドウを受け付ける。クライアントは `guiclient.sp` で、自分の canvas に描いて共有バッファへ書き（`canvas_to_shm`）、`present` を送る。`guid` はそのバッファを自分の canvas へ写して枠（タイトルバー・移動・最前面・閉じる）を付け、ウィンドウ内のポインタ・キー・テキストのイベントをメッセージでクライアントへ返す（`ptr` / `key` / `text` / `close`）。デモのクライアントは `gdemo.sp`（デスクトップの「Demo」アイコンで起動）。ターミナルの `dls` / `dcat` / `dput` は `fsclient` で `fsd` に問い合わせる。

検証: `make os-disk-test`（2 台目の ATA ディスクに SprintFS を作り、`fsd` をカーネルなしで動かして読み書き・300 KB 超のファイル・エラー種別を確かめ、書いた結果をホストが `fsck` で検査する）、`make os-img-test`（デスクトップ上で Demo を起動してクライアントのウィンドウが出る・ポインタとキーが届く・クライアントの画素が画面にある・ターミナルが `fsd` 経由でディスクのファイルを読む）。

**GPU サーバ `gpud`**（`os/user/gpud.sp`、C-OS の `virtio_gpu.c` の 2D 経路が土台）: VirtIO-GPU（QEMU の `virtio-vga` / `virtio-gpu-pci`）を Ring 3 から動かす。PCI 設定空間はポート 0xCF8/0xCFC（`PORTS` で許可）、レジスタは BAR の MMIO、キューとピクセルメモリは物理的に連続な DMA メモリで、カーネルが `gpud` だけに次の 2 つの機構を許す:

- syscall 1020 `mmio_map(phys, bytes)`: デバイスのレジスタをキャッシュ無効（PCD|PWT）で自分のアドレス空間へ写す。
- syscall 1021 `dma_alloc(bytes)`: 物理連続のページを確保して共有セグメントとして写し、物理アドレスを返す（`kmem.alloc_contig`）。

`gpud` は PCI を走査して virtio-gpu（0x1AF4:0x1050）を見つけ、virtio-pci の capability（common / notify）から modern インターフェースを開き（VERSION_1 のみ、3D なし）、control queue と cursor queue を作り、`GET_DISPLAY_INFO` の画面サイズで 2D リソース＋バッキング（1 エントリ）＋`SET_SCANOUT` を行う。`"gpu"` として登録し、`info`（画面のピクセルメモリを共有セグメントで返す）、`flush x y w h`（`TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH`）、`cursor_image` / `cursor_move`（ハードウェアカーソル）、`quit` を受ける。デバイスが無ければ `info` に `ENODEV` を返す。

`guid` は起動時に `"gpu"` に問い合わせ、あれば（`gdev.fb_use`）そのピクセルメモリを画面として描き、表示のたびに `flush` を送り、ポインタはハードウェアカーソルにする。無ければ従来どおりカーネルのフレームバッファ。`boot` が `fsd`・`gpud`・`guid` を順に起動し、終了時に `fsd`・`gpud` を止める。

検証: `make os-gpu-test`（`virtio-vga` 上で、`gputest` が 4 色の帯を描いて `flush` → QEMU の screendump にその画素が出る、矩形だけの `flush`、カーソル画像の受理。続けて通常の `boot` を `-vga none -device virtio-vga` で起動し、デスクトップが GPU サーバ経由で描かれ、ダブルクリックでターミナルが開き、ホストの画面にそのウィンドウが出る）。

既知の問題: 2 CPU のセルフテストが約 1 割の確率で、`burner` プロセスの Ring 3 のページフォルト（cr2=0）で落ちる。サーバ分離の前から出ていた現象で（変更前の木でも 14 回中 2 回）、原因は未調査。
