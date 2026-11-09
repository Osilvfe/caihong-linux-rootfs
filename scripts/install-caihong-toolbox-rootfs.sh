#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
rootfs=${1:-}
source_tree="$project_dir/external/caihong-toolbox"

if [[ -z $rootfs || ! -d $rootfs ]]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi

rootfs=$(cd -- "$rootfs" && pwd)
case "$rootfs" in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe rootfs directory: $rootfs" >&2
		exit 1
		;;
esac

for path in Makefile pyproject.toml bin/caihong-toolbox \
	caihong_toolbox/gui.py packaging/caihong-toolbox.service; do
	if [[ ! -e $source_tree/$path ]]; then
		echo "incomplete Caihong Toolbox source tree: $source_tree" >&2
		exit 1
	fi
done

for tool in git make rsync; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

if [[ -d $source_tree/.git ]]; then
	if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
		echo "refusing to package uncommitted Caihong Toolbox changes" >&2
		exit 1
	fi
	source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)
else
	source_commit=unknown
fi
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$source_tree/pyproject.toml" | head -n 1)
[[ -n $version ]] || version=unknown

stage_parent="$project_dir/build"
mkdir -p "$stage_parent"
work_dir=$(mktemp -d "$stage_parent/caihong-toolbox.XXXXXX") || exit 1
stage="$work_dir/root"

cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

make -C "$source_tree" DESTDIR="$stage" install >/dev/null

for path in \
	usr/bin/caihong-toolbox \
	usr/lib/caihong-toolbox/caihong-toolbox-service \
	usr/lib/caihong-toolbox/caihong_toolbox/gui.py \
	usr/lib/systemd/system/caihong-toolbox.service \
	usr/share/dbus-1/system-services/org.caihong.Toolbox1.service \
	usr/share/dbus-1/system.d/org.caihong.Toolbox1.conf \
	usr/share/polkit-1/actions/org.caihong.toolbox.policy \
	usr/share/applications/caihong-toolbox.desktop \
	usr/share/icons/hicolor/scalable/apps/caihong-toolbox.svg; do
	if [[ ! -e $stage/$path ]]; then
		echo "Caihong Toolbox install is missing /$path" >&2
		exit 1
	fi
done

install -d -m 0755 "$stage/usr/share/caihong"
cat > "$stage/usr/share/caihong/toolbox-build-info" <<INFO
build=caihong
version=$version
source_commit=$source_commit
INFO
chmod 0644 "$stage/usr/share/caihong/toolbox-build-info"

rsync -aHAX --numeric-ids "$stage/" "$rootfs/"
echo "Caihong Toolbox installed into $rootfs"
