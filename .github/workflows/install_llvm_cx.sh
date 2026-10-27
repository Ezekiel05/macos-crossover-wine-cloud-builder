#!/bin/bash
# Installs CodeWeavers' llvm-cx compiler into /opt/local/libexec/llvm-cx.
# MacPorts downloads the CrossOver compiler source; we build it with Xcode's clang + CMake 3.x.
set -uo pipefail

PORT=(arch -x86_64 sudo /opt/local/bin/port)
PREFIX=/opt/local/libexec/llvm-cx

show_logs() {
  echo "================ llvm-cx CMakeError.log / CMakeOutput.log ================"
  sudo find /opt/local/var/macports/build -path '*llvm-cx*' \( -name CMakeError.log -o -name CMakeOutput.log \) \
    -exec sh -c 'echo "--- $1"; tail -n 120 "$1"' _ {} \; 2>/dev/null
  echo "================ llvm-cx main.log (last 150 lines) ================"
  local log
  log="$("${PORT[@]}" -q logfile llvm-cx 2>/dev/null | tail -n 1)"
  [ -n "$log" ] && sudo tail -n 150 "$log"
  echo "=========================================================================="
}

# MacPorts' own build of llvm-cx can't work on GitHub's Apple Silicon runners: it forces
# DEVELOPER_DIR=CommandLineTools, whose libxcrun has no x86_64 slice, so every compiler call
# fails under Rosetta. We only let MacPorts download the source, then build it ourselves.
if ! "${PORT[@]}" -N fetch llvm-cx; then
  echo "::error::Could not download the llvm-cx source"
  show_logs
  exit 1
fi

set -e
TARBALL="$(sudo find /opt/local/var/macports/distfiles -name 'crossover-sources-*.tar.gz' | head -n 1)"
if [ -z "$TARBALL" ]; then
  echo "::error::Could not find the CrossOver source tarball MacPorts downloaded"
  exit 1
fi
echo "Using $TARBALL"

WORK="$RUNNER_TEMP/llvm-cx"
rm -rf "$WORK"; mkdir -p "$WORK"
sudo tar -xzf "$TARBALL" -C "$WORK" sources/clang
sudo chown -R "$(id -u)" "$WORK"
ln -sfn "$WORK/sources/clang/clang" "$WORK/sources/clang/llvm/projects/clang"

# Newer libc++ made std::string's converting constructor explicit; fix the one place this breaks
sed -i '' 's/SpecialCaseList::createOrDie({{ClBlacklist}})/SpecialCaseList::createOrDie({std::string(ClBlacklist)})/' \
  "$WORK/sources/clang/llvm/tools/sancov/sancov.cpp" || true

# x86_64 Python + CMake 3.x + Ninja, so the whole build runs as x86_64 under Rosetta
arch -x86_64 /usr/bin/python3 -m venv "$WORK/venv"
arch -x86_64 "$WORK/venv/bin/pip" install --quiet "cmake>=3.20,<4" ninja
CMAKE="$WORK/venv/bin/cmake"
NINJA="$WORK/venv/bin/ninja"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# The compiler only has to run on this build machine, so target a macOS the current SDK fully supports
export MACOSX_DEPLOYMENT_TARGET=11.0

# Older LLVM code + newer Apple clang/libc++ needs a few relaxations.
# -Qunused-arguments stops "argument unused" warnings at link time, which make CMake's
# flag checks (e.g. the C++11 check) wrongly report failure.
CXXFLAGS_EXTRA="-Qunused-arguments -Wno-error -include cstdint -include limits"
if echo 'int x;' | /usr/bin/clang++ -x c++ -Werror -Wno-enum-constexpr-conversion -fsyntax-only - 2>/dev/null; then
  CXXFLAGS_EXTRA="$CXXFLAGS_EXTRA -Wno-enum-constexpr-conversion"
fi
echo "Extra C++ flags: $CXXFLAGS_EXTRA"

show_cmake_logs() {
  for f in "$WORK/build/CMakeFiles/CMakeError.log" "$WORK/build/CMakeFiles/CMakeConfigureLog.yaml"; do
    [ -f "$f" ] && { echo "--- $f (last 150 lines)"; tail -n 150 "$f"; }
  done
}
trap 'echo "::error::llvm-cx source build failed"; show_cmake_logs' ERR

arch -x86_64 "$CMAKE" -G Ninja \
  -S "$WORK/sources/clang/llvm" -B "$WORK/build" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS_EXTRA" \
  -DCMAKE_C_FLAGS="-Qunused-arguments -Wno-error" \
  -DPYTHON_EXECUTABLE="$WORK/venv/bin/python3" \
  -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
  -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-darwin \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBPFM=OFF \
  -DLLVM_ENABLE_THREADS=ON \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DLLVM_TOOL_SANCOV_BUILD=OFF

# -k 0: keep building after a failure so one run reports every broken file
if ! arch -x86_64 "$CMAKE" --build "$WORK/build" -- -k 0 -j"$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1; then
  echo "::error::llvm-cx compile failed. Failed targets and errors:"
  grep -E '^FAILED: |: error: ' "$WORK/build.log" | head -n 80
  echo "--- last 60 lines of the build log"
  tail -n 60 "$WORK/build.log"
  trap - ERR
  exit 1
fi
tail -n 5 "$WORK/build.log"
sudo arch -x86_64 "$CMAKE" --install "$WORK/build"
# Same as the MacPorts port: fall back on Xcode's libLTO
sudo rm -f "$PREFIX/lib/libLTO.dylib"
echo "llvm-cx built from source into $PREFIX"
"$PREFIX/bin/clang" --version
