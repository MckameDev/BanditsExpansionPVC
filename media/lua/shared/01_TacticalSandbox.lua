--[[==========================================================================
    01_TacticalSandbox.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Puente entre las opciones de partida (media/sandbox-options.txt) y las
    tablas Config de cada modulo.

    ---------------------------------------------------------------------------
    POR QUE UN SOLO SITIO
    ---------------------------------------------------------------------------
    Cada modulo ya consultaba su propio `Config.<Mecanica>.Enabled` en tiempo de
    ejecucion. Aqui NO se cambia esa logica: solo se sobrescribe el valor por
    defecto con lo que el jugador (o el admin del servidor) haya elegido. Asi
    no hay que tocar ni una linea de las mecanicas, y quien lea un modulo sigue
    viendo un unico interruptor.

    ---------------------------------------------------------------------------
    LOS TRES MODOS, UNA SOLA DEFINICION
    ---------------------------------------------------------------------------
    Project Zomboid replica SandboxVars del servidor a cada cliente, asi que:
      - partida individual : lo elegido en la pantalla de Sandbox
      - Anfitrion          : lo elegido al crear la partida, valido para todos
      - dedicado           : lo del .ini del servidor, valido para todos
    No hay que ramificar por modo ni sincronizar nada a mano.

    ---------------------------------------------------------------------------
    POR QUE EL PREFIJO "01_" Y POR QUE SE APLICA EN OnGameStart
    ---------------------------------------------------------------------------
    Kahlua carga media/lua/shared/ por orden alfabetico, asi que este archivo va
    despues de los 00_ (que definen PVCShared y MaurinBombin). Pero las tablas
    de las mecanicas (TQW, TA, TA2, TD) viven en media/lua/client/, que carga
    DESPUES de shared/: en el cuerpo de este archivo todavia no existen. Por eso
    la aplicacion se hace en Events.OnGameStart, cuando ya esta todo cargado.

    Las mecanicas leen `Enabled` en cada llamada (no lo cachean al arrancar), asi
    que aplicarlo aqui llega a tiempo aunque el Bootstrap del modulo ya se haya
    ejecutado.
============================================================================]]

if PVCSandbox then return end -- guarda anti doble carga

PVCSandbox = {}
local SB = PVCSandbox

SB.VERSION = "1.0.0"

-- Espacio de nombres de las opciones: SandboxVars.BEP.<clave>
SB.NAMESPACE = "BEP"

SB.Config = {
    Debug = false,
}

local function Log(msg)
    if SB.Config.Debug then print("[PVCSandbox] " .. tostring(msg)) end
end

-- ---------------------------------------------------------------------------
-- LECTURA DEFENSIVA
-- Si la opcion no existe (partida vieja guardada antes de anadirla, o un .ini
-- de servidor incompleto), se devuelve el valor por defecto en vez de nil: una
-- mecanica nunca debe apagarse sola por una opcion ausente.
-- ---------------------------------------------------------------------------
function SB.GetBool(key, default)
    if default == nil then default = true end

    local okVars, vars = pcall(function() return SandboxVars end)
    if not okVars or type(vars) ~= "table" then return default end

    local group = vars[SB.NAMESPACE]
    if type(group) ~= "table" then return default end

    local value = group[key]
    if type(value) ~= "boolean" then return default end
    return value
end

