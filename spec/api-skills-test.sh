#!/usr/bin/env bash
# Skills tier smoke test: get_skills on a fresh build (no gems), add a gem,
# toggle level/quality/enabled, remove it. Then add two gems and run
# calc_with_gems to verify the snapshot-mutate-restore pipeline.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/skills-stderr.log"
STDOUT_LOG="$HERE/skills-stdout.jsonl"

cd "$SRC"

# Sequence:
#   new_build           - fresh Ranger
#   get_skills          - socket group list (likely one empty default group)
#   add_gem             - add Ice Nova (active) to group 1. Use canonical
#                         gem name; findGemByIdentifier resolves it.
#   get_skills          - verify gem present, gemType="Spell", skillType="spell"
#   set_gem_level 1     - level 1
#   set_gem_quality 20  - quality 20
#   set_gem_enabled=false
#   get_stats           - baseline while Ice Nova disabled
#   set_gem_enabled=true
#   add_gem             - add Fire Attunement (support) to same group
#   get_skills          - verify 2 gems, support classified correctly
#   calc_with_gems noop - empty params should produce base==out
#   calc_with_gems      - replaceGems: swap Fire Attunement -> Rapid Attacks I
#   get_skills          - verify restore (Fire Attunement still present)
#   remove_gem gem 2    - drop Fire Attunement
#   get_skills          - verify 1 gem
#   remove_skill grp 1  - drop whole group (should fail if source-backed)
#   quit

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_skills"}
{"action":"create_socket_group","params":{"label":"Main"}}
{"action":"add_gem","params":{"groupIndex":1,"gemName":"Ice Nova","level":1,"quality":0}}
{"action":"get_skills"}
{"action":"set_gem_level","params":{"groupIndex":1,"gemIndex":1,"level":10}}
{"action":"set_gem_quality","params":{"groupIndex":1,"gemIndex":1,"quality":20}}
{"action":"set_gem_enabled","params":{"groupIndex":1,"gemIndex":1,"enabled":false}}
{"action":"get_stats","params":{"fields":["Life","Mana","TotalDPS","CombinedDPS"]}}
{"action":"set_gem_enabled","params":{"groupIndex":1,"gemIndex":1,"enabled":true}}
{"action":"add_gem","params":{"groupIndex":1,"gemName":"Fire Attunement","level":1,"quality":0}}
{"action":"get_skills"}
{"action":"calc_with_gems","params":{}}
{"action":"calc_with_gems","params":{"replaceGems":[{"groupIndex":1,"gemIndex":2,"gem":{"skillId":"Rapid Attacks I","level":1,"quality":0}}]}}
{"action":"get_skills"}
{"action":"remove_gem","params":{"groupIndex":1,"gemIndex":2}}
{"action":"get_skills"}
{"action":"remove_skill","params":{"groupIndex":1}}
{"action":"get_skills"}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 30 lines) ---"
tail -30 "$STDERR_LOG"
