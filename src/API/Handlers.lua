-- API/Handlers.lua (SPIKE MINIMAL — PoB2 Q4 IPC feasibility)
-- Strips out BuildOps.lua to test transport + bootstrap only.

local API_VERSION = "0.1.0-spike"

local function version_meta()
  return {
    number      = _G.launch and launch.versionNumber or '?',
    branch      = _G.launch and launch.versionBranch or '?',
    platform    = _G.launch and launch.versionPlatform or '?',
    apiVersion  = API_VERSION,
    engine      = "PoB2",
  }
end

local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta() }
end

handlers.build_loaded = function(params)
  return {
    ok = true,
    has_mainObject = _G.mainObject ~= nil,
    has_build      = _G.build ~= nil,
    has_newBuild   = type(_G.newBuild) == 'function',
    has_loadXML    = type(_G.loadBuildFromXML) == 'function',
  }
end

return {
  handlers     = handlers,
  version_meta = version_meta,
}
