#!/usr/bin/env bash
# Tree mutation smoke test: set_tree, update_tree_delta, find_path.
# Exercises the 9-arg ImportFromNodeList wrapper.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/tree-mutation-stderr.log"
STDOUT_LOG="$HERE/tree-mutation-stdout.jsonl"

cd "$SRC"

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"find_path","params":{"targetNodeId":33404}}
{"action":"update_tree_delta","params":{"addNodes":[33404]}}
{"action":"find_path","params":{"targetNodeId":33404}}
{"action":"update_tree_delta","params":{"removeNodes":[33404]}}
{"action":"get_tree"}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 20 lines) ---"
tail -20 "$STDERR_LOG"
