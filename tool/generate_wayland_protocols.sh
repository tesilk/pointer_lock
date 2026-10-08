#!/usr/bin/env bash
# Regenerates the Wayland bindings from linux/protocols/; the output is checked in so consumers never need wayland-scanner.
set -euo pipefail

linux_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../linux" && pwd)
mkdir -p "$linux_dir/include/wayland" "$linux_dir/wayland"
for protocol in pointer-constraints-unstable-v1 relative-pointer-unstable-v1; do
  wayland-scanner client-header "$linux_dir/protocols/$protocol.xml" \
    "$linux_dir/include/wayland/$protocol-client-protocol.h"
  wayland-scanner private-code "$linux_dir/protocols/$protocol.xml" "$linux_dir/wayland/$protocol-protocol.c"
done
