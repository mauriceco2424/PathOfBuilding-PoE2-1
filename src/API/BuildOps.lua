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

return M
