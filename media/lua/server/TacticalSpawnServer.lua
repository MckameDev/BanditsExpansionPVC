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
      BEPSpawn / Fx          : efecto de mundo puntual (Fire / Explode / Smoke)
                               pedido por la IA de un cliente. El servidor fija
                               la magnitud y deduplica por posicion.
      BEPSpawn / Reinforce   : refuerzos por radio de un clan. El servidor acota
                               el tamano y deduplica por clan.
      BEPSpawn / Ambush      : un cliente freno o choco contra un bloqueo y
                               pide la emboscada (la deteccion del frenazo es
                               inherentemente local: depende del vehiculo de
                               ESE jugador).
      BEPSpawn / TeamPVCHere : spawn manual desde el menu de debug (admin en MP).
      BEPSpawn / RoadblockHere: bloqueo forzado desde el menu de debug (idem).
      BEPSpawn / SyncBlocks  : un cliente que entra pide los bloqueos vigentes.

    TODOS pasan por la escalera de validacion (tipos -> antiflood -> proximidad
    -> privilegio -> deduplicacion). Ver la seccion "VALIDACION DE PETICIONES".
============================================================================]]

if isClient() then return end   -- un cliente conectado nunca ejecuta esto

if TacticalSpawnServer then return end -- guarda anti doble carga
TacticalSpawnServer = {}
local TSS = TacticalSpawnServer
TSS.VERSION = "1.2.0"

local ZombRand       = ZombRand
local math_floor     = math.floor
local pcall          = pcall
local type           = type
local pairs          = pairs
local tostring       = tostring
local tonumber       = tonumber
local getTimestampMs = getTimestampMs
local getWorld       = getWorld

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

-- ---------------------------------------------------------------------------
-- ESTADO PERSISTENTE DEL DEBUT
-- Vive en ModData global, o sea que se guarda con la partida y sobrevive a
-- recargas. Lo escribe SOLO este archivo, que ya es la unica autoridad de
-- spawn en los tres modos, asi que no hay carrera posible.
-- No se llama a ModData.transmit(): ningun cliente lee estas claves (el debut
-- se decide y se ejecuta entero aqui), replicarlas seria trafico para nada.
-- ---------------------------------------------------------------------------
TSS.MODDATA_KEY = "BEP_TeamPVCSpawn"

-- baselineDay: edad del mundo EN EL MOMENTO en que el mod se activo. Contar
-- desde aqui (y no desde el dia 0 absoluto) es lo que hace que anadir el mod a
-- una partida vieja no deje el debut ya caducado antes de empezar.
function TSS.GetSpawnState()
    local data = ModData.getOrCreate(TSS.MODDATA_KEY)
    if data.baselineDay == nil then
        local cfg = PVCShared.Spawn
        local span = cfg.DebutMaxDay - cfg.DebutMinDay
        data.baselineDay = PVCShared.GetWorldAgeDays()
        data.debutDay    = cfg.DebutMinDay + ((span > 0) and ZombRandFloat(0, span) or 0)
        data.debuted     = false
        print(string.format(
            "[TacticalSpawnServer] Debut del Team PVC programado para el dia %.1f del mundo " ..
            "(mod activado en el dia %.1f, ventana +%s a +%s).",
            data.baselineDay + data.debutDay, data.baselineDay,
            tostring(cfg.DebutMinDay), tostring(cfg.DebutMaxDay)))
    end
    return data
end

