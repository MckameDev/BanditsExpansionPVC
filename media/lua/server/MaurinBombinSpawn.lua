--[[==========================================================================
    MaurinBombinSpawn.lua
    Ecosistema "MaurinBombin Market" - FASE 2 de 3
    SPAWN HIBRIDO del escuadron mercante + reclamo/etiquetado de sus NPC

    ---------------------------------------------------------------------------
    POR QUE EL SPAWN ESTA EN server/ Y NO EN client/
    ---------------------------------------------------------------------------
    El brief de la Fase 2 pedia todo en client/, pero el spawn no puede vivir
    ahi: un servidor DEDICADO no ejecuta media/lua/client/ (solo lo carga para
    el checksum). Si el planificador estuviera en el cliente, en dedicado no
    aparaceria ningun mercado, y en modo Anfitrion podrian aparecer VARIOS (uno
    por cliente que lo sortee). Es exactamente el reparto que ya documenta este
    submod: "el SERVIDOR crea, los CLIENTES interpretan"
    (ver la cabecera de TacticalSpawnServer.lua).

    La IA propiamente dicha -- inmovilidad, hack de ruido, pacto de no
    agresion, municion infinita -- SI esta en client/MaurinBombinAI.lua, porque
    el tick de IA del mod base es client-side.

    ---------------------------------------------------------------------------
    EL PROBLEMA DEL "RECLAMO" (por que hay una segunda pasada)
    ---------------------------------------------------------------------------
    BanditServer.Spawner.Clan() no devuelve los zombis que crea. Y la Fase 1
    necesita dos cosas que solo puede dar el servidor:
      1. la marca persistente en el modData del NPC (MBM.TagNPC), que es lo
         unico que sobrevive a que Bandits2 borre el brain al morir; y
      2. los uid del escuadron, para validar los avisos de muerte por red.
    Por eso, tras spawnear se hace una pasada de RECLAMO: se barren los zombis
    cargados cerca del punto, se identifican por brain.cid y se etiquetan. Si
    en ese instante el chunk aun no los materializo, se reintenta.

    ---------------------------------------------------------------------------
    RENDIMIENTO
    ---------------------------------------------------------------------------
    Planificador en EveryTenMinutes; reclamo en EveryOneMinute y SOLO mientras
    hay un reclamo pendiente (sale en la primera linea el 99.9% del tiempo).
    El estado del reclamo es una tabla preasignada: no se instancia nada por
    tick. El barrido de zombis tiene tope duro de iteraciones.
============================================================================]]

if isClient() then return end             -- un cliente conectado nunca ejecuta esto
if MaurinBombinSpawn then return end       -- guarda anti doble carga

MaurinBombinSpawn = {}
local MBMSpawn = MaurinBombinSpawn
local MBM      = MaurinBombin

MBMSpawn.VERSION = "1.0.0"

local ZombRand      = ZombRand
local ZombRandFloat = ZombRandFloat
local math_floor    = math.floor
local math_cos      = math.cos
local math_sin      = math.sin
local math_pi       = math.pi
local pcall         = pcall
local type          = type
local tostring      = tostring
local getCell       = getCell

