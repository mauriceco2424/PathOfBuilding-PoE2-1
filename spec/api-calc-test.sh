#!/usr/bin/env bash
# Calc tier smoke test: calc_with baseline + node-override round-trip.
# Verifies GetMiscCalculator pipeline against PoB2.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/calc-stderr.log"
STDOUT_LOG="$HERE/calc-stdout.jsonl"

cd "$SRC"

# Sequence:
#   new_build              — fresh Ranger
#   calc_with {}           — empty override; base and after must match
#   calc_with addNodes=[57110]
#                          — "Infused Flesh" notable (+20 to maximum Life
#                            +8% Damage Recouped as Life). Unconnected add;
#                            PoB2's calc override path processes the node
#                            directly into the mod list even without the
#                            node being reachable through the allocated
#                            graph. Expect after.Life > base.Life.
#
#                            NB: we deliberately do NOT use "+5 to any
#                            Attribute" nodes here — the ModParser entry for
#                            that mod in PoB2 0.15 is an empty table
#                            (src/Modules/ModParser.lua:5960), so attribute
#                            nodes are a no-op on the calc output.
#   calc_with addNodes=[999999]
#                          — nonsense id; expect diagnostics.addUnresolved=[999999]
#                            and no numeric change.
#   quit
cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"calc_with","params":{}}
{"action":"calc_with","params":{"addNodes":[57110]}}
{"action":"calc_with","params":{"addNodes":[999999]}}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 30 lines) ---"
tail -30 "$STDERR_LOG"
