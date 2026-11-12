#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
module_root=${1:-"$project_dir/modules-current"}
target=${2:-"$project_dir/rootfs-stage"}
expected_release=${CAIHONG_EXPECTED_RELEASE:-}

if [ ! -d "$module_root/lib/modules" ]; then
	echo "module tree not found: $module_root/lib/modules" >&2
	exit 1
fi

module_root=$(cd -- "$module_root" && pwd)
mkdir -p "$target"
target=$(cd -- "$target" && pwd)

release=
for candidate in "$module_root"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	if [ -n "$release" ]; then
		echo "more than one kernel release exists below $module_root/lib/modules" >&2
		exit 1
	fi
	release=${candidate##*/}
done

if [ -z "$release" ]; then
	echo "no installed kernel release found" >&2
	exit 1
fi

if [ -n "$expected_release" ] && [ "$release" != "$expected_release" ]; then
	echo "kernel module tree release mismatch: $release (expected $expected_release)" >&2
	exit 1
fi

#
# Ship the complete modules_install tree.  A hand-maintained module list used
# to silently drop anything it did not mention (USB audio, for example), and a
# new `=m` option then disappeared from the package without a build failure.
# Copying the whole tree keeps the payload identical to the kernel build, and
# depmod below regenerates the indexes for the new location.
dest_release="$target/lib/modules/$release"
mkdir -p "$dest_release"
# The caller may reuse a staging tree.  Never leave a previous kernel release
# mixed into the new rootfs.
find "$target/lib/modules" -mindepth 1 -maxdepth 1 \
	! -path "$dest_release" -exec rm -rf -- {} +
find "$dest_release" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

# `build` and `source` point at the kernel build and source trees on the build
# host.  They are meaningless in a package and must not leak absolute paths.
tar -C "$module_root/lib/modules/$release" \
	--exclude=./build --exclude=./source -cf - . |
	tar -C "$dest_release" -xf -

depmod -b "$target" "$release"

count=$(find "$dest_release" -name '*.ko' | wc -l)

modules_load_conf="$project_dir/rootfs/archlinuxarm/etc/modules-load.d/caihong.conf"
if [ -f "$modules_load_conf" ]; then
	install -D -m 0644 "$modules_load_conf" \
		"$target/etc/modules-load.d/caihong.conf"
fi

echo "installed $count modules for $release into $dest_release"
