#!/usr/bin/env bash
# S7: which files under Sources/PowerUp typecheck unchanged with Swift 5.9 on Linux?
#
# Run from the repository root, inside the container:
#   docker run --rm -v "$PWD":/src -w /src swift:5.9 \
#     bash docs/research/spikes/s7-linux-compile/typecheck.sh
#
# It also runs on macOS (`bash docs/research/spikes/s7-linux-compile/typecheck.sh`)
# so a Linux failure can be told apart from a missing-dependency failure.
#
# Output: three sections, all plain text, nothing is written to disk.
#   1. ALONE      each file typechecked by itself (no other module sources)
#   2. PURE-SET   fixed point: start from every file that imports only Foundation
#                 (or nothing), typecheck them together, drop each file that has an
#                 error, repeat until the remaining set typechecks cleanly
#   3. DROPPED    the first error of every file that left the pure set
set -u
SRC=${SRC:-Sources/PowerUp}
FLAGS=(-typecheck -parse-as-library -module-name PowerUp -swift-version 5)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

uname -sm
swiftc --version 2>&1 | head -1
echo

first_error() { grep -m1 -E 'error:' "$1" | sed -E 's#^.*/##'; }

echo "== ALONE"
for f in "$SRC"/*.swift; do
  b=$(basename "$f")
  if swiftc "${FLAGS[@]}" "$f" >"$TMP/$b.alone" 2>&1; then
    printf '%-34s PASS\n' "$b"
  else
    printf '%-34s FAIL  %s\n' "$b" "$(first_error "$TMP/$b.alone")"
  fi
done
echo

# Candidate set: files whose only imports are Foundation (or none).
set_files=()
for f in "$SRC"/*.swift; do
  others=$(grep -E '^[[:space:]]*(@[A-Za-z_]+ )*import ' "$f" \
    | awk '{print $NF}' | grep -v -x Foundation || true)
  [ -z "$others" ] && set_files+=("$(basename "$f")")
done

DROPPED="$TMP/dropped"; : >"$DROPPED"
round=0
while :; do
  round=$((round + 1))
  paths=()
  for b in "${set_files[@]}"; do paths+=("$SRC/$b"); done
  if swiftc "${FLAGS[@]}" "${paths[@]}" >"$TMP/round$round" 2>&1; then
    break
  fi
  bad=$(grep -E '^[^ ]+\.swift:[0-9]+:[0-9]+: error:' "$TMP/round$round" \
    | sed -E 's#^([^:]+):.*#\1#' | xargs -n1 basename | sort -u)
  if [ -z "$bad" ]; then
    echo "round $round failed without a file-attributed error:"
    cat "$TMP/round$round"
    exit 1
  fi
  keep=()
  for b in "${set_files[@]}"; do
    if grep -qx "$b" <<<"$bad"; then
      printf '%-34s round %s: %s\n' "$b" "$round" \
        "$(grep -m1 -E "/$b:[0-9]+:[0-9]+: error:" "$TMP/round$round" | sed -E 's#^.*/##')" >>"$DROPPED"
    else
      keep+=("$b")
    fi
  done
  set_files=("${keep[@]}")
done

echo "== PURE-SET (typechecks together after $round round(s))"
printf '%s\n' "${set_files[@]}"
echo
echo "== DROPPED from the Foundation-only candidates"
sort "$DROPPED"
