--[[==========================================================================
    TacticalRoadblock.lua  (LADO CLIENTE)
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Modulo "Peaje": detecta el frenazo/choque contra un bloqueo y pide la
    emboscada al servidor.

    ---------------------------------------------------------------------------
    REPARTO CLIENTE / SERVIDOR (multijugador)
    ---------------------------------------------------------------------------
    La CONSTRUCCION del bloqueo (barricada, coches quemados, cadaver con el
    cuaderno de Evaristo) vive en server/TacticalSpawnServer.lua, no aqui.
    Motivo: media/lua/server/ se ejecuta en single player, en el servidor
    interno del modo Anfitrion y en un dedicado, pero NUNCA en un cliente
    conectado. Eso da "exactamente una autoridad" en los tres modos, que es lo
    que evita que con 4 amigos aparezcan 4 bloqueos para el mismo evento.

    Lo que SI tiene que estar en el cliente es la DETECCION del frenazo: mide
    la velocidad del vehiculo de ESTE jugador, algo inherentemente local. Al
    detectarlo se manda un comando y el servidor decide (y descarta peticiones
    repetidas del mismo bloqueo, vengan del jugador que vengan).

    Flujo completo:
      servidor construye -> avisa 'RoadblockAdded' -> el cliente lo apunta
      -> el cliente frena cerca -> manda 'Ambush' -> el servidor spawnea.

    ---------------------------------------------------------------------------
    CORRECCIONES SOBRE EL BRIEF ORIGINAL (verificadas contra el codigo real)
    ---------------------------------------------------------------------------
    - "Base.CarNormal con skin Burnt" -> los coches quemados NO son un skin:
      son SCRIPTS DE VEHICULO APARTE (CarNormalBurnt, SUVBurnt, VanBurnt...),
      confirmado en burntvehicles.txt y en ISVehicleMechanics.lua.
    - "IsoThumpable con constructedobjects_01_*" -> el roadblock nativo usa
      IsoObject.new + AddSpecialObject + transmitCompleteItemToClients, que es
      lo que sincroniza bien en multijugador. Copiamos ese patron.
    - "Events.LoadGridsquare filtrando asfalto" -> se dispara una vez por
      CASILLA al cargar terreno (decenas de miles por chunk): carisimo. El mod
      base tampoco lo usa para esto; busca sitio bajo demanda con un
      temporizador lento.
    - "zone = Forest" -> Spawner.Clan acepta x/y/z, no zona. El servidor
      calcula las casillas naturales adyacentes.
============================================================================]]

if TacticalRoadblock then return end -- guarda anti doble carga
TacticalRoadblock = {}
local TR = TacticalRoadblock
TR.VERSION = "2.0.0"

local getTimestampMs    = getTimestampMs
local getSpecificPlayer = getSpecificPlayer
local getCell           = getCell
local ZombRand          = ZombRand
local pcall             = pcall
local math_floor        = math.floor
local math_abs          = math.abs

TR.Config = {
    Debug = false,

    -- Disparador (todo lo demas lo decide el servidor)
    TriggerRange     = 25,    -- casillas para que la trampa este "armada"
    TriggerRangeFar  = 100,   -- mas alla de esto ni siquiera medimos distancias
    TickIntervalMs   = 2000,  -- presupuesto del chequeo
    BrakeDropKmh     = 18,    -- caida de velocidad entre dos chequeos = frenazo
    MinApproachKmh   = 15,    -- por debajo de esto no cuenta como "venia rapido"
}

