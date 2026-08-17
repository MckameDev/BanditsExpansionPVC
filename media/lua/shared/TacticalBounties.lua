--[[==========================================================================
    TacticalBounties.lua  (shared/)
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Red de Alijos Ocultos: al morir el Capitan de Team PVC deja un cuaderno con
    las coordenadas de un alijo militar, que se materializa la primera vez que
    alguien carga esa casilla del mapa.

    ---------------------------------------------------------------------------
    POR QUE ESTE ARCHIVO VIVE EN shared/ Y NO EN client/
    ---------------------------------------------------------------------------
    ESTO ES UNA CORRECCION IMPORTANTE SOBRE EL BRIEF, y aplica a todo el submod.
    Verificado: un servidor DEDICADO carga los .lua de media/lua/client/ solo
    para calcular el checksum que compara con el cliente, pero NO LOS EJECUTA.
    Un modulo que vive en client/ y escribe en ModData global funciona en
    partida individual y en "host local", pero en un dedicado el servidor jamas
    correria esa logica: cada cliente escribiria su propia copia local, el
    servidor no se enteraria, y los alijos se desincronizarian entre jugadores.

    Por eso este modulo se coloca en shared/ (se ejecuta en AMBOS lados) y
    reparte el trabajo con el reparto canonico que usa el propio Bandits2:

      - AUTORIDAD (crear/borrar alijos en ModData): SOLO el servidor.
        En single player isClient() es false, asi que la misma rama corre
        localmente sin red. En modo ANFITRION no: alli el juego levanta un
        proceso servidor interno y la partida del anfitrion se conecta a el
        como cliente (isClient()==true), de modo que el anfitrion toma la
        rama de PETICION y es el servidor interno quien registra. El
        resultado es correcto en los dos casos. Mismo criterio que usa
        BanditGMD.lua del mod base.
      - PETICION: el cliente NUNCA escribe el ModData global; manda
        sendClientCommand(...) y espera. Mismo patron que
        BanditServer.Commands.PostToggle / BanditPost.lua del mod base.
      - SINCRONIZACION: el servidor llama ModData.transmit(), y el cliente
        recibe por Events.OnReceiveGlobalModData, exactamente como hace
        TransmitBanditModData() / loadBanditModData() en BanditGMD.lua.

    ---------------------------------------------------------------------------
    LA TABLA HASH (optimizacion pedida en el brief)
    ---------------------------------------------------------------------------
    ModData guarda los alijos como un diccionario persistente:

        Bounties.Stashes["10537_9420"] = {x=10537, y=9420, z=0, looted=false}

    La clave es el string "x_y". Eso ya ES una tabla hash de Lua, o sea que
    consultarla es O(1): una sola busqueda por hash, sin recorrer nada.

    El brief pedia ademas una tabla EN MEMORIA aparte (ActiveStashes) para no
    "iterar el ModData en cada frame". El matiz importante es que consultar
    ModData por clave NUNCA itera -- ya es O(1). Lo que si aporta la tabla en
    memoria es evitar la llamada a getOrCreate() (que cruza a Java) en cada
    casilla cargada, y por eso la mantenemos: es un cache Lua puro, plano,
    consultado con UNA indexacion por casilla. Ver TB.ActiveStashes.

    LoadGridsquare se dispara MUCHISIMAS veces (una por casilla al cargar
    terreno), asi que la ruta rapida sale en 2 comparaciones y sin construir
    ningun string cuando no hay alijos activos (ver el contador TB.ActiveCount).
============================================================================]]

if TacticalBounties then return end -- guarda anti doble carga
TacticalBounties = {}
local TB = TacticalBounties
TB.VERSION = "1.0.0"

local pcall     = pcall
local pairs     = pairs
local tostring  = tostring
local math_floor = math.floor

TB.MODDATA_KEY = "TeamPVC_Bounties"

TB.Config = {
    Debug = false,
    -- Botin del alijo: fusil + municion de alto calibre, condicion al 100%.
    -- Todos verificados contra media/scripts (OJO: el antibiotico es
    -- "Base.Antibiotics", NO "Base.PillsAntibiotics", que no existe).
    Loot = {
        {item = "Base.AssaultRifle",  count = 1},
        {item = "Base.556Box",        count = 2},
        {item = "Base.AssaultRifle2", count = 1},
        {item = "Base.308Box",        count = 1},
        {item = "Base.Bandage",       count = 4},
        {item = "Base.Antibiotics",   count = 2},
    },
    -- Sprite de arcon de carpinteria, el mismo que usan los escenarios del
    -- juego para crear contenedores por Lua (Trailer2Scenario.lua).
    ContainerSprite = "carpentry_02_68",
}

