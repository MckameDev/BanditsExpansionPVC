--[[==========================================================================
    00_TacticalShared.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Capa COMPARTIDA: constantes, datos y utilidades que necesitan por igual el
    cliente (comportamiento/IA) y el servidor (spawn/mundo).

    ---------------------------------------------------------------------------
    POR QUE EXISTE (multijugador)
    ---------------------------------------------------------------------------
    Un servidor dedicado NO ejecuta media/lua/client/. Solo lo carga para
    comprobar el checksum. Por eso todo lo que deba funcionar en un dedicado
    tiene que vivir en shared/ (ambos lados) o en server/ (solo servidor).

    El reparto correcto, que es EXACTAMENTE el que usa el propio Bandits2:

      - SPAWN / MUNDO  -> server/  (BanditServerSpawner.lua del mod base:
                          checkEvent con "if isClient() then return end").
                          server/ se ejecuta en single player, en el servidor
                          interno del modo Anfitrion Y en un dedicado, asi que
                          con una sola implementacion cubrimos los tres modos.
      - IA / COMPORTAMIENTO -> client/  (BanditUpdate.lua del mod base esta en
                          client/ y ademas corta con "if isServer() then return
                          end" en la linea ~1925). La IA de bandidos corre solo
                          en los clientes, por diseno del mod base. Nuestros
                          modulos que anaden tareas (Bandit.AddTask), leen el
                          brain o muestran dialogos DEBEN quedarse en client/:
                          en el servidor no tendrian ningun bandido sobre el
                          que actuar.
      - DATOS COMPARTIDOS -> este archivo.

    El prefijo "00_" fuerza que cargue antes que el resto de shared/.
============================================================================]]

if PVCShared then return end -- guarda anti doble carga

PVCShared = {}
PVCShared.VERSION = "1.0.0"

PVCShared.MOD_ID = "BanditsExpansionPVC"

-- ---------------------------------------------------------------------------
-- IDENTIFICADORES (deben coincidir con common/bandits/clans.txt y bandits.txt)
-- ---------------------------------------------------------------------------
PVCShared.CLAN_ID       = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de001"  -- Team PVC
PVCShared.AMBUSH_CID    = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de002"  -- Salteadores de ruta

PVCShared.CAPTAIN_BID   = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"
PVCShared.EVARISTO_BID  = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"
PVCShared.CHISPA_BID    = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de107"

-- ---------------------------------------------------------------------------
-- CONFIGURACION DE SPAWN (la lee el planificador del servidor)
-- ---------------------------------------------------------------------------
PVCShared.Spawn = {
    -- Team PVC
    TeamPVCChance   = 1,     -- "1%", misma escala que el clan mas raro del mod base
    TeamPVCSize     = 6,
    DayStart        = 0,
    DayEnd          = 10000,
    NaturalMinDist  = 20,
    NaturalMaxDist  = 40,
    ChispaChance    = 20,    -- % de que venga el 7mo integrante

    -- Bloqueos de carretera
    RoadblockEnabled  = true,
    RoadblockChance   = 35,
    RoadblockMax      = 2,
    RoadblockMinDist  = 40,
    RoadblockMaxDist  = 90,
    RoadblockClearR   = 4,
    BurntCarChance    = 70,
    AmbushSize        = 4,
    AmbushTeamPVCPct  = 3,   -- % de que el peaje lo cobre el propio Team PVC
}

-- ---------------------------------------------------------------------------
-- PERFIL DE EL CHISPA
-- No esta en common/bandits/bandits.txt a proposito: si estuviera, el clan
-- tendria 7 candidatos permanentes y spawnGroup() elegiria 6 AL AZAR de esos 7,
-- rompiendo la garantia de "los 6 fijos siempre entran". Se inyecta en
-- BanditCustom.banditData solo en el momento del spawn y se retira despues.
-- Vive aqui (shared) porque lo necesita el planificador del servidor.
-- ---------------------------------------------------------------------------
local OUTFIT_CHISPA = {
    Hat                  = "Base.Hat_Army",
    Eyes                 = "Base.Glasses_SafetyGoggles",
    Tshirt               = "Base.Tshirt_CamoGreen",
    Jacket               = "Base.Jacket_ArmyCamoGreen",
    Pants                = "Base.Trousers_CamoGreen",
    Hands                = "Base.Gloves_LeatherGlovesBlack",
    UnderwearBottom      = "Base.Briefs_White",
    Socks                = "Base.Socks_Long_White",
    Shoes                = "Base.Shoes_ArmyBoots",
}

-- Copia superficial: cada integrante necesita SU tabla de ropa, porque el mod
-- base guarda la referencia en el brain y la persiste en el savegame.
function PVCShared.CopyTable(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

function PVCShared.BuildChispaData()
    return {
        general = {
            modid = PVCShared.MOD_ID, cid = PVCShared.CLAN_ID,
            name = "El Chispa",
            female = false, skin = 3, hairType = 13, beardType = 7, hairColor = 9,
            health = 7, strength = 6, endurance = 7, sight = 8,
            exp1 = 0, exp2 = 0, exp3 = 0,
        },
        clothing = PVCShared.CopyTable(OUTFIT_CHISPA),
        tint = {},
        weapons = {melee = "Base.Machete"},
        ammo    = {},
        bag     = {name = "Base.Bag_DuffelBagTINT"},
    }
end

-- Decide si El Chispa entra e inyecta/retira su perfil EN EL MOMENTO.
-- Devuelve el tamano de grupo correcto para que spawnGroup() del mod base tome
-- EXACTAMENTE los candidatos que hay: 6-de-6 o 7-de-7, nunca "6 de 7" al azar.
function PVCShared.RollChispa(force)
    if type(BanditCustom) ~= "table" or type(BanditCustom.banditData) ~= "table" then
        return PVCShared.Spawn.TeamPVCSize, false
    end
    local include = force or (ZombRand(100) < PVCShared.Spawn.ChispaChance)
    if include then
        BanditCustom.banditData[PVCShared.CHISPA_BID] = PVCShared.BuildChispaData()
        return PVCShared.Spawn.TeamPVCSize + 1, true
    end
    BanditCustom.banditData[PVCShared.CHISPA_BID] = nil
    return PVCShared.Spawn.TeamPVCSize, false
end

-- ---------------------------------------------------------------------------
-- TERRENO
-- Replica exacta del getGroundType() `local` del mod base
-- (server/BanditServerSpawner.lua ~110): mismo criterio embodies().
-- ---------------------------------------------------------------------------
function PVCShared.GetGroundType(square)
    local groundType = "generic"
    local objects = square:getObjects()
    if not objects then return groundType end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object then
            local sprite = object:getSprite()
            if sprite then
                local name = sprite:getName()
                if name then
                    if name:embodies("street") then
                        groundType = "street"
                    elseif name:embodies("natural") then
                        groundType = "natural"
                    end
                end
            end
        end
    end
    return groundType
end

-- ---------------------------------------------------------------------------
-- JUGADORES (patron exacto del mod base, BanditServerSpawner.lua ~50)
-- En multijugador hay que enumerar los conectados; en single player solo hay
-- uno y getOnlinePlayers() no sirve.
-- ---------------------------------------------------------------------------
function PVCShared.GetPlayers()
    local world = getWorld()
    if world and world:getGameMode() == "Multiplayer" then
        return getOnlinePlayers()
    end
    return IsoPlayer.getPlayers()
end

-- Un jugador al azar entre los conectados (o el unico, en single player).
function PVCShared.PickPlayer()
    local list = PVCShared.GetPlayers()
    if not list or list:size() == 0 then return nil end
    return list:get(ZombRand(list:size()))
end