local function CheckTeamPVCSpawn()
    local cfg = PVCShared.Spawn

    local player = PVCShared.PickPlayer()
    if not player or player:isDead() then return end

    -- La ventana se mide sobre la EDAD DEL MUNDO, no sobre las horas del
    -- personaje. Es lo que pide "los 15 dias de vida de la partida o servidor":
    -- un unico reloj para todos los conectados, y por tanto UN debut por mundo
    -- en vez de uno por jugador.
    -- Contrapartida asumida en dedicado: quien entre pasada la ventana no vive
    -- el debut, solo los spawns normales. La alternativa (reloj por jugador)
    -- haria aparecer al escuadron una vez por cada recien llegado, que para un
    -- clan unico y con nombre propio se siente peor.
    local okState, state = pcall(TSS.GetSpawnState)
    if not okState then
        LogError("GetSpawnState", state)
        return
    end

    local elapsed = PVCShared.GetWorldAgeDays() - state.baselineDay

    -- Se acabo el plazo: este spawn ya no se sortea, se fuerza.
    local force = cfg.DebutEnabled and not state.debuted and elapsed >= state.debutDay

    if not force then
        if elapsed < cfg.DayStart or elapsed > cfg.DayEnd then return end

        local multiplier = (SandboxVars.Bandits and SandboxVars.Bandits.General_SpawnMultiplier) or 1
        local chance = cfg.TeamPVCChance * multiplier / 6
        if ZombRandFloat(0, 100) >= chance then return end
    end

    local square = PickNaturalSquare(player)
    if not square then return end

    local ok, res = pcall(TSS.SpawnTeamPVC, player, square, false)
    if not ok then
        LogError("SpawnTeamPVC", res)
        return
    end

    -- El debut se marca SOLO si el spawn de verdad salio. Si fallo (mod base no
    -- disponible, casilla invalida, chunk sin cargar...) sigue pendiente y se
    -- reintenta en la siguiente pasada -- que es justo lo que "garantizado"
    -- tiene que significar. Un spawn natural temprano tambien cuenta como
    -- debut: ya lo viste, no hace falta forzar otro.
    if res and not state.debuted then
        state.debuted = true
        print(string.format(
            "[TacticalSpawnServer] Debut del Team PVC completado en el dia +%.1f desde la activacion del mod.",
            elapsed))
    end
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
-- EFECTOS DE MUNDO (fuego, explosion, humo)  --  AUTORIDAD UNICA
-- ---------------------------------------------------------------------------
-- POR QUE ESTAN AQUI Y NO EN client/
-- El tick de IA corre en TODOS los clientes que simulan al mismo bandido, asi
-- que "que lo haga solo la autoridad local" (PVCCore.IsWorldAuthority) tiene
-- dos problemas: en un DEDICADO ningun cliente es autoridad -> el efecto no
-- ocurre para nadie; y en ANFITRION el anfitrion lo hacia en local mientras el
-- servidor interno tambien podia hacerlo -> dos incendios.
-- Con este handler hay exactamente UN camino en los tres modos: el cliente
-- pide, el servidor ejecuta y deduplica. En single player el server/ vive en
-- este mismo proceso, asi que PVCCore.RequestFx llama directo a TSS.ApplyFx
-- sin pasar por la red (ver 00_TacticalCore.lua).
--
-- La MAGNITUD del efecto la fija el servidor, nunca el paquete: un cliente
-- modificado no puede pedir una explosion de potencia 10000.
-- ---------------------------------------------------------------------------
TSS.FxLimits = {
    FireIntensity = 60,
    FireFuel      = 300,
    ExplodePower  = 100,
    SmokeIntensity= 100,
    SmokeFuel     = 300,
    MaxRange      = 60,    -- casillas: radio maximo que un cliente puede pedir tocar
    DedupeMs      = 2500,  -- misma posicion + mismo efecto dentro de esta ventana = una vez
    CooldownMs    = 500,   -- antiflood por jugador y comando
    ClanDedupeMs  = 60000, -- refuerzos: una llamada por clan en esta ventana
    MaxSquadSize  = 4,
}

local FX = {
    Fire = function(cell, square)
        return IsoFireManager.StartFire(cell, square, true,
                                        TSS.FxLimits.FireIntensity, TSS.FxLimits.FireFuel)
    end,
    Explode = function(cell, square)
        -- OJO: el metodo real es en MINUSCULA (IsoFireManager.explode).
        return IsoFireManager.explode(cell, square, TSS.FxLimits.ExplodePower)
    end,
    Smoke = function(cell, square)
        return IsoFireManager.StartSmoke(cell, square, true,
                                         TSS.FxLimits.SmokeIntensity, TSS.FxLimits.SmokeFuel)
    end,
}

-- Los efectos con fuego respetan la opcion del servidor: si el admin puso
-- NoFire=true en el .ini, no hay mod que valga. getServerOptions() solo existe
-- en multijugador, de ahi el pcall.
local FX_IS_FIRE = {Fire = true, Explode = true}

local function ServerFireDisabled()
    local ok, opts = pcall(getServerOptions)
    if not ok or not opts then return false end
    local okFire, noFire = pcall(opts.getBoolean, opts, "NoFire")
    return okFire and noFire == true
end

-- Deduplicacion por clave + ventana. Tabla plana; se purga en el barrido lento.
local fxRecent = {}

local function FxDedupe(key, windowMs)
    local now = getTimestampMs()
    local last = fxRecent[key]
    if last and (now - last) < windowMs then return false end
    fxRecent[key] = now
    return true
end