-- Coordenadas candidatas: zonas boscosas/apartadas alrededor de Muldraugh y
-- Rosewood. Se eligen al azar al morir el Capitan.
TB.Locations = {
    {x = 10680, y = 9750, z = 0},   -- bosque al este de Muldraugh
    {x = 10420, y = 9180, z = 0},   -- arboleda al norte de Muldraugh
    {x = 8180,  y = 11450, z = 0},  -- bosque al oeste de Rosewood
    {x = 8450,  y = 11900, z = 0},  -- linde sur de Rosewood
}

local function Log(msg)
    if TB.Config.Debug then print("[TacticalBounties] " .. tostring(msg)) end
end

local function LogError(where, err)
    print("[TacticalBounties][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

-- La clave canonica del diccionario. Siempre por esta funcion, para que el
-- que escribe y el que lee no puedan generar formatos distintos.
function TB.Key(x, y)
    return math_floor(x) .. "_" .. math_floor(y)
end

-- ---------------------------------------------------------------------------
-- CACHE EN MEMORIA (la "hash map" del brief)
-- Tabla Lua plana [clave] = true, reconstruida cuando cambian los datos.
-- ActiveCount permite que LoadGridsquare salga sin tocar NADA cuando no hay
-- alijos pendientes, que es el caso el 99.9% del tiempo.
-- ---------------------------------------------------------------------------
TB.ActiveStashes = {}
TB.ActiveCount   = 0

function TB.GetData()
    local data = ModData.getOrCreate(TB.MODDATA_KEY)
    if not data.Stashes then data.Stashes = {} end
    return data
end

-- Reconstruye el cache desde ModData. Se llama al inicializar y cada vez que
-- llegan datos nuevos del servidor: es O(n) sobre un punado de alijos, y NO
-- ocurre por frame.
function TB.RebuildCache()
    local ok, err = pcall(function()
        local data = TB.GetData()
        local cache, count = {}, 0
        for key, stash in pairs(data.Stashes) do
            if not stash.looted then
                cache[key] = true
                count = count + 1
            end
        end
        TB.ActiveStashes = cache
        TB.ActiveCount   = count
        Log("Cache reconstruido: " .. count .. " alijos activos")
    end)
    if not ok then LogError("RebuildCache", err) end
end

-- ---------------------------------------------------------------------------
-- AUTORIDAD (servidor, o partida individual donde no hay red)
-- ---------------------------------------------------------------------------

-- true si este lado manda sobre el ModData global.
--   single player       : isClient()==false -> escribimos directo, sin red.
--   anfitrion (su juego): isClient()==true  -> NO escribe; pide por comando.
--   servidor interno    : isClient()==false -> escribe (es quien manda).
--   dedicado / amigos   : igual que las dos anteriores segun el proceso.
-- OJO: no confundir "anfitrion" con "single player". Ver la nota de
-- PVCCore.IsSpawnAuthority en 00_TacticalCore.lua.
local function IsAuthority()
    return not isClient()
end

-- Crea el alijo y lo persiste. SOLO lado autoridad.
function TB.RegisterStash(x, y, z)
    if not IsAuthority() then return nil end

    local key = TB.Key(x, y)
    local data = TB.GetData()

    if data.Stashes[key] then
        Log("El alijo " .. key .. " ya existia")
        return key
    end

    data.Stashes[key] = {x = math_floor(x), y = math_floor(y), z = z or 0, looted = false}

    TB.ActiveStashes[key] = true
    TB.ActiveCount = TB.ActiveCount + 1

    -- Reparte el estado nuevo a todos los clientes. En SP es inocuo.
    pcall(ModData.transmit, TB.MODDATA_KEY)

    Log("Alijo registrado en " .. key)
    return key
end

-- Marca como saqueado (no se borra: asi nunca vuelve a materializarse aunque
-- el jugador recargue la partida o vuelva a pisar la casilla).
function TB.MarkLooted(key)
    if not IsAuthority() then return end

    local data = TB.GetData()
    local stash = data.Stashes[key]
    if not stash or stash.looted then return end

    stash.looted = true
    if TB.ActiveStashes[key] then
        TB.ActiveStashes[key] = nil
        TB.ActiveCount = TB.ActiveCount - 1
    end

    pcall(ModData.transmit, TB.MODDATA_KEY)
    Log("Alijo " .. key .. " marcado como saqueado")
end

-- ---------------------------------------------------------------------------
-- MATERIALIZACION (Lazy Loading)
-- ---------------------------------------------------------------------------

local function FillContainer(container)
    local cfg = TB.Config.Loot
    for i = 1, #cfg do
        local entry = cfg[i]
        for _ = 1, entry.count do
            local ok, item = pcall(BanditCompatibility.InstanceItem, entry.item)
            if ok and item then
                container:AddItem(item)
            end
        end
    end
end

-- Coloca fisicamente el arcon. Patron REAL y probado del juego
-- (client/DebugUIs/Scenarios/Trailer2Scenario.lua): IsoThumpable +
-- setIsContainer(true) + getContainer():setType() + AddTileObject.
-- Se eligio esto sobre IsoObject:createContainer() porque createContainer no
-- aparece ni una vez en el Lua del juego -- habria sido una suposicion.
-- IsoThumpable ademas hace el arcon destructible, coherente con un alijo.
-- IDEMPOTENCIA (importante para multijugador): LoadGridsquare esta registrado
-- en shared/, asi que en un dedicado puede dispararse tanto en el servidor
-- como en el cliente para la misma casilla. Sin esta comprobacion podrian
-- aparecer DOS arcones superpuestos. Preguntamos al mundo, que es la unica
-- fuente de verdad valida en ambos lados, en vez de fiarnos de un flag local.
local function SquareAlreadyHasStash(square)
    local objects = square:getObjects()
    if not objects then return false end
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if o then
            local sprite = o:getSprite()
            if sprite and sprite:getName() == TB.Config.ContainerSprite then
                return true
            end
        end
    end
    return false
end

local function MaterializeStash(square, key)
    -- ISSimpleFurniture vive en server/BuildingObjects/, pero esta disponible
    -- tambien en cliente (lo usan Trailer2Scenario.lua y Tutorial1.lua, que
    -- son client/). Aun asi lo comprobamos: si faltara, no reventamos.
    if type(IsoThumpable) == "nil" or type(ISSimpleFurniture) == "nil" then
        LogError("MaterializeStash", "IsoThumpable/ISSimpleFurniture no disponibles")
        return false
    end

    -- ya materializado (por el otro lado de la red, o por una recarga): no duplicar
    if SquareAlreadyHasStash(square) then
        Log("Alijo " .. key .. " ya existia en el mundo; no se duplica")
        return true
    end

    local obj = IsoThumpable.new(getCell(), square, TB.Config.ContainerSprite, false,
                                 ISSimpleFurniture:new("Crate", TB.Config.ContainerSprite,
                                                       TB.Config.ContainerSprite))
    obj:setIsContainer(true)

    local container = obj:getContainer()
    if not container then return false end

    container:setType("crate")
    FillContainer(container)

    square:AddTileObject(obj)
    pcall(obj.transmitCompleteItemToClients, obj)

    Log("Alijo materializado en " .. key)
    return true
end

-- ---------------------------------------------------------------------------
-- GATILLO: LoadGridsquare
-- Se dispara una vez por casilla al cargar terreno -> ruta rapida obligatoria.
-- ---------------------------------------------------------------------------
local function OnLoadGridsquare(square)
    -- 1) sin alijos pendientes no se hace NADA (ni siquiera construir el string)
    if TB.ActiveCount == 0 then return end
    if not square then return end

    -- 2) solo planta baja
    local z = square:getZ()
    if z ~= 0 then return end

    -- 3) consulta O(1) en la tabla hash en memoria
    local key = TB.Key(square:getX(), square:getY())
    if not TB.ActiveStashes[key] then return end

    -- A partir de aqui ocurre como mucho una vez por alijo en toda la partida.
    -- Se marca ANTES de construir, para que si dos casillas entran a la vez
    -- (o si la construccion falla) no se dupliquen cajas.
    TB.ActiveStashes[key] = nil
    TB.ActiveCount = TB.ActiveCount - 1

    local ok, built = pcall(MaterializeStash, square, key)
    if not ok then
        LogError("MaterializeStash", built)
        return
    end

    if built then
        if IsAuthority() then
            TB.MarkLooted(key)
        else
            -- El cliente no escribe el ModData global: pide al servidor que
            -- lo marque, igual que hace BanditPost.lua del mod base.
            local player = getSpecificPlayer(0)
            if player then
                pcall(sendClientCommand, player, 'BEPBounties', 'MarkLooted', {key = key})
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- EL DROP: cuaderno del Capitan
-- ---------------------------------------------------------------------------

