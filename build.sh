# Compiles one or more core revisions and installs the bit-reversed
# bitstreams into dist/Cores/.
#
# Usage: build.sh [--force] [genesis|megacd|all]   (default: genesis)
#
#   --force  install even if the design fails timing. Never silently
#            installs a failing bitstream -- it still reports the failure,
#            it just does not stop. Does NOT bypass a compile error or a
#            crashed Timing Analyzer; those are always fatal, because in
#            both cases we cannot know what the bitstream contains.

set -euo pipefail

usage() { sed -n '1,10p' "$0" | sed 's/^# \?//'; }

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

force=0
args=()
for a in "$@"; do
  case "$a" in
    --force)   force=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         args+=("$a") ;;
  esac
done

if [[ ! -f src/fpga/ap_core.qpf ]]; then
  echo "Run from the repository root (src/fpga/ap_core.qpf not found)" >&2
  exit 1
fi

targets=("${args[@]:-genesis}")
if [[ "${targets[0]}" == "all" ]]; then
  targets=(genesis megacd)
fi

for t in "${targets[@]}"; do
  rev_name "$t" > /dev/null || { echo "Unknown target '$t' (genesis|megacd|all)" >&2; exit 1; }
done

# Pairs each "Type : ..." line in a .sta.summary with the "Slack : ..." that
# follows it, so we can report worst-first instead of dumping the file.
sta_slacks() {
  awk '
    /^Type[[:space:]]*:/  { t = $0; sub(/^Type[[:space:]]*:[[:space:]]*/,  "", t) }
    /^Slack[[:space:]]*:/ { s = $0; sub(/^Slack[[:space:]]*:[[:space:]]*/, "", s)
                            if (s ~ /^-?[0-9]/) printf "%s\t%s\n", s, t }
  ' "$1" | sort -g
}

for t in "${targets[@]}"; do
  rev="$(rev_name "$t")"
  dest="$(rev_dest "$t")"
  rbf="src/fpga/output_files/$rev.rbf"
  sta="src/fpga/output_files/$rev.sta.summary"

  echo "=== Building '$t' (revision $rev) -> $dest ==="

  # Marker predates the compile, so anything not newer than it is a leftover
  # from a previous run. Guards against Quartus returning 0 while leaving a
  # stale .rbf behind -- the old script would happily reinstall it.
  marker="$(mktemp)"
  trap 'rm -f "$marker"' EXIT

  if ! (cd src/fpga && quartus_sh --flow compile ap_core -c "$rev"); then
    echo "FAIL($t): compile returned non-zero -- refusing to install." >&2
    echo "         '$dest' left untouched (it would otherwise have been" >&2
    echo "         overwritten with the PREVIOUS build's bitstream)." >&2
    exit 1
  fi

  [[ -f "$rbf" && "$rbf" -nt "$marker" ]] || {
    echo "FAIL($t): '$rbf' missing or older than this run -- stale artifact." >&2
    exit 1
  }

  # A crashed Timing Analyzer leaves the summary empty or stale. That must be
  # distinguished from a clean pass: grepping an empty file for negative slack
  # finds nothing, so a naive check would be most permissive exactly when the
  # tool broke. quartus_sta has been seen to die with an internal error
  # (CDB_ATOM_ARRIAV, iterm != 0) and succeed on an identical re-run, so
  # retry once before giving up.
  if [[ ! -s "$sta" || ! "$sta" -nt "$marker" ]]; then
    echo "WARN($t): Timing Analyzer produced no usable summary -- retrying once." >&2
    (cd src/fpga && quartus_sta ap_core -c "$rev") || true
  fi
  if [[ ! -s "$sta" || ! "$sta" -nt "$marker" ]]; then
    echo "FAIL($t): Timing Analyzer did not produce a summary; timing is UNKNOWN." >&2
    echo "         Not installing. --force does not apply -- an unverified" >&2
    echo "         bitstream is not the same as a known-failing one." >&2
    exit 1
  fi

  echo
  echo "=== Timing ($rev), worst first ==="
  sta_slacks "$sta" | head -12
  echo

  violations="$(grep -cE '^Slack[[:space:]]*:[[:space:]]*-' "$sta" || true)"
  if [[ "$violations" -gt 0 ]]; then
    echo "FAIL($t): $violations timing corner(s) report negative slack." >&2
    if [[ "$force" -ne 1 ]]; then
      echo "         Not installing. Re-run with --force to install anyway." >&2
      exit 1
    fi
    echo "         --force given: installing a bitstream that FAILS TIMING." >&2
  fi

  # Bit-reverse into a temp file and move into place, so an interrupted or
  # failed conversion cannot leave a partial bitstream in dist/.
  tmp="$(mktemp "${dest}.XXXXXX")"
  python3 - "$rbf" "$tmp" <<'EOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
table = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
with open(src, "rb") as f:
    data = f.read()
if not data:
    sys.exit("refusing to install an empty bitstream")
with open(dst, "wb") as f:
    f.write(data.translate(table))
print(f"Wrote {dst} ({len(data)} bytes)")
EOF
  # mktemp makes the temp 0600; match the other files in dist/ rather than
  # shipping a bitstream the SD-card copy step might not be able to read.
  chmod 644 "$tmp"
  mv "$tmp" "$dest"
  echo "Installed $dest"

  echo
  echo "=== Fitter summary ($rev) ==="
  cat "src/fpga/output_files/$rev.fit.summary"

  rm -f "$marker"
  trap - EXIT
done
