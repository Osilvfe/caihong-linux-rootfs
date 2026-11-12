# power-profiles-daemon-caihong

Caihong ships upstream power-profiles-daemon with one additional CPU driver,
`qcom_cpufreq`. Stock PPD falls back to the `placeholder` driver on this
device because `qcom-cpufreq-hw` exposes neither an energy/performance
preference nor an ACPI `platform_profile`.

## Profiles

| Profile | CPU boost | CPU max | GPU max |
| --- | --- | --- | --- |
| `power-saver` | off | 70% of each policy's non-boost maximum | 50% of the GPU maximum |
| `balanced` | off | full non-boost range | full range |
| `performance` | on | full range, including the prime-core boost OPP | full range |

The percentages are rounded down to the nearest supported OPP. Thermal
throttling is still enforced by the kernel; the driver only lowers the
userspace caps and never raises a thermal limit.

## Testing

Tested on the OnePlus Pad Pro: the driver works as intended, and selecting
the `power-saver` profile noticeably reduces CPU heat compared with
`balanced`.

## Tuning

The power-saver caps can be changed without rebuilding by adding a systemd
drop-in:

```ini
# /etc/systemd/system/power-profiles-daemon.service.d/qcom.conf
[Service]
Environment=PPD_QCOM_CPU_POWER_SAVER_PERCENT=60
Environment=PPD_QCOM_GPU_POWER_SAVER_PERCENT=40
```

Valid values are 10-100. Invalid values are ignored with a warning and the
built-in defaults (70 and 50) are used.

## Build

`scripts/checkout-dependencies.sh` checks out the pinned upstream commit into
`external/power-profiles-daemon`. The platform package build applies
`0001-qcom-cpufreq.patch` through `scripts/install-caihong-ppd-stage.sh` inside
the shared AArch64 build root, then places the resulting files in
`caihong-platform`. Rootfs image builds install that same package instead of
building a second copy. The stock `power-profiles-daemon` package is replaced
by the packaged binary while keeping the upstream service, D-Bus and polkit
file names.

To rebuild the package by hand on an AArch64 Arch Linux system:

```sh
packaging/power-profiles-daemon-caihong/build-rootfs-package.sh \
  external/power-profiles-daemon \
  packaging/power-profiles-daemon-caihong/0001-qcom-cpufreq.patch \
  build/ppd
sudo pacman -U build/ppd/power-profiles-daemon-caihong-*.pkg.tar.zst
```

The source directory must be pristine, because the patch is applied to it.