-- ---------------------------------------------------------------------------
-- MAPA: opcion de sandbox -> donde vive el interruptor
--
-- Cada entrada dice como llegar al campo `Enabled`:
--   root : nombre de la tabla global del modulo (se resuelve en _G al aplicar,
--          porque en un servidor dedicado las tablas de client/ no existen)
--   path : ruta dentro de esa tabla hasta la tabla que tiene `Enabled`
--   field: nombre del campo a escribir (por defecto "Enabled")
-- ---------------------------------------------------------------------------
SB.Map = {
    -- Modulos generales
    {opt = "Dialogues",   root = "BanditTacticalDialogues", path = {"Config"}},
    {opt = "Morale",      root = "TacticalAdvanced",        path = {"Config", "Morale"}},
    {opt = "Medic",       root = "TacticalAdvanced",        path = {"Config", "Medic"}},

    -- Comportamientos de bandido (TacticalQuickWins)
    {opt = "Meds",        root = "TQW", path = {"Config", "Meds"}},
    {opt = "Sidearm",     root = "TQW", path = {"Config", "Sidearm"}},
    {opt = "Torch",       root = "TQW", path = {"Config", "Torch"}},
    {opt = "Limp",        root = "TQW", path = {"Config", "Limp"}},
    {opt = "Negotiator",  root = "TQW", path = {"Config", "Negotiator"}},
    {opt = "Scavenger",   root = "TQW", path = {"Config", "Scavenger"}},
    {opt = "Pyro",        root = "TQW", path = {"Config", "Pyro"}},
    {opt = "Radio",       root = "TQW", path = {"Config", "Radio"}},
    {opt = "Loot",        root = "TQW", path = {"Config", "Loot"}},

    -- Tacticas asimetricas
    {opt = "FakeSurrender", root = "TacticalAsymmetric", path = {"Config", "FakeSurrender"}},
    {opt = "HordeBait",     root = "TacticalAsymmetric", path = {"Config", "HordeBait"}},
    {opt = "CarSabotage",   root = "TacticalAsymmetric", path = {"Config", "CarSabotage"}},
    {opt = "SmokeAmbush",   root = "TacticalAsymmetric", path = {"Config", "SmokeAmbush"}},

    -- Contenido propio. Estos viven en shared/, asi que existen en los dos lados.
    {opt = "TeamPVC",      root = "PVCShared",        path = {"Spawn"}, field = "TeamPVCEnabled"},
    {opt = "TeamPVCDebut", root = "PVCShared",        path = {"Spawn"}, field = "DebutEnabled"},
    {opt = "Roadblock",    root = "PVCShared",        path = {"Spawn"}, field = "RoadblockEnabled"},
    {opt = "Bounties",     root = "TacticalBounties", path = {"Config"}},
    {opt = "Market",       root = "MaurinBombin",     path = {"Config"}},
}

-- Resuelve root.path[1].path[2]... devolviendo la tabla final, o nil si en el
-- camino falta algo (modulo desactivado, o tabla de client/ en un dedicado).
local function Resolve(entry)
    local node = _G[entry.root]
    if type(node) ~= "table" then return nil end

    for i = 1, #entry.path do
        node = node[entry.path[i]]
        if type(node) ~= "table" then return nil end
    end
    return node
end

-- ---------------------------------------------------------------------------
-- APLICACION
-- ---------------------------------------------------------------------------
function SB.Apply()
    local applied, skipped, disabled = 0, 0, 0

    for i = 1, #SB.Map do
        local entry = SB.Map[i]
        local target = Resolve(entry)

        if not target then
            skipped = skipped + 1
            Log("omitido (no cargado en este proceso): " .. entry.opt)
        else
            local field = entry.field or "Enabled"
            -- El valor por defecto es el que ya trae el modulo: si el jugador no
            -- toco la opcion, todo se queda exactamente como estaba.
            local current = target[field]
            if type(current) ~= "boolean" then current = true end

            local value = SB.GetBool(entry.opt, current)
            target[field] = value

            applied = applied + 1
            if not value then
                disabled = disabled + 1
                Log("DESACTIVADO por sandbox: " .. entry.opt)
            end
        end
    end

    print("[PVCSandbox] v" .. SB.VERSION .. ": " .. applied .. " opciones aplicadas (" ..
          disabled .. " desactivadas, " .. skipped .. " no presentes en este proceso).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(SB.Apply)
    if not ok then print("[PVCSandbox] ERROR al aplicar opciones: " .. tostring(err)) end
end)
