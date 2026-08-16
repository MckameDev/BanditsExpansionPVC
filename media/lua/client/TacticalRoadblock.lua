--[[==========================================================================
    TacticalRoadblock.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Modulo "Peaje": bloqueos de carretera abandonados con emboscada diferida.

    ---------------------------------------------------------------------------
    LO QUE YA EXISTE EN EL MOD BASE (y por que NO lo reimplementamos)
    ---------------------------------------------------------------------------
    Bandits2 YA trae un sistema de roadblocks completo, verificado en
    server/BanditServerSpawner.lua (spawnRoadblock, ~linea 671) y
    shared/ZombiePrograms/ZPRoadblock.lua:
      - detecta calzada por tipo de suelo, comprueba espacio libre,
      - orienta la barricada segun si la calle es horizontal o vertical,
      - coloca construction_01_8 / construction_01_9 + un vehiculo con luces,
      - los bandidos quedan estacionarios (ForceStationary) y saltan al
        programa de asalto cuando TE VEN a 30 casillas.
    Se activa con el flag `roadblock` del clan y el sandbox
    Bandits.General_BuildRoadblock (por defecto ON).

    Este modulo NO duplica nada de eso. Aporta un bloqueo de sabor DISTINTO y
    complementario, que el nativo no hace:
      - puesto ABANDONADO (coches quemados, sin bandidos a la vista),
      - una pista narrativa de Evaristo Brea (cadaver + cuaderno),
      - y sobre todo un DISPARADOR DISTINTO: no salta al verte, salta cuando
        FRENAS o CHOCAS contra el bloqueo yendo en coche. Es una trampa, no un
        control de carretera.
    Para no pisarse con el nativo, respeta el mismo sandbox toggle y descarta
    cualquier sitio donde ya haya vehiculos u objetos.

    ---------------------------------------------------------------------------
    CORRECCIONES SOBRE EL BRIEF (verificadas contra el codigo real)
    ---------------------------------------------------------------------------
    - "Base.CarNormal con skin Burnt" -> los coches quemados NO son un skin:
      son SCRIPTS DE VEHICULO APARTE. Confirmado en
      media/scripts/generated/vehicles/burntAndSmashedVehicles/burntvehicles.txt
      (CarNormalBurnt, SUVBurnt, VanBurnt, PickupBurnt...) y en
      ISVehicleMechanics.lua, que detecta quemados con
      string.match(script:getName(), "Burnt"). Usamos los scripts reales.
    - "IsoThumpable con sprites constructedobjects_01_*" -> IsoThumpable exige
      un objeto Lua acompanante (patron ISBarbedWire: IsoThumpable.new(cell,
      sq, sprite, north, self)) pensado para construcciones DEL JUGADOR, con su
      modData y su sincronizacion. El propio roadblock nativo no lo usa: coloca
      IsoObject.new(square, sprite, "") + AddSpecialObject +
      transmitCompleteItemToClients. Copiamos ese patron, que es el probado
      para esto y el que sincroniza bien en multijugador.
    - "Events.LoadGridsquare filtrando celdas de asfalto" -> ese evento se
      dispara UNA VEZ POR CASILLA al cargar el terreno (decenas de miles por
      chunk). Escanear ahi seria carisimo. El propio mod base no lo usa para
      esto: busca sitio bajo demanda alrededor del jugador. Hacemos lo mismo
      con un temporizador lento.
    - "zone = Forest" -> BanditServer.Spawner.Clan no acepta zona: acepta
      x/y/z (verificado en su firma). Calculamos nosotros las casillas
      naturales adyacentes con el mismo criterio que el mod base
      (sprite:embodies("natural")).
    - getGroundType() del mod base es `local`, no alcanzable desde aqui:
      replicamos su logica exacta en GetGroundType (misma comparacion embodies).
============================================================================]]

if TacticalRoadblock then return end -- guarda anti doble carga
TacticalRoadblock = {}
local TR = TacticalRoadblock
TR.VERSION = "1.0.0"

local getTimestampMs    = getTimestampMs
local getSpecificPlayer = getSpecificPlayer
local getCell           = getCell
local ZombRand          = ZombRand
local pcall             = pcall
local math_floor        = math.floor
local math_abs          = math.abs

