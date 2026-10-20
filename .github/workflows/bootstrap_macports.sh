#!/bin/bash

set -euo pipefail

macports_version="2.12.4"
darwin_major="$(uname -r | cut -d. -f1)"
archive="MacPorts-${macports_version}-${darwin_major}.tar.bz2"
archive_path="${RUNNER_TEMP:-/tmp}/${archive}"
archive_url="https://github.com/macports/macports-ci-files/releases/download/v${macports_version}/${archive}"

curl -fsSL "$archive_url" -o "$archive_path"
sudo tar -xpf "$archive_path" -C /
rm "$archive_path"

set +u
source /opt/local/share/macports/setupenv.bash
set -u
sudo /opt/local/libexec/macports/postflight/postflight

if [[ "$(uname -m)" == "arm64" ]]; then
  arch -x86_64 /usr/bin/true
fi

printf 'build_arch x86_64\nuniversal_archs x86_64\nui_interactive no\n' |
  sudo tee -a /opt/local/etc/macports/macports.conf >/dev/null

sudo /opt/local/bin/port sync
