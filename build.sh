# Compiles the core and installs the bit-reversed bitstream into
# dist/Cores/ericlewis.Genesis/bitstream.rbf_r.
#
# Usage: build-core

if [[ ! -f src/fpga/ap_core.qpf ]]; then
  echo "Run from the repository root (src/fpga/ap_core.qpf not found)" >&2
  exit 1
fi

(cd src/fpga && quartus_sh --flow compile ap_core)

# The Pocket expects the RBF with the bits of each byte reversed
python3 - src/fpga/output_files/ap_core.rbf dist/Cores/ericlewis.Genesis/bitstream.rbf_r <<'EOF'
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
echo "=== Fitter summary ==="
cat src/fpga/output_files/ap_core.fit.summary
