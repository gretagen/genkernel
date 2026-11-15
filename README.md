# Haliade system Genkernel

# This tool was mostly written by AI! hense why the quality is so shitty
# still, we're gradually rewriting it.


This repository contains the kernel generation script used by Haliade system
maintainers:

```text
bin/genkernel
```

It downloads the selected Linux kernel, applies the Haliade system defaults, builds
and installs it, generates an initramfs, and updates the bootloader.

## Usage

Run the script as root:

```bash
sudo bin/genkernel
```

Options:

```text
--dry-run       Display the target kernel and stop after confirmation.
--jobs N        Build with N parallel jobs.
--jobs=N        Equivalent to --jobs N.
```

The following environment variables are supported:

| Variable | Default | Purpose |
| --- | --- | --- |
| `BUILD_DIR` | `/usr/src` | Source download and build directory |
| `JOBS` | `$(nproc)` | Number of parallel build jobs |

## How the script works

### 1. Select the kernel

The script prompts the maintainer to choose the kernel to generate. It then
displays the running and target versions and waits for confirmation.

The menu is built from the kernel.org release feed and lists the mainline
release candidate, the current stable, and every active longterm series.
`linux-next` is not offered because kernel.org does not publish a source
tarball for it.

### 2. Download the sources

The selected source archive is downloaded from its upstream source. The archive
name is taken from the URL, so the mainline `.tar.gz` and the stable and
longterm `.tar.xz` files are all handled without special cases.

An archive already present in `BUILD_DIR` is reused, but only after it is
confirmed to be a complete tarball that unpacks into the expected
`linux-<version>` directory. Anything else (a truncated download, an HTML
error page, or a leftover from a different version) is discarded and fetched
again.

When a detached signature is published, the script reads the signing key ID out
of the signature, imports that key from a keyserver if the keyring is missing
it, and verifies the archive. Signature failure emits a warning and does not
stop the build; the full GPG output is written to the log.

Mainline release candidates are not signed, so verification is skipped for
them.

Note that kernel.org's `.tar.sign` files do not always match the tarballs
currently on the CDN, which makes the signature step report a bad signature
even for a correctly downloaded archive. To cross-check an archive by hand,
compare it against kernel.org's signed checksum file:

```bash
sha256sum linux-6.18.54.tar.xz
grep linux-6.18.54.tar.xz <(curl -fsSL \
  https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc)
```

### 3. Configure the kernel

The archive is extracted to `<BUILD_DIR>/linux-<version>`.

The initial configuration comes from `/boot/config-$(uname -r)` followed by
`make olddefconfig`. If that file does not exist, `make defconfig` is used.

The maintainer can then:

1. keep the prepared configuration;
2. run `make menuconfig`;
3. replace it with `make tinyconfig`.

The script subsequently applies the Haliade system defaults:

- set `CONFIG_LOCALVERSION` to `-gen`;
- disable module signing;
- clear the trusted and revoked system key settings;
- build Btrfs support into the kernel;
- build OverlayFS support into the kernel.

The configuration is refreshed with `make olddefconfig` afterwards so that any
symbol the script added is resolved by the kernel build system.

### 4. Build and install

The kernel is compiled with `make -j"$JOBS"`, then its modules are installed
with `make modules_install`.

The following files are copied to `/boot` using the release name returned by
`make kernelrelease`:

```text
vmlinuz-<kernel-release>
System.map-<kernel-release>
config-<kernel-release>
```

Modules are installed under `/lib/modules/<kernel-release>`.

### 5. Generate the initramfs

The target path is `/boot/initramfs-<kernel-release>.img`. The first available
method is used in this order:

1. `mkinitcpio`;
2. `dracut`;
3. `update-initramfs`;
4. `kernel-install`;
5. rebuild the tree at `/tmp/initramfs_extract`;
6. copy the current kernel's initramfs.

If no method is available, the script warns and continues.

Before generating, the script probes `/boot` by actually creating a file.
`[[ -w /boot ]]` is not good enough for this: as root, `access(2)` reports
success even on a read-only mount, so it would wave through the very failure it
is meant to catch. If the probe fails the script stops with a message telling
you to remount `/boot` read-write.

`mkinitcpio` and `dracut` are given the output path directly, so they generate
into `/boot/.initramfs-<kernel-release>.tmp.img` (a name that does not exist
yet), and the result is moved into place afterwards. This matters because
`mkinitcpio` validates the `-g` path before doing any work and, once that file
already exists, only tests writability of the file itself; it never falls back
to the parent directory. A stale image left behind by an earlier run therefore
aborts generation with `Invalid option -g -- ... must be writable` even though
`/boot` is perfectly writable. The temporary name is created in `/boot` rather
than `/tmp` because these images are hundreds of megabytes and `/tmp` is
normally a tmpfs; moving within the same filesystem also replaces the stale
image atomically.

`update-initramfs` and `kernel-install` choose their own output names and are
therefore called as-is.

Once the image is in place, the script verifies that it exists and is not empty,
and stops with a clear error if it is not.

### 6. Update the bootloader

For Limine, the script backs up `/boot/limine.conf` to
`/boot/limine.conf.bak`.

On Haliade system that file belongs to `chronos`: it regenerates the whole file and
marks it as not to be hand-edited. The script therefore runs
`chronos rewrite-limine` when `chronos` is available, and logs its output.
`chronos` pins each boot entry to the kernel its subvolume actually has modules
for: the default entry follows the booted subvolume (the newest kernel after an
upgrade) and every generation keeps the kernel it was captured with. The
`vmlinuz-*` / `initramfs-<version>.img` pair installed above is therefore used
by the default entry, and the two tools cannot disagree about which kernel is
booted.

`chronos` writes through a temporary file, so if it fails the existing config is
left untouched. The script falls back to editing `/boot/limine.conf` in place,
replacing the **default** entry's kernel and initramfs paths with the new
release and leaving any generation entries untouched. That in-place edit is
also the only path used when `chronos` is not installed.

If GRUB tooling is present, the detected `grub.cfg` is backed up with a
`.bak` suffix and regenerated with `grub-mkconfig` or `update-grub`.

### 7. Snapshot the new kernel as a generation

When `chronos` is available (Haliade system), the script snapshots the freshly
upgraded root as a new btrfs generation:

```bash
chronos create "kernel <version>"
```

so the new kernel gets its own Limine entry and rollback point. `chronos`
pins every boot entry to the kernel its subvolume actually has modules for:
existing generations keep the kernel they were captured with, and only the
new generation (plus the live `@` entry) boot the new kernel. This is what
keeps a rollback from booting a kernel whose modules are absent from the
chosen generation (which would leave the machine with no drivers and no
network).

The step runs after the header/DKMS stage so the snapshot contains the newly
rebuilt out-of-tree modules. It is optional: on systems without the btrfs
`@`/`@snapshots` layout (for example the live ISO) the call fails and the
script warns and continues: the kernel itself is already installed.

### 8. Clean up

After a successful installation, the extracted source directory, the downloaded
archive, and its signature are removed from `BUILD_DIR`.

The system is not rebooted automatically.

## Logs

Progress and build output are appended to:

```text
/var/log/kernel_generation.log
```

Compilation and installation failures stop the script and are recorded there.