-- ---------------------------------------------------------------------------
-- CONFIGURACION
-- ---------------------------------------------------------------------------
MBMSpawn.Config = {
    SquadSize        = 3,     -- 1 mercader + 2 guardias
    SquadHealth      = 50.0,  -- vida del escuadron (autoritativa: ver TryClaim)

    -- Puestos FIJOS. Se usan cuando un jugador se acerca lo suficiente como
    -- para que el chunk este cargado (si no, el spawner del mod base no puede
    -- materializar a nadie).
    ActivationRange  = 90,    -- casillas jugador <-> punto fijo

    -- Modo DINAMICO: si nadie pasa cerca de un puesto fijo durante este tiempo,
    -- el mercado se monta cerca de quien este jugando.
    DynamicAfterHours = 36,   -- horas de mundo sin mercado antes de improvisar
    DynamicMinDist    = 35,   -- distancia al jugador para el puesto improvisado
    DynamicMaxDist    = 70,
    DynamicTries      = 12,   -- intentos de encontrar un sitio despejado
    ClearRadius       = 2,    -- radio que debe estar libre alrededor del puesto

    -- RURAL + CARRETERA. Ver la nota larga en "FILTRO RURAL" mas abajo.
    RuralCheckRadius   = 10,   -- radio (casillas) del muestreo de densidad
    RuralMaxBuildings  = 25,   -- techo de casillas con edificio en ese radio
    RoadCheckRadius    = 20,   -- alcance del rastreo de asfalto (cruz, no caja)

    -- Anillo de busqueda de casilla libre. El modo fijo usa uno mas grande
    -- porque el punto de partida ya esta pensado como "afueras"; el dinamico
    -- necesita mas margen porque el ancla es un angulo al azar desde el
    -- jugador y puede caer en cualquier tipo de terreno.
    FixedRing        = 8,
    DynamicRing      = 6,

    -- Reclamo
    ClaimRadius      = 14,    -- casillas alrededor del punto de spawn
    ClaimMaxTries    = 10,    -- reintentos (1 por minuto de mundo)
    ScanCap          = 800,   -- tope duro de zombis inspeccionados por pasada

    Debug            = false,
}

-- ---------------------------------------------------------------------------
-- PUESTOS FIJOS
-- Afueras / zonas abiertas de tres ciudades vanilla. Son APROXIMACIONES a
-- nivel de manzana: no se puede garantizar por codigo que una casilla concreta
-- del mapa vanilla siga despejada tras cualquier parcheo del juego o de otros
-- mods, asi que cada punto pasa igualmente por el filtro de despeje
-- (FindClearSquare) y, si no da, se cae al modo dinamico. Es la parte
-- "hibrida" del spawn.
-- ---------------------------------------------------------------------------
MBMSpawn.FixedSpots = {
    {x = 10620, y = 9650, z = 0, name = "afueras de Muldraugh"},
    {x = 8300,  y = 11700, z = 0, name = "afueras de Rosewood"},
    {x = 11550, y = 6800,  z = 0, name = "afueras de West Point"},
}

local function Log(msg)
    if MBMSpawn.Config.Debug then print("[MaurinBombinSpawn] " .. tostring(msg)) end
end

-- ---------------------------------------------------------------------------
-- SELECCION DE CASILLA
-- ---------------------------------------------------------------------------

-- Una casilla sirve si existe, esta libre, es exterior y no tiene un vehiculo
-- encima. "Exterior" importa: un mercader dentro de una casa quedaria detras
-- de una pared y el jugador no podria ni verlo ni hacerle clic derecho.
local function IsUsableSquare(square)
    if not square then return false end

    local okFree, free = pcall(square.isFree, square, false)
    if not okFree or not free then return false end

    local okOut, outside = pcall(square.isOutside, square)
    if okOut and outside == false then return false end

    local okVeh, veh = pcall(square.getVehicleContainer, square)
    if okVeh and veh then return false end

    return true
end

-- Comprueba que el entorno inmediato tambien este despejado: el escuadron son
-- tres cuerpos, no uno.
local function IsAreaClear(cell, cx, cy, cz, r)
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            local sq = cell:getGridSquare(x, y, cz)
            if not IsUsableSquare(sq) then return false end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- FILTRO RURAL
