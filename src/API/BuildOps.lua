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

-- Full calcs dump — the heavy stats surface for LangChain tools / analysis.
-- Goes beyond export_stats by also returning per-skill DPS, per-skill
-- reservation (mana/life/spirit — PoE 2 adds Spirit), active skill name,
-- config snapshot, and skill-tier summary. Used when get_stats' curated list
-- isn't enough (e.g. investigating "why is my DPS low?" with full context).
--
-- PoB2 deltas from PoB1 that shape this handler:
--
--   * Per-skill reservation now includes Spirit. PoE 2's primary reservation
--     pool is Spirit (POB2-5), and CalcDefence.lua:285/302 writes
--     activeSkill.skillData.SpiritReservedBase / .SpiritReservedPercent with
--     the same shape as Life/Mana. We surface all three pools.
--   * `calcsTab.output` / `calcsTab.skillOutput` / `calcsTab.breakdown` from
--     PoB1 are renamed in PoB2: the CALCS-mode output is `calcsTab.calcsOutput`,
--     breakdown lives on `calcsTab.calcsEnv.player.breakdown`. They're
--     INTENTIONALLY NOT SURFACED here — the payloads are huge (every
--     breakdown for every stat) and PoE 1 only used them for deep debug.
--     If a caller actually needs CALCS-mode detail, add a dedicated handler.
--   * `_computeArmyDps` is PoE 1's minion DPS rollup — minion tier not
--     ported yet, so we skip it. When the minion tier lands, inject the call
--     back here so baselines stay shape-consistent.
--   * FullDPS best-skill overlay retained — still useful: when no socket group
--     has `includeInFullDPS` flipped, mainOutput.FullDPS stays 0 and the main
--     skill's DPS lives in a per-skill cache only. We detect that and overlay
--     the best skill's fields onto mainOutput so callers get real numbers.
--   * MainHand / OffHand Accuracy surfacing retained — PoE 2 still nests
--     per-weapon-pass stats on mainOutput.MainHand / .OffHand sub-tables.
function M.get_full_calcs()
  if not build or not build.calcsTab then return nil, 'build not initialized' end

  -- Idempotent rebuild — same discipline as get_main_output. See that comment
  -- for the rationale (cached-output divergence between back-to-back calls).
  wipeGlobalCache()
  build.buildFlag = false
  if build.calcsTab.BuildOutput then build.calcsTab:BuildOutput() end

  local calcsTab = build.calcsTab
  local mainOutput = calcsTab.mainOutput or {}
  local mainEnv = calcsTab.mainEnv

  -- CurseList / BuffList — mainEnv.curseSlots and mainEnv.debuffs/buffs ARE
  -- populated during the MAIN pass (CalcPerform.lua:1704/1709/2740). Inject
  -- them into mainOutput so callers don't have to walk the env.
  if mainEnv then
    if not mainOutput.CurseList then
      local names = {}
      if mainEnv.debuffs then
        for name, _ in pairs(mainEnv.debuffs) do table.insert(names, name) end
      end
      if mainEnv.curseSlots then
        for _, slot in ipairs(mainEnv.curseSlots) do
          if slot.name then table.insert(names, slot.name) end
        end
      end
      table.sort(names)
      mainOutput.CurseList = table.concat(names, ", ")
    end
    if mainEnv.buffs and not mainOutput.BuffList then
      local names = {}
      for name, _ in pairs(mainEnv.buffs) do table.insert(names, name) end
      table.sort(names)
      mainOutput.BuffList = table.concat(names, ", ")
    end
  end

  -- Identify the active skill from the calc env (not build.activeSkill — that's
  -- a GUI control and isn't always authoritative).
  local activeSkillName = nil
  if mainEnv and mainEnv.player and mainEnv.player.mainSkill then
    local ms = mainEnv.player.mainSkill
    if ms.activeEffect and ms.activeEffect.grantedEffect then
      activeSkillName = ms.activeEffect.grantedEffect.name
    end
  end

  -- Per-skill DPS. Walk activeSkillList; for each enabled socket group, pull
  -- that skill's cached output from GlobalCache["MAIN"][uuid]. Cache is
  -- populated by CalcPerform.lua:3269 (end-of-MAIN-pass cacheData call) —
  -- every enabled active skill ends up with an entry.
  local perSkillDPS = {}
  if mainEnv and mainEnv.player and mainEnv.player.activeSkillList then
    for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
      if activeSkill.socketGroup and activeSkill.socketGroup.enabled then
        local skillName
        if activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect then
          skillName = activeSkill.activeEffect.grantedEffect.name
        end
        if skillName then
          local uuid = cacheSkillUUID and cacheSkillUUID(activeSkill, mainEnv) or nil
          local skillOut
          if uuid and GlobalCache and GlobalCache.cachedData and GlobalCache.cachedData["MAIN"] and GlobalCache.cachedData["MAIN"][uuid] then
            local cached = GlobalCache.cachedData["MAIN"][uuid]
            skillOut = cached.Env and cached.Env.player and cached.Env.player.output
          end
          if skillOut then
            table.insert(perSkillDPS, {
              name             = skillName,
              CombinedDPS      = skillOut.CombinedDPS or 0,
              TotalDPS         = skillOut.TotalDPS or 0,
              TotalDotDPS      = skillOut.TotalDotDPS or 0,
              TotalPoisonDPS   = skillOut.TotalPoisonDPS or 0,
              PoisonDPS        = skillOut.PoisonDPS,
              WithPoisonDPS    = skillOut.WithPoisonDPS or 0,
              BleedDPS         = skillOut.BleedDPS or 0,
              IgniteDPS        = skillOut.IgniteDPS or 0,
              includeInFullDPS = activeSkill.socketGroup.includeInFullDPS or false,
            })
          end
        end
      end
    end
  end

  -- FullDPS fallback. When no socket group has includeInFullDPS flipped,
  -- mainOutput.FullDPS stays 0 and the caller can't tell what the build's
  -- actually doing. Find the highest-CombinedDPS non-support skill and
  -- overlay its damage fields onto mainOutput.
  if not mainOutput.FullDPS or mainOutput.FullDPS == 0 then
    local bestDPS = 0
    local bestSkillOut, bestSkillName
    if mainEnv and mainEnv.player and mainEnv.player.activeSkillList then
      for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
        if activeSkill.socketGroup and activeSkill.socketGroup.enabled
           and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
           and not activeSkill.activeEffect.grantedEffect.support then
          local uuid = cacheSkillUUID and cacheSkillUUID(activeSkill, mainEnv) or nil
          if uuid and GlobalCache and GlobalCache.cachedData and GlobalCache.cachedData["MAIN"] and GlobalCache.cachedData["MAIN"][uuid] then
            local cached = GlobalCache.cachedData["MAIN"][uuid]
            local so = cached.Env and cached.Env.player and cached.Env.player.output
            if so and (so.CombinedDPS or 0) > bestDPS then
              bestDPS = so.CombinedDPS
              bestSkillOut = so
              bestSkillName = activeSkill.activeEffect.grantedEffect.name
            end
          end
        end
      end
    end
    if bestSkillOut and bestDPS > (mainOutput.CombinedDPS or 0) then
      local dpsFields = {
        "CombinedDPS", "TotalDPS", "TotalDotDPS", "TotalPoisonDPS", "PoisonDPS",
        "WithPoisonDPS", "BleedDPS", "IgniteDPS", "TotalIgniteDPS", "DecayDPS",
        "ImpaleDPS", "HitDPS", "AverageDamage", "Speed", "CritChance",
        "CritMultiplier", "EffectiveCritChance", "PoisonChance", "PoisonDamage",
        "TotalDot", "MirageDPS", "CullingDPS",
        "Accuracy", "HitChance", "PreEffectiveCritChance",
        "AverageHit", "AverageBurstDamage", "AverageBurstHits",
        "PhysicalHitAverage", "FireHitAverage", "ColdHitAverage",
        "LightningHitAverage", "ChaosHitAverage",
        "FirePenetration", "ColdPenetration", "LightningPenetration", "ChaosPenetration",
      }
      for _, field in ipairs(dpsFields) do
        if bestSkillOut[field] ~= nil then mainOutput[field] = bestSkillOut[field] end
      end
      mainOutput.FullDPS = bestDPS
      activeSkillName = bestSkillName
    elseif mainOutput.CombinedDPS and mainOutput.CombinedDPS > 0 then
      mainOutput.FullDPS = mainOutput.CombinedDPS
    end
  end

  -- Surface per-hand accuracy/hit chance when top-level is missing.
  -- CalcOffence populates mainOutput.MainHand / .OffHand sub-tables with
  -- per-weapon-pass numbers; for attack builds, mainOutput.Accuracy at the
  -- top level can be nil while the actual value lives in the sub-table.
  if (not mainOutput.Accuracy or mainOutput.Accuracy == 0) then
    local mh = mainOutput.MainHand
    local oh = mainOutput.OffHand
    if type(mh) == "table" and mh.Accuracy and mh.Accuracy > 0 then
      mainOutput.Accuracy = mh.Accuracy
    elseif type(oh) == "table" and oh.Accuracy and oh.Accuracy > 0 then
      mainOutput.Accuracy = oh.Accuracy
    end
  end
  if (not mainOutput.AccuracyHitChance or mainOutput.AccuracyHitChance == 0) then
    local mh = mainOutput.MainHand
    if type(mh) == "table" and mh.AccuracyHitChance and mh.AccuracyHitChance > 0 then
      mainOutput.AccuracyHitChance = mh.AccuracyHitChance
    end
  end

  -- Per-skill reservation breakdown. Reads values set by CalcDefence.lua:285-302
  -- (doActorLifeManaSpiritReservation). PoE 2 adds Spirit — the primary
  -- reservation pool (POB2-5) — so we report all three pools per skill.
  local perSkillReservation = {}
  if mainEnv and mainEnv.player and mainEnv.player.activeSkillList then
    for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
      local sd = activeSkill.skillData
      if sd then
        local manaPct   = sd.ManaReservedPercent or 0
        local manaFlat  = sd.ManaReservedBase or 0
        local lifePct   = sd.LifeReservedPercent or 0
        local lifeFlat  = sd.LifeReservedBase or 0
        local spiritPct  = sd.SpiritReservedPercent or 0
        local spiritFlat = sd.SpiritReservedBase or 0
        -- When reservation is percent-based, base is a computed flat equivalent
        -- (pool * percent / 100). Only report "real" flat reservations —
        -- percent==0 AND flat>0 — to avoid a misleading redundant flat entry.
        local flatOnlyMana   = manaPct == 0   and manaFlat > 0
        local flatOnlyLife   = lifePct == 0   and lifeFlat > 0
        local flatOnlySpirit = spiritPct == 0 and spiritFlat > 0
        local hasAny = manaPct > 0 or lifePct > 0 or spiritPct > 0
                    or flatOnlyMana or flatOnlyLife or flatOnlySpirit
        if hasAny then
          local skillName
          if activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect then
            skillName = activeSkill.activeEffect.grantedEffect.name
          end
          if skillName then
            table.insert(perSkillReservation, {
              name         = skillName,
              manaPercent  = manaPct,
              manaFlat     = flatOnlyMana and manaFlat or 0,
              lifePercent  = lifePct,
              lifeFlat     = flatOnlyLife and lifeFlat or 0,
              spiritPercent = spiritPct,
              spiritFlat   = flatOnlySpirit and spiritFlat or 0,
            })
          end
        end
      end
    end
  end

  return {
    mainOutput          = deepCopySafe(mainOutput),
    config              = deepCopySafe(build.configTab and build.configTab.input or {}),
    skills              = M.get_skills(),
    activeSkill         = activeSkillName,
    perSkillDPS         = perSkillDPS,
    perSkillReservation = perSkillReservation,
  }
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
-- Skills tier
-- ============================================================================
--
-- PoB2 deltas from PoB1 that shape this tier:
--
--   * **No physical gem sockets on gear** (POB2-4). Skills live in a dedicated
--     gem panel; support gems attach via UI, not links on gear. BUT — and this
--     is the key finding from POB2-13 — PoB2 kept PoB1's
--     `skillSets[n].socketGroupList[].gemList[]` data-model verbatim. Socket
--     groups still exist, they just don't have a physical slot backing them.
--     `socketGroup.slot` is now a UI-affinity string, not a mechanical link.
--
--   * **Support gem identity**: PoE 1's "gem name Support suffix mismatch"
--     gotcha does NOT apply to PoB2. Support gems are named by their ability
--     (e.g. "Fire Attunement", "Rapid Attacks I") — no "Support" suffix in
--     `gemData.name`. `gemData.gemType == "Support"` is the canonical
--     identifier; `gemData.grantedEffect.support == true` still works too.
--     `gemData.tags.support == true` is ALSO set on every support gem.
--
--   * **Tag roster** (verified by greps over src/Data/Gems.lua):
--       - Still present: aura, herald, warcry, totem, trap, mine, attack,
--         spell, area, cold/fire/lightning/chaos, melee, movement, minion,
--         duration, curse, slam, travel, strength/dex/int
--       - NEW in PoE 2: grants_active_skill, shapeshift, bear, nova, payoff
--       - Gone: guard (replaced by split dodge/deflect/block mechanics).
--     Priority order for `skillType` classification drops `guard` and keeps
--     everything else PoE 1 had.
--
--   * **New top-level gem fields** worth surfacing:
--       - `gemType` — first-class "Attack" / "Spell" / "Support" category
--       - `Tier` (int, 0-7 observed) — gem tier in PoE 2
--       - `weaponRequirements` — comma-joined string like "One Hand Mace,
--         Two Hand Mace"
--       - `naturalMaxLevel` — gem's max level before +level scaling
--       - `gemFamily` — groups support-gem upgrades (e.g. "Fire Attunement")
--
--   * **build.skillsTab.socketGroupList** is set to
--     `skillSets[activeSkillSetId].socketGroupList` in SetActiveSkillSet
--     (SkillsTab.lua:1308). We still go through the active skill set
--     explicitly for safety — matches PoE 1 port's contract.
--
--   * **ProcessSocketGroup** is unchanged in spirit — resolves each gem's
--     `gemData` from `data.gems[gemId]` (or via `data.gemsByGameId` for
--     transfigured variants), then walks the granted effect to populate
--     color / level / requirements. Must be called after any gemList mutation.

-- Default level for a gem when the caller doesn't supply one. PoE 2 gems have
-- a `Tier` system and `naturalMaxLevel` per gem — fall back to
-- naturalMaxLevel when known, otherwise 20 (skill-gem cap).
local function defaultGemLevel(gemData)
  if gemData and gemData.naturalMaxLevel then return gemData.naturalMaxLevel end
  return 20
end

-- Tag priority for primary skillType classification. PoE 2 dropped `guard`
-- (replaced by distinct dodge/deflect/block). Order must stay stable so
-- callers can rely on e.g. minion gems classifying as 'minion' even when
-- they also have `attack` set.
local SKILL_TYPE_PRIORITY = {
  "aura", "herald", "warcry", "movement", "minion",
  "totem", "trap", "mine", "attack", "spell",
}

local function classifySkillType(tags)
  if type(tags) ~= 'table' then return nil end
  for _, t in ipairs(SKILL_TYPE_PRIORITY) do
    if tags[t] then return t end
  end
  return nil
end

-- Resolve a gem-panel lookup by nameSpec, gemId, skillId (= grantedEffectId),
-- or gameId. Returns the gemData entry from `data.gems` or nil.
--
-- Matching order tries display name + gemFamily first (what ladder data and
-- LLM tool calls usually carry), then falls back to canonical IDs. Unlike
-- PoE 1, the " Support" suffix swap is not needed — PoB2 support gems
-- identify themselves via gemType/tags, and their `.name` field has no
-- "Support" suffix. We still try the swap for PoE-1-legacy ladder strings
-- that carry "Increased Duration Support" etc. — cheap, and robust to any
-- future PoE 2 migration that revives the suffix.
local function findGemByIdentifier(identifier)
  if not build or not build.data or not build.data.gems then return nil end
  if not identifier then return nil end
  local term = tostring(identifier)
  local altTerm
  if term:sub(-8) == " Support" then
    altTerm = term:sub(1, -9)
  else
    altTerm = term .. " Support"
  end
  for _, gemData in pairs(build.data.gems) do
    if gemData.name == term       or gemData.nameSpec == term
       or gemData.name == altTerm or gemData.nameSpec == altTerm
       or gemData.id == term      or gemData.gameId == term
       or gemData.variantId == term then
      return gemData
    end
    if gemData.grantedEffectId == term then return gemData end
    if gemData.grantedEffect and gemData.grantedEffect.id == term then return gemData end
  end
  return nil
end

-- Always mutate through the active skill set. Returns (skillSet, err).
local function activeSkillSet()
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  local id = build.skillsTab.activeSkillSetId or 1
  local set = build.skillsTab.skillSets and build.skillsTab.skillSets[id]
  if not set then return nil, 'active skill set not found' end
  return set
end

-- Dump the global PoE 2 gem catalog (all gems known to PoB2's bundled
-- Data/Gems.lua), NOT the current build's socketed gems. This is the
-- authoritative gem database for the TS side: PoB2 already parses Gems.lua
-- natively, so reading it back through IPC guarantees the gem identifiers
-- (gemId / gameId / variantId / grantedEffectId / name) match exactly what
-- add_gem / calc_with_gems / findGemByIdentifier resolve against. Mirrors
-- the DEC-14 tree-data principle (use PoB2's own parsed data, no duplicate,
-- no second parser). Compact per-gem record; per-level stat progression is
-- deliberately omitted (catalog/validation/autocomplete use case — a
-- consumer that needs level scaling should query the build via calc).
--
-- Precondition: a build must be loaded so build.data is populated
-- (build.data is static game data — even an empty new_build satisfies it),
-- same precondition as get_jewel_sockets / get_skills.
function M.list_gems()
  if not build or not build.data or not build.data.gems then
    return nil, 'build/game-data not initialized'
  end

  local result = {}
  for key, gemData in pairs(build.data.gems) do
    -- Support-gem detection: PoB2 marks them three ways (mirror get_skills).
    local isSupport = false
    if gemData.gemType == "Support" then isSupport = true
    elseif gemData.tags and gemData.tags.support then isSupport = true
    elseif gemData.grantedEffect and gemData.grantedEffect.support then isSupport = true
    end

    local tags = {}
    if gemData.tags then
      for k, v in pairs(gemData.tags) do
        if v == true then tags[k] = true end
      end
    end

    table.insert(result, {
      -- Canonical key (the pairs() key == gemId in data.gems).
      gemId           = key,
      name            = gemData.name,
      gameId          = gemData.gameId,
      variantId       = gemData.variantId,
      grantedEffectId = gemData.grantedEffectId
                          or (gemData.grantedEffect and gemData.grantedEffect.id),
      baseTypeName    = gemData.baseTypeName,
      gemType         = gemData.gemType,
      gemFamily       = gemData.gemFamily,
      isSupport       = isSupport,
      tagString       = gemData.tagString,
      tags            = tags,
      reqStr          = gemData.reqStr,
      reqDex          = gemData.reqDex,
      reqInt          = gemData.reqInt,
      tier            = gemData.Tier,
      naturalMaxLevel = gemData.naturalMaxLevel,
    })
  end

  return result
end

-- Enumerate the current build's skill gem panel. Uses the active skill set
-- (build.skillsTab.skillSets[activeSkillSetId].socketGroupList). Drops
-- PoB1's socket-color / socket-group-count serialization — PoE 2 gem panel
-- has neither concept.
function M.get_skills()
  if not build or not build.skillsTab or not build.calcsTab then
    return nil, 'skills not initialized'
  end
  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local socketGroupList = skillSet.socketGroupList or build.skillsTab.socketGroupList or {}

  local groups = {}
  for idx, g in ipairs(socketGroupList) do
    local names = {}
    if g.displaySkillList then
      for _, eff in ipairs(g.displaySkillList) do
        if eff and eff.activeEffect and eff.activeEffect.grantedEffect then
          table.insert(names, eff.activeEffect.grantedEffect.name)
        end
      end
    end

    local gemList = {}
    if g.gemList then
      for gemIdx, gem in ipairs(g.gemList) do
        if gem then
          -- Support-gem detection: PoB2 marks them three ways — surface any
          -- of them being true as isSupport.
          local isSupport = false
          if gem.gemData then
            if gem.gemData.gemType == "Support" then isSupport = true
            elseif gem.gemData.tags and gem.gemData.tags.support then isSupport = true
            elseif gem.gemData.grantedEffect and gem.gemData.grantedEffect.support then isSupport = true
            end
          end

          local gemTags = {}
          local skillType
          local tagString
          local gemType
          local weaponRequirements
          local gemFamily
          local tier
          local naturalMaxLevel
          if gem.gemData then
            local tags = gem.gemData.tags or {}
            tagString          = gem.gemData.tagString
            gemType            = gem.gemData.gemType
            weaponRequirements = gem.gemData.weaponRequirements
            gemFamily          = gem.gemData.gemFamily
            tier               = gem.gemData.Tier
            naturalMaxLevel    = gem.gemData.naturalMaxLevel
            for k, v in pairs(tags) do
              if v == true then gemTags[k] = true end
            end
            skillType = classifySkillType(tags)
          end

          table.insert(gemList, {
            index              = gemIdx,
            nameSpec           = gem.nameSpec,
            gemId              = gem.gemId,
            skillId            = gem.skillId,
            variantId          = gem.variantId,
            level              = gem.level,
            quality            = gem.quality,
            qualityId          = gem.qualityId,
            enabled            = gem.enabled ~= false,
            enableGlobal1      = gem.enableGlobal1,
            enableGlobal2      = gem.enableGlobal2,
            count              = gem.count,
            isSupport          = isSupport,
            skillType          = skillType,
            gemType            = gemType,            -- PoB2 NEW
            tier               = tier,               -- PoB2 NEW
            naturalMaxLevel    = naturalMaxLevel,    -- PoB2 NEW
            weaponRequirements = weaponRequirements, -- PoB2 NEW
            gemFamily          = gemFamily,          -- PoB2 NEW (support-gem grouping)
            tags               = gemTags,
            tagString          = tagString,
            reqStr             = gem.reqStr and gem.reqStr > 0 and gem.reqStr or nil,
            reqDex             = gem.reqDex and gem.reqDex > 0 and gem.reqDex or nil,
            reqInt             = gem.reqInt and gem.reqInt > 0 and gem.reqInt or nil,
            reqLevel           = gem.reqLevel,
            skillPart          = gem.skillPart,
            skillMinion        = gem.skillMinion,
            skillMinionSkill   = gem.skillMinionSkill,
          })
        end
      end
    end

    table.insert(groups, {
      index            = idx,
      label            = g.label,
      slot             = g.slot,      -- UI-affinity in PoB2, not a real socket
      source           = g.source,
      enabled          = g.enabled,
      includeInFullDPS = g.includeInFullDPS,
      groupCount       = g.groupCount,
      mainActiveSkill  = g.mainActiveSkill,
      skills           = names,
      gemList          = gemList,
    })
  end

  return {
    mainSocketGroup  = build.mainSocketGroup,
    activeSkillSetId = build.skillsTab.activeSkillSetId,
    calcsSkillNumber = build.calcsTab.input and build.calcsTab.input.skill_number or nil,
    groups           = groups,
  }
end

-- set_main_selection: pick the main socket group / main active skill / skill
-- part. `skillPart` mutates the source gem instance's `skillPart` field
-- (used by multi-part skills like vaal variants).
function M.set_main_selection(params)
  if not build or not build.skillsTab or not build.calcsTab then
    return nil, 'skills not initialized'
  end
  if type(params) ~= 'table' then return nil, 'invalid params' end

  if params.mainSocketGroup ~= nil then
    build.mainSocketGroup = tonumber(params.mainSocketGroup) or build.mainSocketGroup
  end
  local set, err = activeSkillSet()
  if not set then return nil, err end
  local groupList = set.socketGroupList or build.skillsTab.socketGroupList or {}
  local g = groupList[build.mainSocketGroup]
  if not g then return nil, 'invalid mainSocketGroup' end

  if params.mainActiveSkill ~= nil then
    g.mainActiveSkill = tonumber(params.mainActiveSkill) or g.mainActiveSkill
  end
  if params.skillPart ~= nil then
    local idx = g.mainActiveSkill or 1
    local src = g.displaySkillList and g.displaySkillList[idx]
                and g.displaySkillList[idx].activeEffect
                and g.displaySkillList[idx].activeEffect.srcInstance
    if src then src.skillPart = tonumber(params.skillPart) end
  end

  if build.calcsTab.input then
    build.calcsTab.input.skill_number = build.mainSocketGroup
  end
  M.get_main_output()
  return true
end

-- Internal: resolve + push gem identity onto an instance.
local function _assignGemIdentity(inst, gemData)
  if not gemData then return end
  inst.gemData  = gemData
  inst.gemId    = gemData.id
  inst.nameSpec = gemData.name or inst.nameSpec
  inst.skillId  = (gemData.grantedEffect and gemData.grantedEffect.id) or gemData.grantedEffectId
  if gemData.variantId then inst.variantId = gemData.variantId end
end

-- create_socket_group: create an empty socket group in the active skill set.
-- A fresh PoB2 new_build has ZERO socket groups (PoB1 seeded one — PoB2's
-- NewSkillSet doesn't). Callers need to seed a group before any add_gem
-- call. The data shape matches PoB2's Load path (SkillsTab.lua:272-281).
function M.create_socket_group(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then params = {} end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end

  local socketGroup = {
    label                 = params.label or '',
    slot                  = params.slot,
    source                = nil,
    enabled               = params.enabled ~= false,
    includeInFullDPS      = params.includeInFullDPS == true,
    groupCount            = tonumber(params.groupCount) or 1,
    mainActiveSkill       = 1,
    mainActiveSkillCalcs  = 1,
    gemList               = {},
  }

  skillSet.socketGroupList = skillSet.socketGroupList or {}
  table.insert(skillSet.socketGroupList, socketGroup)
  local index = #skillSet.socketGroupList

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return { index = index, label = socketGroup.label }
end

-- add_gem: append a gem to an existing socket group. PoE 2 accepts a name
-- ("Fire Attunement"), a gemId ("Metadata/Items/Gems/..."), a skillId
-- ("SupportAddedFireDamagePlayer"), or a variantId ("AddedFireDamageSupport")
-- — all routed through findGemByIdentifier.
function M.add_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil or not params.gemName then
    return nil, 'missing groupIndex or gemName'
  end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then
    return nil, 'socket group not found at index ' .. tostring(groupIndex)
  end

  local gemData = findGemByIdentifier(params.gemName)
  if not gemData then
    return nil, "gem '" .. tostring(params.gemName) .. "' not found in gem database"
  end

  local inst = {
    nameSpec      = gemData.name,
    level         = tonumber(params.level)   or defaultGemLevel(gemData),
    quality       = tonumber(params.quality) or 0,
    qualityId     = params.qualityId or 'Default',
    enabled       = params.enabled ~= false,
    enableGlobal1 = true,
    enableGlobal2 = true,
    count         = tonumber(params.count) or 1,
  }
  _assignGemIdentity(inst, gemData)

  socketGroup.gemList = socketGroup.gemList or {}
  table.insert(socketGroup.gemList, inst)
  local gemIndex = #socketGroup.gemList

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()

  return {
    groupIndex = groupIndex,
    gemIndex   = gemIndex,
    name       = inst.nameSpec,
    gemId      = inst.gemId,
    skillId    = inst.skillId,
  }
end

-- remove_gem: drop a gem by index. Socket group is reprocessed so downstream
-- calcs drop the removed gem's granted effects.
function M.remove_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil or params.gemIndex == nil then
    return nil, 'missing groupIndex or gemIndex'
  end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local socketGroup = skillSet.socketGroupList[tonumber(params.groupIndex)]
  if not socketGroup or not socketGroup.gemList then return nil, 'socket group not found' end

  local gemIndex = tonumber(params.gemIndex)
  local gem = socketGroup.gemList[gemIndex]
  if not gem then return nil, 'gem not found at index ' .. tostring(gemIndex) end

  table.remove(socketGroup.gemList, gemIndex)

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return true
end

-- remove_skill: drop an entire socket group. Source-backed groups
-- (`socketGroup.source` — item-granted / node-granted skills) cannot be
-- removed through the API; the game data owns them.
function M.remove_skill(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil then return nil, 'missing groupIndex' end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end
  if socketGroup.source then
    return nil, 'cannot remove source-backed socket groups (item/node granted skills)'
  end

  table.remove(skillSet.socketGroupList, groupIndex)
  build.buildFlag = true
  M.get_main_output()
  return true
end

-- set_gem_level: clamp to 1-40 (highest seen in PoE 2 data is naturalMaxLevel
-- + awakened levels, capped at 40 for defensive input).
function M.set_gem_level(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil or params.gemIndex == nil or params.level == nil then
    return nil, 'missing groupIndex, gemIndex, or level'
  end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local socketGroup = skillSet.socketGroupList[tonumber(params.groupIndex)]
  if not socketGroup then return nil, 'socket group not found' end
  local gem = socketGroup.gemList and socketGroup.gemList[tonumber(params.gemIndex)]
  if not gem then return nil, 'gem not found' end

  local level = tonumber(params.level)
  if not level or level < 1 or level > 40 then
    return nil, 'invalid level (must be 1-40)'
  end
  gem.level = level

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return true
end

-- set_gem_quality: PoB2 keeps the 0-23 quality range + alternate-quality
-- variants (Default/Anomalous/Divergent/Phantasmal).
function M.set_gem_quality(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil or params.gemIndex == nil or params.quality == nil then
    return nil, 'missing groupIndex, gemIndex, or quality'
  end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local socketGroup = skillSet.socketGroupList[tonumber(params.groupIndex)]
  if not socketGroup then return nil, 'socket group not found' end
  local gem = socketGroup.gemList and socketGroup.gemList[tonumber(params.gemIndex)]
  if not gem then return nil, 'gem not found' end

  local quality = tonumber(params.quality)
  if not quality or quality < 0 or quality > 23 then
    return nil, 'invalid quality (must be 0-23)'
  end
  gem.quality = quality
  if params.qualityId then gem.qualityId = tostring(params.qualityId) end

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return true
end

-- set_gem_enabled: toggle per-gem enable state. Used to compare with/without
-- a support gem's contribution without deleting it.
function M.set_gem_enabled(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.groupIndex == nil or params.gemIndex == nil or params.enabled == nil then
    return nil, 'missing groupIndex, gemIndex, or enabled'
  end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local socketGroup = skillSet.socketGroupList[tonumber(params.groupIndex)]
  if not socketGroup then return nil, 'socket group not found' end
  local gem = socketGroup.gemList and socketGroup.gemList[tonumber(params.gemIndex)]
  if not gem then return nil, 'gem not found' end

  gem.enabled = params.enabled == true
  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end
  build.buildFlag = true
  M.get_main_output()
  return {
    groupIndex = tonumber(params.groupIndex),
    gemIndex   = tonumber(params.gemIndex),
    gemName    = gem.nameSpec,
    enabled    = gem.enabled,
  }
end

-- ============================================================================
-- calc_with_gems — calc tier, gem edition
-- ============================================================================
--
-- Snapshot every gemList in the active skill set, apply mutations, rebuild
-- output, snapshot result, then restore. Unlike calc_with (which threads
-- changes through a calc override), gem mutations require the full
-- ProcessSocketGroup → BuildOutput pipeline — they don't go through
-- GetMiscCalculator's addNodes/removeNodes/conditions override path.
--
-- Supported params:
--   addGems      : [{ groupIndex, gem = { skillId, level?, quality?, qualityId? }}]
--   replaceGems  : [{ groupIndex, gemIndex, gem = { skillId, level?, quality?, qualityId? }}]
--   conditions   : string[]   — threaded through calcFunc override on both passes
--   useFullDPS   : boolean    — default unset (inherits PoB2's FullDPS toggle)
--
-- Removals are deliberately out of scope: they break gemIndex-based restore.
-- If a caller needs to measure "without gem X" use set_gem_enabled=false.

function M.calc_with_gems(params)
  if not build or not build.skillsTab or not build.calcsTab then
    return nil, 'build not initialized'
  end

  local skillSet, err = activeSkillSet()
  if not skillSet then return nil, err end
  local socketGroupList = skillSet.socketGroupList or {}

  -- 1. Snapshot gem state. DO NOT deepCopySafe — that strips gemData
  --    (userdata-like table with metatable back-refs). Preserve references.
  local originalState = {}
  for groupIdx, group in ipairs(socketGroupList) do
    if group.gemList then
      originalState[groupIdx] = { _originalLength = #group.gemList }
      for gemIdx, gem in ipairs(group.gemList) do
        originalState[groupIdx][gemIdx] = {
          nameSpec      = gem.nameSpec,
          gemId         = gem.gemId,
          skillId       = gem.skillId,
          variantId     = gem.variantId,
          gemData       = gem.gemData,
          level         = gem.level,
          quality       = gem.quality,
          qualityId     = gem.qualityId,
          enabled       = gem.enabled,
          enableGlobal1 = gem.enableGlobal1,
          enableGlobal2 = gem.enableGlobal2,
          count         = gem.count,
        }
      end
    end
  end

  -- 2. Baseline BEFORE any mutations.
  local baseCalcFunc, baseOut = build.calcsTab:GetMiscCalculator()
  if type(baseCalcFunc) ~= 'function' then
    return nil, 'calculator not initialized (call BuildOutput first?)'
  end
  local condOverride = {}
  if params and type(params.conditions) == 'table' then
    condOverride.conditions = params.conditions
  end
  baseOut = baseCalcFunc(condOverride, params and params.useFullDPS)

  -- 3. Apply mutations.
  local modified = false
  local warnings = {}

  if params and type(params.replaceGems) == 'table' then
    for _, replace in ipairs(params.replaceGems) do
      local group = socketGroupList[tonumber(replace.groupIndex)]
      if not group or not group.gemList then
        table.insert(warnings, 'replaceGem: group ' .. tostring(replace.groupIndex) .. ' missing')
      elseif not group.gemList[tonumber(replace.gemIndex)] then
        table.insert(warnings, 'replaceGem: gemIndex ' .. tostring(replace.gemIndex) .. ' missing in group ' .. tostring(replace.groupIndex))
      elseif not replace.gem then
        table.insert(warnings, 'replaceGem: no gem spec')
      else
        local ident = replace.gem.skillId or replace.gem.gemId or replace.gem.name or replace.gem.gemName
        local gemData = findGemByIdentifier(ident)
        if not gemData then
          table.insert(warnings, "replaceGem: '" .. tostring(ident) .. "' not in gem database")
        else
          local gem = group.gemList[tonumber(replace.gemIndex)]
          _assignGemIdentity(gem, gemData)
          gem.level     = replace.gem.level     or defaultGemLevel(gemData)
          gem.quality   = replace.gem.quality   or 0
          gem.qualityId = replace.gem.qualityId or 'Default'
          modified = true
        end
      end
    end
  end

  if params and type(params.addGems) == 'table' then
    for _, add in ipairs(params.addGems) do
      local group = socketGroupList[tonumber(add.groupIndex)]
      if not group then
        table.insert(warnings, 'addGem: group ' .. tostring(add.groupIndex) .. ' missing')
      elseif not add.gem then
        table.insert(warnings, 'addGem: no gem spec')
      else
        local ident = add.gem.skillId or add.gem.gemId or add.gem.name or add.gem.gemName
        local gemData = findGemByIdentifier(ident)
        if not gemData then
          table.insert(warnings, "addGem: '" .. tostring(ident) .. "' not in gem database")
        else
          group.gemList = group.gemList or {}
          local inst = {
            level         = add.gem.level     or defaultGemLevel(gemData),
            quality       = add.gem.quality   or 0,
            qualityId     = add.gem.qualityId or 'Default',
            enabled       = true,
            enableGlobal1 = true,
            enableGlobal2 = true,
            count         = 1,
          }
          _assignGemIdentity(inst, gemData)
          table.insert(group.gemList, inst)
          modified = true
        end
      end
    end
  end

  -- 4. Recompute if anything changed.
  local out
  if modified then
    for _, group in ipairs(socketGroupList) do
      if build.skillsTab.ProcessSocketGroup then
        build.skillsTab:ProcessSocketGroup(group)
      end
    end
    build.calcsTab:BuildOutput()
    local modCalcFunc = build.calcsTab:GetMiscCalculator()
    out = modCalcFunc(condOverride, params and params.useFullDPS)
  else
    out = baseOut
  end

  -- 5. Restore gem state.
  for groupIdx, groupState in pairs(originalState) do
    local group = socketGroupList[groupIdx]
    if group and group.gemList then
      for gemIdx, gemState in pairs(groupState) do
        if type(gemIdx) == 'number' then
          local gem = group.gemList[gemIdx]
          if gem then
            gem.nameSpec      = gemState.nameSpec
            gem.gemId         = gemState.gemId
            gem.skillId       = gemState.skillId
            gem.variantId     = gemState.variantId
            gem.gemData       = gemState.gemData
            gem.level         = gemState.level
            gem.quality       = gemState.quality
            gem.qualityId     = gemState.qualityId
            gem.enabled       = gemState.enabled
            gem.enableGlobal1 = gemState.enableGlobal1
            gem.enableGlobal2 = gemState.enableGlobal2
            gem.count         = gemState.count
          end
        end
      end
      local origLen = groupState._originalLength or 0
      while #group.gemList > origLen do table.remove(group.gemList) end
    end
  end

  if modified then
    for _, group in ipairs(socketGroupList) do
      if build.skillsTab.ProcessSocketGroup then
        build.skillsTab:ProcessSocketGroup(group)
      end
    end
    build.calcsTab:BuildOutput()
  end

  local bDPS = (baseOut and baseOut.CombinedDPS) or 0
  local aDPS = (out     and out.CombinedDPS)     or 0
  io.stderr:write(string.format(
    "[calc_with_gems] CombinedDPS %.1f -> %.1f (delta=%.1f)%s\n",
    bDPS, aDPS, aDPS - bDPS,
    (#warnings > 0) and (" | warnings=" .. #warnings) or ""))

  return {
    output     = deepCopySafe(out),
    baseOutput = deepCopySafe(baseOut),
    warnings   = warnings,
  }
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

-- ============================================================================
-- Jewel tier
-- ============================================================================
--
-- PoB2 deltas from PoB1 that shape this tier:
--
--   * Cluster jewels don't exist (POB2-7). All cluster-specific machinery from
--     PoE 1's jewel tier is dropped: _fixClusterJewelValid, BuildClusterJewelGraphs,
--     autoAllocateNotables BFS into subgraphs, subgraph socket discovery,
--     clusterSocketSize / acceptsClusterJewel / isSubgraphSocket metadata, and
--     the set_cluster_chain handler entirely. `node.expansionJewel` still exists
--     on the base tree for forward compat but doesn't produce subgraphs.
--   * The socket / jewel infra (itemsTab.sockets[nodeId], spec.jewels[nodeId],
--     socketCtrl:SetSelItemId, itemsTab:PopulateSlots) is unchanged from PoB1 —
--     verified via calc_with_jewel which round-trips cleanly.
--   * Socket auto-allocation uses the direct `spec.allocNodes[nodeId] = node`
--     pattern proven out in calc_with_jewel — sidesteps POB2-9's 9-arg
--     ImportFromNodeList ceremony for this narrow case.

-- Enumerate jewel sockets on the current tree. Returns one entry per socket
-- with allocation state and (if equipped) the jewel in it.
function M.get_jewel_sockets()
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if not build.itemsTab         then return nil, 'items not initialized' end

  local spec = build.spec
  local itemsTab = build.itemsTab
  local result = {}

  -- itemsTab.sockets is keyed by nodeId. In PoB1 it can retain stale entries
  -- from destroyed cluster subgraphs; in PoB2 that class of stale key doesn't
  -- arise (no subgraphs), but we still gate on spec.nodes[nodeId] for safety.
  for nodeId, socketCtrl in pairs(itemsTab.sockets) do
    local node = spec.nodes[nodeId]
    if node then
      local equippedJewelId = spec.jewels[nodeId] or 0
      local equippedJewel = nil
      if equippedJewelId > 0 then
        local item = itemsTab.items[equippedJewelId]
        if item then
          equippedJewel = {
            id       = equippedJewelId,
            name     = item.name,
            baseName = item.baseName,
            type     = item.type,
            rarity   = item.rarity,
            raw      = item.raw,
          }
        end
      end

      table.insert(result, {
        nodeId          = nodeId,
        slotName        = socketCtrl.slotName,
        isAllocated     = spec.allocNodes[nodeId] ~= nil,
        equippedJewelId = equippedJewelId,
        equippedJewel   = equippedJewel,
        x               = node.x,
        y               = node.y,
      })
    end
  end

  table.sort(result, function(a, b) return a.nodeId < b.nodeId end)
  return result
end

-- Equip a jewel into a tree socket. Persistent counterpart of calc_with_jewel.
-- params: { nodeId: number, text: string } OR { nodeId: number, itemId: number },
-- plus optional { autoAllocateSocketPath: bool } to path from class start to the
-- socket when it isn't already allocated.
--
-- Non-cluster only: PoE 2 has no cluster jewels (POB2-7), so all cluster-subgraph
-- handling (autoAllocateNotables, _fixClusterJewelValid, BuildClusterJewelGraphs)
-- from the PoE 1 port is intentionally absent here.
function M.set_jewel(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if not build.itemsTab         then return nil, 'items not initialized' end
  if type(params) ~= 'table'    then return nil, 'invalid params' end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then return nil, 'missing or invalid nodeId' end

  local spec = build.spec
  local itemsTab = build.itemsTab
  local socketCtrl = itemsTab.sockets[nodeId]
  if not socketCtrl then
    return nil, 'nodeId ' .. tostring(nodeId) .. ' is not a jewel socket'
  end

  -- Auto-allocate the socket (+ optional path to it) when it isn't allocated.
  -- Uses the direct spec.allocNodes[] mutation pattern proven out in
  -- calc_with_jewel — skips the 9-arg ImportFromNodeList ceremony (POB2-9)
  -- for this narrow case where we're only adding to the allocation set.
  local allocatedPathIds = nil
  if not spec.allocNodes[nodeId] then
    allocatedPathIds = {}
    if params.autoAllocateSocketPath then
      local pathResult, pathErr = M.find_path({ targetNodeId = nodeId })
      if not pathResult then
        return nil, 'failed to path to socket ' .. tostring(nodeId) .. ': ' .. tostring(pathErr)
      end
      for _, pn in ipairs(pathResult.path or {}) do
        local pid = tonumber(pn.id)
        if pid then
          local node = spec.nodes[pid]
          if node and not spec.allocNodes[pid] then
            node.alloc = true
            spec.allocNodes[pid] = node
            table.insert(allocatedPathIds, pid)
          end
        end
      end
    end
    -- Always allocate the socket itself.
    local socketNode = spec.nodes[nodeId]
    if socketNode and not spec.allocNodes[nodeId] then
      socketNode.alloc = true
      spec.allocNodes[nodeId] = socketNode
      table.insert(allocatedPathIds, nodeId)
    end
  end

  -- Resolve item: either parse from text, or look up an existing itemId.
  local itemId, item
  if params.text then
    if #params.text == 0 then return nil, 'item text cannot be empty' end
    if #params.text > MAX_ITEM_TEXT_LENGTH then
      return nil, string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
    end
    local ok, parsed = pcall(new, 'Item', params.text)
    if not ok then return nil, 'invalid item text: ' .. tostring(parsed) end
    if not parsed or not parsed.baseName then return nil, 'failed to parse item' end
    if parsed.type ~= 'Jewel' then
      return nil, 'item is not a jewel (type: ' .. tostring(parsed.type) .. ')'
    end
    parsed:NormaliseQuality()
    itemsTab:AddItem(parsed, true) -- noAutoEquip = true; we equip manually
    itemId = parsed.id
    item = parsed
  elseif params.itemId then
    itemId = tonumber(params.itemId)
    if not itemId or not itemsTab.items[itemId] then
      return nil, 'invalid itemId or item not found'
    end
    item = itemsTab.items[itemId]
  else
    return nil, 'must provide either text or itemId'
  end

  -- Equip via the socket control — this writes both spec.jewels[nodeId] and
  -- the slot's selItemId atomically. PopulateSlots + buildFlag + get_main_output
  -- rebuild calcs with the jewel in place.
  local slotName = socketCtrl.slotName
  socketCtrl:SetSelItemId(itemId)
  itemsTab:PopulateSlots()
  itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()

  return {
    nodeId             = nodeId,
    slotName           = slotName,
    itemId             = itemId,
    name               = item and item.name or nil,
    baseName           = item and item.baseName or nil,
    allocatedPathNodes = allocatedPathIds, -- nil if socket was already allocated
  }
end

-- Remove a jewel from a tree socket. Leaves the socket node itself allocated
-- (callers who want to deallocate use update_tree_delta). Returns the
-- previously-equipped jewel id for audit.
function M.remove_jewel(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if not build.itemsTab         then return nil, 'items not initialized' end
  if type(params) ~= 'table'    then return nil, 'invalid params' end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then return nil, 'missing or invalid nodeId' end

  local spec = build.spec
  local itemsTab = build.itemsTab
  local socketCtrl = itemsTab.sockets[nodeId]
  if not socketCtrl then
    return nil, 'nodeId ' .. tostring(nodeId) .. ' is not a jewel socket'
  end

  local slotName = socketCtrl.slotName
  local previousJewelId = spec.jewels[nodeId] or 0

  -- SetSelItemId(0) clears both spec.jewels[nodeId] and slot.selItemId.
  socketCtrl:SetSelItemId(0)
  itemsTab:PopulateSlots()
  itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()

  return {
    nodeId          = nodeId,
    slotName        = slotName,
    previousJewelId = previousJewelId,
  }
end

-- ============================================================================
-- Tree / items misc tier
-- ============================================================================

-- Debug helper: inspect the live passive node state PoB is using for a specific
-- node. Useful when the LLM's mental model of a node disagrees with what the
-- calc engine sees (e.g. "why isn't this notable contributing?"). Dumps spec /
-- allocNode / treeNode state alongside any jewels whose radius covers the node.
function M.get_tree_node_debug(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table'    then return nil, 'invalid params' end
  local nodeId = tonumber(params.nodeId)
  if not nodeId then return nil, 'missing or invalid nodeId' end

  local spec = build.spec
  local function summarize(node)
    if not node then return nil end
    local stats = {}
    if type(node.sd) == 'table' then
      for _, s in ipairs(node.sd) do
        if type(s) == 'string' then table.insert(stats, s) end
      end
    end
    return {
      id                = node.id,
      dn                = node.dn,
      name              = node.name,
      icon              = node.icon,
      activeEffectImage = node.activeEffectImage,
      type              = node.type,
      alloc             = node.alloc == true,
      isKeystone        = node.isKeystone == true,
      isNotable         = node.isNotable == true,
      stats             = stats,
      reminderText      = node.reminderText,
      allocMode         = node.allocMode,        -- POB2-6
      unlockConstraint  = node.unlockConstraint, -- POB2-11
      -- `conqueredBy` from PoE 1 intentionally not surfaced — PoE 2 has no
      -- Timeless Jewel / Legion conqueror system.
    }
  end

  local influencingJewels = {}
  for socketNodeId, itemId in pairs(spec.jewels or {}) do
    local item = build.itemsTab and build.itemsTab.items and build.itemsTab.items[itemId] or nil
    local socketNode = spec.nodes[socketNodeId]
    local radiusIndex = item and item.jewelRadiusIndex or nil
    local inRadius = false
    if socketNode and socketNode.nodesInRadius and radiusIndex and socketNode.nodesInRadius[radiusIndex] then
      inRadius = socketNode.nodesInRadius[radiusIndex][nodeId] ~= nil
    end
    if inRadius or socketNodeId == nodeId then
      table.insert(influencingJewels, {
        socketNodeId = socketNodeId,
        itemId       = itemId,
        name         = item and item.name or nil,
        baseName     = item and item.baseName or nil,
        radiusIndex  = radiusIndex,
      })
    end
  end

  return {
    nodeId            = nodeId,
    specNode          = summarize(spec.nodes and spec.nodes[nodeId] or nil),
    allocNode         = summarize(spec.allocNodes and spec.allocNodes[nodeId] or nil),
    treeNode          = summarize(spec.tree and spec.tree.nodes and spec.tree.nodes[nodeId] or nil),
    influencingJewels = influencingJewels,
  }
end

-- Aggregated stat contributions from the allocated passive tree. Uses modDB
-- source filtering to pull only tree-sourced mods (gear/gems/jewels excluded).
-- Stat list kept deliberately narrow — these are the stats most callers care
-- about when answering "what did the tree give me?".
function M.get_tree_stats()
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  if build.calcsTab.BuildOutput then build.calcsTab:BuildOutput() end
  local modDB = build.calcsTab.mainEnv and build.calcsTab.mainEnv.modDB
  if not modDB then return nil, 'modDB unavailable' end
  local cfg = { source = "Tree" }

  return {
    -- EHP contributors
    lifeInc           = modDB:Sum("INC",  cfg, "Life") or 0,
    esInc             = modDB:Sum("INC",  cfg, "EnergyShield") or 0,
    armourInc         = modDB:Sum("INC",  cfg, "Armour", "ArmourAndEvasion", "Defences") or 0,
    evasionInc        = modDB:Sum("INC",  cfg, "Evasion", "ArmourAndEvasion", "Defences") or 0,
    blockBase         = modDB:Sum("BASE", cfg, "BlockChance") or 0,
    spellSuppressBase = modDB:Sum("BASE", cfg, "SpellSuppressionChance") or 0,
    -- Attributes
    strBase = modDB:Sum("BASE", cfg, "Str") or 0,
    dexBase = modDB:Sum("BASE", cfg, "Dex") or 0,
    intBase = modDB:Sum("BASE", cfg, "Int") or 0,
    -- DPS contributors
    damageInc      = modDB:Sum("INC",  cfg, "Damage") or 0,
    critChanceInc  = modDB:Sum("INC",  cfg, "CritChance") or 0,
    critMultiBase  = modDB:Sum("BASE", cfg, "CritMultiplier") or 0,
    dotMultiBase   = modDB:Sum("BASE", cfg, "DotMultiplier") or 0,
    attackSpeedInc = modDB:Sum("INC",  cfg, "Speed", "AttackSpeed") or 0,
    castSpeedInc   = modDB:Sum("INC",  cfg, "Speed", "CastSpeed") or 0,
  }
end

-- For every allocated Mastery node, report the currently-selected effect +
-- the alternatives the caller could swap to. Mastery data in PoB2 uses the
-- same `node.masteryEffects` array and `spec.masterySelections` table as
-- PoB1 — ports unchanged (POB2-11 notes).
function M.get_mastery_alternatives()
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  local result = {}
  local masterySelections = build.spec.masterySelections or {}
  local masteryEffectsRef = build.spec.tree and build.spec.tree.masteryEffects or {}

  for nodeId, node in pairs(build.spec.allocNodes or {}) do
    if node.type == "Mastery" and node.masteryEffects then
      local currentEffectId = masterySelections[nodeId]
      local entry = {
        nodeId          = nodeId,
        name            = node.name or ("Mastery " .. tostring(nodeId)),
        currentEffectId = currentEffectId,
        currentStats    = {},
        alternatives    = {},
      }
      if currentEffectId and masteryEffectsRef[currentEffectId] then
        entry.currentStats = masteryEffectsRef[currentEffectId].sd or {}
      end
      for _, effect in ipairs(node.masteryEffects) do
        if effect.effect ~= currentEffectId then
          local resolved = masteryEffectsRef[effect.effect]
          table.insert(entry.alternatives, {
            effectId = effect.effect,
            stats    = resolved and resolved.sd or effect.stats or {},
          })
        end
      end
      if #entry.alternatives > 0 then
        result[tostring(nodeId)] = entry
      end
    end
  end
  return result
end

-- Per-attribute requirement breakdown: who's demanding Str/Dex/Int, how much,
-- and from where. Pulls from mainEnv.requirementsTableItems + .requirementsTableGems
-- (the authoritative source CalcPerform uses). Also surfaces the
-- IgnoreAttributeRequirements / OmniscienceRequirements flags (Supreme
-- Ostentation and Crystallised Omniscience analogs in PoB2).
function M.get_attribute_requirements()
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  local mainEnv = build.calcsTab.mainEnv
  if not mainEnv then return nil, 'calculations not available (run BuildOutput first)' end
  local mainOutput = build.calcsTab.mainOutput or {}

  local reqTable = {}
  if mainEnv.requirementsTableItems then
    for _, e in ipairs(mainEnv.requirementsTableItems) do table.insert(reqTable, e) end
  end
  if mainEnv.requirementsTableGems then
    for _, e in ipairs(mainEnv.requirementsTableGems) do table.insert(reqTable, e) end
  end
  if #reqTable == 0 and mainEnv.requirementsTable then
    reqTable = mainEnv.requirementsTable
  end

  local sources = { str = {}, dex = {}, int = {} }
  for _, req in ipairs(reqTable) do
    for _, attr in ipairs({"Str", "Dex", "Int"}) do
      local val = req[attr]
      if val and val > 0 then
        local entry = { requirement = val }
        if req.source == "Item" then
          entry.type = "item"
          entry.name = (req.sourceItem and req.sourceItem.name) or "Unknown Item"
          entry.slot = req.sourceSlot or "Unknown"
        elseif req.source == "Gem" then
          entry.type = "gem"
          entry.name = (req.sourceGem and req.sourceGem.nameSpec) or "Unknown Gem"
          entry.slot = "Gem"
        else
          entry.type = "unknown"
          entry.name = "Unknown"
          entry.slot = "Unknown"
        end
        table.insert(sources[attr:lower()], entry)
      end
    end
  end

  local modDB = mainEnv.modDB
  return {
    str = { current = mainOutput.Str or 0, required = mainOutput.ReqStr or 0, sources = sources.str },
    dex = { current = mainOutput.Dex or 0, required = mainOutput.ReqDex or 0, sources = sources.dex },
    int = { current = mainOutput.Int or 0, required = mainOutput.ReqInt or 0, sources = sources.int },
    ignoreAttrReq    = modDB and modDB:Flag(nil, "IgnoreAttributeRequirements") or nil,
    omniRequirements = modDB and modDB:Flag(nil, "OmniscienceRequirements") or nil,
  }
end

-- ============================================================================
-- Skill config tier
-- ============================================================================
--
-- set_skill_config / set_batch_skill_config are thin wrappers around
-- configTab.input[varName] = value. Used by backend code that wants to flip
-- individual skill-related config vars (multiplierPoisonOnEnemy,
-- multiplierImpalesOnEnemy, conditionShockEffect, etc.) without the big
-- set_config payload.

function M.set_skill_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table'           then return nil, 'invalid params' end
  if type(params.varName) ~= 'string' or params.varName == '' then
    return nil, 'missing or invalid varName'
  end
  if params.value == nil then return nil, 'missing value parameter' end

  local input = build.configTab.input or {}
  build.configTab.input = input
  input[params.varName] = params.value

  -- When value=0 for count-type configs, clear placeholder so BuildModList
  -- doesn't fall back to an auto-calculated value. Same guard as PoE 1.
  if params.value == 0 then
    local placeholder = build.configTab.configSets
      and build.configTab.configSets[build.configTab.activeConfigSetId]
      and build.configTab.configSets[build.configTab.activeConfigSetId].placeholder
    if placeholder then placeholder[params.varName] = nil end
  end

  if build.configTab.BuildModList then build.configTab:BuildModList() end
  build.buildFlag = true
  M.get_main_output()
  return { varName = params.varName, value = params.value }
end

function M.set_batch_skill_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table' or type(params.configs) ~= 'table' then
    return nil, 'invalid params: expected { configs: [...] }'
  end

  local input = build.configTab.input or {}
  build.configTab.input = input
  local placeholder = build.configTab.configSets
    and build.configTab.configSets[build.configTab.activeConfigSetId]
    and build.configTab.configSets[build.configTab.activeConfigSetId].placeholder

  local applied = {}
  for _, entry in ipairs(params.configs) do
    if type(entry.varName) == 'string' and entry.varName ~= '' and entry.value ~= nil then
      input[entry.varName] = entry.value
      if entry.value == 0 and placeholder then placeholder[entry.varName] = nil end
      table.insert(applied, { varName = entry.varName, value = entry.value })
    end
  end

  if #applied > 0 then
    if build.configTab.BuildModList then build.configTab:BuildModList() end
    build.buildFlag = true
    M.get_main_output()
  end
  return { applied = applied, count = #applied }
end

-- ============================================================================
-- Minion tier
-- ============================================================================
--
-- PoB2 `build.spectreList` (Build.lua:44) and `data.minions` / `data.spectres`
-- (Data.lua:955-961) have the same structure as PoB1. Handler ports cleanly.
-- PoE 2 minion roster differs from PoE 1 — `data.minions` is populated from
-- PoE 2's `Data/Spectres.lua`, so validation automatically matches the PoE 2
-- catalog. Ascendancy-specific adjustments (Infernalist demons etc.) rely on
-- the same spectreList path and drop in when backend minion-config is rewritten.

function M.set_minion_config(params)
  if not build then return nil, 'build not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end

  local appliedSpectres = {}
  local invalidSpectres = {}
  if type(params.spectreList) == 'table' then
    wipeTable(build.spectreList)
    for _, id in ipairs(params.spectreList) do
      if type(id) == 'string' and build.data and build.data.minions and build.data.minions[id] then
        table.insert(build.spectreList, id)
        table.insert(appliedSpectres, id)
      else
        table.insert(invalidSpectres, tostring(id))
      end
    end
  end

  -- Auto-enable includeInFullDPS on the best minion-carrying socket group so
  -- FullDPS reflects minion damage. Mirrors PoE 1 logic; skill-name matching
  -- adapted to PoE 2 minion-summoning gems (Summon * / Raise *). If the PoE 2
  -- roster grows (Druid's animal companions, Infernalist demons), extend
  -- minionSkillPatterns. Drops PoE 1-only patterns: "Animate Guardian",
  -- "Animate Weapon", "Dominating Blow", "Absolution", "Herald of Purity".
  local minionSkillPatterns = {
    "Raise Spectre", "Raise Zombie", "Summon Skelet", "^Summon ",
  }
  local minionGroupsEnabled = {}
  local enableFullDps = params.enableFullDpsOnMinionSkills
  if enableFullDps == nil then enableFullDps = true end

  if enableFullDps and build.skillsTab then
    local skillSetId = build.skillsTab.activeSkillSetId or 1
    local skillSet = build.skillsTab.skillSets and build.skillsTab.skillSets[skillSetId]
    local groups = (skillSet and skillSet.socketGroupList) or build.skillsTab.socketGroupList or {}

    -- Pick the highest-gem-count socket group per minion skill — enabling
    -- multiple groups that raise the same minion double-counts damage
    -- (player casts Raise Spectre once).
    local bestByName = {}
    for idx, sg in ipairs(groups) do
      if sg.enabled and sg.gemList then
        local matchedSkill
        for _, gem in ipairs(sg.gemList) do
          local name = gem.nameSpec or ''
          for _, pat in ipairs(minionSkillPatterns) do
            if name:match(pat) then matchedSkill = name; break end
          end
          if matchedSkill then break end
        end
        if matchedSkill then
          local gemCount = 0
          for _, g in ipairs(sg.gemList) do
            if g.enabled ~= false then gemCount = gemCount + 1 end
          end
          local prev = bestByName[matchedSkill]
          if not prev or gemCount > prev.gemCount then
            bestByName[matchedSkill] = { idx = idx, gemCount = gemCount, group = sg }
          end
        end
      end
    end

    for skillName, info in pairs(bestByName) do
      if not info.group.includeInFullDPS then
        info.group.includeInFullDPS = true
        if build.skillsTab.ProcessSocketGroup then
          build.skillsTab:ProcessSocketGroup(info.group)
        end
        table.insert(minionGroupsEnabled, { index = info.idx, skill = skillName })
      end
    end
  end

  build.buildFlag = true
  M.get_main_output()
  return {
    spectresApplied     = appliedSpectres,
    spectresInvalid     = invalidSpectres,
    minionGroupsEnabled = minionGroupsEnabled,
  }
end

function M.get_minion_config()
  if not build then return nil, 'build not initialized' end
  local spectreList = {}
  if build.spectreList then
    for _, id in ipairs(build.spectreList) do
      if type(id) == 'string' then table.insert(spectreList, id) end
    end
  end
  return { spectreList = spectreList }
end

-- ============================================================================
-- Flask tier — minimal PoE 2 rewrite
-- ============================================================================
--
-- PoE 1's get_flask_uptime_data was ~250 LOC of charge-generation + uptime math
-- tied to PoE 1's 5-slot flask system with per-slot recovery-rate mods and
-- utility-flask-active conditions. PoE 2 has only 2 flask slots + 3 charm
-- slots (POB2-10), a different charge/consume model, and no "life/mana flask
-- recovery rate" mod family.
--
-- This is a LEAN port: reports per-slot flask presence + duration + base data
-- + charges (max/used). Does NOT compute uptime / fill-time — if a caller
-- needs that, extend with PoE 2-specific math once the flask system is
-- formally spec'd. Good enough for "is there a flask in this slot and what is
-- it" queries.

function M.get_flask_uptime_data()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local itemsTab = build.itemsTab
  local result = {}

  -- Walk flask + charm slots together — both use the same selItemId / active
  -- pattern and callers benefit from a unified view.
  local slotNames = { "Flask 1", "Flask 2", "Charm 1", "Charm 2", "Charm 3" }
  for _, slotName in ipairs(slotNames) do
    local slotCtrl = itemsTab.slots[slotName]
    if slotCtrl and slotCtrl.selItemId and slotCtrl.selItemId > 0 then
      local item = itemsTab.items[slotCtrl.selItemId]
      if item and item.base and (item.base.flask or item.base.charm) then
        local entry = {
          slot     = slotName,
          itemId   = slotCtrl.selItemId,
          name     = item.name,
          baseName = item.baseName,
          rarity   = item.rarity,
          active   = itemsTab.activeItemSet and itemsTab.activeItemSet[slotName]
                       and itemsTab.activeItemSet[slotName].active or false,
          isFlask  = item.base.flask ~= nil,
          isCharm  = item.base.charm ~= nil,
        }
        if item.flaskData then
          entry.duration    = item.flaskData.duration
          entry.chargesMax  = item.flaskData.chargesMax
          entry.chargesUsed = item.flaskData.chargesUsed
          entry.lifeTotal   = item.flaskData.lifeTotal
          entry.manaTotal   = item.flaskData.manaTotal
        end
        table.insert(result, entry)
      end
    end
  end
  return result
end

-- ============================================================================
-- Config tier
-- ============================================================================
--
-- PoB2 deltas from PoB1 that shape this tier (POB2-14 in pob2-integration-notes):
--
--   * PoE 2 has no Bandit quest (`bandit` key gone) and no Pantheon system
--     (`pantheonMajorGod` / `pantheonMinorGod` gone). The whole PoE 1 act-1
--     reward subsystem is missing.
--   * PoE 2 renames `enemyPhysicalDamageReduction` → `enemyPhysicalReduction`.
--   * PoE 2 drops PoE 1-only buffs: `buffTailwind`, `buffConvergence`.
--   * PoE 2 adds new ailment / condition keys — this tier surfaces the ones
--     the backend needs: armour break, daze, pin, heavy stun, electrocute,
--     ailment consumption, sprint/dodge, charm usage, darkness.
--   * PoB2 configTab.input is a live reference to configSets[activeConfigSetId].input
--     after SetActiveConfigSet (ConfigTab.lua:997) — reading/writing either is equivalent.
--
-- Flasks: PoB2 has NUM_FLASK_SLOTS = 2 (vs PoE 1's 5) + 3 Charm slots. See
-- set_flask_active below for slot-name handling.

local NUM_FLASK_SLOTS = 2
local NUM_CHARM_SLOTS = 3

-- Minimal config snapshot for callers that only need the essentials.
function M.get_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local input = build.configTab.input or {}
  local cfg = {
    enemyLevel        = build.configTab.enemyLevel,
    resistancePenalty = input.resistancePenalty,
    customMods        = input.customMods or "",
  }
  return cfg
end

-- Comprehensive config snapshot mirroring the PoE 1 handler shape. Keys are
-- PoB2-verified — PoE 1-only keys (bandit, pantheon*, buffTailwind,
-- buffConvergence, enemyPhysicalDamageReduction) are dropped; PoE 2-only keys
-- (electrocute / armour break / daze / pin / heavy stun / ailment consumption
-- / sprint / charm / darkness) are added.
function M.get_full_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local input = build.configTab.input or {}
  local cfg = {
    -- Basic config. `enemyLevel` is the effective level in use (auto-derived
    -- from placeholder / character level when no explicit override is set).
    -- `enemyLevelOverride` surfaces the explicit override separately so callers
    -- can distinguish "user-set" from "auto-scaled".
    enemyLevel         = build.configTab.enemyLevel,
    enemyLevelOverride = input.enemyLevel,
    resistancePenalty  = input.resistancePenalty,

    -- Calc modes
    ailmentMode           = input.ailmentMode,
    cooldownMode          = input.cooldownMode,       -- NEW in PoE 2
    lifeRegenMode         = input.lifeRegenMode,
    resourceGainMode      = input.resourceGainMode,
    armourCalculationMode = input.armourCalculationMode,
    EHPUnluckyWorstOf     = input.EHPUnluckyWorstOf,

    -- Charges
    usePowerCharges         = input.usePowerCharges or false,
    useFrenzyCharges        = input.useFrenzyCharges or false,
    useEnduranceCharges     = input.useEnduranceCharges or false,
    overridePowerCharges    = input.overridePowerCharges,
    overrideFrenzyCharges   = input.overrideFrenzyCharges,
    overrideEnduranceCharges = input.overrideEnduranceCharges,

    -- Combat buffs (PoE 2 roster — buffTailwind / buffConvergence gone)
    buffOnslaught      = input.buffOnslaught or false,
    buffFortification  = input.buffFortification or false,
    overrideFortification = input.overrideFortification,
    buffAdrenaline     = input.buffAdrenaline or false,
    buffUnholyMight    = input.buffUnholyMight or false,
    buffPhasing        = input.buffPhasing or false,
    buffElusive        = input.buffElusive or false,
    buffArcaneSurge    = input.buffArcaneSurge or false,
    buffFanaticism     = input.buffFanaticism or false,
    buffDivinity       = input.buffDivinity or false,
    conditionUsingFlask = input.conditionUsingFlask or false,
    conditionUsingCharm = input.conditionUsingCharm or false, -- NEW in PoE 2

    -- Self conditions
    conditionLowLife             = input.conditionLowLife or false,
    conditionFullLife            = input.conditionFullLife or false,
    conditionLowMana             = input.conditionLowMana or false,
    conditionFullMana            = input.conditionFullMana or false,
    conditionLeeching            = input.conditionLeeching or false,
    conditionOnConsecratedGround = input.conditionOnConsecratedGround or false,
    conditionKilledRecently      = input.conditionKilledRecently or false,
    conditionHitRecently         = input.conditionHitRecently or false,
    conditionCritRecently        = input.conditionCritRecently or false,
    conditionBeenHitRecently     = input.conditionBeenHitRecently or false,
    conditionMoving              = input.conditionMoving or false,
    conditionSprinting           = input.conditionSprinting or false,           -- NEW in PoE 2
    conditionDodgeRolledRecently = input.conditionDodgeRolledRecently or false, -- NEW in PoE 2
    conditionInDodgeRoll         = input.conditionInDodgeRoll or false,         -- NEW in PoE 2

    -- PoE 2 ailment-consumption flags (driving POE 2's payoff / combo skills)
    conditionAilmentConsumed = input.conditionAilmentConsumed or false,
    conditionIgniteConsumed  = input.conditionIgniteConsumed or false,
    conditionFreezeConsumed  = input.conditionFreezeConsumed or false,
    conditionShockConsumed   = input.conditionShockConsumed or false,

    -- Darkness reservation (PoE 2 Chaos pool)
    reservedDarkness = input.reservedDarkness,

    -- Enemy basics
    enemyIsBoss = input.enemyIsBoss or "Pinnacle",

    -- Enemy ailments / conditions (full PoE 2 roster)
    conditionEnemyIntimidated      = input.conditionEnemyIntimidated or false,
    conditionEnemyUnnerved         = input.conditionEnemyUnnerved or false,
    conditionEnemyCoveredInAsh     = input.conditionEnemyCoveredInAsh or false,
    conditionEnemyCoveredInFrost   = input.conditionEnemyCoveredInFrost or false,
    conditionEnemyMaimed           = input.conditionEnemyMaimed or false,
    conditionEnemyBleeding         = input.conditionEnemyBleeding or false,
    conditionEnemyPoisoned         = input.conditionEnemyPoisoned or false,
    conditionEnemyIgnited          = input.conditionEnemyIgnited or false,
    conditionEnemyBurning          = input.conditionEnemyBurning or false,
    conditionEnemyHindered         = input.conditionEnemyHindered or false,
    conditionEnemyTaunted          = input.conditionEnemyTaunted or false,
    conditionEnemyDebilitated      = input.conditionEnemyDebilitated or false,
    conditionEnemyFireExposure     = input.conditionEnemyFireExposure or false,
    conditionEnemyColdExposure     = input.conditionEnemyColdExposure or false,
    conditionEnemyLightningExposure = input.conditionEnemyLightningExposure or false,
    conditionEnemyScorched         = input.conditionEnemyScorched or false,
    conditionEnemyBrittle          = input.conditionEnemyBrittle or false,
    conditionEnemySapped           = input.conditionEnemySapped or false,
    conditionEnemyChilled          = input.conditionEnemyChilled or false,
    conditionEnemyShocked          = input.conditionEnemyShocked or false,
    conditionEnemyCrushed          = input.conditionEnemyCrushed or false,
    conditionEnemyBlinded          = input.conditionEnemyBlinded or false,
    -- PoE 2-only enemy conditions
    conditionEnemyElectrocuted  = input.conditionEnemyElectrocuted or false,
    conditionEnemyArmourBroken  = input.conditionEnemyArmourBroken or false,
    conditionEnemyDazed         = input.conditionEnemyDazed or false,
    conditionEnemyHeavyStunned  = input.conditionEnemyHeavyStunned or false,
    conditionHitsAlwaysHeavyStun = input.conditionHitsAlwaysHeavyStun or false,
    conditionEnemyPinned        = input.conditionEnemyPinned or false,
    conditionEnemyImmobilised   = input.conditionEnemyImmobilised or false,

    -- Enemy stat overrides (NOTE: enemyPhysicalReduction, NOT
    -- enemyPhysicalDamageReduction — renamed in PoB2)
    enemyFireResist         = input.enemyFireResist,
    enemyColdResist         = input.enemyColdResist,
    enemyLightningResist    = input.enemyLightningResist,
    enemyChaosResist        = input.enemyChaosResist,
    enemyPhysicalReduction  = input.enemyPhysicalReduction,

    -- Numeric ailment / stack multipliers surfaced for set_skill_config
    multiplierWitheredStackCount = input.multiplierWitheredStackCount or 0,
    conditionShockEffect         = input.conditionShockEffect or 0,
    conditionEnemyChilledEffect  = input.conditionEnemyChilledEffect or 0,
    conditionScorchedEffect      = input.conditionScorchedEffect or 0,
    conditionBrittleEffect       = input.conditionBrittleEffect or 0,
    conditionSapEffect           = input.conditionSapEffect or 0,
    multiplierPoisonOnEnemy      = input.multiplierPoisonOnEnemy or 0,
    multiplierImpalesOnEnemy     = input.multiplierImpalesOnEnemy or 0,
    multiplierRuptureStacks      = input.multiplierRuptureStacks or 0,
    multiplierCorrosionStackCount = input.multiplierCorrosionStackCount or 0,
    multiplierArmourBreak        = input.multiplierArmourBreak or 0,       -- NEW in PoE 2

    -- Custom modifiers + curse override (A/B testing hook from PoE 1)
    customMods         = input.customMods or "",
    disabledCurses     = input.disabledCurses,
    overrideCurseLimit = input.overrideCurseLimit,
  }
  return cfg
end

-- Mutate selected config values and rebuild. Preserves the input-restoration
-- pattern from PoE 1: BuildModList can wipe vars that weren't touched by this
-- call, so we snapshot first and restore anything that got wiped but wasn't
-- explicitly overridden.
function M.set_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local input = build.configTab.input
  if not input then
    -- Fresh builds that bypassed SetActiveConfigSet — fall back to the active
    -- set's input table. This shouldn't happen in practice because new_build
    -- runs through ConfigTab:SetActiveConfigSet, but guard anyway.
    if build.configTab.configSets and build.configTab.activeConfigSetId then
      local cs = build.configTab.configSets[build.configTab.activeConfigSetId]
      input = cs and cs.input or nil
    end
    if not input then return nil, 'configTab.input unavailable' end
    build.configTab.input = input
  end
  local changed = false

  -- Basic config. NOTE: write to input.enemyLevel, NOT build.configTab.enemyLevel
  -- directly — BuildModList re-derives self.enemyLevel from input (ConfigTab.lua
  -- :856-862). Direct writes to configTab.enemyLevel get overwritten on the next
  -- BuildModList, which is exactly the rebuild we then trigger below.
  if params.enemyLevel ~= nil then
    input.enemyLevel = tonumber(params.enemyLevel) or input.enemyLevel
    changed = true
  end
  if params.resistancePenalty ~= nil then input.resistancePenalty = tonumber(params.resistancePenalty); changed = true end

  -- Calc modes (string enums)
  local stringEnums = {
    'ailmentMode', 'cooldownMode', 'lifeRegenMode', 'resourceGainMode',
    'armourCalculationMode', 'enemyIsBoss',
  }
  for _, k in ipairs(stringEnums) do
    if params[k] ~= nil then input[k] = tostring(params[k]); changed = true end
  end
  if params.EHPUnluckyWorstOf ~= nil then input.EHPUnluckyWorstOf = tonumber(params.EHPUnluckyWorstOf); changed = true end

  -- Boolean config keys — one list, driven by the full PoE 2 condition roster.
  local boolKeys = {
    -- Charges
    'usePowerCharges', 'useFrenzyCharges', 'useEnduranceCharges',
    -- Buffs
    'buffOnslaught', 'buffFortification', 'buffAdrenaline', 'buffUnholyMight',
    'buffPhasing', 'buffElusive', 'buffArcaneSurge', 'buffFanaticism', 'buffDivinity',
    'conditionUsingFlask', 'conditionUsingCharm',
    -- Self conditions
    'conditionLowLife', 'conditionFullLife', 'conditionLowMana', 'conditionFullMana',
    'conditionLeeching', 'conditionOnConsecratedGround', 'conditionKilledRecently',
    'conditionHitRecently', 'conditionCritRecently', 'conditionBeenHitRecently',
    'conditionMoving', 'conditionSprinting', 'conditionDodgeRolledRecently',
    'conditionInDodgeRoll',
    -- PoE 2 ailment-consumed
    'conditionAilmentConsumed', 'conditionIgniteConsumed', 'conditionFreezeConsumed',
    'conditionShockConsumed',
    -- Enemy conditions (shared PoE 1 + 2)
    'conditionEnemyIntimidated', 'conditionEnemyUnnerved', 'conditionEnemyCoveredInAsh',
    'conditionEnemyCoveredInFrost', 'conditionEnemyMaimed', 'conditionEnemyBleeding',
    'conditionEnemyPoisoned', 'conditionEnemyIgnited', 'conditionEnemyBurning',
    'conditionEnemyHindered', 'conditionEnemyTaunted', 'conditionEnemyDebilitated',
    'conditionEnemyFireExposure', 'conditionEnemyColdExposure', 'conditionEnemyLightningExposure',
    'conditionEnemyScorched', 'conditionEnemyBrittle', 'conditionEnemySapped',
    'conditionEnemyChilled', 'conditionEnemyShocked', 'conditionEnemyCrushed',
    'conditionEnemyBlinded',
    -- Enemy conditions (PoE 2-only)
    'conditionEnemyElectrocuted', 'conditionEnemyArmourBroken', 'conditionEnemyDazed',
    'conditionEnemyHeavyStunned', 'conditionHitsAlwaysHeavyStun', 'conditionEnemyPinned',
    'conditionEnemyImmobilised',
  }
  for _, k in ipairs(boolKeys) do
    if params[k] ~= nil then input[k] = params[k]; changed = true end
  end

  -- Numeric overrides (fall back to nil when missing so placeholders drive)
  local numericKeys = {
    'overridePowerCharges', 'overrideFrenzyCharges', 'overrideEnduranceCharges',
    'overrideFortification', 'reservedDarkness',
    'enemyFireResist', 'enemyColdResist', 'enemyLightningResist', 'enemyChaosResist',
    'enemyPhysicalReduction',
  }
  for _, k in ipairs(numericKeys) do
    if params[k] ~= nil then input[k] = tonumber(params[k]); changed = true end
  end

  -- Numeric-stack keys — when set to 0, clear the placeholder too (same
  -- rationale as PoE 1: BuildModList falls back to auto-calculated placeholder
  -- otherwise, so "0" wouldn't round-trip without this guard).
  local placeholder = build.configTab.configSets
    and build.configTab.configSets[build.configTab.activeConfigSetId]
    and build.configTab.configSets[build.configTab.activeConfigSetId].placeholder
  local function setNumericVar(varName, rawValue)
    local val = tonumber(rawValue)
    input[varName] = val
    if val == 0 and placeholder then placeholder[varName] = nil end
    changed = true
  end
  local numericStackKeys = {
    'multiplierWitheredStackCount', 'conditionShockEffect', 'conditionEnemyChilledEffect',
    'conditionScorchedEffect', 'conditionBrittleEffect', 'conditionSapEffect',
    'multiplierPoisonOnEnemy', 'multiplierImpalesOnEnemy', 'multiplierRuptureStacks',
    'multiplierCorrosionStackCount', 'multiplierArmourBreak',
  }
  for _, k in ipairs(numericStackKeys) do
    if params[k] ~= nil then setNumericVar(k, params[k]) end
  end

  -- Custom mods (freeform string)
  if params.customMods ~= nil then input.customMods = tostring(params.customMods); changed = true end

  -- Curse override hook (mirrors PoE 1 API; PoB2 curse modelling matches so far)
  if params.resetApiConfig then
    input.disabledCurses = nil
    input.overrideCurseLimit = nil
    changed = true
  end
  if params.disabledCurses ~= nil then
    if type(params.disabledCurses) == 'table' then
      input.disabledCurses = params.disabledCurses
    else
      input.disabledCurses = nil
    end
    changed = true
  end
  if params.overrideCurseLimit ~= nil then
    input.overrideCurseLimit = tonumber(params.overrideCurseLimit)
    changed = true
  end

  -- Snapshot → rebuild → restore pattern. BuildModList reconstructs the mod
  -- list from ConfigOptions and can reset vars that we set via the API but
  -- didn't explicitly pass this call. Restore only keys NOT in the current
  -- params (those we *did* pass are authoritative).
  local savedInput = {}
  for k, v in pairs(input) do savedInput[k] = v end

  if changed and build.configTab.BuildModList then build.configTab:BuildModList() end

  for k, v in pairs(savedInput) do
    if input[k] ~= v and params[k] == nil then
      input[k] = v
    end
  end

  build.buildFlag = true
  M.get_main_output()
  return true
end

-- Toggle a flask or charm slot on/off. PoE 2 flask slots are "Flask 1"/"Flask 2"
-- (NUM_FLASK_SLOTS=2) and charms are "Charm 1".."Charm 3" (POB2-10). Callers
-- pick the slot family via `slotType` ("flask" default, or "charm") + index,
-- or pass `slot` explicitly for full control.
function M.set_flask_active(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end

  local slotName
  if params.slot then
    slotName = tostring(params.slot)
  else
    local slotType = params.slotType and tostring(params.slotType):lower() or 'flask'
    local idx = tonumber(params.index)
    local maxIdx = slotType == 'charm' and NUM_CHARM_SLOTS or NUM_FLASK_SLOTS
    if not idx or idx < 1 or idx > maxIdx then
      return nil, string.format('invalid index (must be 1-%d for %s)', maxIdx, slotType)
    end
    slotName = (slotType == 'charm' and 'Charm ' or 'Flask ') .. tostring(idx)
  end

  local active = params.active == true
  if not build.itemsTab.activeItemSet or not build.itemsTab.activeItemSet[slotName] then
    return nil, 'slot not found: ' .. slotName
  end
  build.itemsTab.activeItemSet[slotName].active = active
  if build.itemsTab.slots[slotName] then
    build.itemsTab.slots[slotName].active = active
    if build.itemsTab.slots[slotName].controls and build.itemsTab.slots[slotName].controls.activate then
      build.itemsTab.slots[slotName].controls.activate.state = active
    end
  end
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return true
end

return M
