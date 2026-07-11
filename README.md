# Intel Xe Battlemage stale temperature workaround

Experimental Linux `xe` driver workaround for stale package-temperature readings
and a fan that remains unnecessarily fast on an idle Intel Battlemage GPU.

This is **not an upstream fix**. The current expanded patch force-wakes the root
GT before MMIO temperature reads, waits 1–2 ms for telemetry to refresh, and
exposes the available per-channel VRAM temperature registers.

## Tested hardware and software

- Intel Arc Pro B70 / Battlemage G31 (`8086:e223`)
- Subsystem `6688:8073`
- Ubuntu 24.04
- Ubuntu HWE kernel `6.17.0-35-generic`
- `xe` kernel driver

The installed test module was built from Ubuntu's matching
`linux-hwe-6.17_6.17.0-35.35~24.04.1` source package. Do not install a compiled
module built for a different kernel.

## Symptoms and result

With a llama.cpp model resident in GPU memory but not generating tokens:

- package temperature could remain implausibly high;
- the fan could remain at full speed despite the card feeling cold;
- starting a tiny inference caused the reported temperature to fall instantly;
- manually force-waking GT0 also refreshed the package-temperature reading.

After applying this patch, the package temperature cooled progressively instead
of remaining stale (observed `55 -> 50 -> ... -> 44°C`), and the fan returned to
about 1400 RPM. Starting inference no longer caused an impossible package-
temperature collapse.

The expanded patch exposes the aggregate and available per-channel VRAM
temperatures. The tested B70 firmware rejects the thermal mailbox used for
memory-controller (`mctrl`) and PCIe temperatures, so those channels remain
hidden rather than reporting invented or stale values.

Updating Battlemage GuC firmware from `70.44.1` to `70.49.4` did not resolve the
problem on the tested card. The card's persistent firmware was `31.1058`, with no
newer firmware offered by LVFS at the time of testing.

## Patch

[`xe-hwmon-battlemage-telemetry.patch`](xe-hwmon-battlemage-telemetry.patch) is
the current patch. It contains the force-wake workaround, VRAM channels, and
thermal-mailbox support. Unsupported mailbox channels are hidden.

[`xe-hwmon-battlemage-forcewake.patch`](xe-hwmon-battlemage-forcewake.patch) is
retained as the historical minimal option. It only applies the package/VRAM
force-wake workaround.

## Automatic setup on Ubuntu 24.04

Install the build dependencies and this repository's helper and package hooks:

```bash
sudo apt install bc bison build-essential dpkg-dev flex libelf-dev libssl-dev \
  linux-headers-"$(uname -r)" wget zstd
sudo ./install.sh
```

The installer copies the expanded patch to `/var/lib/b70-xe-hwmon`, installs
`b70-xe-rebuild` in `/usr/local/sbin`, and registers the same fail-open hook in
both `/etc/kernel/postinst.d` and `/etc/kernel/header_postinst.d`. Using both is
important because image and header packages can be configured in either order.
The hook logs failures to `/var/log/b70-xe-hwmon.log` but always returns success,
so an optional local module can never fail a kernel package update.

The helper intentionally supports only kernels whose headers identify their
source package as `linux-hwe-6.17`. It downloads the exact matching source files
from Launchpad, applies the patch, builds with the installed kernel's exact
release, and compares both vermagic and imported symbol CRCs with Ubuntu's stock
`xe.ko`. Only then does it atomically place the override and refresh depmod and
the initramfs. A missing header, source/patch mismatch (including a future source
that already contains some backport), build error, or verification error leaves
the stock module—and any existing working override—untouched.

To build immediately rather than waiting for a package hook:

```bash
sudo /usr/local/sbin/b70-xe-rebuild "$(uname -r)"
```

This automation is deliberately not generalized to another Ubuntu source
package or kernel series: kernel module ABI compatibility must be re-evaluated
before extending it beyond 6.17.

## Manual build (historical minimal patch)

These commands intentionally build the module locally against the running
kernel. Kernel modules have a strict ABI/version dependency.

Install build dependencies and matching headers:

```bash
sudo apt install \
  bc bison build-essential flex libelf-dev libssl-dev linux-headers-"$(uname -r)" \
  zstd
```