-- Se registra en PVCCore (client) desde TacticalBountiesClient.lua; aqui vive
-- la logica para que el servidor tambien pueda usarla si hiciera falta.
function TB.OnCaptainDeath(zombie, brain, id)
    if type(TeamPVC) ~= "table" or type(TeamPVC.CAPTAIN_BID) ~= "string" then return end
    if brain.bid ~= TeamPVC.CAPTAIN_BID then return end

    -- MULTIJUGADOR: este handler corre en el cliente de CADA jugador que vea
    -- morir al Capitan, y la coordenada se elige AL AZAR mas abajo. Sin esta
    -- guarda, cada cliente sortearia un alijo DISTINTO y se registrarian
    -- varios por una sola muerte (la idempotencia de RegisterStash no ayuda:
    -- las claves serian diferentes). Decide una sola maquina.
    if type(PVCCore) == "table" and type(PVCCore.IsSpawnAuthority) == "function" then
        if not PVCCore.IsSpawnAuthority() then return end
    end

    local loc = TB.Locations[ZombRand(#TB.Locations) + 1]
    if not loc then return end

    local key = TB.Key(loc.x, loc.y)

    -- El cliente pide; la autoridad registra.
    if IsAuthority() then
        TB.RegisterStash(loc.x, loc.y, loc.z)
    else
        local player = getSpecificPlayer(0)
        if player then
            pcall(sendClientCommand, player, 'BEPBounties', 'RegisterStash',
                  {x = loc.x, y = loc.y, z = loc.z})
        end
        -- optimista en local para que el alijo funcione ya en esta sesion
        TB.ActiveStashes[key] = true
        TB.ActiveCount = TB.ActiveCount + 1
    end

    -- El cuaderno con las coordenadas, al cadaver del Capitan.
    local ok, err = pcall(function()
        local note = BanditCompatibility.InstanceItem("Base.Notebook")
        if not note then return end
        pcall(note.addPage, note, 1,
              getText("UI_BEP_TB_NoteBody", math_floor(loc.x), math_floor(loc.y)))
        pcall(note.setName, note, getText("UI_BEP_TB_NoteTitle"))
        pcall(note.setCustomName, note, true)

        local inv = zombie:getInventory()
        if inv then
            inv:AddItem(note)
            -- que el cuaderno acabe en el cadaver, no solo en el inventario vivo
            if type(Bandit) == "table" and type(Bandit.UpdateItemsToSpawnAtDeath) == "function" then
                pcall(Bandit.UpdateItemsToSpawnAtDeath, zombie, brain)
            end
        end
    end)
    if not ok then LogError("OnCaptainDeath/nota", err) end

    Log("Capitan caido: alijo en " .. key)
end

-- ---------------------------------------------------------------------------
-- COMANDOS DE CLIENTE -> SERVIDOR (solo lado servidor)
-- Mismo patron que BanditServer.Commands + Events.OnClientCommand del mod base.
-- ---------------------------------------------------------------------------
if isServer() then
    local function onClientCommand(module, command, player, args)
        if module ~= 'BEPBounties' then return end

        if command == 'RegisterStash' and args and args.x and args.y then
            pcall(TB.RegisterStash, args.x, args.y, args.z or 0)
        elseif command == 'MarkLooted' and args and args.key then
            pcall(TB.MarkLooted, args.key)
        end
    end
    Events.OnClientCommand.Add(onClientCommand)
end

-- ---------------------------------------------------------------------------
-- ARRANQUE
-- ---------------------------------------------------------------------------
local function OnInitGlobalModData(isNewGame)
    local ok, err = pcall(function()
        TB.GetData()
        -- El cliente pide la copia autoritativa al servidor (en SP no hace nada)
        if isClient() then
            ModData.request(TB.MODDATA_KEY)
        end
        TB.RebuildCache()
    end)
    if not ok then LogError("OnInitGlobalModData", err) end
end

-- Cuando el servidor transmite, el cliente refresca su cache.
local function OnReceiveGlobalModData(key, data)
    if key ~= TB.MODDATA_KEY then return end
    TB.RebuildCache()
end

Events.OnInitGlobalModData.Add(OnInitGlobalModData)
Events.OnReceiveGlobalModData.Add(OnReceiveGlobalModData)
Events.LoadGridsquare.Add(OnLoadGridsquare)

print("[TacticalBounties] v" .. TB.VERSION .. " cargado (red de alijos ocultos).")
