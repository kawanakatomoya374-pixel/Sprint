# 24. Sprint OS (ブート可能なOS)

`make os`（または `make os-iso`）で `build/os/sprintos.iso` (GRUB / Multiboot2, x86-64) を作る。必要: `musl-tools`, `grub-pc-bin`, `xorriso`, `mtools`、テストに `qemu-system-x86`。

## 構成

- **薄いC/asm** (`os/boot`, `os/kernel`): 起動(32→64bit)、GDT/TSS/IDT、SYSCALL入口、トラップの保存/復帰、`hw` モジュール(ポートI/O、物理メモリpeek/poke、framebuffer、ctx切替)。
- **ポリシーは全てSprint** (`os/sprint`): `kmem`(物理ページ)、`vmm`(4段ページテーブルの構築/走査/解放)、`kelf`(ELFローダ)、`kproc`(プロセス/メモリ領域/要求時ページング)、`ksys`(Linux互換syscall表)、`osmain`(カーネル本体ループ)、`ps2`/`rtc`(ドライバ)。
- **Ring 3**: `os/user/umain.c` は同じSprintインタプリタを静的PIEでビルドしたもの。`os/user/*.sp` が各プロセスの中身で、**各ユーザプロセスは独立したSprint VM**。カーネルは `initrd.S` で組み込んだ ELF を `kelf` でロードする。
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
