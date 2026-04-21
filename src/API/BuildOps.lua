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

return M
