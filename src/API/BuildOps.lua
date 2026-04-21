-- API/BuildOps.lua (PoB2)
-- Thin wrappers around PoB2 headless objects for programmatic operations.
--
-- Phase 2 scope: bootstrap + stats tier only. Gear, skills, tree, calc, jewel,
-- minion, and config handlers will be added in subsequent phases as we verify
-- PoB2's schema for each.
--
-- PoB2 differences from PoB1 that matter at this tier:
--   * build.calcsTab.mainOutput still works the same (verified in CalcsTab:BuildOutput).
--   * wipeGlobalCache() exists globally (Modules/Common.lua).
--   * build.spec.curClassName / curAscendClassName / curClassId / curAscendClassId exist.
--   * build.spec.curSecondaryAscendClassId is PoE 2 new — not populated in PoE 1.
--     (PoE 2 does NOT actually use a secondary ascendancy; field exists for XML/codec
--      compatibility but stays 0 in practice as of 0.4.)
--   * build:SaveDB(fileName) returns XML with <PathOfBuilding2> root (not <PathOfBuilding>).

local M = {}

local MIN_PLAYER_LEVEL = 1
local MAX_PLAYER_LEVEL = 100
local MAX_ITEM_TEXT_LENGTH = 16 * 1024 -- 16KB — matches PoE 1 cap; rare item text is ~1-2KB

-- Strip functions / userdata / cycles / non-scalar keys so output tables survive
-- the JSON encoder in Server.lua. Copied verbatim from PoE 1's BuildOps.lua —
-- PoB2 has no equivalent utility in Common.lua.
local function deepCopySafe(tbl, seen)
  if type(tbl) ~= 'table' then
    return tbl
  end
  seen = seen or {}
  if seen[tbl] then
    return nil
  end
  seen[tbl] = true
  local out = {}
  for k, v in pairs(tbl) do
    local ktype = type(k)
    if ktype == 'string' or ktype == 'number' or ktype == 'boolean' then
      local vtype = type(v)
      if vtype == 'table' then
        local copied = deepCopySafe(v, seen)
        if copied ~= nil then out[k] = copied end
      elseif vtype ~= 'function' and vtype ~= 'userdata' and vtype ~= 'thread' then
        out[k] = v
      end
    end
  end
  return out
end

-- Ensure outputs are (re)built and return the main output table safely.
-- Idempotent: always wipes GlobalCache and forces a full BuildOutput pass so
-- sequential API calls never read stale cache entries written by a prior pass
-- with different config. See PoE 1 BuildOps.lua for the incident that prompted
-- this (set_config followed by get_full_calcs producing divergent DPS).
function M.get_main_output()
  if not build or not build.calcsTab then
    return nil, "build not initialized"
  end
  wipeGlobalCache()
  build.buildFlag = false
  if build.calcsTab.BuildOutput then
    build.calcsTab:BuildOutput()
  end
  local output = build.calcsTab and build.calcsTab.mainOutput or nil
  if not output then
    return nil, "no output available"
  end
  return output
end

-- Export a curated subset of main-output stats as a flat JSON-friendly table.
-- `fields` (optional) narrows to specific keys. Unknown keys are silently dropped
-- rather than surfaced as errors — callers shape the field list to the engine
-- version they're targeting.
--
-- PoB2 field names verified against Modules/BuildDisplayStats.lua (see
-- pob2-integration-notes POB2-3 for the full enumerated list). Differences from
-- PoE 1 worth noting:
--   * "Spirit" / "SpiritUnreserved" / "SpiritUnreservedPercent"     — NEW (reservation pool)
--   * "EffectiveBlockChance" (was "BlockChance" in PoB1)
--   * "EffectiveSpellBlockChance" (was "SpellBlockChance" in PoB1)
--   * "EffectiveSpellSuppressionChance"                             — NEW
--   * "AttackDodgeChance" (was just "DodgeChance" in PoB1)
--   * "PhysicalDamageReduction"                                     — replaces PoB1 "physDR"
--   * "PhysicalMaximumHitTaken" / "FireMaximumHitTaken" / ...       — NEW first-class max-hit stats
--   * "DeflectionRating" / "DeflectChance"                          — NEW (PoE 2-only mechanic)
--   * "Darkness" / "ReservedDarkness"                               — NEW
-- "Ward" / "BlockChance" / "SpellBlockChance" / "DodgeChance" / "LifeRegen" / "ManaRegen"
-- from the PoB1 default list are intentionally NOT in the PoB2 default — they don't exist
-- (or have been renamed) in PoB2's output schema.
function M.export_stats(fields)
  local output, err = M.get_main_output()
  if not output then
    return nil, err
  end
  local wanted = fields or {
    "Life", "LifeUnreserved", "LifeRegenRecovery",
    "Mana", "ManaUnreserved", "ManaRegenRecovery",
    "Spirit", "SpiritUnreserved",
    "EnergyShield", "EnergyShieldRegenRecovery",
    "Armour", "Evasion",
    "FireResist", "ColdResist", "LightningResist", "ChaosResist",
    "FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap", "ChaosResistOverCap",
    "EffectiveBlockChance", "EffectiveSpellBlockChance",
    "AttackDodgeChance", "SpellDodgeChance", "EffectiveSpellSuppressionChance",
    "PhysicalDamageReduction",
    "PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken",
    "LightningMaximumHitTaken", "ChaosMaximumHitTaken",
    "TotalEHP",
    "Str", "Dex", "Int",
    "TotalDPS", "FullDPS", "CombinedDPS", "TotalDot", "TotalDotDPS",
    "AverageHit", "AverageDamage",
    "Speed", "HitChance", "CritChance", "CritMultiplier", "PreEffectiveCritChance",
    "ManaCost", "LifeCost", "ESCost",
  }
  local result = {}
  for _, k in ipairs(wanted) do
    if type(output[k]) ~= 'nil' then
      result[k] = output[k]
    end
  end
  result._meta = result._meta or {}
  if build and build.targetVersion then
    result._meta.treeVersion = tostring(build.targetVersion)
  end
  if build and build.characterLevel then
    result._meta.level = tonumber(build.characterLevel)
  end
  if build and build.buildName then
    result._meta.buildName = tostring(build.buildName)
  end
  result._meta.engine = "PoB2"
  return result
end

-- Export the full build XML (PathOfBuilding2 root element).
function M.export_build_xml()
  if not build or not build.SaveDB then
    return nil, 'build not initialized'
  end
  local xml = build:SaveDB('api-export')
  if not xml then return nil, 'failed to compose xml' end
  return xml
end