-- ---------------------------------------------------------------------------
-- El puesto tiene que sentirse "afueras junto a la carretera", no "puesto de
-- mercado en plena plaza del pueblo": en el centro de una ciudad, tres NPC
-- fijos con dialogo y disparos ocasionales llaman muchisima atencion (y en la
-- practica, a mas zombis del vecindario).
--
-- No hay ningun dato de "esto es zona urbana" expuesto a Lua (el juego no
-- entrega poligonos de ciudad), asi que se aproxima con dos medidas baratas
-- y ya usadas en otras partes de este submod:
--
--   1. DENSIDAD DE EDIFICIOS: si en un radio corto hay muchas casillas con
--      square:getBuilding() ~= nil, es un bloque urbano solido (casas pegadas
--      unas a otras). Las afueras tienen huecos: campo, parcelas sueltas,
--      algun galpon aislado.
--   2. CERCANIA A ASFALTO: sin esto, "rural" tambien aceptaria un descampado
--      en medio de la nada sin ninguna carretera cerca, que no es lo que se
--      pidio ("cerca de las carreteras principales"). Se reutiliza
--      PVCShared.GetGroundType, el mismo detector que usa el peaje de
--      Evaristo, en un rastreo en cruz (los ejes X e Y por separado) igual
--      que TacticalSpawnServer.GetRoadOrientation: barato, O(radio) y no
--      O(radio^2).
--
-- Las dos comprobaciones son mas caras que IsUsableSquare/IsAreaClear (que
-- son ya establecidas), asi que se corren DESPUES de esas, solo sobre un
-- candidato que ya paso los filtros baratos -- nunca sobre cada casilla del
-- anillo. A la cadencia de este planificador (EveryTenMinutes) el coste es
-- irrelevante de cualquier forma.
-- ---------------------------------------------------------------------------

local function CountBuildingsNear(cell, cx, cy, cz, r, cap)
    local count = 0
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            local sq = cell:getGridSquare(x, y, cz)
            if sq then
                local okB, building = pcall(sq.getBuilding, sq)
                if okB and building then
                    count = count + 1
                    if count > cap then return count end   -- salida temprana
                end
            end
        end
    end
    return count
end

local function HasRoadNearby(cell, cx, cy, cz, r)
    if type(PVCShared) ~= "table" or type(PVCShared.GetGroundType) ~= "function" then
        return true   -- sin el detector no se puede exigir carretera: no bloquea
    end
    for x = cx - r, cx + r do
        local sq = cell:getGridSquare(x, cy, cz)
        if sq then
            local ok, ground = pcall(PVCShared.GetGroundType, sq)
            if ok and ground == "street" then return true end
        end
    end
    for y = cy - r, cy + r do
        local sq = cell:getGridSquare(cx, y, cz)
        if sq then
            local ok, ground = pcall(PVCShared.GetGroundType, sq)
            if ok and ground == "street" then return true end
        end
    end
    return false
end

local function IsRuralRoadside(cell, cx, cy, cz)
    local cfg = MBMSpawn.Config
    if not HasRoadNearby(cell, cx, cy, cz, cfg.RoadCheckRadius) then return false end
    local buildings = CountBuildingsNear(cell, cx, cy, cz, cfg.RuralCheckRadius, cfg.RuralMaxBuildings)
    return buildings <= cfg.RuralMaxBuildings
end

-- Busca la casilla utilizable mas cercana al punto pedido, en anillos
-- crecientes. Devuelve nil si no hay nada aprovechable (chunk sin cargar,
-- edificio encima, demasiado urbano, sin carretera cerca, etc.).
local function FindClearSquare(x, y, z, maxRing)
    local cell = getCell()
    if not cell then return nil end

    local cfg = MBMSpawn.Config
    for ring = 0, (maxRing or 6) do
        for dx = -ring, ring do
            for dy = -ring, ring do
                -- solo el borde del anillo: el interior ya se probo
                if ring == 0 or dx == -ring or dx == ring or dy == -ring or dy == ring then
                    local sx, sy = math_floor(x) + dx, math_floor(y) + dy
                    local sz = math_floor(z or 0)
                    local sq = cell:getGridSquare(sx, sy, sz)
                    if IsUsableSquare(sq) and IsAreaClear(cell, sx, sy, sz, cfg.ClearRadius)
                       and IsRuralRoadside(cell, sx, sy, sz) then
                        return sq
                    end
                end
            end
        end
    end
    return nil
end

-- Puesto improvisado cerca de un jugador (modo dinamico).
local function FindDynamicSquare(player)
    local cfg = MBMSpawn.Config
    for _ = 1, cfg.DynamicTries do
        local dist  = cfg.DynamicMinDist + ZombRand(cfg.DynamicMaxDist - cfg.DynamicMinDist)
        local angle = ZombRandFloat(0, 2 * math_pi)
        local x = player:getX() + math_cos(angle) * dist
        local y = player:getY() + math_sin(angle) * dist
        local sq = FindClearSquare(x, y, player:getZ(), cfg.DynamicRing)
        if sq then return sq end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- SPAWN
