#!/usr/bin/env bash
# Items tier smoke test.
# Exercises add_item_text (synthetic rare) + add_items_batch + get_items.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/items-stderr.log"
STDOUT_LOG="$HERE/items-stdout.jsonl"

cd "$SRC"

# Inline Lua strings need literal \n between lines of PoB item text — JSON
# strings don't support raw newlines, so we embed "\n" escapes.
cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_items"}
{"action":"add_item_text","params":{"slotName":"Amulet","text":"Rarity: RARE\nTest Amulet\nAmber Amulet\nItem Level: 80\nImplicits: 1\n{tags:attribute}+25 to Strength\n+30 to maximum Life\n+20% to Fire Resistance"}}
{"action":"get_items"}
{"action":"get_stats","params":{"fields":["Life","Str","FireResist"]}}
{"action":"add_items_batch","params":{"items":[{"slotName":"Boots","text":"Rarity: RARE\nTest Boots\nIron Greaves\nItem Level: 80\n+40 to maximum Life\n30% increased Movement Speed"},{"slotName":"Ring 1","text":"Rarity: RARE\nTest Ring\nBreach Ring\nItem Level: 80\n+45 to maximum Life\n+25% to Cold Resistance"}]}}
{"action":"get_items"}
{"action":"get_stats","params":{"fields":["Life","Str","FireResist","ColdResist"]}}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 30 lines) ---"
tail -30 "$STDERR_LOG"
