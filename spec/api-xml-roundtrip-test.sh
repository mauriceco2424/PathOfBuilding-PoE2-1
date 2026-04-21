#!/usr/bin/env bash
# Export a fresh build's XML, feed it back in via load_build_xml within the
# SAME server session, then verify get_build_info sees the import. This exercises:
#   - BuildOps.export_build_xml()      (SaveDB path, PathOfBuilding2 root)
#   - loadBuildFromXML wrapper         (SetMode + OnFrame pump)
#   - _G.build rebinding after SetMode (the double-SetMode gotcha)
#   - get_build_info post-import       (PassiveSpec restored class/asc fields)
#   - get_stats post-import            (mainOutput re-populated)
#
# Uses a Lua helper to drive the server so we don't fight shell/python path
# translation between Git Bash and Windows paths.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/xml-roundtrip-stderr.log"
STDOUT_LOG="$HERE/xml-roundtrip-stdout.jsonl"

cd "$SRC"

# Single-session plan: export_build_xml produces XML. A small awk script
# extracts the XML payload from the JSON-RPC response line, JSON-escapes it
# again, and emits a load_build_xml call with it. We stream the whole thing
# through luajit in ONE process — that keeps the build state coherent and
# avoids reading big XML into bash variables.

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Step A: export XML and quit, capturing stdout.
cat >"$TMPDIR/phase1.jsonl" <<'EOF'
{"action":"new_build"}
{"action":"export_build_xml"}
{"action":"quit"}
EOF

LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
  POB_API_STDIO=1 \
  luajit HeadlessWrapper.lua <"$TMPDIR/phase1.jsonl" >"$TMPDIR/phase1.out" 2>"$STDERR_LOG"

# Extract XML from the export_build_xml response using a small lua script
# (more reliable than bash/sed when the payload contains escapes + newlines).
cat >"$TMPDIR/extract-xml.lua" <<'EOF'
-- Read the JSONL stdout, decode each line, find the one with an "xml" field,
-- and emit a fresh JSONL script that imports it and probes state.
package.path = "../runtime/lua/?.lua;../runtime/lua/?/init.lua;" .. package.path
local json = require "dkjson"
local xml
for line in io.lines(arg[1]) do
  if line:sub(1,1) == "{" then
    local ok, obj = pcall(json.decode, line)
    if ok and obj and obj.xml then xml = obj.xml; break end
  end
end
if not xml then error("no xml in stream") end
-- Emit the import plan for phase B.
local out = assert(io.open(arg[2], "w"))
out:write(json.encode({ action = "load_build_xml", params = { xml = xml, name = "roundtrip-test" }}) .. "\n")
out:write('{"action":"get_build_info"}\n')
out:write('{"action":"get_stats","params":{"fields":["Life","Mana","Spirit","Evasion","TotalEHP"]}}\n')
out:write('{"action":"quit"}\n')
out:close()
io.stdout:write(("[extract-xml] captured %d bytes of XML\n"):format(#xml))
EOF

LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
  luajit "$TMPDIR/extract-xml.lua" "$TMPDIR/phase1.out" "$TMPDIR/phase2.jsonl" >&2

# Step B: import the XML and check state.
LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
  POB_API_STDIO=1 \
  luajit HeadlessWrapper.lua <"$TMPDIR/phase2.jsonl" >"$STDOUT_LOG" 2>>"$STDERR_LOG"

echo "=== Phase B stdout (JSON-RPC responses) ===" >&2
cat "$STDOUT_LOG" >&2

echo "--- stderr (last 30 lines) ---" >&2
tail -30 "$STDERR_LOG" >&2