-- Set player level and rebuild.
function M.set_level(level)
  if not build or not build.configTab then
    return nil, 'build/config not initialized'
  end
  local lvl = tonumber(level)
  if not lvl or lvl < MIN_PLAYER_LEVEL or lvl > MAX_PLAYER_LEVEL then
    return nil, string.format('invalid level (must be %d-%d)', MIN_PLAYER_LEVEL, MAX_PLAYER_LEVEL)
  end
  build.characterLevel = lvl
  build.characterLevelAutoMode = false
  if build.configTab and build.configTab.BuildModList then
    build.configTab:BuildModList()
  end
  M.get_main_output()
  return true
end

-- Basic build info — class/ascendancy names + IDs, level, tree version.
-- secondaryAscendClassId included for forward compat even though PoE 2 0.4
-- doesn't use it (field always 0 in practice).
function M.get_build_info()
  if not build then return nil, 'build not initialized' end
  local info = {
    name = build.buildName,
    level = build.characterLevel,
    className = build.spec and build.spec.curClassName or nil,
    ascendClassName = build.spec and build.spec.curAscendClassName or nil,
    classId = build.spec and build.spec.curClassId or nil,
    ascendClassId = build.spec and build.spec.curAscendClassId or nil,
    secondaryAscendClassId = build.spec and build.spec.curSecondaryAscendClassId or nil,
    treeVersion = build.targetVersion or (build.spec and build.spec.treeVersion) or nil,
    engine = "PoB2",
  }
  return info
end

-- ============================================================================
-- Tree tier
-- ============================================================================
--
-- PoB2 deltas from PoB1 that shape this tier:
--
--   * PassiveSpec:ImportFromNodeList signature grew from 7 args to 9
--     (POB2-9 in pob2-integration-notes). Every mutation now has to thread
--     className (arg 1, string) and weaponSets (arg 6, table).
--   * PassiveSpec:CountAllocNodes now returns 6 values instead of 4:
--     used, ascUsed, secondaryAscUsed, sockets, weaponSet1Used, weaponSet2Used.
--   * Nodes gained allocMode (1 = weapon set 1, 2 = weapon set 2, nil = both)
--     — surface per-weapon-set counts in get_tree.
--   * Nodes gained unlockConstraint — pathing respects it; we surface it raw
--     so callers can reason about what blocks allocation.
--   * Cluster-jewel nodes do NOT exist in PoE 2 (POB2-7). We intentionally
--     omit the PoE 1 get_cluster_nodes / cluster-subgraph handling.

-- get_tree: dump the current allocated tree + metadata + point budget.
function M.get_tree()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  local spec = build.spec
  local out = {
    treeVersion            = spec.treeVersion,
    className              = spec.curClassName,
    ascendClassName        = spec.curAscendClassName,
    classId                = tonumber(spec.curClassId) or 0,
    ascendClassId          = tonumber(spec.curAscendClassId) or 0,
    secondaryAscendClassId = tonumber(spec.curSecondaryAscendClassId or 0) or 0,
    nodes                  = {},
    masteryEffects         = {},
    nodeOverrides          = {},
  }

  for id, node in pairs(spec.allocNodes or {}) do
    table.insert(out.nodes, id)
    if node then
      local name = node.dn or node.name
      local stats = {}
      if type(node.sd) == "table" then
        for _, stat in ipairs(node.sd) do
          if type(stat) == "string" then
            table.insert(stats, stat)
          end
        end
      end
      if name then
        out.nodeOverrides[tostring(id)] = {
          name              = name,
          stats             = stats,
          icon              = node.icon,
          activeEffectImage = node.activeEffectImage,
          reminderText      = node.reminderText,
          allocMode         = node.allocMode,        -- POB2-6: weapon swap
          unlockConstraint  = node.unlockConstraint, -- PoE 2 unlock req
        }
      end
    end
  end
  for mastery, effect in pairs(spec.masterySelections or {}) do
    out.masteryEffects[mastery] = effect
  end
  table.sort(out.nodes)
  if not next(out.nodeOverrides) then
    out.nodeOverrides = nil
  end

  -- Point budget. PoB2's CountAllocNodes returns 6 values — we surface all of
  -- them so the caller can render per-weapon-set totals if it cares.
  if spec.CountAllocNodes then
    local used, ascUsed, secondaryAscUsed, sockets, ws1Used, ws2Used = spec:CountAllocNodes()
    out.passivePointsUsed            = used
    out.ascendancyPointsUsed         = ascUsed
    out.secondaryAscendancyPointsUsed = secondaryAscUsed
    out.jewelSocketsUsed             = sockets
    out.weaponSet1NodesUsed          = ws1Used
    out.weaponSet2NodesUsed          = ws2Used
  else
    -- Fallback — kept for robustness but should not fire in PoB2.
    local used, ascUsed = 0, 0
    for _, node in pairs(spec.allocNodes or {}) do
      if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
        if node.ascendancyName then
          ascUsed = ascUsed + 1
        else
          used = used + 1
        end
      end
    end
    out.passivePointsUsed    = used
    out.ascendancyPointsUsed = ascUsed
  end

  -- Total available passive points — do NOT port PoB1's hardcoded act-quest
  -- table (PoE 1 campaign). PoE 2 has different act structure and different
  -- passive-point quest rewards. Surface PoB2's own acts table if present,
  -- otherwise let the caller compute. See build.acts, built from
  -- data.questRewards in buildMode:Init.
  local charLevel = build.characterLevel or 1
  out.characterLevel = charLevel
  if build.acts and build.maxActs then
    local questPoints = 0
    for i = build.maxActs, 1, -1 do
      if build.acts[i] and charLevel >= (build.acts[i].level or 999) then
        questPoints = build.acts[i].questPoints or 0
        break
      end
    end
    local extra = 0
    if build.calcsTab and build.calcsTab.mainOutput then
      extra = build.calcsTab.mainOutput.ExtraPoints or 0
    end
    out.totalPassivePoints = (charLevel - 1) + questPoints + extra
    out.questPointsEarned  = questPoints
  end

  return out
end

