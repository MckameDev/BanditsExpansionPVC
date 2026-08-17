--[[==========================================================================
    TacticalSpawnServer.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Capa de SPAWN Y MUNDO. Aqui se decide QUE aparece, CUANDO y DONDE.

    ---------------------------------------------------------------------------
    POR QUE ESTE ARCHIVO ESTA EN server/
    ---------------------------------------------------------------------------
    media/lua/server/ se ejecuta en los TRES modos de juego:
      - single player          (el juego corre servidor y cliente en proceso)
      - anfitrion              (el servidor interno CoopServer lo ejecuta)
      - servidor dedicado      (obvio)
    ...y NO se ejecuta en los clientes conectados. O sea: con una sola
    implementacion obtenemos "exactamente una autoridad" en cualquier modo,
    sin trucos ni comprobaciones de isCoopHost().

    Es el mismo sitio y el mismo patron que usa el planificador del mod base
    (server/BanditServerSpawner.lua, funcion checkEvent), que ademas empieza
    con "if isClient() then return end" por si acaso. Lo copiamos igual.

    ---------------------------------------------------------------------------
    QUE NO ESTA AQUI (y por que)
    ---------------------------------------------------------------------------
    La IA / comportamiento (dialogos, tacticas, moral, El Chispa, emboscada al
    frenar) sigue en client/. No es una decision nuestra: el tick de IA del mod
    base (client/BanditUpdate.lua) es client-side y corta con "if isServer()
    then return end". En el servidor no hay ningun bandido que actualizar, asi
    que ese codigo alli no tendria nada sobre lo que operar.
    Reparto final: el SERVIDOR crea, los CLIENTES interpretan.

    ---------------------------------------------------------------------------
    COMANDOS QUE ATIENDE (cliente -> servidor)
    ---------------------------------------------------------------------------
      BEPSpawn / Ambush      : un cliente freno o choco contra un bloqueo y
                               pide la emboscada (la deteccion del frenazo es
                               inherentemente local: depende del vehiculo de
                               ESE jugador).
      BEPSpawn / TeamPVCHere : spawn manual desde el menu de debug.
============================================================================]]

if isClient() then return end   -- un cliente conectado nunca ejecuta esto

if TacticalSpawnServer then return end -- guarda anti doble carga
TacticalSpawnServer = {}
local TSS = TacticalSpawnServer
TSS.VERSION = "1.0.0"

local ZombRand    = ZombRand
local math_floor  = math.floor
local pcall       = pcall

local lastErrorMs = 0
local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TacticalSpawnServer][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

-- Coches quemados reales (scripts verificados en burntvehicles.txt: los
-- quemados NO son un skin, son scripts de vehiculo aparte).
local BURNT_CARS = {
    "Base.CarNormalBurnt",
    "Base.SmallCarBurnt",
    "Base.SUVBurnt",
    "Base.VanBurnt",
    "Base.PickupBurnt",
}

local function Choice(tab)
    local n = #tab
    if n == 0 then return nil end
    return tab[ZombRand(n) + 1]
end

-- ---------------------------------------------------------------------------
-- SPAWN DE CLAN
-- En el servidor NO se usa sendClientCommand: se llama directamente al
-- spawner del mod base, que es justo lo que hace su propio checkEvent.
-- ---------------------------------------------------------------------------
local function SpawnClanAt(player, cid, size, x, y, z, program)
    if type(BanditServer) ~= "table" or type(BanditServer.Spawner) ~= "table"
       or type(BanditServer.Spawner.Clan) ~= "function" then
        LogError("SpawnClanAt", "BanditServer.Spawner.Clan no disponible")
        return false
    end
    local ok, err = pcall(BanditServer.Spawner.Clan, player, {
        cid     = cid,
        size    = size,
        program = program or "Bandit",
        x       = x, y = y, z = z or 0,
    })
    if not ok then
        LogError("BanditServer.Spawner.Clan", err)
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- TEAM PVC: planificador natural
-- Misma cadencia y misma formula de probabilidad que el planificador nativo
-- (spawnChance * SpawnMultiplier / 6), para que el slider de sandbox del
-- jugador siga controlando que tan seguido aparecen. La diferencia es que
-- nosotros llamamos con size fijo, sin pasar por la formula de TAMANO nativa
-- (que multiplica por el multiplicador y puede dar un grupo incompleto).
-- ---------------------------------------------------------------------------
local function PickNaturalSquare(player)
    local cfg = PVCShared.Spawn
    local dist = cfg.NaturalMinDist + ZombRand(cfg.NaturalMaxDist - cfg.NaturalMinDist)
    local angle = ZombRandFloat(0, 2 * math.pi)
    local x = math_floor(player:getX() + math.cos(angle) * dist)
    local y = math_floor(player:getY() + math.sin(angle) * dist)
    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, player:getZ())
    if square then return square end
    return player:getSquare()
