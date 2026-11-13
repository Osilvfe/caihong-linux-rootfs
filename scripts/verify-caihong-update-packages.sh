#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail
project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$project_dir/scripts/verify-platform-packages.py" "$@"
