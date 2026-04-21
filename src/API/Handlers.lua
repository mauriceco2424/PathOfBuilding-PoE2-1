-- API/Handlers.lua (PoB2)
-- Shared JSON-RPC handlers. Transport-agnostic — Server.lua wraps us in stdio.
--
-- Phase 2 scope: bootstrap + stats tier. Gear/skills/tree/calc/jewel handlers
-- are added in later phases as each is verified against PoB2 internals
-- (see pob2-integration-notes POB2-IPC-2 for the full port order).

-- Debug logging control
local DEBUG = os.getenv('POB_API_DEBUG') == '1'
local function debug_log(msg)
  if DEBUG then io.stderr:write('[Handlers] ' .. msg .. '\n') end
end

-- Resolve BuildOps reliably regardless of CWD. require() works when LUA_PATH
-- includes the src dir; the dofile fallbacks keep us working from any invocation.
local BuildOps
do
  debug_log('Attempting to require API.BuildOps')
  local ok_ops, mod = pcall(require, 'API.BuildOps')
  if ok_ops and mod then
    BuildOps = mod
  else
    local dir = ''
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if type(src) == 'string' and src:sub(1,1) == '@' then
      local p = src:sub(2)
      dir = (p:gsub('[^/\\]+$', ''))
    end
    local tried = {}
    local function try(p)
      if not p then return false end
      table.insert(tried, p)
      local ok2, m = pcall(dofile, p)
      if ok2 and m then BuildOps = m; return true end
      return false
    end
    if not BuildOps then
      local _ = try(dir .. 'BuildOps.lua')
              or try((rawget(_G,'POB_SCRIPT_DIR') or '.') .. '/API/BuildOps.lua')
              or try('API/BuildOps.lua')
              or try('src/API/BuildOps.lua')
    end
    if not BuildOps then
      error('API/BuildOps.lua not found. Tried: ' .. table.concat(tried, ', '))
    end
  end
end

-- API version — bumped from 0.1.0-spike now that real handlers are landing.
local API_VERSION = "0.2.0"

local function version_meta()
  return {
    number      = _G.launch and launch.versionNumber or '?',
    branch      = _G.launch and launch.versionBranch or '?',
    platform    = _G.launch and launch.versionPlatform or '?',
    apiVersion  = API_VERSION,
    engine      = "PoB2",
  }
end

-- Memory-aware GC: LuaJIT's 2GB address-space limit bites us on repeated calc
-- passes if we don't pressure-check. collectgarbage("count") is free (reads an
-- internal counter); a full collect runs only when we cross the threshold.
-- Threshold ported from PoE 1 — revisit once PoB2 memory profile is known.
local GC_THRESHOLD_KB = 512000  -- 500MB
local function checkMemoryPressure()
  local memKB = collectgarbage("count")
  if memKB > GC_THRESHOLD_KB then
    collectgarbage("collect")
    collectgarbage("collect")
    local afterKB = collectgarbage("count")
    io.stderr:write(string.format("[GC] Memory pressure: %.1fMB -> %.1fMB\n", memKB/1024, afterKB/1024))
  end
end

local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta() }
end

-- Q4-spike diagnostic handler — kept because it's useful when bootstrap issues
-- mask themselves as missing globals.
handlers.build_loaded = function(params)
  return {
    ok = true,
    has_mainObject = _G.mainObject ~= nil,
    has_build      = _G.build ~= nil,
    has_newBuild   = type(_G.newBuild) == 'function',
    has_loadXML    = type(_G.loadBuildFromXML) == 'function',
    has_loadJSON   = type(_G.loadBuildFromJSON) == 'function',
  }
end

handlers.new_build = function(params)
  if not _G.newBuild then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.newBuild()
  -- After SetMode, refresh _G.build (see load_build_xml for the rationale).
  if _G.mainObject and _G.mainObject.main and _G.mainObject.main.modes then
    local newB = _G.mainObject.main.modes["BUILD"]
    if newB and newB ~= _G.build then _G.build = newB end
  end
  return { ok = true }
end

