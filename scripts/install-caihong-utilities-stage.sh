#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Compile Caihong board utilities inside the prepared AArch64 build root so the
# image and the incremental platform package contain the same binaries.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
build_root=${CAIHONG_BUILD_ROOT:-}

if [[ -z $stage || ! -d $stage ]]; then
	echo "usage: $0 STAGE_DIR" >&2
	exit 2
fi
stage=$(cd -- "$stage" && pwd)
if [[ -z $build_root || ! -d $build_root ]]; then
	echo "CAIHONG_BUILD_ROOT must point to a prepared AArch64 build root" >&2
	exit 1
fi
build_root=$(cd -- "$build_root" && pwd)
for tool in cc chroot file install; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing host tool: $tool" >&2
		exit 1
	}
done
for source in tools/caihong-nvram-mac.c tools/caihong-npu-info.c; do
	[[ -f $project_dir/$source ]] || {
		echo "missing source: $project_dir/$source" >&2
		exit 1
	}
done

install -d -m 0755 "$build_root/var/tmp"
rm -rf -- "$build_root/var/tmp/caihong-utilities"
install -d -m 0755 "$build_root/var/tmp/caihong-utilities"
install -m 0644 "$project_dir/tools/caihong-nvram-mac.c" \
	"$build_root/var/tmp/caihong-utilities/caihong-nvram-mac.c"
install -m 0644 "$project_dir/tools/caihong-npu-info.c" \
	"$build_root/var/tmp/caihong-utilities/caihong-npu-info.c"

chroot "$build_root" /usr/bin/env -i HOME=/root LANG=C \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	cc -O2 -Wall -Wextra -Werror \
	-o /var/tmp/caihong-utilities/caihong-nvram-mac \
	/var/tmp/caihong-utilities/caihong-nvram-mac.c -lcrypto
chroot "$build_root" /usr/bin/env -i HOME=/root LANG=C \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	cc -O2 -Wall -Wextra -Werror \
	-o /var/tmp/caihong-utilities/caihong-npu-info \
	/var/tmp/caihong-utilities/caihong-npu-info.c -ldl

install -D -m 0755 "$build_root/var/tmp/caihong-utilities/caihong-nvram-mac" \
	"$stage/usr/local/libexec/caihong-nvram-mac"
install -D -m 0755 "$build_root/var/tmp/caihong-utilities/caihong-npu-info" \
	"$stage/usr/local/sbin/caihong-npu-info"
for path in usr/local/libexec/caihong-nvram-mac usr/local/sbin/caihong-npu-info; do
	file "$stage/$path" | grep -q 'ARM aarch64' || {
		echo "$path is not AArch64" >&2
		exit 1
	}
done
rm -rf -- "$build_root/var/tmp/caihong-utilities"
echo "Caihong board utilities staged for the platform package"
