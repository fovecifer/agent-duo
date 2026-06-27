#!/usr/bin/env bash
# test/run.sh - layer-aware runner. No args = unit -> cli -> integration -> e2e.
set -u
shopt -s nullglob

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDER=(unit cli integration e2e)

is_known_layer() {
  case "$1" in
    unit|cli|integration|e2e) return 0 ;;
    *) return 1 ;;
  esac
}

LAYERS=()
if [[ "$#" -eq 0 ]]; then
  LAYERS=("${ORDER[@]}")
else
  for arg in "$@"; do
    if ! is_known_layer "$arg"; then
      printf 'unknown test layer: %s\n' "$arg" >&2
      exit 2
    fi
  done
  for layer in "${ORDER[@]}"; do
    for arg in "$@"; do
      if [[ "$arg" == "$layer" ]]; then
        LAYERS+=("$layer")
        break
      fi
    done
  done
fi

rc=0
total_pass=0
total_skip=0
total_fail=0

for layer in "${LAYERS[@]}"; do
  pass=0
  skip=0
  fail=0
  printf '=== %s ===\n' "$layer"
  for t in "$DIR/$layer"/*.test.sh; do
    name="$(basename "$t" .test.sh)"
    out="$(bash "$t" 2>&1)"
    trc="$?"
    if [[ "$trc" != "0" ]]; then
      printf '%s\n' "$out"
      printf '%s FAIL\n' "$name"
      fail=$(( fail + 1 ))
      rc=1
    elif printf '%s\n' "$out" | grep -q '^skip '; then
      printf '%s skip\n' "$name"
      skip=$(( skip + 1 ))
    else
      printf '%s PASS\n' "$name"
      pass=$(( pass + 1 ))
    fi
  done
  total_pass=$(( total_pass + pass ))
  total_skip=$(( total_skip + skip ))
  total_fail=$(( total_fail + fail ))
  printf '%s: %d passed, %d skipped, %d failed\n' "$layer" "$pass" "$skip" "$fail"
done

printf 'total: %d passed, %d skipped, %d failed\n' "$total_pass" "$total_skip" "$total_fail"
echo "==============="
[[ "$rc" == "0" ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