-- Mismo primitivo que usa TacticalSpawnServer: se llama DIRECTO al spawner del
-- mod base, sin pasar por la red, porque aqui ya somos la autoridad.
-- ---------------------------------------------------------------------------
local function SpawnSquadAt(player, square)
    if type(BanditServer) ~= "table" or type(BanditServer.Spawner) ~= "table"
       or type(BanditServer.Spawner.Clan) ~= "function" then
        MBM.LogError("SpawnSquadAt", "BanditServer.Spawner.Clan no disponible")
        return false
    end

    -- OJO CON EL PROGRAMA: "Bandit" (ZPBandit) es la IA de bandido completa y
    -- su etapa Prepare llama Bandit.ForceStationary(bandit, false), asi que el
    -- escuadron salia corriendo a buscar bases y perseguir gente. Usamos el
    -- nuestro, que no devuelve tareas nunca y mantiene la inmovilidad.
    -- Ver media/lua/shared/ZombiePrograms/ZPMaurinBombin.lua.
    local ok, err = pcall(BanditServer.Spawner.Clan, player, {
        cid     = MBM.CLAN_ID,
        size    = MBMSpawn.Config.SquadSize,
        program = "MaurinBombin",
        x       = square:getX(), y = square:getY(), z = square:getZ(),
    })
    if not ok then
        MBM.LogError("BanditServer.Spawner.Clan", err)
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- RECLAMO / ETIQUETADO
-- Estado preasignado: el handler de EveryOneMinute no instancia nada mientras
-- no haya un reclamo en curso.
-- ---------------------------------------------------------------------------
local claim = {pending = false, x = 0, y = 0, z = 0, tries = 0, spot = ""}

local function RoleForBid(bid)
    if bid == MBM.MERCHANT_BID then return MBM.ROLE_MERCHANT end
    if bid == MBM.GUARD_A_BID or bid == MBM.GUARD_B_BID then return MBM.ROLE_GUARD end
    return nil
end

-- Barre los zombis cargados y etiqueta a los del clan que esten cerca del
-- punto. Devuelve la tabla de miembros (uid -> rol) si encontro al mercader.
local function TryClaim()
    local cell = getCell()
    if not cell then return nil end

    local okList, list = pcall(cell.getZombieList, cell)
    if not okList or not list then return nil end

    local cfg     = MBMSpawn.Config
    local r2      = cfg.ClaimRadius * cfg.ClaimRadius
    local members = nil
    local merchantFound = false
    -- Posicion REAL del mercader. El puesto se registra ahi y no en la casilla
    -- de spawn: el escuadron se reparte por las casillas libres del entorno, asi
    -- que el mercader puede acabar a varias casillas del punto pedido. Como la
    -- comprobacion de proximidad de las compras se hace contra este punto,
    -- usar la casilla de spawn hacia que el servidor rechazara con TOO_FAR
    -- compras hechas literalmente delante del mercader.
    local mx, my, mz = nil, nil, nil

    local n = list:size()
    if n > cfg.ScanCap then n = cfg.ScanCap end

    for i = 0, n - 1 do
        local z = list:get(i)
        if z then
            local dx, dy = z:getX() - claim.x, z:getY() - claim.y
            if (dx * dx + dy * dy) <= r2 then
                -- Se lee el brain del modData directamente y no con
                -- BanditBrain.Get: esa funcion vive en client/ del mod base y
                -- en un dedicado no existe.
                local okMd, md = pcall(z.getModData, z)
                local brain = okMd and md and md.brain
                if type(brain) == "table" and brain.cid == MBM.CLAN_ID then
                    local role = RoleForBid(brain.bid)
                    if role then
                        local uid = tostring(brain.id)
                        MBM.TagNPC(z, role, uid)

                        -- VIDA: se fija AQUI, en el servidor, y no solo en el
                        -- primer tick de la IA de cliente. En multijugador la
                        -- salud de un zombi es autoritativa del servidor: un
                        -- setHealth hecho en un cliente no viaja, asi que si
                        -- dependieramos solo de la IA, en un dedicado el
                        -- escuadron conservaria la vida que le puso el spawner.
                        pcall(z.setHealth, z, MBMSpawn.Config.SquadHealth)

                        -- El pacto de no agresion se siembra ya aqui (el brain
                        -- se replica a todos los clientes); la IA de cliente lo
                        -- reafirma en cada tick.
                        -- Solo el mercader deja de ser hostil en general: los
                        -- guardias tienen que poder tirotear zombis. Lo que se
                        -- apaga para todos es la hostilidad hacia el JUGADOR.
                        brain.hostileP = false
                        if role == MBM.ROLE_MERCHANT then brain.hostile = false end

                        if role == MBM.ROLE_MERCHANT then
                            merchantFound = true
                            mx, my, mz = z:getX(), z:getY(), z:getZ()
                            -- "Ignorado por los zombis": se aplica en el lado
                            -- que simula a los zombis, o sea aqui.
                            MBM.MakeIgnoredByZombies(z)
                        end

                        members = members or {}
                        members[uid] = role
                    end
                end
            end
        end
    end

    if not merchantFound then return nil end
    return members, mx, my, mz
