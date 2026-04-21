#!/usr/bin/env bash
# calc_with_jewel smoke test: equip a rare Emerald in socket 61834 with
# autoAllocateSocketPath, verify Life delta, point cost, and state restore.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/calc-jewel-stderr.log"
STDOUT_LOG="$HERE/calc-jewel-stdout.jsonl"

cd "$SRC"

# Sequence:
#   new_build                         - fresh Ranger, socket 61834 is ~15 nodes
#                                       away via the Eternal Youth path
#   get_stats (baseline Life)
#   calc_with_jewel socket=61834,
#     autoAllocateSocketPath=true,
#     jewelText="<rare Emerald +40 Life>"
#                                     - expect afterOutput.Life > beforeOutput.Life,
#                                       pointCost > 0 (travel path + socket)
#   get_stats (post-restore; must equal baseline)
#   quit
cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_stats","params":{"fields":["Life","Mana","Str"]}}
{"action":"calc_with_jewel","params":{"socketNodeId":61834,"autoAllocateSocketPath":true,"jewelText":"Rarity: RARE\nTest Jewel\nEmerald\nItem Level: 80\n+40 to maximum Life"}}
{"action":"get_stats","params":{"fields":["Life","Mana","Str"]}}
{"action":"get_tree"}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 20 lines) ---"
tail -20 "$STDERR_LOG"
