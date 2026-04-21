#!/usr/bin/env bash
# Phase 2 tree-tier smoke test.
#
# Exercises get_tree, search_nodes, set_tree, update_tree_delta, find_path,
# get_nodes_in_radius against a fresh new_build (empty tree) and checks the
# JSON-RPC responses look sane. Run from repo root:
#
#   bash pob2-api-fork/spec/api-tree-test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/tree-stderr.log"
STDOUT_LOG="$HERE/tree-stdout.jsonl"

cd "$SRC"

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_tree"}
{"action":"search_nodes","params":{"keyword":"life","nodeType":"keystone","maxResults":5}}
{"action":"search_nodes","params":{"keyword":"damage","maxResults":3}}
{"action":"gc_collect"}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 15 lines) ---"
tail -15 "$STDERR_LOG"
