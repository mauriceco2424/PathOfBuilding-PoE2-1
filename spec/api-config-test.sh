#!/usr/bin/env bash
# Config tier smoke test: fresh Ranger, read baseline config, flip a handful
# of PoE 2-shaped keys, then verify the set survives a rebuild. Also round-
# trips set_flask_active on both Flask and Charm slot families.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/config-stderr.log"
STDOUT_LOG="$HERE/config-stdout.jsonl"

cd "$SRC"

# Sequence:
#   new_build                           - fresh Ranger
#   get_config                          - baseline (enemyLevel, resistancePenalty, customMods)
#   get_full_config                     - full PoE 2-shaped snapshot
#   set_config (basics + buffs)         - enemyLevel=84, resistancePenalty=-30,
#                                         buffOnslaught=true, buffFortification=true,
#                                         conditionLowLife=true, conditionMoving=true
#   get_full_config                     - verify the flips round-tripped
#   set_config (PoE 2-specific flags)   - conditionEnemyElectrocuted, conditionEnemyArmourBroken,
#                                         conditionEnemyHeavyStunned, conditionUsingCharm,
#                                         conditionSprinting, multiplierArmourBreak=5
#   get_full_config                     - verify PoE 2-only keys flipped
#   set_config (enemy stat overrides)   - enemyFireResist=25, enemyPhysicalReduction=15
#   get_full_config                     - verify numeric overrides
#   set_config (charges)                - usePowerCharges=true, overridePowerCharges=4
#   get_full_config                     - verify
#   set_config (charms + flask off)     - conditionUsingCharm=false
#   set_flask_active Flask 1            - index=1, active=true (flask slot is empty, but the
#                                         slot flag should still flip — used by backend to
#                                         track "active" state ahead of flask equipping)
#   set_flask_active Charm 2            - slotType=charm, index=2, active=true
#   set_flask_active explicit slot      - slot="Flask 2", active=false
#   get_stats                           - final read to catch any BuildOutput crash from the config churn
#   quit

cat <<'EOF' | LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
                POB_API_STDIO=1 luajit HeadlessWrapper.lua >"$STDOUT_LOG" 2>"$STDERR_LOG"
{"action":"new_build"}
{"action":"get_config"}
{"action":"get_full_config"}
{"action":"set_config","params":{"enemyLevel":84,"resistancePenalty":-30,"buffOnslaught":true,"buffFortification":true,"conditionLowLife":true,"conditionMoving":true}}
{"action":"get_full_config"}
{"action":"set_config","params":{"conditionEnemyElectrocuted":true,"conditionEnemyArmourBroken":true,"conditionEnemyHeavyStunned":true,"conditionUsingCharm":true,"conditionSprinting":true,"multiplierArmourBreak":5}}
{"action":"get_full_config"}
{"action":"set_config","params":{"enemyFireResist":25,"enemyPhysicalReduction":15}}
{"action":"get_full_config"}
{"action":"set_config","params":{"usePowerCharges":true,"overridePowerCharges":4}}
{"action":"get_full_config"}
{"action":"set_config","params":{"conditionUsingCharm":false}}
{"action":"set_flask_active","params":{"index":1,"active":true}}
{"action":"set_flask_active","params":{"slotType":"charm","index":2,"active":true}}
{"action":"set_flask_active","params":{"slot":"Flask 2","active":false}}
{"action":"get_stats","params":{"fields":["Life","Mana","FireResist","ColdResist","TotalEHP"]}}
{"action":"quit"}
EOF

echo "=== stdout (JSON-RPC responses) ==="
cat "$STDOUT_LOG"
echo ""
echo "--- stderr (last 30 lines) ---"
tail -30 "$STDERR_LOG"
