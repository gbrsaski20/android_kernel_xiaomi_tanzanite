#!/usr/bin/env bash
# tanzanite (Redmi Note 14 4G, MT6789) GKI 5.10 kernel build
# Dijalankan di GitHub Actions ubuntu-22.04.
set -uo pipefail

TARGET="${TARGET:-5.10.273}"
DO_PATCH="${DO_PATCH:-1}"
LTO_MODE="${LTO_MODE:-thin}"
REPORT="ci-report.txt"
: > "$REPORT"

log() { echo "$@" | tee -a "$REPORT"; }

log "=== tanzanite GKI build ==="
log "target=$TARGET  do_patch=$DO_PATCH  lto=$LTO_MODE"
log "runner=$(uname -srm)  cpus=$(nproc)"

CUR_SUB=$(awk '/^SUBLEVEL/{print $3}' Makefile)
log "tree base: 5.10.$CUR_SUB"

########################################
# 1. dependencies
########################################
log "--- installing build deps ---"
sudo apt-get update -qq
sudo apt-get install -y -qq bc bison flex libssl-dev libelf-dev \
  python3 cpio lz4 xz-utils zip unzip ccache rsync \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu >/dev/null
log "deps ok"

########################################
# 2. toolchain
########################################
if [ ! -x clang/bin/clang ]; then
  log "--- cloning proton-clang ---"
  git clone --depth=1 https://github.com/kdrag0n/proton-clang.git clang >/dev/null 2>&1 || {
    log "FATAL: toolchain clone failed"; exit 1; }
fi
export PATH="$PWD/clang/bin:$PATH"
export CROSS_COMPILE=aarch64-linux-gnu-
clang --version | head -2 | tee -a "$REPORT"

########################################
# 3. linux-stable patches
########################################
if [ "$DO_PATCH" = "1" ]; then
  TGT_SUB=$(echo "$TARGET" | awk -F. '{print $3}')
  if [ "$TGT_SUB" -gt "$CUR_SUB" ]; then
    log "--- applying linux-stable 5.10.$((CUR_SUB+1)) .. 5.10.$TGT_SUB ---"
    mkdir -p inc
    : > patch.log
    : > patch-rejects.txt
    partial=0

    for i in $(seq $((CUR_SUB+1)) "$TGT_SUB"); do
      p=$((i-1))
      f="inc/patch-5.10.$p-$i.xz"
      if [ ! -f "$f" ]; then
        if ! curl -sfL --retry 3 -o "$f" \
            "https://cdn.kernel.org/pub/linux/kernel/v5.x/incr/patch-5.10.$p-$i.xz"; then
          log "FATAL: download failed for 5.10.$i"; exit 1
        fi
      fi
      xz -dc "$f" > inc/current.patch
      echo "### 5.10.$i" >> patch.log
      if patch -p1 -f -F3 --no-backup-if-mismatch --forward \
           < inc/current.patch >> patch.log 2>&1; then
        echo "OK      5.10.$i"
      else
        echo "PARTIAL 5.10.$i"
        partial=$((partial+1))
        find . -name '*.rej' -printf '%p\n' 2>/dev/null >> patch-rejects.txt
      fi
      find . -name '*.orig' -delete 2>/dev/null
    done

    sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $TGT_SUB/" Makefile
    sort -u -o patch-rejects.txt patch-rejects.txt
    nrej=$(wc -l < patch-rejects.txt)
    log "patches: $partial release(s) partially applied, $nrej reject file(s)"
    log "version now: $(awk '/^SUBLEVEL/{print "5.10."$3}' Makefile)"
  else
    log "target <= current, skipping patches"
  fi
else
  log "--- patching disabled, building tree as-is ---"
fi

########################################
# 4. configure
########################################
log "--- configure ---"
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 tanzanite_defconfig >> "$REPORT" 2>&1 || {
  log "FATAL: defconfig failed"; exit 1; }

# warnings must not abort the build with an older clang
scripts/config --file out/.config -d WERROR

# no vendor ABI whitelist available here; keep every exported symbol
scripts/config --file out/.config -d TRIM_UNUSED_KSYMS

# full LTO (defconfig) needs a single monolithic vmlinux.o link and OOMs the
# 16 GB runners; GKI itself ships THIN LTO, so default to that.
case "$LTO_MODE" in
  none)
    scripts/config --file out/.config -d LTO_CLANG -d LTO -e LTO_NONE
    ;;
  thin)
    scripts/config --file out/.config -d LTO_CLANG_FULL -e LTO_CLANG_THIN
    ;;
  *)
    : # keep defconfig as-is
    ;;
esac

make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig >> "$REPORT" 2>&1
log "key config:"
grep -E '^CONFIG_(WERROR|LTO|LTO_CLANG|LTO_CLANG_THIN|LTO_NONE|TRIM_UNUSED_KSYMS|MODVERSIONS)=' \
  out/.config | tee -a "$REPORT"

########################################
# 5. build
########################################
log "--- compiling Image ---"
set -o pipefail
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 Image 2>&1 | tee build.log
rc=$?
if [ $rc -ne 0 ]; then
  log "FATAL: build failed (rc=$rc)"
  log "last errors:"
  grep -nE "error:|Error [0-9]|undefined reference" build.log | tail -25 | tee -a "$REPORT"
  exit $rc
fi
ls -lh out/arch/arm64/boot/Image | tee -a "$REPORT"

########################################
# 6. package AnyKernel3
########################################
log "--- packaging AnyKernel3 ---"
KVER=$(make -s -C . kernelrelease O=out 2>/dev/null || echo "5.10.${TARGET##*.}")
log "kernelrelease=$KVER"

git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git ak3 >/dev/null 2>&1
rm -rf ak3/.git ak3/README.md ak3/modules
cp out/arch/arm64/boot/Image ak3/Image

cat > ak3/anykernel.sh <<EOF
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

properties() { '
kernel.string=Tanzanite GKI $KVER
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh

ui_print " "
ui_print "Tanzanite GKI $KVER"
ui_print "Redmi Note 14 4G (MT6789)"
ui_print " "

kernel_version=\$(cat /proc/version | awk -F '-' '{print \$1}' | awk '{print \$3}')
case "\$kernel_version" in
    5.10.*) supp=true ;;
    *) supp=false ;;
esac
ui_print "-> running: \$kernel_version (5.10 required: \$supp)"
\$supp || abort "This package needs an existing 5.10 kernel"

if [ -L "/dev/block/bootdevice/by-name/init_boot_a" -o -L "/dev/block/by-name/init_boot_a" ]; then
    split_boot
    flash_boot
else
    dump_boot
    write_boot
fi
EOF

( cd ak3 && zip -r9 "../tanzanite-gki-$KVER.zip" . -x '*.git*' >/dev/null )
ls -lh "tanzanite-gki-$KVER.zip" | tee -a "$REPORT"
log "=== done ==="
