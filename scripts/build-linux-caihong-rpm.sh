#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
module_tree=${1:-"$project_dir/modules-current"}
release_dir=${2:-"$project_dir/release"}

for tool in bsdtar depmod rpmbuild rpm rpm2cpio sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing tool: $tool" >&2
		exit 1
	}
done

release=
for candidate in "$module_tree"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	[ -z "$release" ] || {
		echo "module tree contains more than one kernel release" >&2
		exit 1
	}
	release=${candidate##*/}
done
[ -n "$release" ] || { echo "module tree contains no kernel release" >&2; exit 1; }

boot_linux="$release_dir/caihong-boot-linux-$release.img"
boot_userdata="$release_dir/caihong-boot-userdata-$release.img"
for input in "$boot_linux" "$boot_userdata"; do
	[ -f "$input" ] || { echo "missing package input: $input" >&2; exit 1; }
done

version=$(printf '%s' "$release" | sed 's/[^[:alnum:].+~^]/./g')
output="$release_dir/linux-caihong.rpm"
temporary="$output.new"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/linux-caihong-rpm.XXXXXX")
stage="$work_dir/stage"
topdir="$work_dir/rpmbuild"

cleanup()
{
	rm -rf -- "$work_dir"
	rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

module_stage="$work_dir/module-stage"
CAIHONG_EXPECTED_RELEASE=$release \
	"$project_dir/scripts/install-caihong-modules.sh" "$module_tree" "$module_stage"
install -d -m 0755 "$stage/usr/lib/linux-caihong/modules"
mv -- "$module_stage/lib/modules/$release" \
	"$stage/usr/lib/linux-caihong/modules/$release"
install -D -m 0644 "$project_dir/rootfs/archlinuxarm/etc/modules-load.d/caihong.conf" \
	"$stage/usr/lib/modules-load.d/caihong.conf"
install -D -m 0755 \
	"$project_dir/packaging/linux-caihong/install-current-slot" \
	"$stage/usr/lib/linux-caihong/install-current-slot"
install -m 0644 "$boot_linux" "$stage/usr/lib/linux-caihong/boot-linux.img"
install -m 0644 "$boot_userdata" "$stage/usr/lib/linux-caihong/boot-userdata.img"
printf '%s\n' "$release" > "$stage/usr/lib/linux-caihong/kernel-release"
install -D -m 0644 "$project_dir/linux/COPYING" \
	"$stage/usr/share/licenses/linux-caihong/COPYING"

install -d -m 0755 "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" \
	"$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS"
cat > "$topdir/SPECS/linux-caihong.spec" <<EOF
Name: linux-caihong
Version: $version
Release: 1
Summary: Mainline Linux kernel and modules for OnePlus Pad Pro (caihong)
License: GPL-2.0-only
URL: https://github.com/Osilvfe/linux
BuildArch: aarch64
Requires: bash
Requires: coreutils
Requires: findutils
Requires: grep
Requires: kmod
Requires: util-linux

%description
Mainline Linux kernel, boot images, and matching modules for OnePlus Pad Pro.

%install
mkdir -p %{buildroot}
cp -a "$stage"/. %{buildroot}/

%posttrans
/usr/lib/linux-caihong/install-current-slot

%preun
if [ "\$1" -eq 0 ]; then
    /usr/lib/linux-caihong/install-current-slot --remove-modules
fi

%files
%license /usr/share/licenses/linux-caihong/COPYING
/usr/lib/linux-caihong
/usr/lib/modules-load.d/caihong.conf
EOF

rpmbuild -bb --target aarch64 --define "_topdir $topdir" \
	"$topdir/SPECS/linux-caihong.spec"
built=$(find "$topdir/RPMS" -type f -name 'linux-caihong-*.rpm' -print)
[ "$(printf '%s\n' "$built" | sed '/^$/d' | wc -l)" -eq 1 ] || {
	echo "expected exactly one built linux-caihong RPM" >&2
	exit 1
}
install -m 0644 "$built" "$temporary"
mv -- "$temporary" "$output"

[ "$(rpm -qp --queryformat '%{NAME}\n' "$output")" = linux-caihong ]
[ "$(rpm -qp --queryformat '%{ARCH}\n' "$output")" = aarch64 ]
rpm -qpl "$output" | grep -qx '/usr/lib/linux-caihong/kernel-release'
if rpm -qpl "$output" | grep -q '^/usr/lib/modules/'; then
	echo "RPM must not own the activated module directory" >&2
	exit 1
fi
archived_release=$(rpm2cpio "$output" | bsdtar -xOf - \
	./usr/lib/linux-caihong/kernel-release)
[ "$archived_release" = "$release" ] || {
	echo "packaged kernel release does not match $release" >&2
	exit 1
}
for root_partlabel in linux userdata; do
	source_hash=$(sha256sum "$release_dir/caihong-boot-$root_partlabel-$release.img" |
		awk '{ print $1 }')
	archive_hash=$(rpm2cpio "$output" | bsdtar -xOf - \
		"./usr/lib/linux-caihong/boot-$root_partlabel.img" |
		sha256sum | awk '{ print $1 }')
	[ "$source_hash" = "$archive_hash" ] || {
		echo "packaged $root_partlabel boot image failed verification" >&2
		exit 1
	}
done

rm -rf -- "$work_dir"
trap - EXIT HUP INT TERM
echo "created RPM package: $output"
sha256sum "$output"
