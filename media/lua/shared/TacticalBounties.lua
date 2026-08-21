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
      - MATERIALIZACION (crear el arcon en el mundo): SOLO la autoridad. Este
        archivo registra LoadGridsquare desde shared/, asi que en un dedicado el
        evento se dispara en el servidor Y en cada cliente que cargue la
        casilla; si el cliente tambien construyera, cada jugador se fabricaria
        su propio arcon con su propia copia del botin. Ver OnLoadGridsquare.
      - ELECCION DE UBICACION: determinista a partir del brain, no ZombRand.
        Asi todos los clientes calculan la misma clave y las peticiones
        repetidas son idempotentes. Ver TB.PickLocation.
      - VALIDACION: 'RegisterStash' solo acepta coordenadas de TB.Locations y
        una peticion por jugador cada 5 s. Ver TB.IsKnownLocation.

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
TB.VERSION = "1.1.0"

local pcall     = pcall
local pairs     = pairs
local type      = type
local tostring  = tostring
local math_floor = math.floor
local math_abs   = math.abs

TB.MODDATA_KEY = "TeamPVC_Bounties"

TB.Config = {
    -- Interruptor maestro de la red de alijos. Lo puede apagar el jugador desde
    -- las opciones de partida (BEP.Bounties; ver media/sandbox-options.txt).
    -- Apagado: el Capitan no deja cuaderno y no se materializa ningun arcon.
    Enabled = true,
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
-- LISTA BLANCA DE COORDENADAS
-- El alijo solo puede caer en una de las ubicaciones predefinidas
-- (TB.Locations). Sin esta comprobacion, el comando 'RegisterStash' es un
-- generador de fusiles de asalto: cualquier cliente modificado podria pedir un
-- alijo en la casilla que quisiera, tantas veces como quisiera. La lista es de
-- 4 entradas, asi que validar es un for de 4 iteraciones.
-- ---------------------------------------------------------------------------
function TB.IsKnownLocation(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return false end
    local fx, fy = math_floor(x), math_floor(y)
    for i = 1, #TB.Locations do
        local loc = TB.Locations[i]
        if math_floor(loc.x) == fx and math_floor(loc.y) == fy then return true end
    end
    return false
end

function TB.IsKnownKey(key)
    if type(key) ~= "string" then return false end
    for i = 1, #TB.Locations do
        local loc = TB.Locations[i]
        if TB.Key(loc.x, loc.y) == key then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- ELECCION DE UBICACION: DETERMINISTA, NO AL AZAR
-- ---------------------------------------------------------------------------
-- OnCaptainDeath corre en el cliente de CADA jugador que ve morir al Capitan.
-- Con ZombRand, cada cliente sorteaba una ubicacion DISTINTA: la idempotencia
-- del servidor no ayudaba (las claves eran diferentes) y podian registrarse
-- varios alijos por una sola muerte. La solucion anterior era dejar que
-- decidiera solo la autoridad... lo que en un servidor dedicado significa que
-- no decide nadie (ningun cliente es autoridad y el servidor no ejecuta
-- client/): el alijo no existia en dedicado.
-- Se deriva del brain, que el SERVIDOR asigna al crear el bandido y viaja
-- igual a todos los clientes: todos calculan la MISMA ubicacion sin red y sin
-- ventana de carrera. Es el mismo truco que ya usa AssignTactic en
-- TacticalAsymmetric.lua e IsPyro en TacticalQuickWins.lua.
function TB.PickLocation(brain)
    local n = #TB.Locations
    if n == 0 then return nil end

    local seed = brain and ((brain.rnd and brain.rnd[3]) or brain.id)
    if type(seed) ~= "number" then
        -- Sin semilla estable no se inventa una al azar: se usa la primera
        -- ubicacion, que sigue siendo igual para todos los clientes.
        return TB.Locations[1]
    end
    return TB.Locations[(math_floor(math_abs(seed)) % n) + 1]
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

    -- Defensa en profundidad: esta es la UNICA via de escritura, asi que aqui
    -- se vuelve a validar la lista blanca aunque el handler de red ya lo haya
    -- hecho. Ver TB.IsKnownLocation.
    if not TB.IsKnownLocation(x, y) then
        LogError("RegisterStash", "coordenadas fuera de la lista blanca: " ..
                 tostring(x) .. "," .. tostring(y))
        return nil
    end

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
    -- Solo claves de la lista blanca: marcar como saqueado es destructivo (el
    -- alijo no vuelve a materializarse nunca), asi que la clave tiene que ser
    -- una de las nuestras y no cualquier string.
    if not TB.IsKnownKey(key) then
        LogError("MarkLooted", "clave desconocida: " .. tostring(key))
        return
    end

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
    -- 0) interruptor de las opciones de partida (BEP.Bounties)
    if TB.Config.Enabled == false then return end
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

    -- CONSTRUIR ES COSA DE LA AUTORIDAD, SIEMPRE.
    -- Este handler vive en shared/, asi que en un dedicado se dispara en el
    -- servidor Y en cada cliente que cargue la casilla. Si el cliente tambien
    -- construyera, cada jugador se fabricaria SU PROPIO arcon con SU PROPIA
    -- copia del botin (fusiles de asalto multiplicados por jugador), y encima
    -- llamaria a transmitCompleteItemToClients desde un cliente. La
    -- comprobacion de SquareAlreadyHasStash no alcanza: hay una ventana real
    -- entre que el servidor crea el objeto y que el cliente lo recibe.
    -- El arcon del servidor llega a todos por la replicacion normal del mundo.
    if not IsAuthority() then
        Log("Alijo " .. key .. ": lo materializa el servidor, aqui solo se espera")
        return
    end

    local ok, built = pcall(MaterializeStash, square, key)
    if not ok then
        LogError("MaterializeStash", built)
        return
    end

    if built then TB.MarkLooted(key) end
end

-- ---------------------------------------------------------------------------
-- EL DROP: cuaderno del Capitan
-- ---------------------------------------------------------------------------

-- Se registra en PVCCore (client) desde TacticalBountiesClient.lua; aqui vive
-- la logica para que el servidor tambien pueda usarla si hiciera falta.
function TB.OnCaptainDeath(zombie, brain, id)
    -- Interruptor de las opciones de partida (BEP.Bounties): sin alijos, el
    -- Capitan muere sin dejar pista ninguna.
    if TB.Config.Enabled == false then return end

    -- El bid del capitan vive en shared (PVCShared), no en el modulo de cliente:
    -- asi esta funcion tambien es utilizable desde el servidor. Se mantiene
    -- TeamPVC como respaldo por compatibilidad.
    local captainBid = (type(PVCShared) == "table" and PVCShared.CAPTAIN_BID) or
                       (type(TeamPVC) == "table" and TeamPVC.CAPTAIN_BID)
    if type(captainBid) ~= "string" then return end
    if brain.bid ~= captainBid then return end

    -- Ubicacion DETERMINISTA a partir del brain: todos los clientes que ven la
    -- muerte calculan la misma clave, asi que se pueden mandar todas las
    -- peticiones que hagan falta -- el servidor registra una sola vez
    -- (RegisterStash es idempotente por clave). Ver TB.PickLocation.
    local loc = TB.PickLocation(brain)
    if not loc then return end

    local key = TB.Key(loc.x, loc.y)

    -- El cliente pide; la autoridad registra. Ya no hay guarda de "solo la
    -- autoridad local decide": eso dejaba la mecanica muerta en dedicado.
    if IsAuthority() then
        TB.RegisterStash(loc.x, loc.y, loc.z)
    else
        local player = getSpecificPlayer(0)
        if player then
            pcall(sendClientCommand, player, 'BEPBounties', 'RegisterStash',
                  {x = loc.x, y = loc.y, z = loc.z})
        end
        -- Ya no se marca el alijo "optimista" en el cache local: desde que solo
        -- la autoridad materializa el arcon, al cliente no le sirve de nada
        -- tenerlo apuntado. El estado real llega solo, por el ModData.transmit()
        -- que hace RegisterStash en el servidor -> OnReceiveGlobalModData ->
        -- RebuildCache.
    end

    -- ---------------------------------------------------------------------
    -- LA PISTA: cuaderno en el cadaver, o aviso por pantalla
    -- ---------------------------------------------------------------------
    -- Meter el cuaderno en el inventario del bandido es una mutacion de objeto:
    -- si lo hiciera cada cliente, el cadaver podria acabar con una nota por
    -- jugador. Por eso lo sigue haciendo solo la autoridad local.
    -- En un dedicado NADIE es autoridad local, y sin pista el alijo es
    -- inencontrable: alli el jugador recibe las MISMAS coordenadas como aviso
    -- en pantalla (mismo texto traducido que la nota, UI_BEP_TB_NoteBody).
    local hasLocalAuthority = not (type(PVCCore) == "table" and
                                   type(PVCCore.NotWorldAuthority) == "function" and
                                   PVCCore.NotWorldAuthority())

    if hasLocalAuthority then
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
    else
        local player = getSpecificPlayer(0)
        if player then
            pcall(player.addLineChatElement, player,
                  getText("UI_BEP_TB_NoteBody", math_floor(loc.x), math_floor(loc.y)),
                  1, 0.85, 0.2)
        end
    end

    Log("Capitan caido: alijo en " .. key)
end

-- ---------------------------------------------------------------------------
-- COMANDOS DE CLIENTE -> SERVIDOR (solo lado servidor)
-- Mismo patron que BanditServer.Commands + Events.OnClientCommand del mod base.
-- ---------------------------------------------------------------------------
if isServer() then
    -- Antiflood por jugador: registrar un alijo es un evento unico (muerte del
    -- Capitan), asi que una peticion por jugador cada 5 s es holgadisimo.
    local lastRequestMs = {}
    local REQUEST_COOLDOWN_MS = 5000

    local function PassRateLimit(player)
        local name = "?"
        local okName, n = pcall(player.getUsername, player)
        if okName and type(n) == "string" then name = n end

        local now  = getTimestampMs()
        local last = lastRequestMs[name]
        if last and (now - last) < REQUEST_COOLDOWN_MS then return false end
        lastRequestMs[name] = now
        return true
    end

    local function onClientCommand(module, command, player, args)
        if module ~= 'BEPBounties' then return end
        if not player then return end

        -- 'MarkLooted' YA NO EXISTE como comando de cliente, a proposito.
        -- Desde que solo la autoridad materializa el arcon (ver
        -- OnLoadGridsquare), ningun cliente necesita marcar nada -- y dejarlo
        -- abierto permitia que un cliente modificado marcase los cuatro alijos
        -- como saqueados antes de que nadie llegase, borrando el contenido del
        -- mod para toda la partida.
        if command ~= 'RegisterStash' then return end
        if not args then return end
        if not PassRateLimit(player) then return end

        -- Lista blanca: solo las ubicaciones predefinidas. Sin esto, el comando
        -- es una fabrica de fusiles de asalto en la casilla que el cliente
        -- quiera. Ver TB.IsKnownLocation.
        if not TB.IsKnownLocation(args.x, args.y) then
            print("[TacticalBounties] Peticion de alijo rechazada (coordenadas no validas).")
            return
        end

        pcall(TB.RegisterStash, args.x, args.y, args.z or 0)
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
