# Compiles one or more core revisions and installs the bit-reversed
# bitstreams into dist/Cores/.
#
# Usage: build-core [genesis|megacd|all]   (default: genesis)

rev_dest() {
  case "$1" in
    genesis) echo "dist/Cores/ericlewis.Genesis/bitstream.rbf_r" ;;
    megacd)  echo "dist/Cores/jeremy.MegaCD/megacd.rbf_r" ;;
    *) return 1 ;;
  esac
}

rev_name() {
  case "$1" in
    genesis) echo "ap_core" ;;
    megacd)  echo "megacd" ;;
    *) return 1 ;;
  esac
}

if [[ ! -f src/fpga/ap_core.qpf ]]; then
  echo "Run from the repository root (src/fpga/ap_core.qpf not found)" >&2
  exit 1
fi

targets=("${@:-genesis}")
if [[ "${targets[0]}" == "all" ]]; then
  targets=(genesis megacd)
fi

for t in "${targets[@]}"; do
  rev_name "$t" > /dev/null || { echo "Unknown target '$t' (genesis|megacd|all)" >&2; exit 1; }
done

for t in "${targets[@]}"; do
  rev="$(rev_name "$t")"
  dest="$(rev_dest "$t")"
  echo "=== Building '$t' (revision $rev) -> $dest ==="
  (cd src/fpga && quartus_sh --flow compile ap_core -c "$rev")

  # The Pocket expects the RBF with the bits of each byte reversed
  python3 - "src/fpga/output_files/$rev.rbf" "$dest" <<'EOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
table = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
with open(src, "rb") as f:
    data = f.read()
with open(dst, "wb") as f:
    f.write(data.translate(table))
print(f"Wrote {dst} ({len(data)} bytes)")
EOF

  echo
  echo "=== Fitter summary ($rev) ==="
  cat "src/fpga/output_files/$rev.fit.summary"
done
