# HaliadeOS Genkernel

This repository contains the kernel generation script used by HaliadeOS
maintainers:

```text
bin/genkernel
```

It downloads the selected Linux kernel, applies the HaliadeOS defaults, builds
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
`linux-<version>` directory. Anything else — a truncated download, an HTML
error page, or a leftover from a different version — is discarded and fetched
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

The script subsequently applies the HaliadeOS defaults:

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

### 6. Update the bootloader

For Limine, the script backs up `/boot/limine.conf` to
`/boot/limine.conf.bak`, then replaces the kernel and initramfs paths with the
new release.

If GRUB tooling is present, the detected `grub.cfg` is backed up with a
`.bak` suffix and regenerated with `grub-mkconfig` or `update-grub`.

### 7. Clean up

After a successful installation, the extracted source directory, the downloaded
archive, and its signature are removed from `BUILD_DIR`.

The system is not rebooted automatically.

## Logs

Progress and build output are appended to:

```text
/var/log/kernel_generation.log
```

Compilation and installation failures stop the script and are recorded there.
