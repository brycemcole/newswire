#!/usr/bin/env bash
set -euo pipefail
task_runtime="$HOME/.local/share/newswire-browser"
mkdir -p "$task_runtime/rpms" "$task_runtime/runtime"
dnf download --destdir "$task_runtime/rpms" atk at-spi2-core libXcomposite libXdamage libXfixes
cd "$task_runtime/runtime"
for package in "$task_runtime"/rpms/*.rpm; do
  rpmkeys --checksig "$package"
  rpm2cpio "$package" | cpio -id --quiet
done
