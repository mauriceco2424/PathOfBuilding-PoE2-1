#!/usr/bin/env bash
# get_full_calcs smoke test: fresh Ranger with an Ice Nova + Fire Attunement
# skill pair, run get_full_calcs and verify the perSkillDPS list is populated,
# activeSkill resolves, and the FullDPS overlay kicks in (no socket group has
# includeInFullDPS set by default, so the handler must overlay Ice Nova's DPS
# onto mainOutput).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/full-calcs-stderr.log"
STDOUT_LOG="$HERE/full-calcs-stdout.jsonl"

cd "$SRC"

# Sequence:
#   new_build                              - fresh Ranger
#   create_socket_group                    - skill group needed (PoB2 new_build starts empty)
#   add_gem Ice Nova, level 10, quality 20 - active skill (becomes mainSkill)
#   add_gem Fire Attunement                - support gem (reservation-free)
#   get_full_calcs                         - expect:
#                                              * activeSkill = "Ice Nova"
#                                              * perSkillDPS[] contains Ice Nova
#                                              * FullDPS > 0 via best-skill overlay
#                                              * perSkillReservation might be empty
#                                                (Ice Nova doesn't reserve) — fine
#                                              * mainOutput includes Life, Mana,
#                                                CombinedDPS, etc.
#                                              * skills payload present
#   quit

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"create_socket_group","params":{"label":"Main"}}
{"action":"add_gem","params":{"groupIndex":1,"gemName":"Ice Nova","level":10,"quality":20}}
{"action":"add_gem","params":{"groupIndex":1,"gemName":"Fire Attunement","level":1,"quality":0}}
{"action":"get_full_calcs"}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 20 lines) ---"
tail -20 "$STDERR_LOG"