handlers.load_build_xml = function(params)
  checkMemoryPressure()
  if not params or type(params.xml) ~= 'string' then
    return { ok = false, error = 'missing xml' }
  end
  local name = (params.name and tostring(params.name)) or 'API Build'
  if not _G.loadBuildFromXML then
    return { ok = false, error = 'headless wrapper not initialized' }
  end

  -- NOTE: Do NOT call newBuild() before loadBuildFromXML — loadBuildFromXML
  -- itself calls SetMode which clears prior state. Double-SetMode drops the
  -- imported XML on the floor. Burned on this in PoE 1; same bug applies here.
  _G.loadBuildFromXML(params.xml, name)

  -- Extra OnFrame passes let PostLoad-style rebuilds finish (tree rebuild,
  -- mastery effect resolution, etc.) before any stats read.
  if _G.runCallback then
    _G.runCallback("OnFrame")
    _G.runCallback("OnFrame")
  end

  -- CRITICAL: SetMode creates a new build object in mainObject.main.modes.BUILD
  -- but _G.build was bound once at startup to the OLD one. Rebind it so
  -- downstream handlers read the freshly-imported build.
  if _G.mainObject and _G.mainObject.main and _G.mainObject.main.modes then
    local newB = _G.mainObject.main.modes["BUILD"]
    if newB and newB ~= _G.build then
      io.stderr:write("[load_build_xml] Updating _G.build to new build object\n")
      _G.build = newB
    end
  end

  if not _G.build then
    io.stderr:write("[load_build_xml] ERROR: build object is nil after load\n")
    return { ok = false, error = 'build object nil after load' }
  end

  -- Surface PoB2's own error channel if the import failed.
  if _G.mainObject and _G.mainObject.promptMsg then
    local msg = tostring(_G.mainObject.promptMsg)
    _G.mainObject.promptMsg = nil
    return { ok = false, error = 'pob2 import error: ' .. msg }
  end

  return { ok = true, build_id = 1 }
end

handlers.load_build_json = function(params)
  checkMemoryPressure()
  if not params or type(params.itemsJson) ~= 'string' or type(params.passiveSkillsJson) ~= 'string' then
    return { ok = false, error = 'missing itemsJson or passiveSkillsJson' }
  end
  if not _G.loadBuildFromJSON then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.loadBuildFromJSON(params.itemsJson, params.passiveSkillsJson)

  if _G.runCallback then
    _G.runCallback("OnFrame")
    _G.runCallback("OnFrame")
  end

  if _G.mainObject and _G.mainObject.main and _G.mainObject.main.modes then
    local newB = _G.mainObject.main.modes["BUILD"]
    if newB and newB ~= _G.build then
      io.stderr:write("[load_build_json] Updating _G.build to new build object\n")
      _G.build = newB
    end
  end

  if _G.mainObject and _G.mainObject.promptMsg then
    local msg = tostring(_G.mainObject.promptMsg)
    _G.mainObject.promptMsg = nil
    return { ok = false, error = 'pob2 import error: ' .. msg }
  end

  return { ok = true, build_id = 1 }
end

handlers.export_build_xml = function(params)
  local xml, err = BuildOps.export_build_xml()
  if not xml then return { ok = false, error = err } end
  return { ok = true, xml = xml }
end

handlers.get_build_info = function(params)
  local info, err = BuildOps.get_build_info()
  if not info then return { ok = false, error = err } end
  return { ok = true, info = info }
end

handlers.set_level = function(params)
  if not params or params.level == nil then
    return { ok = false, error = 'missing level' }
  end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.get_stats = function(params)
  local fields = params and params.fields or nil
  local stats, err = BuildOps.export_stats(fields)
  if not stats then
    return { ok = false, error = err }
  end
  return { ok = true, stats = stats }
end

handlers.gc_collect = function(params)
  collectgarbage("collect")
  collectgarbage("collect")
  local memoryKB = collectgarbage("count")
  return { ok = true, memoryKB = memoryKB }
end

return {
  handlers     = handlers,
  version_meta = version_meta,
}