end

function TSS.SpawnTeamPVC(player, square, forceChispa)
    if not player then return false end
    square = square or player:getSquare()
    if not square then return false end

    local ok, size, withChispa = pcall(PVCShared.RollChispa, forceChispa)
    if not ok then
        LogError("RollChispa", size)
        size, withChispa = PVCShared.Spawn.TeamPVCSize, false
    end

    local res = SpawnClanAt(player, PVCShared.CLAN_ID, size,
                            square:getX(), square:getY(), square:getZ(), "Bandit")
    if res then
        print("[TacticalSpawnServer] Team PVC: " .. size .. " integrantes en " ..
              square:getX() .. "," .. square:getY() .. " (El Chispa: " .. tostring(withChispa) .. ")")
    end
    return res
end

local function CheckTeamPVCSpawn()
    local cfg = PVCShared.Spawn

    local player = PVCShared.PickPlayer()
    if not player or player:isDead() then return end

    -- En MP el "dia" es por jugador; en SP es la edad del mundo.
    local world = getWorld()
    local day
    if world and world:getGameMode() == "Multiplayer" then
        day = player:getHoursSurvived() / 24
    else
        day = getWorldAge()
    end
    if day < cfg.DayStart or day > cfg.DayEnd then return end

    local multiplier = (SandboxVars.Bandits and SandboxVars.Bandits.General_SpawnMultiplier) or 1
    local chance = cfg.TeamPVCChance * multiplier / 6
    if ZombRandFloat(0, 100) >= chance then return end

    local square = PickNaturalSquare(player)
    if not square then return end

    local ok, err = pcall(TSS.SpawnTeamPVC, player, square, false)
    if not ok then LogError("SpawnTeamPVC", err) end
end

-- ---------------------------------------------------------------------------
-- BLOQUEOS DE CARRETERA
-- El servidor los construye (asi existen para TODOS los jugadores y se
-- replican solos); los clientes solo detectan el frenazo y piden la emboscada.
-- ---------------------------------------------------------------------------
TSS.Blocks = {}   -- [key] = {x, y, ambushed}

local function BlockKey(x, y)
    return math_floor(x) .. "_" .. math_floor(y)
end

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

local function GetRoadOrientation(cell, cx, cy)
    local xcnt, ycnt = 0, 0
    for x = cx - 20, cx + 20 do
        local sq = cell:getGridSquare(x, cy, 0)
        if sq and PVCShared.GetGroundType(sq) == "street" then xcnt = xcnt + 1 end
    end
    for y = cy - 20, cy + 20 do
        local sq = cell:getGridSquare(cx, y, 0)
        if sq and PVCShared.GetGroundType(sq) == "street" then ycnt = ycnt + 1 end
    end
    if xcnt > ycnt then
        return "construction_01_9", 0, 1   -- calle horizontal -> barricada en Y
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

local function MakeTollNote()
    if type(BanditCompatibility) ~= "table" then return nil end
    local ok, item = pcall(BanditCompatibility.InstanceItem, "Base.Notebook")
    if not ok or not item then return nil end
    pcall(item.addPage, item, 1, getText("UI_BEP_TR_NoteBody"))
    pcall(item.setName, item, getText("UI_BEP_TR_NoteTitle"))
    pcall(item.setCustomName, item, true)
    return item
