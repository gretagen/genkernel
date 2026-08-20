#!/usr/bin/env bash

set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/usr/src}"
JOBS="${JOBS:-$(nproc)}"
DRY_RUN=false
LOG_FILE="/var/log/kernel_generation.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info() { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error() {
  echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"
  exit 1
}
step() { echo -e "\n${BOLD}══ $* ${RESET}" | tee -a "$LOG_FILE"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run)
    DRY_RUN=true
    shift
    ;;
  --jobs=*)
    JOBS="${1#*=}"
    shift
    ;;
  --jobs)
    JOBS="$2"
    shift 2
    ;;
  *) error "Unknown option: $1" ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "Generating a kernel requires superuser privileges."
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
echo "=== Kernel generation started $(date) ===" >>"$LOG_FILE"

info "Genkernel : Custom kernels, made easy."

while true; do
  echo ""
  echo -e "${BOLD}Kernel source:${RESET}"
  echo "  1) stable — latest stable kernel from kernel.org"
  echo "  2) zen — latest Linux Zen kernel"
  echo ""
  read -rp "Choice [1/2]: " kernel_choice

  case "$kernel_choice" in
  1)
    KERNEL_SOURCE="stable"
    break
    ;;
  2)
    KERNEL_SOURCE="zen"
    break
    ;;
  *)
    warn "Invalid choice. Enter 1 or 2."
    ;;
  esac
done

step "Fetching latest $KERNEL_SOURCE kernel version"
if [[ "$KERNEL_SOURCE" == "zen" ]]; then
  LATEST=$(curl -s "https://api.github.com/repos/zen-kernel/zen-kernel/tags?per_page=100" | python3 -c "
import json,re,sys
for tag in json.load(sys.stdin):
  name=tag['name']
  if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+-zen[0-9]+', name):
    print(name[1:]); break
") || error "Could not determine latest Linux Zen kernel version."
else
  LATEST=$(curl -s "https://www.kernel.org/releases.json" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for r in data['releases']:
  if r['moniker'] == 'stable': print(r['version']); break
") || error "Could not determine latest stable kernel version from kernel.org."
fi
echo "OK"

[[ -z "$LATEST" ]] && error "Failed to parse latest $KERNEL_SOURCE kernel version"
step "Kernel Information"

CURRENT=$(uname -r)

info "Running: $CURRENT"
info "Will generate: $LATEST"
warn "Generating a kernel will change your current one."

read -rp "Proceed with kernel generation? (this will switch your kernel on reboot.) [y/N]: " choice

case "$choice" in
y | Y | yes | YES)
  echo "genkernel : Proceeding..."
  ;;
*)
  echo "genkernel : Cancelled."
  exit 0
  ;;
esac

$DRY_RUN && {
  info "--dry-run: exiting without making changes."
  exit 0
}

if [[ "$KERNEL_SOURCE" == "zen" ]]; then
  TARBALL="linux-${LATEST}.tar.gz"
  SIGNATURE=""
  DOWNLOAD_URL="https://github.com/zen-kernel/zen-kernel/archive/refs/tags/v${LATEST}.tar.gz"
  SIG_URL=""
else
  MAJOR="${LATEST%%.*}"
  TARBALL="linux-${LATEST}.tar.xz"
  SIGNATURE="linux-${LATEST}.tar.sign"
  DOWNLOAD_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
  SIG_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${SIGNATURE}"
fi

cd "$BUILD_DIR"

if [[ -f "$TARBALL" ]]; then
  info "Tarball already present — skipping download."
else
  info "Downloading from $DOWNLOAD_URL"
  curl -L --progress-bar -o "$TARBALL" "$DOWNLOAD_URL" ||
    error "Download failed."
  file "$TARBALL" | grep -Eq "XZ compressed|gzip compressed" ||
    error "Downloaded file is not a valid tarball (got $(file "$TARBALL" | cut -d: -f2))."
fi

