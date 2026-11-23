# Sprint OS: a bootable ISO. The kernel (ring 0) is the Sprint interpreter running os/sprint/*.sp; every
# user process (ring 3) is a static-PIE build of the same interpreter running os/user/*.sp.
# Needs: musl-gcc (musl-tools), grub-mkrescue + grub-pc-bin + xorriso + mtools, and qemu for `os-test`.
OSB      := $(BUILD)/os
OSCC     := musl-gcc
OSWARN   := -std=c11 -pedantic-errors -Werror -Wall -Wextra -Wconversion -Wsign-conversion -Wshadow -Wundef -Wpointer-arith \
            -Wwrite-strings -Wvla -Wstrict-prototypes -Wold-style-definition -Wmissing-prototypes -Wmissing-declarations \
            -Wformat=2 -Wcast-qual -Wredundant-decls -Wnested-externs -Wswitch-default -Wswitch-enum
OSCOMMON := $(OSWARN) -O2 -g -Isrc -Ios/kernel -fno-stack-protector -fno-delete-null-pointer-checks -fwrapv \
            -ftrivial-auto-var-init=zero -DNDEBUG_SP
OSKFLAGS := $(OSCOMMON) -static -fno-pie -fno-pic -mno-red-zone -DSP_OS
OSUFLAGS := $(OSCOMMON) -fPIE -DSP_OS_USER
CORE_SRC := $(FRONT_SRC) $(RUNTIME_SRC) $(LIB_SRC)
OSKSRC   := $(CORE_SRC) os/kernel/kmain.c os/kernel/hw.c os/kernel/cpu.c os/kernel/smp.c
OSUSRC   := $(CORE_SRC) os/user/umain.c os/user/udev.c
OSKOBJ   := $(patsubst %.c,$(OSB)/k/%.o,$(OSKSRC)) $(OSB)/k/bundled.o $(OSB)/boot.o $(OSB)/cpu_s.o $(OSB)/isr_stubs.o $(OSB)/ap_tramp.o $(OSB)/initrd.o
OSUOBJ   := $(patsubst %.c,$(OSB)/u/%.o,$(OSUSRC)) $(OSB)/u/bundled.o
OSKSP    := $(sort $(wildcard os/sprint/*.sp))
OSUSP    := $(sort $(wildcard os/user/*.sp))

# ---- Sprint sources embedded in each binary ----
$(OSB)/k/bundled.c: tools/embedsrc.c $(STDSRC) $(GEN)/gui.sp $(OSKSP) Makefile os/os.mk
	@mkdir -p $(OSB)/k
	$(CC) -O1 -o $(OSB)/embedsrc tools/embedsrc.c
	$(OSB)/embedsrc $@ gui=$(GEN)/gui.sp $(foreach f,$(STDSRC) $(OSKSP),$(basename $(notdir $(f)))=$(f))

$(OSB)/u/bundled.c: tools/embedsrc.c $(STDSRC) $(GEN)/gui.sp $(OSUSP) Makefile os/os.mk
	@mkdir -p $(OSB)/u
	$(CC) -O1 -o $(OSB)/embedsrc tools/embedsrc.c
	$(OSB)/embedsrc $@ gui=$(GEN)/gui.sp $(foreach f,$(STDSRC) $(OSUSP),$(basename $(notdir $(f)))=$(f))

$(OSB)/k/%.o: %.c src/sp.h src/sprint.h os/kernel/kernel.h Makefile os/os.mk
	@mkdir -p $(dir $@)
	$(OSCC) $(OSKFLAGS) -c -o $@ $<
$(OSB)/k/bundled.o: $(OSB)/k/bundled.c src/sp.h
	$(OSCC) $(OSKFLAGS) -c -o $@ $<

$(OSB)/u/%.o: %.c src/sp.h src/sprint.h os/kernel/kernel.h Makefile os/os.mk
	@mkdir -p $(dir $@)
	$(OSCC) $(OSUFLAGS) -c -o $@ $<
$(OSB)/u/bundled.o: $(OSB)/u/bundled.c src/sp.h
	$(OSCC) $(OSUFLAGS) -c -o $@ $<

# ---- user program (ring 3): static-PIE, loaded by the kernel's ELF loader written in Sprint ----
$(OSB)/userland.elf: $(OSUOBJ) os/tools/link_userland.sh
	sh os/tools/link_userland.sh $(OSCC) $@ $(OSUOBJ)

# ---- kernel ----
$(OSB)/boot.o: os/boot/boot.S
	@mkdir -p $(OSB)
	$(OSCC) -static -fno-pie -c -o $@ $<

$(OSB)/cpu_s.o: os/kernel/cpu.S os/kernel/cpu_defs.h
	@mkdir -p $(OSB)
	$(OSCC) -static -fno-pie -c -o $@ $<

$(OSB)/isr_stubs.o: os/kernel/isr_stubs.S
	@mkdir -p $(OSB)
	$(OSCC) -static -fno-pie -c -o $@ $<

$(OSB)/ap_tramp.o: os/kernel/ap_tramp.S
	@mkdir -p $(OSB)
	$(OSCC) -static -fno-pie -c -o $@ $<

$(OSB)/initrd.o: os/kernel/initrd.S $(OSB)/userland.elf
	@mkdir -p $(OSB)
	$(OSCC) -static -fno-pie -I$(OSB) -c -o $@ $<

$(OSB)/kernel.elf: $(OSKOBJ) os/link.ld
	$(OSCC) -static -nostartfiles -fno-pie -no-pie -Wl,-T,os/link.ld -Wl,-z,max-page-size=4096 -Wl,-q -o $@ $(OSKOBJ) -lgcc
	objcopy -R '.rela*' -O elf32-i386 $@ $(OSB)/kernel32.elf   # kernel.elf keeps its relocations (-q): the UEFI loader relocates the kernel

$(OSB)/sprintos.iso: $(OSB)/kernel.elf os/boot/grub.cfg
	rm -rf $(OSB)/iso && mkdir -p $(OSB)/iso/boot/grub
	cp $(OSB)/kernel32.elf $(OSB)/iso/boot/kernel.elf
	cp os/boot/grub.cfg $(OSB)/iso/boot/grub/grub.cfg
	grub-mkrescue -o $@ $(OSB)/iso >/dev/null 2>&1

# the same kernel, booting the self-test program instead of the desktop
$(OSB)/sprintos-test.iso: $(OSB)/kernel.elf os/boot/grub-test.cfg
	rm -rf $(OSB)/isot && mkdir -p $(OSB)/isot/boot/grub
	cp $(OSB)/kernel32.elf $(OSB)/isot/boot/kernel.elf
	cp os/boot/grub-test.cfg $(OSB)/isot/boot/grub/grub.cfg
	grub-mkrescue -o $@ $(OSB)/isot >/dev/null 2>&1

# the boot menu of the user-facing images (see os/boot/boot_menu.sp): TIMEOUT;label|command line;...   Test images use one fixed command line.
OS_MENU  := 3;Sprint OS desktop|init=boot;Sprint OS self-test (serial log)|init=init;Sprint OS desktop, quiet (no serial log)|init=boot quiet

# ---- the same kernel booted by the bootloader written in Sprint (os/boot/sprintboot.sp): a raw disk image, no GRUB ----
$(OSB)/sprintos.img: $(OSB)/kernel.elf os/boot/sprintboot.sp os/boot/bios_loader.sp os/boot/elf32.sp os/boot/boot_menu.sp stdlib/asm.sp $(BUILD)/sprint
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/sprintboot.sp $(OSB)/kernel32.elf $@ '$(OS_MENU)'
$(OSB)/sprintos-test.img: $(OSB)/kernel.elf os/boot/sprintboot.sp os/boot/bios_loader.sp os/boot/elf32.sp os/boot/boot_menu.sp stdlib/asm.sp $(BUILD)/sprint
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/sprintboot.sp $(OSB)/kernel32.elf $@ "init=init"

# ---- UEFI: a GPT disk image with an EFI System Partition, loader and image generator written in Sprint (os/boot/uefiboot.sp) ----
# the kernel is relocatable (kernel.elf keeps its relocations): the loader picks a free block, the table comes from the 64-bit kernel.elf
UEFI_SP  := os/boot/uefiboot.sp os/boot/uefi_loader.sp os/boot/elf32.sp os/boot/uefi_pe.sp os/boot/diskimg.sp os/boot/boot_menu.sp os/boot/sha256_asm.sp os/boot/authenticode.sp os/boot/bn.sp os/boot/der.sp stdlib/asm.sp
$(OSB)/sprintos-uefi.img: $(OSB)/kernel.elf $(UEFI_SP) $(BUILD)/sprint
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/uefiboot.sp $(OSB)/kernel32.elf $@ '$(OS_MENU)' $(OSB)/kernel.elf
$(OSB)/sprintos-uefi-test.img: $(OSB)/kernel.elf $(UEFI_SP) $(BUILD)/sprint
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/uefiboot.sp $(OSB)/kernel32.elf $@ "init=init" $(OSB)/kernel.elf

# ---- hybrid: one disk image that boots under BIOS and under UEFI (os/boot/hybridboot.sp) ----
HYBRID_SP := os/boot/hybridboot.sp os/boot/bios_loader.sp os/boot/uefi_loader.sp os/boot/elf32.sp os/boot/uefi_pe.sp os/boot/diskimg.sp os/boot/boot_menu.sp os/boot/sha256_asm.sp os/boot/authenticode.sp os/boot/bn.sp os/boot/der.sp stdlib/asm.sp
$(OSB)/sprintos-hybrid.img: $(OSB)/kernel.elf $(HYBRID_SP) $(BUILD)/sprint
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/hybridboot.sp $(OSB)/kernel32.elf $@ '$(OS_MENU)' $(OSB)/kernel.elf
$(OSB)/sprintos-hybrid-test.img: $(OSB)/kernel.elf $(HYBRID_SP) $(BUILD)/sprint
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/hybridboot.sp $(OSB)/kernel32.elf $@ "init=init" $(OSB)/kernel.elf

.PHONY: os os-check os-kernel os-user os-iso os-run os-test os-img os-img-run os-img-test os-uefi os-uefi-run os-uefi-test os-hybrid os-hybrid-run os-hybrid-uefi-run os-hybrid-test
# `make os`: check the tools, then build the bootable ISO
os: os-check os-iso
	@echo "ISO ready: $(OSB)/sprintos.iso   (try: make os-run)"
os-check:
	@miss=""; for t in musl-gcc grub-mkrescue xorriso mformat; do command -v $$t >/dev/null 2>&1 || miss="$$miss $$t"; done; \
	if [ -n "$$miss" ]; then echo "make os: missing:$$miss"; echo "  Debian/Ubuntu: sudo apt install musl-tools grub-pc-bin xorriso mtools   (qemu-system-x86 to run it)"; exit 1; fi
os-kernel: $(OSB)/kernel.elf
os-user: $(OSB)/userland.elf
os-iso: $(OSB)/sprintos.iso
os-run: $(OSB)/sprintos.iso
	qemu-system-x86_64 -m 256 -cdrom $< -serial stdio
os-test: $(OSB)/sprintos-test.iso $(OSB)/sprintos.iso
	python3 os/tests/qemu_test.py $(OSB)/sprintos-test.iso $(OSB)/sprintos.iso

os-img: $(OSB)/sprintos.img
os-img-run: $(OSB)/sprintos.img
	qemu-system-x86_64 -m 256 -drive format=raw,file=$< -serial stdio
# the same checks as os-test, but booted by the Sprint bootloader from a disk image
os-img-test: $(OSB)/sprintos-test.img $(OSB)/sprintos.img
	python3 os/tests/qemu_test.py $(OSB)/sprintos-test.img $(OSB)/sprintos.img

os-hybrid: $(OSB)/sprintos-hybrid.img
os-hybrid-run: $(OSB)/sprintos-hybrid.img
	qemu-system-x86_64 -m 256 -drive format=raw,file=$< -serial stdio
os-hybrid-uefi-run: $(OSB)/sprintos-hybrid.img
	qemu-system-x86_64 -m 256 -bios $(OVMF) -drive format=raw,file=$< -serial stdio
# the same image, the same checks: once booted by the BIOS (SeaBIOS), once by UEFI (OVMF)
os-hybrid-test: $(OSB)/sprintos-hybrid-test.img $(OSB)/sprintos-hybrid.img
	@echo "== BIOS"; python3 os/tests/qemu_test.py $(OSB)/sprintos-hybrid-test.img $(OSB)/sprintos-hybrid.img
	@echo "== UEFI"; SPRINT_FIRMWARE=uefi SPRINT_OVMF=$(OVMF) python3 os/tests/qemu_test.py $(OSB)/sprintos-hybrid-test.img $(OSB)/sprintos-hybrid.img

os-uefi: $(OSB)/sprintos-uefi.img
# OVMF (apt install ovmf) is the UEFI firmware for QEMU
OVMF ?= $(firstword $(wildcard /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd /usr/share/qemu/OVMF.fd))
os-uefi-run: $(OSB)/sprintos-uefi.img
	qemu-system-x86_64 -m 256 -bios $(OVMF) -drive format=raw,file=$< -serial stdio
os-uefi-test: $(OSB)/sprintos-uefi-test.img $(OSB)/sprintos-uefi.img
	SPRINT_OVMF=$(OVMF) python3 os/tests/qemu_test.py $(OSB)/sprintos-uefi-test.img $(OSB)/sprintos-uefi.img

# Secure Boot (needs qemu, the OVMF firmware with Secure Boot, openssl, virt-fw-vars (pip install virt-firmware) and sbverify (sbsigntool)):
# the loader is signed by the Sprint signer, enforced by the firmware; see os/tests/secureboot_test.py
os-secureboot-test: $(OSB)/kernel.elf $(UEFI_SP) $(BUILD)/sprint
	python3 os/tests/secureboot_test.py
# a signed hybrid image with throw-away keys (TEST KEYS ONLY: generate your own for real use):  make os-secureboot-image
os-secureboot-image: $(OSB)/kernel.elf $(HYBRID_SP) $(BUILD)/sprint
	@mkdir -p $(OSB)/keys
	@[ -f $(OSB)/keys/sprintos.key ] || openssl req -new -x509 -newkey rsa:2048 -nodes -keyout $(OSB)/keys/sprintos.key -out $(OSB)/keys/sprintos.crt -days 3650 -subj "/CN=Sprint OS test signing key/" -sha256
	$(BUILD)/sprint run --allow-read=$(OSB) --allow-write=$(OSB) os/boot/hybridboot.sp $(OSB)/kernel32.elf $(OSB)/sprintos-hybrid-signed.img '$(OS_MENU)' $(OSB)/kernel.elf $(OSB)/keys/sprintos.key $(OSB)/keys/sprintos.crt
.PHONY: os-secureboot-test os-secureboot-image

# the boot menu of the BIOS loader, the UEFI loader and the hybrid image (keys sent to the menu through the QEMU monitor)
os-menu-test: $(OSB)/kernel.elf os/boot/sprintboot.sp os/boot/bios_loader.sp $(UEFI_SP) $(HYBRID_SP) $(BUILD)/sprint
	python3 os/tests/menu_test.py
.PHONY: os-menu-test
