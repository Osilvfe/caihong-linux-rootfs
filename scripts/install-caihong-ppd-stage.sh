#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build power-profiles-daemon with the Caihong Qualcomm driver into the common
# platform-package stage. The source is patched in a disposable copy and built
# inside the prepared AArch64 build root so images and updates use one binary.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
build_root=${CAIHONG_BUILD_ROOT:-}
source_tree=$project_dir/external/power-profiles-daemon
patch_file=$project_dir/packaging/power-profiles-daemon-caihong/0001-qcom-cpufreq.patch

if [[ -z $stage || ! -d $stage ]]; then
	echo "usage: $0 STAGE_DIR" >&2
	exit 2
fi
stage=$(cd -- "$stage" && pwd)
case $stage in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe stage directory: $stage" >&2
		exit 1
		;;
esac
if [[ -z $build_root || ! -d $build_root ]]; then
	echo "CAIHONG_BUILD_ROOT must point to a prepared AArch64 build root" >&2
	exit 1
fi
build_root=$(cd -- "$build_root" && pwd)
[[ -f $source_tree/meson.build ]] || {
	echo "missing power-profiles-daemon source; run scripts/checkout-dependencies.sh" >&2
	exit 1
}
[[ -f $patch_file ]] || {
	echo "missing power-profiles-daemon patch: $patch_file" >&2
	exit 1
}
for tool in chroot git patch rsync; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing host tool: $tool" >&2
		exit 1
	}
done

work_dir=$(mktemp -d "$project_dir/build/caihong-ppd-stage.XXXXXX")
source_copy="$work_dir/source"
install_root="$work_dir/root"
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_copy" "$install_root"
rsync -aHAX --numeric-ids --exclude=.git --exclude=build \
	"$source_tree/" "$source_copy/"
patch -d "$source_copy" -Np1 --batch -i "$patch_file"

install -d -m 0755 "$build_root/var/tmp"
rm -rf -- "$build_root/var/tmp/caihong-ppd-src" \
	"$build_root/var/tmp/caihong-ppd-build" \
	"$build_root/var/tmp/caihong-ppd-install"
rsync -aHAX --numeric-ids "$source_copy/" "$build_root/var/tmp/caihong-ppd-src/"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
chroot "$build_root" "${chroot_env[@]}" \
	meson setup /var/tmp/caihong-ppd-build /var/tmp/caihong-ppd-src \
	--buildtype=release --prefix=/usr --libexecdir=lib \
	-Dtests=false -Dgtk_doc=false
chroot "$build_root" "${chroot_env[@]}" \
	meson compile -C /var/tmp/caihong-ppd-build
chroot "$build_root" "${chroot_env[@]}" \
	/usr/bin/env DESTDIR=/var/tmp/caihong-ppd-install \
	meson install -C /var/tmp/caihong-ppd-build --no-rebuild

daemon=$build_root/var/tmp/caihong-ppd-install/usr/lib/power-profiles-daemon
[[ -x $daemon ]] || {
	echo "power-profiles-daemon install is missing /usr/lib/power-profiles-daemon" >&2
	exit 1
}
grep -aq 'qcom_cpufreq' "$daemon" || {
	echo "power-profiles-daemon was built without the qcom_cpufreq driver" >&2
	exit 1
}
rsync -aHAX --numeric-ids \
	"$build_root/var/tmp/caihong-ppd-install/" "$install_root/"

install -d -m 0755 "$stage/usr/share/caihong"
if [[ -d $source_tree/.git ]]; then
	source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)
else
	source_commit=$(sed -n 's/^POWER_PROFILES_DAEMON_COMMIT=//p' \
		"$project_dir/build/dependencies.resolved.env" 2>/dev/null | tail -n 1)
fi
if [[ -n ${source_commit:-} ]]; then
	printf 'source_commit=%s\n' "$source_commit" \
		> "$stage/usr/share/caihong/ppd-build-info"
	chmod 0644 "$stage/usr/share/caihong/ppd-build-info"
fi
rsync -aHAX --numeric-ids "$install_root/" "$stage/"

rm -rf -- "$build_root/var/tmp/caihong-ppd-src" \
	"$build_root/var/tmp/caihong-ppd-build" \
	"$build_root/var/tmp/caihong-ppd-install"
echo "power-profiles-daemon staged for the platform package"
