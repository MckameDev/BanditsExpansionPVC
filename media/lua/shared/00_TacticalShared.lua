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
PVCShared.VERSION = "1.2.0"

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

    -- DEBUT GARANTIZADO
    -- El escuadron es unico y con nombre propio; dejarlo a un 1% por tirada
    -- significa que una partida entera puede acabar sin verlo jamas. Con esto,
    -- cuando el mod se inicializa en el mundo se sortea UN dia objetivo dentro
    -- de la ventana, y llegado ese dia el spawn ya no se tira a suerte: se
    -- fuerza.
    -- La cuenta NO es sobre la edad absoluta del mundo, sino sobre la edad
    -- MENOS la que tenia cuando el mod se activo (ver TSS.GetSpawnState en
    -- server/TacticalSpawnServer.lua). Asi tambien funciona al anadir el mod a
    -- una partida ya empezada: mundo en dia 200 -> debut entre el 200 y el 215.
    DebutEnabled    = true,
    DebutMinDay     = 3,     -- margen de gracia: no cae encima el primer dia
    DebutMaxDay     = 15,    -- "dentro de los 15 dias": limite duro

    -- SEGURIDAD DE LOS COMANDOS DE DEBUG
    -- Los comandos 'TeamPVCHere' y 'RoadblockHere' crean contenido de la nada.
    -- El menu que los dispara solo aparece con -debug, pero un cliente
    -- modificado puede mandar el comando igual: en un servidor publico eso es
    -- un vector de griefing (spawnear el escuadron de elite a voluntad).
    -- Con esto en true, en MULTIJUGADOR solo los atienden cuentas con acceso
    -- admin/moderador/gm/overseer. En partida individual nunca se aplica.
    DebugSpawnRequiresAdmin = true,

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
-- EDAD DEL MUNDO
-- "Dias transcurridos desde que empezo la partida". Es una propiedad del
-- MUNDO, no del personaje, asi que vale igual en single player, en anfitrion y
-- en dedicado: no hay que ramificar por modo de juego.
--
-- POR QUE ESTA FUNCION EXISTE
-- La version anterior llamaba a getWorldAge(), que NO es una global de la API
-- de build 42. Kahlua intentaba invocar nil y reventaba con
-- "Object tried to call nil in CheckTeamPVCSpawn" en cada tick del
-- planificador. Como no tenemos forma de verificar la firma exacta contra el
-- JAR desde aqui, no apostamos a un unico accesor: probamos los conocidos en
-- orden, nos quedamos con el primero que responda un numero y lo cacheamos
-- para no pagar el pcall de resolucion cada vez. Si ninguno sirve devolvemos 0
-- y lo decimos por consola, en vez de tumbar el evento del juego.
--   1) getWorldAgeHours()  -> horas de mundo, admite fracciones de dia
--   2) getNightsSurvived() -> granularidad de 1 dia, pero muy estable
-- ---------------------------------------------------------------------------
local WORLD_AGE_SOURCES = {
    function(gt) return gt:getWorldAgeHours() / 24 end,
    function(gt) return gt:getNightsSurvived() end,
}

local worldAgeGetter        -- nil = sin resolver, false = ninguno sirve

function PVCShared.GetWorldAgeDays()
    local ok, gt = pcall(getGameTime)
    if not ok or not gt then return 0 end

    if worldAgeGetter then
        local ok2, days = pcall(worldAgeGetter, gt)
        if ok2 and type(days) == "number" then return days end
        worldAgeGetter = nil    -- dejo de responder: se vuelve a resolver
    elseif worldAgeGetter == false then
        return 0
    end

    for _, getter in ipairs(WORLD_AGE_SOURCES) do
        local ok2, days = pcall(getter, gt)
        if ok2 and type(days) == "number" then
            worldAgeGetter = getter
            return days
        end
    end

    worldAgeGetter = false
    print("[PVCShared][ERROR] Ningun accesor de edad del mundo disponible; se asume dia 0.")
    return 0
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
