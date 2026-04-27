#!/usr/bin/env bash
# Combined smoke test for the remaining handler tiers landed in one batch:
#   * tree/items misc: get_tree_node_debug, get_tree_stats,
#                      get_mastery_alternatives, get_attribute_requirements
#   * skill config: set_skill_config, set_batch_skill_config
#   * minion: set_minion_config, get_minion_config
#   * flask: get_flask_uptime_data
#   * unsupported stubs: get_cluster_nodes (must return not-supported error)
#   * blocked stubs: generate_trade_query (must return blocked=true)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/remaining-stderr.log"
STDOUT_LOG="$HERE/remaining-stdout.jsonl"

cd "$SRC"

# Sequence (Ranger, socket 61834 for tree_node_debug targeting):
#   new_build
#   get_tree                              - sanity: class-start node allocated
#   get_tree_node_debug nodeId=50459      - Ranger class start; specNode & treeNode
#                                           populated, allocNode present
#   get_tree_stats                        - baseline tree contribution (mostly 0)
#   get_mastery_alternatives              - expect empty result on fresh Ranger
#                                           (no masteries allocated yet)
#   get_attribute_requirements            - Ranger starts with 0/0/0 requirements
#   set_skill_config varName=multiplierPoisonOnEnemy,value=5
#                                        - should round-trip ok:true,value:5
#   set_batch_skill_config configs=[...]  - batch flip two vars at once
#   add a Spectre via set_minion_config (use a valid PoE 2 minion id)
#   get_minion_config                     - expect spectreList populated
#   get_flask_uptime_data                 - empty flask slots on fresh Ranger
#                                           → empty array (no items equipped)
#   get_cluster_nodes                     - expect ok:false, cluster-unsupported error
#   generate_trade_query                  - expect ok:false, blocked:true
#   quit

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_tree_node_debug","params":{"nodeId":50459}}
{"action":"get_tree_stats"}
{"action":"get_mastery_alternatives"}
{"action":"get_attribute_requirements"}
{"action":"set_skill_config","params":{"varName":"multiplierPoisonOnEnemy","value":5}}
{"action":"set_batch_skill_config","params":{"configs":[{"varName":"conditionShockEffect","value":10},{"varName":"multiplierWitheredStackCount","value":3}]}}
{"action":"set_minion_config","params":{"spectreList":[]}}
{"action":"get_minion_config"}
{"action":"get_flask_uptime_data"}
{"action":"get_cluster_nodes","params":{}}
{"action":"generate_trade_query","params":{"slotName":"Amulet"}}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 15 lines) ---"
tail -15 "$STDERR_LOG"
