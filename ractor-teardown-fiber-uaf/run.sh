#!/bin/bash
# Reproducer driver: runs repro_loop.rb under an ASan build configured like
# the Ruby CI job (CC=clang cflags=-fsanitize=address cppflags=-DUSE_MN_THREADS=0).
# Build once:
#   git worktree add --detach <dir> <master>
#   cd <dir> && ./autogen.sh
#   ./configure --disable-install-doc CC=clang cflags=-fsanitize=address cppflags=-DUSE_MN_THREADS=0
#   make -j
# Then point RUBY_ASAN at the built ruby and run this script.
set -u
RUBY_ASAN="${RUBY_ASAN:-$PWD/ruby}"
N="${N:-100000}"
PAR="${PAR:-8}"
export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1
pids=()
for id in $(seq 1 "$PAR"); do
  N="$N" "$RUBY_ASAN" "$(dirname "$0")/repro_loop.rb" >"/tmp/ractor-uaf-$id.out" 2>&1 &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
grep -l "ERROR: AddressSanitizer" /tmp/ractor-uaf-*.out 2>/dev/null
exit $rc
