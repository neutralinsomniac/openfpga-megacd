#!/usr/bin/env bash
# Generate + run + compare the per-feature jt12-vs-Nuked battery.
# Usage: run_tests.sh <workdir> [--asic]
set -uo pipefail
cd "$(dirname "$0")"
WORK=${1:?usage: run_tests.sh <workdir> [--asic]}
shift || true
mkdir -p "$WORK"
python3 gen_tests.py "$WORK" >/dev/null

# reference first to calibrate absolute gain
./obj_dir/tb_fm "$WORK/reference.log" "$WORK/reference" 0.5 "$@" 2>/dev/null
GAIN=$(nix-shell -p python3Packages.numpy --run \
  "python3 compare_test.py '$WORK/reference'" | awk '/gain/{for(i=1;i<=NF;i++) if($i=="gain") print $(i+1)}' | tr -d ',')
echo "calibrated gain: $GAIN"

while read -r t; do
  [ "$t" = reference ] && continue
  ./obj_dir/tb_fm "$WORK/$t.log" "$WORK/$t" 0.5 "$@" 2>/dev/null
done < "$WORK/manifest.txt"

nix-shell -p python3Packages.numpy --run "
for t in \$(cat '$WORK/manifest.txt'); do
  [ \$t = reference ] && continue
  python3 compare_test.py '$WORK/'\$t $GAIN
done"
