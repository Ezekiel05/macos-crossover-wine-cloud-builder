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

source /opt/local/share/macports/setupenv.bash
sudo /opt/local/libexec/macports/postflight/postflight

case "$(uname -m)" in
  arm64)
    printf 'build_arch arm64\nuniversal_archs arm64 x86_64\n' |
      sudo tee -a /opt/local/etc/macports/macports.conf >/dev/null
    ;;
  x86_64)
    printf 'build_arch x86_64\n' |
      sudo tee -a /opt/local/etc/macports/macports.conf >/dev/null
    ;;
  *)
    echo "Unsupported runner architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

sudo /opt/local/bin/port sync
