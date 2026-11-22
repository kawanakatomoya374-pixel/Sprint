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

カーネルを 1 MiB に置くと、ファームウェアの領域（OVMF は ACPI NVS を 8 MiB に置く）と衝突するので、**UEFI 用のカーネルは 16 MiB にリンク**する（`os/link.ld` の `1M` を置き換えた `link-uefi.ld`）。ローダーは `ExitBootServices` の前に、カーネルの各アドレス範囲がメモリマップ上「起動後に解放できる種別」であること、ファイルバッファと重ならないことを検査し、違えば衝突した領域を表示して戻る。

制約: カーネルは位置固定（16 MiB）なので、その範囲をファームウェアが予約している機種では起動できない（再配置可能なカーネルが要る）。Secure Boot 未対応。実機では未検証。

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

未実装: Ring 3のGUIサーバ分離 (共有メモリ/メッセージは用意したが、現状のデスクトップは1プロセス)、AP側タイマの高精度化、細粒度ロック。旧Ring 0デスクトップは `os/legacy/` に退避してある。