end

local function OnEveryOneMinute()
    if not claim.pending then return end   -- caso normal: sale sin tocar nada

    local ok, err = pcall(function()
        claim.tries = claim.tries + 1

        local members, mx, my, mz = TryClaim()
        if members then
            claim.pending = false
            -- Se registra la casilla del MERCADER (la de spawn solo como
            -- respaldo): es el punto contra el que se mide la proximidad de las
            -- compras y el que canta la emisora.
            local rx = mx or claim.x
            local ry = my or claim.y
            local rz = mz or claim.z
            MaurinBombinServer.RegisterMarket(rx, ry, rz, members)
            print("[MaurinBombinSpawn] Escuadron reclamado en " .. claim.spot ..
                  " (mercader en " .. math_floor(rx) .. "," .. math_floor(ry) .. ")")
            return
        end

        if claim.tries >= MBMSpawn.Config.ClaimMaxTries then
            claim.pending = false
            -- No se pudo identificar al mercader: el mercado NO se registra, o
            -- sea que IsMarketAllowed sigue en true y el planificador lo
            -- reintentara mas adelante. Preferible a registrar un mercado
            -- fantasma con el que nadie puede comerciar.
            print("[MaurinBombinSpawn] AVISO: no se pudo reclamar el escuadron en " ..
                  claim.spot .. "; se reintentara el spawn mas adelante.")
        end
    end)
    if not ok then
        claim.pending = false
        MBM.LogError("OnEveryOneMinute/claim", err)
    end
end

-- ---------------------------------------------------------------------------
-- PLANIFICADOR
-- ---------------------------------------------------------------------------

-- Punto de entrada unico del spawn (lo usan el planificador y el comando de
-- debug). Deja el reclamo armado.
function MBMSpawn.SpawnMarket(player, square, spotName)
    if not player or not square then return false end
    if claim.pending then return false end          -- ya hay uno a medio nacer

    if not SpawnSquadAt(player, square) then return false end

    claim.pending = true
    claim.x, claim.y, claim.z = square:getX(), square:getY(), square:getZ()
    claim.tries = 0
    claim.spot  = spotName or "puesto improvisado"

    print("[MaurinBombinSpawn] MaurinBombin Market montandose en " .. claim.spot ..
          " (" .. claim.x .. "," .. claim.y .. ")")
    return true
end