local lastErrorMs = 0
local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TacticalRoadblock][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function Log(msg)
    if TR.Config.Debug then print("[TacticalRoadblock] " .. tostring(msg)) end
end

-- ---------------------------------------------------------------------------
-- BLOQUEOS CONOCIDOS POR ESTE CLIENTE
-- Array plano: el disparador lo recorre con for numerico, sin iteradores.
-- Lo llena el servidor via 'RoadblockAdded'.
-- ---------------------------------------------------------------------------
TR.Active = {}

local function AddBlock(x, y)
    for i = 1, #TR.Active do
        local b = TR.Active[i]
        if b.x == x and b.y == y then return end   -- ya lo teniamos
    end
    TR.Active[#TR.Active + 1] = {x = x, y = y, ambushed = false, lastSpeed = 0}
    Log("Bloqueo conocido en " .. x .. "," .. y)
end

-- ---------------------------------------------------------------------------
-- DISPARADOR
-- Ruta rapida: sin bloqueos sale en UNA comparacion; a pie, en dos. Solo con
-- bloqueos Y en vehiculo llega a medir distancias, siempre al cuadrado.
-- ---------------------------------------------------------------------------
local nextTickMs = 0

local function OnTick()
    local n = #TR.Active
    if n == 0 then return end

    local now = getTimestampMs()
    if now < nextTickMs then return end
    nextTickMs = now + TR.Config.TickIntervalMs

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    -- a pie no se mide nada
    local vehicle = player:getVehicle()
    if not vehicle then return end

    local speed = 0
    local okSpeed, s = pcall(vehicle.getCurrentSpeedKmHour, vehicle)
    if okSpeed and s then speed = math_abs(s) end

    local px, py = player:getX(), player:getY()
    local cfg = TR.Config
    local farSq     = cfg.TriggerRangeFar * cfg.TriggerRangeFar
    local triggerSq = cfg.TriggerRange * cfg.TriggerRange

    for i = 1, n do
        local b = TR.Active[i]
        if not b.ambushed then
            local dx, dy = px - b.x, py - b.y
            local d2 = dx * dx + dy * dy

            if d2 <= farSq then          -- descarte barato antes de nada mas
                if d2 <= triggerSq then
                    local drop = b.lastSpeed - speed
                    local braked  = (b.lastSpeed >= cfg.MinApproachKmh) and (drop >= cfg.BrakeDropKmh)
                    local stopped = (b.lastSpeed >= cfg.MinApproachKmh) and (speed < 3)

                    if braked or stopped then
                        -- marcamos en local para no spamear; la decision real
                        -- (y el descarte de peticiones repetidas) es del servidor
                        b.ambushed = true
                        local ok, err = pcall(sendClientCommand, player, 'BEPSpawn', 'Ambush',
                                              {x = b.x, y = b.y})
                        if not ok then LogError("sendClientCommand Ambush", err) end
                        Log("Frenazo detectado: emboscada pedida en " .. b.x .. "," .. b.y)
                    end
                end
                b.lastSpeed = speed
            end
        end
    end
end

-- Poda de bloqueos ya usados o lejanisimos (el jugador no va a volver).
local function CleanupBlocks()
    local player = getSpecificPlayer(0)
    if not player then return end
    local px, py = player:getX(), player:getY()

    for i = #TR.Active, 1, -1 do
        local b = TR.Active[i]
        local dx, dy = px - b.x, py - b.y
        if b.ambushed or (dx * dx + dy * dy) > 400 * 400 then
            table.remove(TR.Active, i)
        end
    end
end

-- ---------------------------------------------------------------------------
-- COMANDOS DEL SERVIDOR
-- ---------------------------------------------------------------------------
local function onServerCommand(module, command, args)
    if module ~= 'BEPSpawn' then return end
    if command == 'RoadblockAdded' and args and args.x and args.y then
        AddBlock(args.x, args.y)
    end
end

-- ---------------------------------------------------------------------------
-- DEBUG: pedir un bloqueo al servidor y teletransportarse a verlo
-- ---------------------------------------------------------------------------
local function FindNearbyStreetSpot(cell, px, py, maxRadius)
    if type(PVCShared) ~= "table" then return nil end
    for radius = 5, maxRadius, 10 do
        for _ = 1, 16 do
            local angle = ZombRand(360) * 0.0174533
            local cx = math_floor(px + math.cos(angle) * radius)
            local cy = math_floor(py + math.sin(angle) * radius)
            local sq = cell:getGridSquare(cx, cy, 0)
            if sq and PVCShared.GetGroundType(sq) == "street" then
                return cx, cy
            end
        end
    end
    return nil
end

local function OnDebugForceRoadblock(worldobjects)
    local player = getSpecificPlayer(0)
    if not player then return end
    local cell = getCell()
    if not cell then return end

    local cx, cy = FindNearbyStreetSpot(cell, player:getX(), player:getY(), 300)
    if not cx then
        print("[TacticalRoadblock] DEBUG: no se encontro calzada cerca del jugador.")
        return
    end

    -- lo construye el servidor (autoridad); nos avisara con 'RoadblockAdded'
    pcall(sendClientCommand, player, 'BEPSpawn', 'RoadblockHere', {x = cx, y = cy})

    -- 6 casillas en diagonal: fuera de la barricada y del radio despejado
    local okTp, errTp = pcall(player.teleportTo, player, cx - 6, cy - 6, 0)
    if not okTp then LogError("teleportTo", errTp) end

    print("[TacticalRoadblock] DEBUG: bloqueo pedido en " .. cx .. "," .. cy .. ".")
end

local function OnDebugTeleportNearest(worldobjects)
    local player = getSpecificPlayer(0)
    if not player then return end

    if #TR.Active == 0 then
        print("[TacticalRoadblock] DEBUG: no hay bloqueos conocidos. Use 'Forzar bloqueo' primero.")
        return
    end

    local px, py = player:getX(), player:getY()
    local best, bestD2
    for i = 1, #TR.Active do
        local b = TR.Active[i]
        local dx, dy = px - b.x, py - b.y
        local d2 = dx * dx + dy * dy
        if not bestD2 or d2 < bestD2 then best, bestD2 = b, d2 end
    end

    if best then
        local ok, err = pcall(player.teleportTo, player, best.x - 6, best.y - 6, 0)
        if not ok then LogError("teleportTo", err) end
        print("[TacticalRoadblock] DEBUG: teletransportado al bloqueo mas cercano.")
    end
end

local function OnFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if not isDebugEnabled or not isDebugEnabled() then return end
    if not context then return end

    local parent  = context:addOption(getText("UI_BEP_TR_DebugMenu"), worldobjects, nil)
    local subMenu = context:getNew(context)
    context:addSubMenu(parent, subMenu)

    subMenu:addOption(getText("UI_BEP_TR_DebugForce"), worldobjects, OnDebugForceRoadblock)
    subMenu:addOption(getText("UI_BEP_TR_DebugTeleport"), worldobjects, OnDebugTeleportNearest)
end

Events.OnFillWorldObjectContextMenu.Add(OnFillWorldObjectContextMenu)

-- ---------------------------------------------------------------------------
-- ARRANQUE
-- ---------------------------------------------------------------------------
local function Bootstrap()
    Events.OnTick.Remove(OnTick)
    Events.OnTick.Add(OnTick)

    Events.EveryHours.Remove(CleanupBlocks)
    Events.EveryHours.Add(CleanupBlocks)

    Events.OnServerCommand.Remove(onServerCommand)
    Events.OnServerCommand.Add(onServerCommand)

    -- al entrar, pedimos al servidor los bloqueos que ya existan
    local player = getSpecificPlayer(0)
    if player then
        pcall(sendClientCommand, player, 'BEPSpawn', 'SyncBlocks', {})
    end

    print("[TacticalRoadblock] v" .. TR.VERSION .. " activo (detector de frenazo).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TacticalRoadblock] INACTIVO por error en el arranque.")
    end
end)
