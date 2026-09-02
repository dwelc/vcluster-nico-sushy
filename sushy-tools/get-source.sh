#!/usr/bin/env bash
# Fetch upstream sushy-tools 2.2.0 and apply the NiCo surface patch into ./src.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -rf "${HERE}/src"
git clone -q https://opendev.org/openstack/sushy-tools.git "${HERE}/src"
git -C "${HERE}/src" checkout -q 2.2.0
git -C "${HERE}/src" apply "${HERE}/nico-surface.patch"
echo "patched sushy-tools at ${HERE}/src ($(git -C "${HERE}/src" describe --tags 2>/dev/null || echo 2.2.0)+nico)"