local function CheckSpawn()
    local ok, err = pcall(function()
        if claim.pending then return end
        if type(MaurinBombinServer) ~= "table" then return end
        if not MaurinBombinServer.IsMarketAllowed() then return end

        local players = PVCShared.GetPlayers()
        if not players or players:size() == 0 then return end

        local cfg = MBMSpawn.Config

        -- 1) PUESTOS FIJOS: gana el primero que tenga a un jugador cerca (el
        --    chunk tiene que estar cargado para que el spawner materialice).
        for i = 1, #MBMSpawn.FixedSpots do
            local spot = MBMSpawn.FixedSpots[i]
            for p = 0, players:size() - 1 do
                local player = players:get(p)
                if player and not player:isDead() then
                    local dx, dy = player:getX() - spot.x, player:getY() - spot.y
                    if (dx * dx + dy * dy) <= (cfg.ActivationRange * cfg.ActivationRange) then
                        local square = FindClearSquare(spot.x, spot.y, spot.z, cfg.FixedRing)
                        if square then
                            MBMSpawn.SpawnMarket(player, square, spot.name)
                            return
                        end
                        Log("Puesto fijo '" .. spot.name .. "' sin casilla utilizable")
                    end
                end
            end
        end

        -- 2) MODO DINAMICO: nadie se acerco a los puestos fijos en un buen
        --    rato -> el mercado se monta cerca de quien este jugando. El
        --    contador vive en el ModData del mercado, o sea que sobrevive a
        --    reinicios del servidor.
        local data = MaurinBombinServer.EnsureData()
        if type(data.lastMarketHour) ~= "number" then
            data.lastMarketHour = MBM.NowHours()
            return
        end
        if (MBM.NowHours() - data.lastMarketHour) < cfg.DynamicAfterHours then return end

        local player = PVCShared.PickPlayer()
        if not player or player:isDead() then return end

        local square = FindDynamicSquare(player)
        if not square then
            Log("Modo dinamico: sin sitio despejado cerca del jugador")
            return
        end

        MBMSpawn.SpawnMarket(player, square, "puesto improvisado")
    end)
    if not ok then MBM.LogError("CheckSpawn", err) end
end

-- ---------------------------------------------------------------------------
-- COMANDO DE DEBUG (mismo criterio que TacticalSpawnServer: en multijugador
-- solo lo atienden cuentas con privilegios, porque crea contenido de la nada).
-- ---------------------------------------------------------------------------
local function IsPrivileged(player)
    if not MBM.IsMultiplayer() then return true end
    if not player then return false end
    local ok, level = pcall(player.getAccessLevel, player)
    if not ok or type(level) ~= "string" then return false end
    level = level:lower()
    return level == "admin" or level == "moderator" or level == "gm" or level == "overseer"
end

local lastDebugMs = 0

local function onClientCommand(module, command, player, args)
    if module ~= MBM.NET.MODULE then return end
    if command ~= "SpawnHere" then return end
    if not player then return end

    local now = getTimestampMs()
    if now - lastDebugMs < 5000 then return end
    lastDebugMs = now

    if not IsPrivileged(player) then
        print("[MaurinBombinSpawn] Spawn de debug rechazado (requiere admin en multijugador).")
        return
    end

    local square = player:getSquare()
    if type(args) == "table" and type(args.x) == "number" and type(args.y) == "number" then
        local cell = getCell()
        square = (cell and cell:getGridSquare(math_floor(args.x), math_floor(args.y),
                                              math_floor(args.z or 0))) or square
    end
    pcall(MBMSpawn.SpawnMarket, player, square, "spawn manual (debug)")
end

-- ---------------------------------------------------------------------------
-- ARRANQUE
-- ---------------------------------------------------------------------------
local started = false

local function Bootstrap()
    if started then return end
    started = true

    Events.EveryTenMinutes.Remove(CheckSpawn)
    Events.EveryTenMinutes.Add(CheckSpawn)

    Events.EveryOneMinute.Remove(OnEveryOneMinute)
    Events.EveryOneMinute.Add(OnEveryOneMinute)

    Events.OnClientCommand.Remove(onClientCommand)
    Events.OnClientCommand.Add(onClientCommand)

    print("[MaurinBombinSpawn] v" .. MBMSpawn.VERSION .. " activo (" ..
          #MBMSpawn.FixedSpots .. " puestos fijos + modo dinamico).")
end

Events.OnInitGlobalModData.Add(Bootstrap)
Events.OnGameStart.Add(Bootstrap)