# GPG signature verification
if [[ "$KERNEL_SOURCE" == "stable" ]] && command -v gpg &>/dev/null; then
  if [[ ! -f "$SIGNATURE" ]]; then
    info "Downloading GPG signature..."
    curl -L -s -o "$SIGNATURE" "$SIG_URL" || warn "Could not download signature — skipping verification."
  fi
  if [[ -f "$SIGNATURE" ]] && [[ -f "$TARBALL" ]]; then
    if ! gpg --list-keys 2>/dev/null | grep -q 'torvalds'; then
      warn "Linus's GPG key not in keyring — importing..."
      curl -s "https://www.kernel.org/keys/kernel.asc" | gpg --import 2>/dev/null || true
    fi
    info "Verifying GPG signature..."
    gpg --verify "$SIGNATURE" "$TARBALL" 2>/dev/null && success "Signature OK." ||
      warn "GPG verification failed — continuing anyway."
  fi
fi

step "Extracting linux-$LATEST"
SRC_DIR="$BUILD_DIR/linux-$LATEST"

if [[ -d "$SRC_DIR" ]]; then
  info "Source directory already exists — skipping extraction."
else
  info "Extracting (this may take a minute)..."
  if [[ "$KERNEL_SOURCE" == "zen" ]]; then
    mkdir -p "$SRC_DIR"
    tar -xf "$TARBALL" -C "$SRC_DIR" --strip-components=1 || error "Extraction failed."
  else
    tar -xf "$TARBALL" -C "$BUILD_DIR" || error "Extraction failed."
  fi
fi
success "Source ready at $SRC_DIR"

step "Configure kernel"
cd "$SRC_DIR"

RUNNING_CONFIG="/boot/config-${CURRENT}"
if [[ -f "$RUNNING_CONFIG" ]]; then
  info "Basing config on running kernel: $RUNNING_CONFIG"
  cp "$RUNNING_CONFIG" .config
  make olddefconfig
else
  info "No existing config found — using defconfig as base."
  make defconfig
fi

echo ""
echo -e "${BOLD}Kernel configuration:${RESET}"
echo "  1) skip — keep current config as-is"
echo "  2) menuconfig — interactive ncurses menu"
echo "  3) tinyconfig — minimal configuration"
echo ""
read -rp "Choice [1/2/3]: " config_choice

case "$config_choice" in
2)
  make menuconfig
  ;;
3)
  make tinyconfig
  ;;
*)
  info "Keeping config unchanged."
  ;;
esac

# Apply Zerene OS defaults: disable signing, set localversion
scripts/config --disable MODULE_SIG_ALL 2>/dev/null || true
scripts/config --disable SYSTEM_TRUSTED_KEYS 2>/dev/null || true
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" 2>/dev/null || true
scripts/config --disable SYSTEM_REVOCATION_KEYS 2>/dev/null || true
scripts/config --set-str SYSTEM_REVOCATION_KEYS "" 2>/dev/null || true

# Set -gen localversion suffix
scripts/config --set-str CONFIG_LOCALVERSION "-gen" 2>/dev/null || true
# Ensure critical filesystems are built-in
scripts/config --enable CONFIG_BTRFS_FS 2>/dev/null || true
scripts/config --enable CONFIG_OVERLAY_FS 2>/dev/null || true

success "Kernel configured."

# Pick up the final version string
NEW_VERSION=$(make -s kernelrelease 2>/dev/null)
info "New kernel version: $NEW_VERSION"

step "Compiling kernel (using $JOBS jobs)"
START_TIME=$SECONDS

make -j"$JOBS" 2>&1 | tee -a "$LOG_FILE" || error "Compilation failed. Check $LOG_FILE"

ELAPSED=$((SECONDS - START_TIME))
success "Compiled in $((ELAPSED / 60))m $((ELAPSED % 60))s"

step "Installing modules"
make modules_install 2>&1 | tee -a "$LOG_FILE" || error "Module install failed."

if [[ ! -d "/lib/modules/$NEW_VERSION" ]]; then
  error "Module directory /lib/modules/$NEW_VERSION was not created"
fi

step "Installing kernel image to /boot"
cp -v arch/x86/boot/bzImage /boot/vmlinuz-"$NEW_VERSION" ||
  error "Failed to copy kernel image to /boot"
cp -v System.map /boot/System.map-"$NEW_VERSION" 2>/dev/null || true
cp -v .config /boot/config-"$NEW_VERSION" 2>/dev/null || true

step "Installing initramfs"
INITRAMFS_SRC=""
INITRAMFS_DEST="/boot/initramfs-${NEW_VERSION}.img"