-- Clan de emboscada propio. spawnChance=0 a proposito: el planificador nativo
-- no debe sacarlos nunca por su cuenta, solo aparecen desde nuestra trampa.
TR.AMBUSH_CID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de002"

TR.Config = {
    Debug = false,

    Enabled        = true,
    ScanIntervalMs = 180000,  -- cada cuanto se intenta colocar un bloqueo nuevo
    MaxActive      = 2,       -- bloqueos simultaneos como maximo
    PlaceChance    = 35,      -- % de exito cuando toca intentarlo
    MinDist        = 40,      -- casillas: no justo encima del jugador...
    MaxDist        = 90,      -- ...ni tan lejos que nunca lo encuentre
    ClearRadius    = 4,       -- radio que debe estar libre para montar el puesto

    BurntCarChance = 70,      -- % de que ademas del bloqueo haya un 2o coche

    -- Disparador
    TriggerRange     = 25,    -- casillas para que la trampa este "armada"
    TriggerRangeFar  = 100,   -- mas alla de esto ni siquiera medimos distancias
    TickIntervalMs   = 2000,  -- presupuesto del chequeo (el brief pedia ~2s)
    BrakeDropKmh     = 18,    -- caida de velocidad entre dos chequeos = frenazo
    MinApproachKmh   = 15,    -- por debajo de esto no cuenta como "venia rapido"

    -- Emboscada
    AmbushSize      = 4,
    TeamPVCChance   = 3,      -- % de que el peaje lo cobre el propio Team PVC
}

