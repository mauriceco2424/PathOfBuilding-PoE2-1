#!/usr/bin/env bash
# Jewel tier smoke test: list sockets, equip a jewel persistently with path
# auto-allocation, verify Life delta survives across calls, then remove the
# jewel and confirm state rolls back to baseline.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/jewel-stderr.log"
STDOUT_LOG="$HERE/jewel-stdout.jsonl"

cd "$SRC"

# Sequence (socket 61834 is ~14 nodes from Ranger class-start, matches the
# calc_with_jewel smoke test's picks so the Life delta +40 is comparable):
#   new_build                          - fresh Ranger
#   get_jewel_sockets                  - enumerate, confirm 61834 is present
#                                        and isAllocated=false, equippedJewelId=0
#   get_stats (baseline)               - Life should be 65
#   set_jewel 61834, autoAllocateSocketPath=true,
#     text="<rare Emerald +40 Life>"   - expect allocatedPathNodes populated
#   get_jewel_sockets                  - 61834 now isAllocated=true, equippedJewel filled
#   get_stats                          - Life should be 65 + 40 = 105 (approx;
#                                        other tree nodes on the path may also
#                                        contribute)
#   remove_jewel 61834                 - clears the equipped jewel; socket stays
#                                        allocated (path survives)
#   get_jewel_sockets                  - 61834 isAllocated=true, equippedJewelId=0
#   get_stats                          - Life drops back to baseline + path contribs
#   quit

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_stats","params":{"fields":["Life"]}}
{"action":"set_jewel","params":{"nodeId":61834,"autoAllocateSocketPath":true,"text":"Rarity: RARE\nTest Jewel\nEmerald\nItem Level: 80\n+40 to maximum Life"}}
{"action":"get_jewel_sockets"}
{"action":"get_stats","params":{"fields":["Life"]}}
{"action":"remove_jewel","params":{"nodeId":61834}}
{"action":"get_jewel_sockets"}
{"action":"get_stats","params":{"fields":["Life"]}}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 20 lines) ---"
tail -20 "$STDERR_LOG"