# Try distro-specific initramfs generators first
if command -v mkinitcpio &>/dev/null; then
  mkinitcpio -k "$NEW_VERSION" -g "$INITRAMFS_DEST" ||
    error "initramfs generation failed for $NEW_VERSION"
elif command -v dracut &>/dev/null; then
  dracut --force "$INITRAMFS_DEST" "$NEW_VERSION" ||
    error "initramfs generation failed for $NEW_VERSION"
elif command -v update-initramfs &>/dev/null; then
  update-initramfs -u -k "$NEW_VERSION" ||
    error "initramfs generation failed for $NEW_VERSION"
elif command -v kernel-install &>/dev/null; then
  kernel-install add "$NEW_VERSION" /boot/vmlinuz-"$NEW_VERSION"
elif [[ -d /tmp/initramfs_extract ]]; then
  # Custom minimal initramfs rebuild (Zerene OS style)
  info "Rebuilding initramfs from /tmp/initramfs_extract..."
  cd /tmp/initramfs_extract
  find . | cpio -o -H newc | gzip >"$INITRAMFS_DEST" ||
    error "initramfs rebuild failed."
elif [[ -f /boot/initramfs-${CURRENT}.img ]]; then
  info "Copying current initramfs (kernel-agnostic)..."
  cp /boot/initramfs-${CURRENT}.img "$INITRAMFS_DEST"
else
  warn "No initramfs generator or source found — kernel may not boot without one."
fi

step "Updating bootloader"

# Limine detection/update
if [[ -f /boot/limine.conf ]]; then
  info "Detected Limine bootloader — updating /boot/limine.conf..."
  LIMINE_CFG="/boot/limine.conf"
  cp "$LIMINE_CFG" "${LIMINE_CFG}.bak"
  info "Backed up to ${LIMINE_CFG}.bak"

  # Update kernel path
  sed -i "s|kernel_path: boot():/vmlinuz-[^ ]*|kernel_path: boot():/vmlinuz-${NEW_VERSION}|g" "$LIMINE_CFG"
  # Update initramfs path
  sed -i "s|module_path: boot():/initramfs-[^ ]*\.img|module_path: boot():/initramfs-${NEW_VERSION}.img|g" "$LIMINE_CFG"
  success "Limine config updated for kernel $NEW_VERSION."
fi

# GRUB detection/update (fallback for non-Zerene distros)
if command -v grub-mkconfig &>/dev/null || command -v update-grub &>/dev/null; then
  GRUB_CMD=""
  if command -v grub-mkconfig &>/dev/null; then
    GRUB_CMD="grub-mkconfig"
  elif command -v update-grub &>/dev/null; then
    GRUB_CMD="update-grub"
  fi

  GRUB_CFG=""
  for p in /boot/grub/grub.cfg /boot/efi/EFI/GRUB/grub.cfg; do
    [[ -f "$p" ]] && {
      GRUB_CFG="$p"
      break
    }
  done
  [[ -z "$GRUB_CFG" ]] && GRUB_CFG="/boot/grub/grub.cfg"

  cp "$GRUB_CFG" "${GRUB_CFG}.bak"
  info "Backed up grub.cfg to ${GRUB_CFG}.bak"

  if [[ "$GRUB_CMD" == "update-grub" ]]; then
    $GRUB_CMD 2>&1 | tee -a "$LOG_FILE" || error "update-grub failed."
  else
    $GRUB_CMD -o "$GRUB_CFG" 2>&1 | tee -a "$LOG_FILE" || error "grub-mkconfig failed."
  fi
  success "GRUB config regenerated with Linux $NEW_VERSION entry."
fi

step "Cleaning up"
cd "$BUILD_DIR" 2>/dev/null || true
rm -rf "$SRC_DIR" 2>/dev/null || warn "Could not remove $SRC_DIR"
if [[ -n "${TARBALL:-}" ]] && [[ -f "$BUILD_DIR/$TARBALL" ]]; then
  rm -f "$BUILD_DIR/$TARBALL" "$BUILD_DIR/${TARBALL}.sign" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Kernel $NEW_VERSION generated successfully.  ║${RESET}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}${BOLD}║  Requiring reboot to use this kernel                 ║${RESET}"
echo -e "${GREEN}${BOLD}║    ${BOLD}reboot                                            ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Full log saved to $LOG_FILE"
