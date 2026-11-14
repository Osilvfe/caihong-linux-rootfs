#!/bin/bash
set -euo pipefail
source_tree=${1:?source directory}
build_dir=${2:?build directory}
test_source=${3:?test source}
output=$build_dir/concurrent-open-test
read -r -a pkg_flags <<< "$(pkg-config --cflags --libs glib-2.0 gio-2.0 qmi-glib libprotobuf-c)"

cc -g -O1 -Wno-unused-parameter \
	-I"$source_tree/src" -I"$source_tree/data" \
	-I"$build_dir/src" -I"$build_dir/data" \
	"$test_source" "$source_tree/src/libssc-client.c" \
	"$source_tree/src/libssc-common.c" "$build_dir"/data/*.pb-c.c \
	"${pkg_flags[@]}" \
	-lm -Wl,--wrap=ssc_client_send -o "$output"
"$output" --quiet
test_directory=$(dirname -- "$test_source")
cc -g -O1 -Wno-unused-parameter \
	-I"$source_tree/src" -I"$source_tree/data" \
	-I"$build_dir/src" -I"$build_dir/data" \
	"$test_directory/test-light-zero.c" "$source_tree/src/libssc-sensor.c" \
	"$source_tree/src/libssc-client.c" "$source_tree/src/libssc-common.c" \
	"$build_dir"/data/*.pb-c.c "${pkg_flags[@]}" -lm \
	-o "$build_dir/light-zero-test"
"$build_dir/light-zero-test" --quiet
