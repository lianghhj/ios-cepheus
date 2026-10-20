#!/bin/bash
# Build the cepheus shim and wrap it in a boot.img v2 with the real-phone FDT
# embedded: the cepheus (SM8150) ABL accepts v2 (a v4 image stalls after
# OKAY). Usage:
#   build.sh [PAYLOAD] [DTB]
# PAYLOAD = xnu payload from tools/mkpayload.py (goes into the v2 ramdisk;
#           the ABL loads it and writes /chosen/linux,initrd-start/end, where
#           loader.c finds the SWEETXNU magic).
# DTB     = cepheus live FDT (cepheus-fdt.dtb, extracted from the phone, kept
#           out of git). Default: ../research/cepheus-fdt.dtb
set -euo pipefail
cd "$(dirname "$0")"
CC=${CC:-aarch64-linux-gnu-gcc}
OBJCOPY=${OBJCOPY:-aarch64-linux-gnu-objcopy}
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($OBJCOPY --help >/dev/null 2>&1; aarch64-linux-gnu-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o 2>/dev/null | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$((16#$(aarch64-linux-gnu-nm out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image

# Ramdisk: the xnu payload if given as $1, else an empty newc cpio (ABL
# dislikes a zero-size ramdisk; the image then runs the UFS diagnostics).
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi

DTB="${2:-../research/cepheus-fdt.dtb}"
if [ ! -f "$DTB" ]; then
	echo "error: DTB '$DTB' not found (pass it as \$2 or put it in research/)" >&2
	exit 1
fi
# sweet v2 packing, from upstream: base 0, offsets as the stock cepheus
# boot.img uses (kernel 0x8000, ramdisk 0x1000000, tags 0x100, dtb 0x1f00000).
${MKBOOTIMG:-python3 mkbootimg.py} --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
	--dtb "$DTB" \
	--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
	--dtb_offset 0x1f00000 --pagesize 4096 \
	--cmdline "console=null" -o out/shim-boot-cepheus.img

# Host render of the console layout.
if command -v gcc >/dev/null 2>&1; then
	gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
fi
ls -l out/Image out/ramdisk.bin out/shim-boot-cepheus.img