end

local function SpawnLoreCorpse(cell, x, y, z)
    local square = cell:getGridSquare(x, y, z)
    if not square then return false end

    local note = MakeTollNote()

    local ok, body = pcall(function()
        local zombie = createZombie(x, y, z, nil, 0, IsoDirections.S)
        if not zombie then return nil end
        pcall(zombie.dressInRandomOutfit, zombie)
        return IsoDeadBody.new(zombie, false)
    end)

    if ok and body then
        if note then
            local inv = body:getContainer()
            if inv then inv:AddItem(note); return true end
        end
        return true
    end

    -- Degradacion: el cuaderno directo al suelo, la pista nunca se pierde.
    if note then
        pcall(square.AddWorldInventoryItem, square, note, 0.5, 0.5, 0)
        return true
    end
    return false
end

local function SpawnBurntCars(cell, cx, cy, xm, ym)
    local function tryCar(ox, oy, dir)
        local sq = cell:getGridSquare(cx + ox, cy + oy, 0)
        if not sq then return end
        pcall(addVehicleDebug, Choice(BURNT_CARS), dir, nil, sq)
    end
    local dirA = (xm == 1) and IsoDirections.N or IsoDirections.E
    tryCar(xm * 3, ym * 3, dirA)
    if ZombRand(100) < PVCShared.Spawn.BurntCarChance then
        local dirB = (xm == 1) and IsoDirections.S or IsoDirections.W
        tryCar(-xm * 3, -ym * 3, dirB)
    end
end

function TSS.CreateRoadblock(cell, cx, cy)
    local key = BlockKey(cx, cy)
    if TSS.Blocks[key] then return false end

    local sprite, xm, ym = GetRoadOrientation(cell, cx, cy)

    local pieces = 0
    for b = -4, 4, 2 do
        if PlaceObject(cell, sprite, cx + xm * b, cy + ym * b, 0) then
            pieces = pieces + 1
        end
    end
    if pieces == 0 then return false end

    pcall(SpawnBurntCars, cell, cx, cy, xm, ym)
    pcall(SpawnLoreCorpse, cell, cx, cy, 0)

    TSS.Blocks[key] = {x = cx, y = cy, ambushed = false}

    -- Avisa a los clientes para que armen su detector de frenazo.
    pcall(sendServerCommand, 'BEPSpawn', 'RoadblockAdded', {x = cx, y = cy})

    print("[TacticalSpawnServer] Bloqueo creado en " .. cx .. "," .. cy)
    return true
end

local function CountBlocks()
    local n = 0
    for _ in pairs(TSS.Blocks) do n = n + 1 end
    return n
end

local function FindStreetSpot(cell, px, py, minD, maxD, clearR, tries)
    local span = maxD - minD
    for _ = 1, tries do
        local dist = minD + ZombRand(span)
        local angle = ZombRand(360) * 0.0174533
        local cx = math_floor(px + math.cos(angle) * dist)
        local cy = math_floor(py + math.sin(angle) * dist)
        local sq = cell:getGridSquare(cx, cy, 0)
        if sq and PVCShared.GetGroundType(sq) == "street" and IsAreaClear(cell, cx, cy, clearR) then
            return cx, cy
        end
    end
    return nil
end

local function CheckRoadblockSpawn()
    local cfg = PVCShared.Spawn
    if not cfg.RoadblockEnabled then return end
    if CountBlocks() >= cfg.RoadblockMax then return end
    if ZombRand(100) >= cfg.RoadblockChance then return end

    -- respeta el mismo interruptor de sandbox que el roadblock nativo
    if SandboxVars.Bandits and SandboxVars.Bandits.General_BuildRoadblock == false then
        return
    end

    local player = PVCShared.PickPlayer()
    if not player or player:isDead() then return end

    local cell = getCell()
    if not cell then return end

    local cx, cy = FindStreetSpot(cell, player:getX(), player:getY(),
                                  cfg.RoadblockMinDist, cfg.RoadblockMaxDist,
                                  cfg.RoadblockClearR, 12)
    if not cx then return end

    local ok, err = pcall(TSS.CreateRoadblock, cell, cx, cy)
    if not ok then LogError("CreateRoadblock", err) end