Enable `deb-src` entries for Ubuntu if necessary, then download the source that
matches the running Ubuntu kernel package:

```bash
apt source linux-hwe-6.17
cd linux-hwe-6.17-*/
```

Confirm that the source version and running image version match before building:

```bash
dpkg-query -W -f='${Version}\n' "linux-image-$(uname -r)"
head -n 1 debian.master/changelog
```

Prepare and apply the old force-wake-only patch. Replace `/path/to/repo` with
this repository's absolute path:

```bash
cp "/boot/config-$(uname -r)" .config
cp "/usr/src/linux-headers-$(uname -r)/Module.symvers" .
make olddefconfig
make modules_prepare
patch -p1 < /path/to/repo/xe-hwmon-battlemage-forcewake.patch
```

Build `xe.ko`. Adding the Xe build directory to `PATH` allows the kernel build to
find its generated `xe_gen_wa_oob` helper:

```bash
PATH="$PWD/drivers/gpu/drm/xe:$PATH" \
  make -j"$(nproc)" \
  KERNELRELEASE="$(uname -r)" \
  M=drivers/gpu/drm/xe \
  modules
```

Verify that the resulting module targets the running kernel:

```bash
modinfo drivers/gpu/drm/xe/xe.ko | grep '^vermagic:'
uname -r
```

## Install

Secure Boot must either be disabled or configured to trust your module-signing
key. An unsigned local module will not load under enforcing Secure Boot.

The following installs an override under `updates/`; it does not modify Ubuntu's
packaged copy of the driver:

```bash
kernel_release="$(uname -r)"
zstd -f drivers/gpu/drm/xe/xe.ko -o /tmp/xe.ko.zst
sudo install -d "/lib/modules/$kernel_release/updates/b70-xe"
sudo install -m 0644 /tmp/xe.ko.zst \
  "/lib/modules/$kernel_release/updates/b70-xe/xe.ko.zst"
sudo depmod -a "$kernel_release"
sudo update-initramfs -u -k "$kernel_release"
sudo reboot
```

After reboot, confirm that Linux selected the override:

```bash
modinfo -n xe
modinfo xe | grep -E '^(filename|vermagic):'
```

The filename should be under:

```text
/lib/modules/<kernel>/updates/b70-xe/xe.ko.zst
```

Locally built modules normally show `OE` in `/proc/sys/kernel/tainted`; that does
not by itself indicate a driver error.

## Monitor the sensors

Find the Xe hwmon directory rather than assuming a fixed `hwmonN` number:

```bash
xe_hwmon="$({
  for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = xe ] && echo "$d" && break
  done
})"

while sleep 1; do
  printf '%(%T)T  pkg=%s  vram=%s  fan=%s\n' -1 \
    "$(cat "$xe_hwmon/temp2_input")" \
    "$(cat "$xe_hwmon/temp3_input")" \
    "$(cat "$xe_hwmon/fan1_input")"
done
```

Temperature values are millidegrees Celsius; fan values are RPM.

## Roll back

Boot a stock kernel first if the patched module causes display or boot problems.
Then remove only this override and rebuild module metadata/initramfs:

```bash
kernel_release="$(uname -r)"
sudo rm -f "/lib/modules/$kernel_release/updates/b70-xe/xe.ko.zst"
sudo rmdir "/lib/modules/$kernel_release/updates/b70-xe" 2>/dev/null || true
sudo depmod -a "$kernel_release"
sudo update-initramfs -u -k "$kernel_release"
sudo reboot
```

The packaged Ubuntu `xe` module remains in the kernel's normal module directory.

## Caveats

- This was tested on one Arc Pro B70 and one Ubuntu kernel build.
- Supported 6.17 HWE kernels are automatically rebuilt after setup; all other
  kernel series continue to use their stock module.
- Polling temperature now briefly force-wakes the GT, which may have a small
  power-management cost proportional to sensor polling frequency.
- This may mask an underlying device-firmware telemetry bug. An eventual
  upstream kernel or firmware fix should be preferred.
- Report exact PCI IDs, kernel version, firmware versions, workload, and before/
  after sensor traces when testing another system.

## License

The patch modifies an MIT-licensed Intel Xe driver source file and is distributed
under the MIT license. See [LICENSE](LICENSE).