-- set_tree: replace the entire allocated node list + mastery selections in
-- one shot. Uses PoB2's 9-arg ImportFromNodeList (POB2-9).
--
-- Missing class/asc/etc. values inherit from current spec so callers can send
-- `{ nodes = [...] }` without having to restate the class every call.
-- weaponSets is passed empty by default — callers doing weapon-set-aware tree
-- work must supply it themselves.
function M.set_tree(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end
  local spec = build.spec
  local className  = params.className or spec.curClassName  -- PoB2 arg 1
  local classId    = params.classId    ~= nil and tonumber(params.classId)    or spec.curClassId    or 0
  local ascendId   = params.ascendClassId ~= nil and tonumber(params.ascendClassId) or spec.curAscendClassId or 0
  local secondaryId = params.secondaryAscendClassId ~= nil and tonumber(params.secondaryAscendClassId) or spec.curSecondaryAscendClassId or 0

  local nodes = {}
  if type(params.nodes) == 'table' then
    for _, v in ipairs(params.nodes) do
      table.insert(nodes, tonumber(v))
    end
  end

  local weaponSets = type(params.weaponSets) == 'table' and params.weaponSets or {}
  local mastery    = params.masteryEffects or {}
  local overrides  = params.hashOverrides  or {}
  local treeVersion = params.treeVersion

  -- POB2-9: 9-arg signature. className first, weaponSets is position 6.
  build.spec:ImportFromNodeList(className, classId, ascendId, secondaryId, nodes, weaponSets, overrides, mastery, treeVersion)

  M.get_main_output()
  return true
end

-- update_tree_delta: incremental allocation change (add/remove lists merged
-- against current tree, then re-imported).
function M.update_tree_delta(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  local current, err = M.get_tree()
  if not current then return nil, err end

  local set = {}
  for _, id in ipairs(current.nodes) do set[id] = true end
  if type(params) == 'table' then
    if type(params.removeNodes) == 'table' then
      for _, id in ipairs(params.removeNodes) do set[tonumber(id)] = nil end
    end
    if type(params.addNodes) == 'table' then
      for _, id in ipairs(params.addNodes) do set[tonumber(id)] = true end
    end
  end

  local nodes = {}
  for id,_ in pairs(set) do table.insert(nodes, id) end
  table.sort(nodes)

  local spec = build.spec
  local className  = (params and params.className) or spec.curClassName
  local classId    = (params and params.classId    ~= nil) and tonumber(params.classId)    or current.classId or 0
  local ascendId   = (params and params.ascendClassId ~= nil) and tonumber(params.ascendClassId) or current.ascendClassId or 0
  local secondaryId = (params and params.secondaryAscendClassId ~= nil) and tonumber(params.secondaryAscendClassId) or current.secondaryAscendClassId or 0
  local treeVersion = (params and params.treeVersion) or current.treeVersion
  local mastery     = current.masteryEffects or {}
  local weaponSets  = (params and type(params.weaponSets) == 'table') and params.weaponSets or {}

  build.spec:ImportFromNodeList(className, tonumber(classId) or 0, tonumber(ascendId) or 0, tonumber(secondaryId) or 0, nodes, weaponSets, {}, mastery, treeVersion)
  M.get_main_output()
  return true
end

-- search_nodes: text search across passive tree node names / sd strings /
-- modList entries. Node type filter + allocated/unallocated filter + cap.
-- Unchanged vs PoE 1 structurally; PoE 2 node flags (isKeystone/isNotable/
-- isJewelSocket) are the same set.
function M.search_nodes(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or type(params.keyword) ~= 'string' then
    return nil, 'missing or invalid keyword'
  end

  local keyword          = params.keyword:lower()
  local filterType       = params.nodeType and params.nodeType:lower() or nil
  local maxResults       = tonumber(params.maxResults) or 50
  local includeAllocated = params.includeAllocated ~= false
  local allocatedOnly    = params.allocatedOnly == true

  local allocatedSet = {}
  for id, _ in pairs(build.spec.allocNodes or {}) do allocatedSet[id] = true end
  local nodeSource = allocatedOnly and build.spec.allocNodes or build.spec.nodes

  local function classifyNode(node)
    if node.ascendancyName          then return 'ascendancy' end
    if node.isKeystone or node.ks   then return 'keystone' end
    if node.isNotable  or node["not"] then return 'notable' end
    if node.isJewelSocket           then return 'jewel' end
    if node.isMastery               then return 'mastery' end
    return 'normal'
  end

  local results, count = {}, 0
  for id, node in pairs(nodeSource or {}) do
    if count >= maxResults then break end
    if allocatedOnly or includeAllocated or not allocatedSet[id] then
      local nType = classifyNode(node)
      if not filterType or nType == filterType then
        local matches = false
        if node.name and node.name:lower():find(keyword, 1, true) then matches = true end
        if not matches and type(node.sd) == 'table' then
          for _, stat in ipairs(node.sd) do
            if type(stat) == 'string' and stat:lower():find(keyword, 1, true) then
              matches = true; break
            end
          end
        end
        if not matches and type(node.modList) == 'table' then
          for _, mod in ipairs(node.modList) do
            if tostring(mod):lower():find(keyword, 1, true) then
              matches = true; break
            end
          end
        end
        if matches then
          local stats = {}
          if type(node.sd) == 'table' then
            for _, s in ipairs(node.sd) do
              if type(s) == 'string' then table.insert(stats, s) end
            end
          end
          table.insert(results, {
            id              = id,
            name            = node.name or node.dn or 'Unnamed',
            type            = nType,
            stats           = stats,
            allocated       = allocatedSet[id] == true,
            x               = node.x,
            y               = node.y,
            orbit           = node.orbit or node.o,
            orbitIndex      = node.orbitIndex or node.oidx,
            ascendancyName  = node.ascendancyName,
            allocMode       = node.allocMode, -- POB2-6
          })
          count = count + 1
        end
      end
    end
  end

  local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, ascendancy = 5, normal = 6 }
  table.sort(results, function(a, b)
    local ao, bo = typeOrder[a.type] or 99, typeOrder[b.type] or 99
    if ao ~= bo then return ao < bo end
    return (a.name or '') < (b.name or '')
  end)

  return { nodes = results, count = #results }
end

-- find_path: shortest path from allocated nodes to target. BFS unchanged from
-- PoB1 — BuildPathFromNode behavior is the same (POB2 added unlockConstraint
-- gating but that's handled inside BuildPathFromNode).
function M.find_path(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or not params.targetNodeId then
    return nil, 'missing targetNodeId'
  end

  local targetId = tonumber(params.targetNodeId)
  local targetNode = build.spec.nodes[targetId]
  if not targetNode then
    return nil, 'target node not found: ' .. tostring(targetId)
  end
  if targetNode.alloc then
    return {
      path = {},
      cost = 0,
      targetNode = {
        id        = targetNode.id,
        name      = targetNode.name or targetNode.dn,
        type      = targetNode.type,
        allocated = true,
      },
    }
  end

  if not build.spec.BuildPathFromNode then
    return nil, 'pathfinding not available (BuildPathFromNode missing)'
  end
  for _, node in pairs(build.spec.nodes) do
    if node.alloc then build.spec:BuildPathFromNode(node) end
  end

  if not targetNode.pathDist or targetNode.pathDist >= 9999 then
    return nil, 'target node is not reachable from allocated nodes'
  end

  local pathNodes = {}
  if targetNode.path then
    for i = #targetNode.path, 1, -1 do
      local node = targetNode.path[i]
      if not node.alloc then
        table.insert(pathNodes, {
          id    = node.id,
          name  = node.name or node.dn,
          type  = node.type,
          stats = node.sd or {},
        })
      end
    end
  end

  return {
    path = pathNodes,
    cost = targetNode.pathDist,
    targetNode = {
      id        = targetNode.id,
      name      = targetNode.name or targetNode.dn,
      type      = targetNode.type,
      stats     = targetNode.sd or {},
      allocated = false,
    },
  }
end

-- get_nodes_in_radius: enumerate tree nodes inside a jewel socket's radii.
-- PoE 2 jewel mechanics are thinner than PoE 1 (no cluster jewels — POB2-7,
-- no timeless jewels confirmed yet). The `nodesInRadius` data structure is
-- populated the same way, so this works; Thread-of-Hope (radius 6-10) doesn't
-- exist in PoE 2, but we keep the filter for forward compat.
function M.get_nodes_in_radius(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then
    return nil, "missing or invalid nodeId"
  end

  local spec = build.spec
  local tree = spec.tree or build.tree
  local socketNode = tree and tree.nodes and tree.nodes[nodeId]
  if not socketNode then
    return nil, "nodeId " .. tostring(nodeId) .. " not found in tree"
  end
  if not socketNode.isJewelSocket then
    return nil, "nodeId " .. tostring(nodeId) .. " is not a jewel socket"
  end
  if not socketNode.nodesInRadius then
    return nil, "socket has no radius data"
  end

  local radiusLabels = { "Small", "Medium", "Large", "Very Large", "Massive" }
  local results = {}
  local targetRadiusIndex = params.radiusIndex and tonumber(params.radiusIndex) or nil

  for radiusIndex, nodesInThisRadius in ipairs(socketNode.nodesInRadius) do
    if (not targetRadiusIndex or radiusIndex == targetRadiusIndex) and radiusIndex <= 5 then
      local radiusResult = {
        radiusIndex = radiusIndex,
        radiusLabel = radiusLabels[radiusIndex] or ("Index " .. radiusIndex),
        nodes       = {},
      }
      for nodeIdInRadius, node in pairs(nodesInThisRadius) do
        local liveNode = (spec.nodes and spec.nodes[nodeIdInRadius]) or node
        local nType = 'normal'
        if liveNode.isKeystone     then nType = 'keystone'
        elseif liveNode.isNotable  then nType = 'notable'
        elseif liveNode.isJewelSocket then nType = 'jewel'
        elseif liveNode.isMastery  then nType = 'mastery'
        end
        local stats = {}
        if type(liveNode.sd) == 'table' then
          for _, s in ipairs(liveNode.sd) do table.insert(stats, s) end
        end
        table.insert(radiusResult.nodes, {
          id           = nodeIdInRadius,
          name         = liveNode.dn or liveNode.name or "Unknown",
          type         = nType,
          isAllocated  = (spec.allocNodes or {})[nodeIdInRadius] ~= nil,
          stats        = stats,
          x            = liveNode.x,
          y            = liveNode.y,
        })
      end
      local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, normal = 5 }
      table.sort(radiusResult.nodes, function(a, b)
        local oa, ob = typeOrder[a.type] or 99, typeOrder[b.type] or 99
        if oa ~= ob then return oa < ob end
        return (a.name or '') < (b.name or '')
      end)
      table.insert(results, radiusResult)
    end
  end

  return {
    socketId   = nodeId,
    socketName = socketNode.dn or socketNode.name or "Jewel Socket",
    socketX    = socketNode.x,
    socketY    = socketNode.y,
    radii      = results,
  }
end

-- ============================================================================
-- Calc tier
-- ============================================================================
--
-- PoB2 deltas from PoB1 for calc handlers:
--
--   * build.calcsTab:GetMiscCalculator() exists with the same signature
--     (returns calcFunc, baseOutput). Verified in Modules/Calcs.lua:123 and
--     Classes/CalcsTab.lua:693. The returned calcFunc(override, useFullDPS)
--     still consumes override.addNodes / removeNodes / conditions — all keyed
--     the same way as PoB1 (verified in Modules/CalcSetup.lua:687,704).
--
--   * override.masteryOverrides is NOT a PoB2 concept — grep shows zero hits
--     under src/Modules/. Mastery selections are persisted on
--     spec.masterySelections and must be mutated through set_tree /
--     update_tree_delta rather than passed as a per-calc override.
--
--   * PoE 1's "mainSocketGroup DPS overlay" (falls back to best-DPS socket
--     group when the currently-selected one is an aura / non-DPS skill) is
--     intentionally NOT ported here. That logic reaches into activeSkillList
--     and the socket-chain data model, which PoE 2 replaces with a flat gem
--     panel. When the skills tier lands we'll revisit whether the same
--     overlay concept applies — for now we trust build.mainSocketGroup and
--     log a diagnostic if the base calculator returns 0 DPS.
--
--   * _computeArmyDps (minion army cap multiplication) is also not ported
--     yet — same reason: minion data model + minionData.limit lookup needs
--     verification against PoB2. Non-minion builds are unaffected; minion
--     builds will show per-minion DPS only until minion tier lands.

-- calc_with: run a what-if calculation with tree mutations applied to the
-- otherwise-persistent build state. Returns both baseOutput (before) and
-- output (after) so callers can diff stats without having to re-read baseline
-- from a separate call.
--
-- Supported params:
--   addNodes     : number[]   — node IDs to add to the allocation
--   removeNodes  : number[]   — node IDs to remove from the allocation
--   conditions   : string[]   — PoB condition flags to set for this calc
--   useFullDPS   : boolean    — default true; pass false to skip FullDPS roll-up
--
-- Unlike set_tree/update_tree_delta, calc_with does NOT mutate build.spec —
-- the override is threaded into calcs.initEnv and discarded after the calc.
-- That means no restore pass is needed here (unlike calc_with_jewel where
-- itemsTab mutations persist).
function M.calc_with(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  if not build.calcsTab.GetMiscCalculator then
    return nil, 'GetMiscCalculator unavailable'
  end

  -- Fetch the cached calculator. CalcsTab:BuildOutput already primes this.
  local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
  if type(calcFunc) ~= 'function' then
    return nil, 'calculator not initialized (call build.calcsTab:BuildOutput first?)'
  end

  local diagnostics = {
    addRequested     = 0,
    addResolved      = 0,
    addUnresolved    = {},
    removeRequested  = 0,
    removeResolved   = 0,
    removeUnresolved = {},
  }

  local override = {}

  if params and type(params.addNodes) == 'table' then
    local addNodes = {}
    local hasAny = false
    diagnostics.addRequested = #params.addNodes
    for _, id in ipairs(params.addNodes) do
      local nid = tonumber(id)
      local node = nid and build.spec and build.spec.nodes and build.spec.nodes[nid]
      if node then
        addNodes[node] = true
        hasAny = true
        diagnostics.addResolved = diagnostics.addResolved + 1
      else
        -- Fallback: a node already allocated (e.g. through a subgraph in a
        -- future jewel system) may have a distinct object ref in allocNodes.
        local allocNode = nid and build.spec and build.spec.allocNodes and build.spec.allocNodes[nid]
        if allocNode then
          addNodes[allocNode] = true
          hasAny = true
          diagnostics.addResolved = diagnostics.addResolved + 1
        else
          table.insert(diagnostics.addUnresolved, id)
          io.stderr:write(string.format(
            "[calc_with] WARN: addNode %s not in spec.nodes or allocNodes\n", tostring(id)))
        end
      end
    end
    if hasAny then override.addNodes = addNodes end
  end

  if params and type(params.removeNodes) == 'table' then
    local removeNodes = {}
    local hasAny = false
    diagnostics.removeRequested = #params.removeNodes
    for _, id in ipairs(params.removeNodes) do
      local nid = tonumber(id)
      local specNode = nid and build.spec and build.spec.nodes and build.spec.nodes[nid]
      local allocNode = nid and build.spec and build.spec.allocNodes and build.spec.allocNodes[nid]
      if allocNode then
        removeNodes[allocNode] = true
        hasAny = true
        diagnostics.removeResolved = diagnostics.removeResolved + 1
      elseif specNode then
        -- Node exists but isn't allocated — no-op, but log.
        io.stderr:write(string.format(
          "[calc_with] WARN: removeNode %s exists in spec.nodes but is NOT allocated (no-op)\n",
          tostring(id)))
      else
        table.insert(diagnostics.removeUnresolved, id)
        io.stderr:write(string.format(
          "[calc_with] WARN: removeNode %s not in spec.nodes or allocNodes\n", tostring(id)))
      end
    end
    if hasAny then override.removeNodes = removeNodes end
  end

  if params and type(params.conditions) == 'table' then
    override.conditions = params.conditions
  end

  local hasOverride = override.addNodes or override.removeNodes or override.conditions
  if not hasOverride then
    io.stderr:write(string.format(
      "[calc_with] WARN: override resolved empty (add %d/%d, remove %d/%d) — before/after will match\n",
      diagnostics.addResolved, diagnostics.addRequested,
      diagnostics.removeResolved, diagnostics.removeRequested))
  end

  local useFullDPS = params and params.useFullDPS
  if useFullDPS == nil then useFullDPS = true end

  local ok, outOrErr = pcall(calcFunc, override, useFullDPS)
  if not ok then
    return nil, 'calc failed: ' .. tostring(outOrErr)
  end
  local out = outOrErr

  -- Log a short diagnostic when a non-empty override produced no change —
  -- typically a sign that the resolved node list wasn't valid or that the
  -- override silently got filtered inside calcs.perform.
  if hasOverride and diagnostics.addRequested + diagnostics.removeRequested > 0 then
    local baseFullDPS  = (baseOut and baseOut.FullDPS)  or 0
    local afterFullDPS = (out and out.FullDPS)  or 0
    local baseTotalDPS = (baseOut and baseOut.TotalDPS) or 0
    local afterTotalDPS = (out and out.TotalDPS) or 0
    io.stderr:write(string.format(
      "[calc_with] FullDPS %d->%d | TotalDPS %d->%d | Life %d->%d | EHP %d->%d\n",
      baseFullDPS, afterFullDPS,
      baseTotalDPS, afterTotalDPS,
      (baseOut and baseOut.Life or 0), (out and out.Life or 0),
      (baseOut and baseOut.TotalEHP or 0), (out and out.TotalEHP or 0)))
  end

  return {
    output     = deepCopySafe(out),
    baseOutput = deepCopySafe(baseOut),
    diagnostics = diagnostics,
  }
end

-- ============================================================================
-- Items tier
-- ============================================================================
--
-- PoB2 deltas from PoB1 that shape this tier:
--
--   * **Slot roster** (POB2-10): 20 base slots instead of PoE 1's 11.
--     Weapons now include 1/2 Swap (weapon swap is first-class, POB2-6);
--     rings are 3 not 2; flasks are 2 not 5; charms (3) are NEW; the four
--     "Arm 1/2 + Leg 1/2" slots hold PoE 2's **Transcendent Limb** items
--     (`src/Data/Bases/incursionlimb.lua` — implicit-bearing late-game
--     items from the Incursion temple). See `baseSlots` in ItemsTab.lua.
--
--   * **No skill-gem sockets** (POB2-4). `it.sockets` still exists but now
--     holds RUNE sockets (small stat bonuses), not linked gem slots. Rune
--     mods are on `it.runeModLines`, the rune list on `it.runes`. PoE 1's
--     socket color/group serialization is dropped.
--
--   * **No PoE 1 influence flags** (`shaperItem`, `elderItem`, `hunterItem`,
--     `crusaderItem`, `redeemerItem`, `warlordItem`) — those mechanics don't
--     exist in PoE 2. Likewise scourge/crucible/eater/exarch/veiled are gone.
--
--   * **New mod line buckets**: `runeModLines`, `classRequirementModLines`,
--     `buffModLines` — surface them for callers that care.
--
--   * **Charms** (new slot type): `build.itemsTab.slots["Charm N"]` has the
--     same `active` checkbox pattern as flasks (ItemSlotControl.lua:43-54).
--     Our add_item_text/add_items_batch auto-activate path extends to Charm
--     slots as well as Flask slots.

-- Extract a mod line from it.implicitModLines / it.explicitModLines /
-- it.enchantModLines / it.runeModLines / it.classRequirementModLines /
-- it.buffModLines into a JSON-friendly entry. Skips mods with empty / nil
-- `line` text (seen as "corrupted" entries on some imports).
local function extractModLine(modLine)
  if not modLine then return nil end
  if not modLine.line or modLine.line == "" then return nil end
  local entry = {
    line    = modLine.line,
    range   = modLine.range,
    modTags = modLine.modTags or {},
  }
  -- Boolean flags we surface (PoE 2 set; no influence/scourge/etc.)
  if modLine.crafted    then entry.crafted    = true end
  if modLine.fractured  then entry.fractured  = true end
  if modLine.implicit   then entry.implicit   = true end
  if modLine.enchant    then entry.enchant    = true end
  if modLine.rune       then entry.rune       = true end
  if modLine.custom     then entry.custom     = true end
  return entry
end

-- get_items: dump the equipped item set + all cached items by slot.
-- Returns an array ordered by `itemsTab.orderedSlots` (the slot-panel order
-- from ItemsTab.lua:30 — Weapon 1, Weapon 2, Helmet ... Arm 1, Arm 2, Leg 1,
-- Leg 2, then jewel sockets appended in node-id order). Only slots with
-- `selItemId > 0` are included. Jewels equipped in tree sockets are also
-- enumerated from build.spec.jewels.
function M.get_items()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local itemsTab = build.itemsTab
  local result = {}
  local seen = {}
  local addedItemIds = {}

  local function append_item(slotName, itemId, activeSlotName)
    if not itemId or itemId <= 0 or addedItemIds[itemId] then return nil end
    local it = itemsTab.items[itemId]
    if not it then return nil end

    local entry = {
      slot      = slotName,
      id        = itemId,
      name      = it.name,
      baseName  = it.baseName,
      type      = it.type,
      subType   = it.base and it.base.subType or nil, -- NEW: Transcendent Arm / Leg
      rarity    = it.rarity,
      raw       = it.raw,
      -- Item metadata
      itemLevel = it.itemLevel,
      quality   = it.quality,
      -- Item flags (PoE 2 set — no influence flags, no scourge/veiled/synth)
      corrupted = it.corrupted  or false,
      mirrored  = it.mirrored   or false,
      fractured = it.fractured  or false,
      split     = it.split      or false,
      -- Jewel radius metadata
      jewelRadiusLabel = it.jewelRadiusLabel,
      jewelRadiusIndex = it.jewelRadiusIndex,
    }

    -- Affix data (prefix/suffix mod IDs + value ranges)
    entry.prefixes = {}
    if it.prefixes then
      for _, p in ipairs(it.prefixes) do
        if p.modId and p.modId ~= "None" then
          table.insert(entry.prefixes, { modId = p.modId, range = p.range })
        end
      end
    end
    entry.suffixes = {}
    if it.suffixes then
      for _, s in ipairs(it.suffixes) do
        if s.modId and s.modId ~= "None" then
          table.insert(entry.suffixes, { modId = s.modId, range = s.range })
        end
      end
    end
    entry.prefixCount = #entry.prefixes
    entry.suffixCount = #entry.suffixes
    if it.rarity == "RARE" or it.rarity == "MAGIC" then
      entry.maxPrefixes = it.rarity == "MAGIC" and 1 or 3
      entry.maxSuffixes = it.rarity == "MAGIC" and 1 or 3
    end

    -- Structured mod lines (PoE 2 buckets)
    entry.implicitMods = {}
    if it.implicitModLines then
      for _, m in ipairs(it.implicitModLines) do
        local e = extractModLine(m); if e then table.insert(entry.implicitMods, e) end
      end
    end
    entry.explicitMods = {}
    if it.explicitModLines then
      for _, m in ipairs(it.explicitModLines) do
        local e = extractModLine(m); if e then table.insert(entry.explicitMods, e) end
      end
    end
    entry.enchantMods = {}
    if it.enchantModLines then
      for _, m in ipairs(it.enchantModLines) do
        local e = extractModLine(m); if e then table.insert(entry.enchantMods, e) end
      end
    end
    entry.runeMods = {}  -- NEW in PoE 2 — rune socket mods live here
    if it.runeModLines then
      for _, m in ipairs(it.runeModLines) do
        local e = extractModLine(m); if e then table.insert(entry.runeMods, e) end
      end
    end
    entry.classRequirementMods = {}
    if it.classRequirementModLines then
      for _, m in ipairs(it.classRequirementModLines) do
        local e = extractModLine(m); if e then table.insert(entry.classRequirementMods, e) end
      end
    end

    -- Runes (the raw rune list — distinct from runeModLines text)
    if it.runes and #it.runes > 0 then
      entry.runes = {}
      for _, r in ipairs(it.runes) do table.insert(entry.runes, r) end
    end

    -- Catalyst (PoE 2 keeps the mechanic — see Item.lua:581-585 + ItemsTab.lua:32-44)
    if it.catalyst then
      local catalystNames = {"Abrasive","Accelerating","Fertile","Imbued","Intrinsic",
                             "Noxious","Prismatic","Tempering","Turbulent","Unstable"}
      entry.catalyst        = catalystNames[it.catalyst]
      entry.catalystQuality = it.catalystQuality or 20
    end

    -- Requirements — use modified values when present (mirror PoB's
    -- env.requirementsTableItems logic).
    if it.requirements then
      local strReq = it.requirements.strMod or it.requirements.str or 0
      local dexReq = it.requirements.dexMod or it.requirements.dex or 0
      local intReq = it.requirements.intMod or it.requirements.int or 0
      entry.requirements = {
        level = it.requirements.level,
        str   = strReq > 0 and strReq or nil,
        dex   = dexReq > 0 and dexReq or nil,
        int   = intReq > 0 and intReq or nil,
        runeLevel = (it.requirements.runeLevel or 0) > 0 and it.requirements.runeLevel or nil,
      }
    end

    -- Defense (Armour / Evasion / Energy Shield — PoE 2 dropped Ward)
    if it.armourData then
      entry.armourData = {
        armour       = it.armourData.Armour,
        evasion      = it.armourData.Evasion,
        energyShield = it.armourData.EnergyShield,
      }
    end

    -- Weapon (per-hand nested table, same as PoB1 — see Item.lua:1549).
    if it.weaponData then
      local slotNum = (slotName and slotName:match("Weapon 2")) and 2 or 1
      local wd = it.weaponData[slotNum]
      if wd then
        entry.weaponData = {
          physicalMin  = wd.PhysicalMin,
          physicalMax  = wd.PhysicalMax,
          physicalDPS  = wd.PhysicalDPS,
          elementalDPS = wd.ElementalDPS,
          chaosDPS     = wd.ChaosDPS,
          totalDPS     = wd.TotalDPS,
          critChance   = wd.CritChance,
          attackRate   = wd.AttackRate,
          range        = wd.range,
          fireMin      = wd.FireMin,      fireMax      = wd.FireMax,
          coldMin      = wd.ColdMin,      coldMax      = wd.ColdMax,
          lightningMin = wd.LightningMin, lightningMax = wd.LightningMax,
          chaosMin     = wd.ChaosMin,     chaosMax     = wd.ChaosMax,
        }
      end
    end

    -- Flask (recovery + charge data). PoB2 adds a handful of Inc/Mod rate
    -- fields; we surface what's stable.
    if it.flaskData then
      entry.flaskData = {
        lifeTotal   = it.flaskData.lifeTotal,
        lifeGradual = it.flaskData.lifeGradual,
        lifeInstant = it.flaskData.lifeInstant,
        manaTotal   = it.flaskData.manaTotal,
        manaGradual = it.flaskData.manaGradual,
        manaInstant = it.flaskData.manaInstant,
        duration    = it.flaskData.duration,
        chargesMax  = it.flaskData.chargesMax,
        chargesUsed = it.flaskData.chargesUsed,
        instantPerc = it.flaskData.instantPerc,
      }
    end

    -- Charm (NEW in PoE 2). Structurally similar to flasks — duration +
    -- charge economy, no recovery pool.
    if it.charmData then
      entry.charmData = {
        duration    = it.charmData.duration,
        chargesMax  = it.charmData.chargesMax,
        chargesUsed = it.charmData.chargesUsed,
        effectInc   = it.charmData.effectInc,
      }
    end

    -- Activation flag (flasks + charms both honor activeItemSet[slot].active)
    local set = itemsTab.activeItemSet
    if activeSlotName and set and set[activeSlotName] and set[activeSlotName].active ~= nil then
      entry.active = set[activeSlotName].active and true or false
    end

    table.insert(result, entry)
    addedItemIds[itemId] = true
    return entry
  end

  local function add_slot(slotName)
    if seen[slotName] then return end
    seen[slotName] = true
    local slotCtrl = itemsTab.slots[slotName]
    if not slotCtrl then return end
    local selId = slotCtrl.selItemId or 0
    if selId > 0 then
      append_item(slotName, selId, slotName)
    end
  end

  local ordered = itemsTab.orderedSlots or {}
  for _, slot in ipairs(ordered) do
    if slot and slot.slotName then add_slot(slot.slotName) end
  end
  -- Catch slots that aren't in orderedSlots (shouldn't happen but safe).
  for slotName, _ in pairs(itemsTab.slots or {}) do add_slot(slotName) end

  -- Tree-socket jewels (build.spec.jewels is node-id -> item-id).
  local spec = build.spec or {}
  if spec.jewels then
    for nodeId, itemId in pairs(spec.jewels) do
      local entry = append_item("Jewel " .. tostring(nodeId), itemId, nil)
      if entry then
        entry.socketNodeId = tonumber(nodeId) or nodeId
      end
    end
  end

  return result
end

-- Internal: activate flask/charm checkbox state when equipping via API.
-- Flasks and charms in PoB2 both use the activeItemSet[slot].active flag +
-- the ItemSlotControl.active cache (see ItemSlotControl.lua:31-54).
local function _autoActivateFlaskOrCharm(itemsTab, slotName)
  if not slotName then return end
  local isFlask = slotName:match('^Flask %d$') ~= nil
  local isCharm = slotName:match('^Charm %d$') ~= nil
  if not (isFlask or isCharm) then return end
  local set = itemsTab.activeItemSet
  if set and set[slotName] then set[slotName].active = true end
  local ctrl = itemsTab.slots[slotName]
  if ctrl then
    ctrl.active = true
    if ctrl.controls and ctrl.controls.activate then
      ctrl.controls.activate.state = true
    end
  end
end

-- add_item_text: parse one item from raw item text, add it to itemsTab.items,
-- and optionally equip it in a slot.
function M.add_item_text(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.text) ~= 'string' then
    return nil, 'missing text'
  end
  if #params.text == 0 then return nil, 'item text cannot be empty' end
  if #params.text > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end

  local ok, item = pcall(new, 'Item', params.text)
  if not ok then return nil, 'invalid item text: ' .. tostring(item) end
  if not item or not item.baseName then return nil, 'failed to parse item' end

  item:NormaliseQuality()
  build.itemsTab:AddItem(item, params.noAutoEquip == true)

  if params.slotName then
    local slot = tostring(params.slotName)
    if build.itemsTab.slots[slot] then
      build.itemsTab.slots[slot]:SetSelItemId(item.id)
      _autoActivateFlaskOrCharm(build.itemsTab, slot)
      build.itemsTab:PopulateSlots()
    end
  end

  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return {
    id   = item.id,
    name = item.name,
    slot = params.slotName or item:GetPrimarySlot(),
  }
end

-- add_items_batch: parse + equip multiple items in one call. Defers the
-- expensive PopulateSlots / AddUndoState / BuildOutput to the end so a
-- 20-item import doesn't incur 20 full recalcs.
function M.add_items_batch(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.items) ~= 'table' then
    return nil, 'missing items array'
  end

  local results = {}
  local successCount = 0

  for i, itemParams in ipairs(params.items) do
    local result = { index = i }

    if type(itemParams) ~= 'table' or type(itemParams.text) ~= 'string' then
      result.ok = false; result.error = 'missing or invalid text'
      table.insert(results, result); goto continue
    end
    if #itemParams.text == 0 then
      result.ok = false; result.error = 'item text cannot be empty'
      table.insert(results, result); goto continue
    end
    if #itemParams.text > MAX_ITEM_TEXT_LENGTH then
      result.ok = false
      result.error = string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
      table.insert(results, result); goto continue
    end

    local ok, item = pcall(new, 'Item', itemParams.text)
    if not ok then
      result.ok = false; result.error = 'invalid item text: ' .. tostring(item)
      table.insert(results, result); goto continue
    end
    if not item or not item.baseName then
      result.ok = false; result.error = 'failed to parse item'
      table.insert(results, result); goto continue
    end

    item:NormaliseQuality()
    build.itemsTab:AddItem(item, itemParams.noAutoEquip == true)

    if itemParams.slotName then
      local slot = tostring(itemParams.slotName)
      if build.itemsTab.slots[slot] then
        build.itemsTab.slots[slot]:SetSelItemId(item.id)
        _autoActivateFlaskOrCharm(build.itemsTab, slot)
      end
    end

    result.ok   = true
    result.id   = item.id
    result.name = item.name
    result.slot = itemParams.slotName or item:GetPrimarySlot()
    successCount = successCount + 1
    table.insert(results, result)

    ::continue::
  end

  if successCount > 0 then
    build.itemsTab:PopulateSlots()
    build.itemsTab:AddUndoState()
    build.buildFlag = true
    M.get_main_output()
  end

  return { results = results, successCount = successCount }
end

-- ============================================================================
-- calc_with_jewel — calc tier, jewel edition
-- ============================================================================
--
-- Equip a jewel in a tree socket, recompute, snapshot output, then restore.
-- Unlike calc_with (override-based, non-persistent), calc_with_jewel actually
-- mutates build state for the duration of the call — jewel radius effects
-- require the real spec.allocNodes walk that GetMiscCalculator's override
-- path skips.
--
-- PoB2 deltas from PoB1 that shape this handler:
--
--   * **No cluster jewels** (POB2-7). The PoE 1 implementation was ~500 LOC;
--     ~300 of those were dedicated to cluster subgraphs (BuildClusterJewelGraphs,
--     allocExtendedNodes / allocSubgraphNodes snapshots, subgraph BFS for
--     auto-allocating notables inside the cluster, clusterSubgraph response
--     shape, clusterJewelValid fix-up for multi-enchant bases). All of it is
--     gone. If GGG ships a cluster-equivalent in PoE 2 later, re-introduce.
--
--   * **No minion army-DPS** postprocessing. Same reason as calc_with:
--     minion tier not yet investigated.
--
--   * **Uses itemsTab:DeleteItem(item, true)** for cleanup — same method
--     as PoB1 but we skip the manual `itemOrderList` iteration (DeleteItem
--     does that internally at Classes/ItemsTab.lua:1448-1453).

function M.calc_with_jewel(params)
  if not build or not build.spec      then return nil, 'build/spec not initialized' end
  if not build.itemsTab               then return nil, 'items not initialized' end
  if not build.calcsTab               then return nil, 'calcs not initialized' end
  if type(params) ~= 'table'          then return nil, 'invalid params' end

  local nodeId = tonumber(params.socketNodeId)
  if not nodeId then return nil, 'missing or invalid socketNodeId' end

  local jewelText = params.jewelText
  if type(jewelText) ~= 'string' or #jewelText == 0 then
    return nil, 'missing or empty jewelText'
  end
  if #jewelText > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('jewelText too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end

  local spec = build.spec
  local itemsTab = build.itemsTab
  local socketCtrl = itemsTab.sockets and itemsTab.sockets[nodeId]
  if not socketCtrl then
    return nil, 'nodeId ' .. tostring(nodeId) .. ' is not a jewel socket'
  end

  -- 1. Baseline — make sure build is current before snapshotting.
  M.get_main_output()
  local beforeOutput = deepCopySafe(build.calcsTab.mainOutput)

  -- 2. Snapshot restore targets.
  local savedSocketSelId = socketCtrl.selItemId or 0

  -- Nodes newly allocated during the test. Kept per-category so we can report
  -- pointCost back to the caller and deallocate in the right order.
  local addedPathIds    = {} -- socket + travel nodes from autoAllocateSocketPath
  local addedExplicitIds = {} -- explicit allocateNodes
  local createdItemId = nil

  -- 3. Restore — runs on both success and failure paths.
  local function restoreState()
    pcall(function() socketCtrl:SetSelItemId(savedSocketSelId) end)

    -- Deallocate everything we allocated. Order doesn't matter because we
    -- track actual IDs rather than doing a diff.
    for _, pid in ipairs(addedPathIds) do
      local node = spec.nodes[pid]
      if node then node.alloc = false end
      spec.allocNodes[pid] = nil
    end
    for _, pid in ipairs(addedExplicitIds) do
      local node = spec.nodes[pid]
      if node then node.alloc = false end
      spec.allocNodes[pid] = nil
    end

    if createdItemId and itemsTab.items[createdItemId] then
      pcall(function() itemsTab:DeleteItem(itemsTab.items[createdItemId], true) end)
    end

    pcall(function()
      itemsTab:PopulateSlots()
      build.buildFlag = true
      M.get_main_output()
    end)
  end

  local ok, result = pcall(function()
    -- 4a. If the socket isn't allocated, optionally path to it.
    if not spec.allocNodes[nodeId] then
      if params.autoAllocateSocketPath then
        local pathResult, pathErr = M.find_path({ targetNodeId = nodeId })
        if not pathResult then
          error('failed to path to socket ' .. tostring(nodeId) .. ': ' .. tostring(pathErr))
        end
        for _, pn in ipairs(pathResult.path or {}) do
          local pid = tonumber(pn.id)
          if pid then
            local node = spec.nodes[pid]
            if node and not spec.allocNodes[pid] then
              node.alloc = true
              spec.allocNodes[pid] = node
              table.insert(addedPathIds, pid)
            end
          end
        end
      end
      -- Always allocate the socket itself when we got here.
      local socketNode = spec.nodes[nodeId]
      if socketNode and not spec.allocNodes[nodeId] then
        socketNode.alloc = true
        spec.allocNodes[nodeId] = socketNode
        table.insert(addedPathIds, nodeId)
      end
    end

    -- 4b. Parse + add the jewel item, then equip it.
    local parseOk, item = pcall(new, 'Item', jewelText)
    if not parseOk then error('invalid jewel text: ' .. tostring(item)) end
    if not item or not item.baseName then error('failed to parse jewel item') end
    if item.type ~= 'Jewel' then
      error('item is not a jewel (type=' .. tostring(item.type) .. ')')
    end

    item:NormaliseQuality()
    itemsTab:AddItem(item, true) -- noAutoEquip = true; we equip below
    createdItemId = item.id
    socketCtrl:SetSelItemId(createdItemId)

    -- 4c. Explicit node allocation (non-cluster path — tests "jewel + these
    -- notables allocated" as a single scenario).
    if type(params.allocateNodes) == 'table' then
      for _, rawId in ipairs(params.allocateNodes) do
        local nid = tonumber(rawId)
        if nid then
          local node = spec.nodes[nid]
          if node and not spec.allocNodes[nid] then
            node.alloc = true
            spec.allocNodes[nid] = node
            table.insert(addedExplicitIds, nid)
          end
        end
      end
    end

    -- 4d. Rebuild output with the jewel equipped.
    itemsTab:PopulateSlots()
    build.buildFlag = true
    M.get_main_output()

    local afterOutput = deepCopySafe(build.calcsTab.mainOutput)

    local bDPS = (beforeOutput and beforeOutput.CombinedDPS) or 0
    local aDPS = (afterOutput  and afterOutput.CombinedDPS)  or 0
    local bLife = (beforeOutput and beforeOutput.Life) or 0
    local aLife = (afterOutput  and afterOutput.Life)  or 0
    io.stderr:write(string.format(
      "[calc_with_jewel] CombinedDPS %.1f -> %.1f (delta=%.1f), Life %d -> %d\n",
      bDPS, aDPS, aDPS - bDPS, bLife, aLife))

    return {
      beforeOutput        = beforeOutput,
      afterOutput         = afterOutput,
      allocatedPathNodes  = addedPathIds,
      allocatedExtraNodes = addedExplicitIds,
      pointCost           = #addedPathIds + #addedExplicitIds,
    }
  end)

  restoreState()

  if not ok then return nil, tostring(result) end
  return result
end

return M