end

-- ---------------------------------------------------------------------------
-- EMBOSCADA (la pide el cliente que freno)
-- ---------------------------------------------------------------------------
local function FindForestSpawn(cell, cx, cy)
    for r = 5, 9 do
        for _ = 1, 8 do
            local ang = ZombRand(360) * 0.0174533
            local x = math_floor(cx + math.cos(ang) * r)
            local y = math_floor(cy + math.sin(ang) * r)
            local sq = cell:getGridSquare(x, y, 0)
            if sq and sq:isFree(false) and PVCShared.GetGroundType(sq) == "natural" then
                return x, y
            end
        end
    end
    return nil
end

function TSS.TriggerAmbush(player, bx, by)
    local key = BlockKey(bx, by)
    local block = TSS.Blocks[key]
    -- La autoridad decide: si ya se disparo, se ignoran las peticiones
    -- repetidas (y las de otros jugadores para el mismo bloqueo).
    if not block or block.ambushed then return end
    block.ambushed = true

    local cell = getCell()
    if not cell then return end

    local sx, sy = FindForestSpawn(cell, bx, by)
    if not sx then sx, sy = bx + 5, by + 5 end

    local cfg = PVCShared.Spawn
    if ZombRand(100) < cfg.AmbushTeamPVCPct then
        local sq = cell:getGridSquare(sx, sy, 0)
        if sq then
            pcall(TSS.SpawnTeamPVC, player, sq, false)
            print("[TacticalSpawnServer] Emboscada: Team PVC cobra el peaje")
            return
        end
    end

    SpawnClanAt(player, PVCShared.AMBUSH_CID, cfg.AmbushSize, sx, sy, 0, "Bandit")
    print("[TacticalSpawnServer] Emboscada disparada en " .. sx .. "," .. sy)
end

-- ---------------------------------------------------------------------------
-- COMANDOS DE CLIENTE
-- ---------------------------------------------------------------------------
local function onClientCommand(module, command, player, args)
    if module ~= 'BEPSpawn' then return end

    if command == 'Ambush' and args and args.x and args.y then
        pcall(TSS.TriggerAmbush, player, args.x, args.y)

    elseif command == 'TeamPVCHere' and args then
        local cell = getCell()
        local sq = cell and args.x and cell:getGridSquare(args.x, args.y, args.z or 0)
        pcall(TSS.SpawnTeamPVC, player, sq or (player and player:getSquare()), args.forceChispa)

    elseif command == 'RoadblockHere' and args and args.x and args.y then
        local cell = getCell()
        if cell then pcall(TSS.CreateRoadblock, cell, args.x, args.y) end

    elseif command == 'SyncBlocks' then
        -- un cliente acaba de entrar: le mandamos los bloqueos vigentes
        for _, b in pairs(TSS.Blocks) do
            if not b.ambushed then
                pcall(sendServerCommand, player, 'BEPSpawn', 'RoadblockAdded', {x = b.x, y = b.y})
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- ARRANQUE
-- ---------------------------------------------------------------------------
local function Bootstrap()
    if type(PVCShared) ~= "table" then
        print("[TacticalSpawnServer] INACTIVO: falta PVCShared (00_TacticalShared.lua).")
        return
    end

    Events.EveryTenMinutes.Remove(CheckTeamPVCSpawn)
    Events.EveryTenMinutes.Add(CheckTeamPVCSpawn)

    Events.EveryTenMinutes.Remove(CheckRoadblockSpawn)
    Events.EveryTenMinutes.Add(CheckRoadblockSpawn)

    Events.OnClientCommand.Remove(onClientCommand)
    Events.OnClientCommand.Add(onClientCommand)

    print("[TacticalSpawnServer] v" .. TSS.VERSION .. " activo (autoridad de spawn).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then print("[TacticalSpawnServer] INACTIVO por error: " .. tostring(err)) end
end)