-- Coches quemados reales (scripts verificados en burntvehicles.txt)
TR.BurntCars = {
    "Base.CarNormalBurnt",
    "Base.SmallCarBurnt",
    "Base.SUVBurnt",
    "Base.VanBurnt",
    "Base.PickupBurnt",
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

local function Choice(tab)
    local n = #tab
    if n == 0 then return nil end
    return tab[ZombRand(n) + 1]
end

-- Replica exacta del getGroundType() `local` del mod base
-- (server/BanditServerSpawner.lua ~110): mismo criterio embodies().
local function GetGroundType(square)
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
-- BLOQUEOS ACTIVOS
-- Array plano de {x, y, z, armed, ambushed}. Nunca crece sin control: se poda
-- en cada colocacion nueva y el disparador solo recorre este array corto.
-- ---------------------------------------------------------------------------
TR.Active = {}

-- ---------------------------------------------------------------------------
-- GENERACION
-- ---------------------------------------------------------------------------

-- Comprueba que el cuadrado de lado 2r alrededor del punto este despejado,
-- mismo criterio que usa spawnRoadblock del mod base (isFree + sin vehiculo).
local function IsAreaClear(cell, cx, cy, r)
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            local sq = cell:getGridSquare(x, y, 0)
            if not sq then return false end
            if not sq:isFree(false) then return false end
            if sq:getVehicleContainer() then return false end
        end
    end
    return true
end

-- Devuelve el sprite de barricada y los multiplicadores de eje segun la
-- orientacion real de la calle (misma tecnica que el mod base: cuenta cuantas
-- casillas de calle hay en cada eje y la calle "va" por el eje mas largo).
local function GetRoadOrientation(cell, cx, cy)
    local xcnt, ycnt = 0, 0
    for x = cx - 20, cx + 20 do
        local sq = cell:getGridSquare(x, cy, 0)
        if sq and GetGroundType(sq) == "street" then xcnt = xcnt + 1 end
    end
    for y = cy - 20, cy + 20 do
        local sq = cell:getGridSquare(cx, y, 0)
        if sq and GetGroundType(sq) == "street" then ycnt = ycnt + 1 end
    end
    if xcnt > ycnt then
        -- calle horizontal: la barricada se extiende en Y
        return "construction_01_9", 0, 1
    end
    return "construction_01_8", 1, 0
end

-- Mismo primitivo que spawnObject() del mod base: IsoObject + AddSpecialObject
-- + transmitCompleteItemToClients (esto ultimo es lo que lo hace visible al
-- resto de jugadores en multijugador).
local function PlaceObject(cell, sprite, x, y, z)
    local square = cell:getGridSquare(x, y, z)
    if not square then return false end
    local obj = IsoObject.new(square, sprite, "")
    square:AddSpecialObject(obj)
    pcall(obj.transmitCompleteItemToClients, obj)
    return true
end

-- Cuaderno de Evaristo. Mismo patron que las notas de TacticalQuickWins
-- (addPage + setName + setCustomName, el que usa el juego al escribir un
-- cuaderno). El texto sale del sistema de traduccion.
local function MakeTollNote()
    local ok, item = pcall(BanditCompatibility.InstanceItem, "Base.Notebook")
    if not ok or not item then return nil end
    pcall(item.addPage, item, 1, getText("UI_BEP_TR_NoteBody"))
    pcall(item.setName, item, getText("UI_BEP_TR_NoteTitle"))
    pcall(item.setCustomName, item, true)
    return item
end

-- Cadaver con la pista. createZombie + IsoDeadBody.new es el patron real del
-- juego (client/Tutorial/Steps.lua). Si algo falla, degradamos a dejar el
-- cuaderno en el suelo: la pista narrativa nunca se pierde.
local function SpawnLoreCorpse(cell, x, y, z)
    local square = cell:getGridSquare(x, y, z)
    if not square then return false end

    local note = MakeTollNote()

    local ok, body = pcall(function()
        local zombie = createZombie(x, y, z, nil, 0, IsoDirections.S)
        if not zombie then return nil end
        pcall(zombie.dressInRandomOutfit, zombie)
        local corpse = IsoDeadBody.new(zombie, false)
        return corpse
    end)

    if ok and body then
        if note then
            local inv = body:getContainer()
            if inv then
                inv:AddItem(note)
                Log("Cadaver con cuaderno colocado")
                return true
            end
        end
        Log("Cadaver colocado (sin cuaderno)")
        return true
    end

    -- Degradacion: el cuaderno directo al suelo.
    if note then
        pcall(square.AddWorldInventoryItem, square, note, 0.5, 0.5, 0)
        Log("Cadaver fallo; cuaderno dejado en el suelo")
        return true
    end
    return false
end

-- Coches quemados atravesados. addVehicleDebug es el mismo constructor que usa
-- spawnVehicle() del mod base para sus roadblocks.
local function SpawnBurntCars(cell, cx, cy, xm, ym)
    local placed = 0

    local function tryCar(ox, oy, dir)
        local sq = cell:getGridSquare(cx + ox, cy + oy, 0)
        if not sq then return end
        local ok, veh = pcall(addVehicleDebug, Choice(TR.BurntCars), dir, nil, sq)
        if ok and veh then placed = placed + 1 end
    end

    -- atravesado respecto a la calzada: si la calle va en X, el coche mira a N
    local dirA = (xm == 1) and IsoDirections.N or IsoDirections.E
    tryCar(xm * 3, ym * 3, dirA)

    if ZombRand(100) < TR.Config.BurntCarChance then
        local dirB = (xm == 1) and IsoDirections.S or IsoDirections.W
        tryCar(-xm * 3, -ym * 3, dirB)
    end

    return placed
end

local function CreateRoadblock(cell, cx, cy)
    local sprite, xm, ym = GetRoadOrientation(cell, cx, cy)

    -- barricada perpendicular a la marcha, igual que el nativo (de -4 a 4 de 2 en 2)
    local pieces = 0
    for b = -4, 4, 2 do
        if PlaceObject(cell, sprite, cx + xm * b, cy + ym * b, 0) then
            pieces = pieces + 1
        end
    end
    if pieces == 0 then return false end

    pcall(SpawnBurntCars, cell, cx, cy, xm, ym)
    pcall(SpawnLoreCorpse, cell, cx, cy, 0)

    TR.Active[#TR.Active + 1] = {
        x = cx, y = cy, z = 0,
        ambushed = false,
        lastSpeed = 0,
    }
    Log("Bloqueo creado en " .. cx .. "," .. cy .. " (" .. pieces .. " piezas)")
    return true
end

-- Busca calzada libre a media distancia del jugador. Muestreo por sondeo
-- (12 intentos al azar) en vez de barrer el area entera: el coste es constante
-- y acotado, y esto corre cada varios minutos, no por frame.
local function TryPlaceRoadblock()
    local cfg = TR.Config
    if not cfg.Enabled then return end
    if #TR.Active >= cfg.MaxActive then return end
    if ZombRand(100) >= cfg.PlaceChance then return end

    -- respeta el mismo interruptor de sandbox que el roadblock nativo
    if SandboxVars.Bandits and SandboxVars.Bandits.General_BuildRoadblock == false then
        return
    end

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    local cell = getCell()
    if not cell then return end

    local px, py = player:getX(), player:getY()
    local span = cfg.MaxDist - cfg.MinDist

    for _ = 1, 12 do
        local dist = cfg.MinDist + ZombRand(span)
        local angle = ZombRand(360) * 0.0174533   -- grados -> radianes
        local cx = math_floor(px + math.cos(angle) * dist)
        local cy = math_floor(py + math.sin(angle) * dist)

        local sq = cell:getGridSquare(cx, cy, 0)
        if sq and GetGroundType(sq) == "street" and IsAreaClear(cell, cx, cy, cfg.ClearRadius) then
            local ok, err = pcall(CreateRoadblock, cell, cx, cy)
            if not ok then LogError("CreateRoadblock", err) end
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- DEBUG: forzar un bloqueo cerca del jugador y teletransportarse a verlo
-- ---------------------------------------------------------------------------

-- Anillos crecientes de radio (a diferencia de TryPlaceRoadblock, que busca a
-- una distancia FIJA lejos del jugador): esto es para debug, queremos el
-- bloqueo mas cercano posible que sea valido, no uno lejano.
local function FindNearbyStreetSpot(cell, px, py, maxRadius)
    for radius = 5, maxRadius, 10 do
        for _ = 1, 16 do
            local angle = ZombRand(360) * 0.0174533
            local cx = math_floor(px + math.cos(angle) * radius)
            local cy = math_floor(py + math.sin(angle) * radius)
            local sq = cell:getGridSquare(cx, cy, 0)
            if sq and GetGroundType(sq) == "street" and IsAreaClear(cell, cx, cy, TR.Config.ClearRadius) then
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
        print("[TacticalRoadblock] DEBUG: no se encontro calzada libre cerca del jugador.")
        return
    end

    local ok, err = pcall(CreateRoadblock, cell, cx, cy)
    if not ok then
        LogError("OnDebugForceRoadblock", err)
        return
    end

    -- 6 casillas en diagonal: fuera del radio despejado (ClearRadius=4) y de
    -- las piezas de la barricada (a lo sumo 4 en un eje), asi el jugador no
    -- aparece encima de nada.
    local okTp, errTp = pcall(player.teleportTo, player, cx - 6, cy - 6, 0)
    if not okTp then LogError("teleportTo", errTp) end

    print("[TacticalRoadblock] DEBUG: bloqueo forzado en " .. cx .. "," .. cy .. ".")
end

local function OnDebugTeleportNearest(worldobjects)
    local player = getSpecificPlayer(0)
    if not player then return end

    if #TR.Active == 0 then
        print("[TacticalRoadblock] DEBUG: no hay bloqueos activos. Use 'Forzar bloqueo' primero.")
        return
    end

    local px, py = player:getX(), player:getY()
    local best, bestD2
    for i = 1, #TR.Active do
        local b = TR.Active[i]
        local dx, dy = px - b.x, py - b.y
        local d2 = dx * dx + dy * dy
        if not bestD2 or d2 < bestD2 then
            best, bestD2 = b, d2
        end
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

-- Se registra siempre (se autocomprueba isDebugEnabled() en cada apertura),
-- igual que el menu de TeamPVC_Group.lua.
Events.OnFillWorldObjectContextMenu.Add(OnFillWorldObjectContextMenu)

-- ---------------------------------------------------------------------------
-- EMBOSCADA
-- ---------------------------------------------------------------------------

-- Busca una casilla natural (tierra/arboles) en el borde del bloqueo, para que
-- los bandidos salgan de la maleza y no del asfalto.
local function FindForestSpawn(cell, cx, cy)
    for r = 5, 9 do
        for _ = 1, 8 do
            local ang = ZombRand(360) * 0.0174533
            local x = math_floor(cx + math.cos(ang) * r)
            local y = math_floor(cy + math.sin(ang) * r)
            local sq = cell:getGridSquare(x, y, 0)
            if sq and sq:isFree(false) and GetGroundType(sq) == "natural" then
                return x, y
            end
        end
    end
    return nil
end

local function TriggerAmbush(block, player)
    if block.ambushed then return end
    block.ambushed = true

    local cell = getCell()
    if not cell then return end

    local sx, sy = FindForestSpawn(cell, block.x, block.y)
    if not sx then
        -- sin maleza alrededor: salen desde detras del propio bloqueo
        sx, sy = block.x + 5, block.y + 5
    end

    -- 3%: el peaje lo cobra el propio Team PVC (reutiliza su spawn ya probado,
    -- que garantiza los 6 integrantes y su tirada de El Chispa).
    if type(TeamPVC) == "table" and type(TeamPVC.SpawnGroup) == "function"
       and ZombRand(100) < TR.Config.TeamPVCChance then
        local sq = cell:getGridSquare(sx, sy, 0)
        if sq then
            local ok, err = pcall(TeamPVC.SpawnGroup, sq)
            if not ok then LogError("TeamPVC.SpawnGroup", err) end
            Log("Emboscada: Team PVC cobra el peaje")
            return
        end
    end

    local ok, err = pcall(sendClientCommand, player, 'Spawner', 'Clan', {
        cid     = TR.AMBUSH_CID,
        size    = TR.Config.AmbushSize,
        program = "Bandit",
        x       = sx,
        y       = sy,
        z       = 0,
    })
    if not ok then LogError("sendClientCommand Spawner/Clan", err) end
    Log("Emboscada disparada desde " .. sx .. "," .. sy)
end

-- ---------------------------------------------------------------------------
-- DISPARADOR
-- Ruta rapida: si no hay bloqueos activos sale en UNA comparacion. Si el
-- jugador va a pie, sale en dos. Solo con bloqueos activos Y en coche llega a
-- medir distancias, y siempre al cuadrado (sin raices).
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

    -- el brief lo pide explicitamente: a pie no se mide nada
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
                    -- frenazo: venia rapido y perdio mucha velocidad de golpe
                    local drop = b.lastSpeed - speed
                    local braked = (b.lastSpeed >= cfg.MinApproachKmh) and (drop >= cfg.BrakeDropKmh)
                    -- choque / parado en seco encima del bloqueo
                    local stopped = (b.lastSpeed >= cfg.MinApproachKmh) and (speed < 3)

                    if braked or stopped then
                        local ok, err = pcall(TriggerAmbush, b, player)
                        if not ok then LogError("TriggerAmbush", err) end
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
-- ARRANQUE
-- ---------------------------------------------------------------------------
local function CheckDependencies()
    local missing = {}
    if type(BanditCompatibility) ~= "table" or type(BanditCompatibility.InstanceItem) ~= "function" then
        missing[#missing + 1] = "BanditCompatibility.InstanceItem"
    end
    if type(IsoObject) ~= "table" and type(IsoObject) ~= "userdata" then
        missing[#missing + 1] = "IsoObject"
    end
    if type(sendClientCommand) ~= "function" then
        missing[#missing + 1] = "sendClientCommand"
    end
    return missing
end

local function Bootstrap()
    if not TR.Config.Enabled then return end

    local missing = CheckDependencies()
    if #missing > 0 then
        print("[TacticalRoadblock] INACTIVO. Falta: " .. table.concat(missing, ", "))
        return
    end

    Events.OnTick.Remove(OnTick)
    Events.OnTick.Add(OnTick)

    Events.EveryTenMinutes.Remove(TryPlaceRoadblock)
    Events.EveryTenMinutes.Add(TryPlaceRoadblock)

    Events.EveryHours.Remove(CleanupBlocks)
    Events.EveryHours.Add(CleanupBlocks)

    print("[TacticalRoadblock] v" .. TR.VERSION .. " activo (peaje de Evaristo Brea).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TacticalRoadblock] INACTIVO por error en el arranque.")
    end
end)
