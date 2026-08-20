# ZereneOS Genkernel

This repository contains the kernel generation script used by ZereneOS
maintainers:

```text
bin/genkernel.sh
```

It downloads the selected Linux kernel, applies the ZereneOS defaults, builds
and installs it, generates an initramfs, and updates the bootloader.

## Usage

Run the script as root:

```bash
sudo bash bin/genkernel.sh
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

### 2. Download the sources

The selected source archive is downloaded from its upstream source. An existing
archive in `BUILD_DIR` is reused.

The archive type is validated with `file`. For stable kernels, if GPG is
installed, the script imports the kernel.org signing key when necessary and
verifies the signature. Signature failure emits a warning but does not stop the
build.

### 3. Configure the kernel

The archive is extracted to `<BUILD_DIR>/linux-<version>`.

The initial configuration comes from `/boot/config-$(uname -r)` followed by
`make olddefconfig`. If that file does not exist, `make defconfig` is used.

The maintainer can then:

1. keep the prepared configuration;
2. run `make menuconfig`;
3. replace it with `make tinyconfig`.

The script subsequently applies the ZereneOS defaults:

- set `CONFIG_LOCALVERSION` to `-gen`;
- disable module signing;
- clear the trusted and revoked system key settings;
- build Btrfs support into the kernel;
- build OverlayFS support into the kernel.

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

After a successful installation, the extracted source directory and downloaded
archive are removed from `BUILD_DIR`.

The system is not rebooted automatically.

## Logs

Progress and build output are appended to:

```text
/var/log/kernel_generation.log
```

Compilation and installation failures stop the script and are recorded there.
