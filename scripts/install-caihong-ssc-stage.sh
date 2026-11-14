#!/usr/bin/env bash
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
build_root=${CAIHONG_BUILD_ROOT:-}
source_tree=$project_dir/external/libssc
patch_file=$project_dir/packaging/libssc/0001-per-operation-report-handler.patch

if [[ -z $stage || ! -d $stage || -z $build_root || ! -d $build_root ]]; then
	echo "usage: CAIHONG_BUILD_ROOT=ROOT $0 STAGE_DIR" >&2
	exit 2
fi
stage=$(cd -- "$stage" && pwd)
build_root=$(cd -- "$build_root" && pwd)
case $stage in
	/|/boot|/home|/usr|/var) echo "refusing unsafe stage: $stage" >&2; exit 1 ;;
esac
case $build_root in
	/|/boot|/home|/usr|/var) echo "refusing unsafe build root: $build_root" >&2; exit 1 ;;
esac
[[ -f $source_tree/src/libssc-sensor.c && -f $patch_file ]] || {
	echo "missing libssc source or patch; run scripts/checkout-dependencies.sh" >&2
	exit 1
}
if [[ -e $source_tree/.git ]]; then
	[[ -z $(git -C "$source_tree" status --porcelain --untracked-files=no) ]] || {
		echo "refusing uncommitted libssc source changes" >&2
		exit 1
	}
	source_commit=$(git -C "$source_tree" rev-parse HEAD)
else
	source_commit=$(sed -n 's/^LIBSSC_COMMIT=//p' \
		"$project_dir/build/dependencies.resolved.env" | tail -n 1)
fi
[[ $source_commit == 0cf77b93b55752da34dca2dcecc06fca8665184b ]] || {
	echo "unexpected libssc source revision: $source_commit" >&2
	exit 1
}

inside_source=/var/tmp/caihong-libssc-src
inside_build=/var/tmp/caihong-libssc-build
rm -rf -- "$build_root$inside_source" "$build_root$inside_build"
install -d -m 0755 "$build_root$inside_source" "$build_root$inside_build"
rsync -a --exclude=.git "$source_tree/" "$build_root$inside_source/"
patch -d "$build_root$inside_source" -Np1 --batch -i "$patch_file"
install -m 0644 "$project_dir/packaging/libssc/test-concurrent-open.c" \
	"$build_root$inside_source/test-concurrent-open.c"
install -m 0644 "$project_dir/packaging/libssc/test-light-zero.c" \
	"$build_root$inside_source/test-light-zero.c"
install -m 0644 "$project_dir/packaging/libssc/run-regression.sh" \
	"$build_root$inside_source/run-regression.sh"
chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
chroot "$build_root" "${chroot_env[@]}" meson setup \
	"$inside_build" "$inside_source" --buildtype=release --prefix=/usr
chroot "$build_root" "${chroot_env[@]}" ninja -C "$inside_build" src/libssc.so.2
chroot "$build_root" "${chroot_env[@]}" bash "$inside_source/run-regression.sh" \
	"$inside_source" "$inside_build" "$inside_source/test-concurrent-open.c"
install -D -m 0755 "$build_root$inside_build/src/libssc.so.2" \
	"$stage/usr/local/lib/caihong-ssc/libssc.so.2"
install -D -m 0644 "$source_tree/LICENSE" \
	"$stage/usr/share/licenses/caihong-ssc/LICENSE.libssc"
install -d -m 0755 "$stage/usr/share/caihong"
{
	printf 'libssc_version=0.4.4\nsource_commit=%s\n' "$source_commit"
	printf 'patch_sha256=%s\n' "$(sha256sum "$patch_file" | cut -d ' ' -f 1)"
	printf 'concurrent_open=per-operation-handler\n'
} > "$stage/usr/share/caihong/ssc-build-info"
rm -rf -- "$build_root$inside_source" "$build_root$inside_build"