-- Punto de entrada autoritativo. Lo llaman el handler de red (MP) y
-- directamente PVCCore.RequestFx en single player.
function TSS.ApplyFx(kind, x, y, z)
    local fn = FX[kind]
    if not fn then
        LogError("ApplyFx", "efecto desconocido: " .. tostring(kind))
        return false
    end
    if type(x) ~= "number" or type(y) ~= "number" then return false end

    if FX_IS_FIRE[kind] and ServerFireDisabled() then return false end

    if not FxDedupe(kind .. "_" .. math_floor(x) .. "_" .. math_floor(y), TSS.FxLimits.DedupeMs) then
        return false
    end

    local cell = getCell()
    if not cell then return false end
    local square = cell:getGridSquare(math_floor(x), math_floor(y), math_floor(z or 0))
    if not square then return false end

    local ok, err = pcall(fn, cell, square)
    if not ok then LogError("ApplyFx/" .. tostring(kind), err) end
    return ok
end

-- Refuerzos por radio (#26 de TacticalQuickWins). El cliente pide; el servidor
-- decide, acota el tamano y deduplica por clan: cuatro clientes simulando al
-- mismo bandido no traen cuatro escuadrones.
function TSS.ApplyReinforce(player, cid, size, x, y, z)
    if type(cid) ~= "string" then return false end
    -- Team PVC no se convoca como refuerzo de nadie: es un clan unico con su
    -- propio planificador (y seria el vector obvio de abuso).
    if cid == PVCShared.CLAN_ID then return false end
    if type(x) ~= "number" or type(y) ~= "number" then return false end

    size = math_floor(tonumber(size) or 0)
    if size < 1 then return false end
    if size > TSS.FxLimits.MaxSquadSize then size = TSS.FxLimits.MaxSquadSize end

    if not FxDedupe("clan_" .. cid, TSS.FxLimits.ClanDedupeMs) then return false end

    local target = player or PVCShared.PickPlayer()
    if not target then return false end

    local res = SpawnClanAt(target, cid, size, math_floor(x), math_floor(y), math_floor(z or 0), "Bandit")
    if res then
        print("[TacticalSpawnServer] Refuerzos del clan " .. cid .. ": " .. size .. " integrantes")
    end
    return res
end

-- ---------------------------------------------------------------------------
-- VALIDACION DE PETICIONES DE CLIENTE
-- Todo paquete es hostil hasta probar lo contrario: un cliente modificado
-- manda lo que quiere, cuando quiere. Orden de comprobacion:
--   1. tipos      -> nada de strings donde se esperan coordenadas
--   2. antiflood  -> por jugador y comando
--   3. proximidad -> solo puede pedir cosas cerca de si mismo
--   4. privilegio -> los comandos de debug, solo admin en multijugador
-- Al rechazar se sale en silencio (salvo debug): un atacante no debe recibir
-- feedback util.
-- ---------------------------------------------------------------------------
local netLimit = {}   -- [username][command] = timestamp del ultimo aceptado

local function PlayerName(player)
    if not player then return "?" end
    local ok, name = pcall(player.getUsername, player)
    if ok and type(name) == "string" then return name end
    return "?"
end

local function PassRateLimit(player, command, cooldownMs)
    local name = PlayerName(player)
    local perPlayer = netLimit[name]
    if not perPlayer then
        perPlayer = {}
        netLimit[name] = perPlayer
    end
    local now  = getTimestampMs()
    local last = perPlayer[command]
    if last and (now - last) < (cooldownMs or TSS.FxLimits.CooldownMs) then return false end
    perPlayer[command] = now
    return true
end

local function NearPlayer(player, x, y, maxRange)
    if not player or type(x) ~= "number" or type(y) ~= "number" then return false end
    local ok, px, py = pcall(function() return player:getX(), player:getY() end)
    if not ok then return false end
    local dx, dy = px - x, py - y
    local r = maxRange or TSS.FxLimits.MaxRange
    return (dx * dx + dy * dy) <= (r * r)
end

local function IsMultiplayer()
    local world = getWorld()
    return world ~= nil and world:getGameMode() == "Multiplayer"
end

-- Los comandos del menu -debug (spawn manual del escuadron, bloqueo forzado)
-- crean contenido de la nada: en un servidor publico son un vector de griefing.
-- En partida individual no hay nada que proteger.
local function IsPrivileged(player)
    if not IsMultiplayer() then return true end
    if not PVCShared.Spawn.DebugSpawnRequiresAdmin then return true end
    if not player then return false end
    local ok, level = pcall(player.getAccessLevel, player)
    if not ok or type(level) ~= "string" then return false end
    level = level:lower()
    return level == "admin" or level == "moderator" or level == "gm" or level == "overseer"
end

-- Purga de las tablas de control: crecen con una entrada por jugador/posicion y
-- no deben acumularse durante toda la vida del servidor.
local function PurgeNetTables()
    local now = getTimestampMs()
    for key, ms in pairs(fxRecent) do
        if (now - ms) > TSS.FxLimits.ClanDedupeMs then fxRecent[key] = nil end
    end
    for name, cmds in pairs(netLimit) do
        local empty = true
        for cmd, ms in pairs(cmds) do
            if (now - ms) > 60000 then cmds[cmd] = nil else empty = false end
        end
        if empty then netLimit[name] = nil end
    end
end

-- ---------------------------------------------------------------------------
-- COMANDOS DE CLIENTE
-- ---------------------------------------------------------------------------
local function onClientCommand(module, command, player, args)
    if module ~= 'BEPSpawn' then return end
    if not player then return end

    if command == 'Fx' and args then
        if not PassRateLimit(player, 'Fx') then return end
        if not NearPlayer(player, args.x, args.y) then return end
        pcall(TSS.ApplyFx, args.kind, args.x, args.y, args.z)

    elseif command == 'Reinforce' and args then
        if not PassRateLimit(player, 'Reinforce', 2000) then return end
        -- el punto de llegada esta a ~25 casillas del bandido, que a su vez
        -- puede estar a 45 del jugador: margen generoso pero acotado.
        if not NearPlayer(player, args.x, args.y, 120) then return end
        pcall(TSS.ApplyReinforce, player, args.cid, args.size, args.x, args.y, args.z)

    elseif command == 'Ambush' then
        if not args or type(args.x) ~= "number" or type(args.y) ~= "number" then return end
        if not PassRateLimit(player, 'Ambush', 1000) then return end
        if not NearPlayer(player, args.x, args.y, 100) then return end
        pcall(TSS.TriggerAmbush, player, args.x, args.y)

    elseif command == 'TeamPVCHere' then
        if not args then return end
        if not PassRateLimit(player, 'TeamPVCHere', 5000) then return end
        if not IsPrivileged(player) then
            print("[TacticalSpawnServer] Spawn de debug rechazado para " ..
                  PlayerName(player) .. " (requiere admin; ver PVCShared.Spawn.DebugSpawnRequiresAdmin).")
            return
        end
        local sq
        if type(args.x) == "number" and type(args.y) == "number" and
           NearPlayer(player, args.x, args.y, 200) then
            local cell = getCell()
            sq = cell and cell:getGridSquare(math_floor(args.x), math_floor(args.y), math_floor(args.z or 0))
        end
        pcall(TSS.SpawnTeamPVC, player, sq or player:getSquare(), args.forceChispa == true)

    elseif command == 'RoadblockHere' then
        if not args or type(args.x) ~= "number" or type(args.y) ~= "number" then return end
        if not PassRateLimit(player, 'RoadblockHere', 5000) then return end
        if not IsPrivileged(player) then return end
        if not NearPlayer(player, args.x, args.y, 400) then return end
        local cell = getCell()
        if cell then pcall(TSS.CreateRoadblock, cell, math_floor(args.x), math_floor(args.y)) end

    elseif command == 'SyncBlocks' then
        if not PassRateLimit(player, 'SyncBlocks', 5000) then return end
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

    -- Se sella la linea base AHORA, no en la primera pasada del planificador:
    -- asi el dia de debut queda anclado al momento real de activacion del mod
    -- y se registra en el log de arranque. Va en su propio pcall porque un
    -- fallo aqui no debe impedir que se registren los eventos (GetSpawnState
    -- se vuelve a intentar sola en cada pasada).
    local okState, errState = pcall(TSS.GetSpawnState)
    if not okState then LogError("GetSpawnState (bootstrap)", errState) end

    Events.EveryTenMinutes.Remove(CheckTeamPVCSpawn)
    Events.EveryTenMinutes.Add(CheckTeamPVCSpawn)

    Events.EveryTenMinutes.Remove(CheckRoadblockSpawn)
    Events.EveryTenMinutes.Add(CheckRoadblockSpawn)

    -- Purga de las tablas de antiflood/deduplicacion (frecuencia baja: son
    -- tablas chicas, pero no deben crecer durante meses de uptime).
    Events.EveryTenMinutes.Remove(PurgeNetTables)
    Events.EveryTenMinutes.Add(PurgeNetTables)

    Events.OnClientCommand.Remove(onClientCommand)
    Events.OnClientCommand.Add(onClientCommand)

    print("[TacticalSpawnServer] v" .. TSS.VERSION .. " activo (autoridad de spawn).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then print("[TacticalSpawnServer] INACTIVO por error: " .. tostring(err)) end
end)
