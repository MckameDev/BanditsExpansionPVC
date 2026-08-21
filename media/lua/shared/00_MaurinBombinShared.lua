--[[==========================================================================
    00_MaurinBombinShared.lua
    Ecosistema "MaurinBombin Market" - Sub-mod Bandits: Tactical Expansion (B42)
    FASE 1 de 3 -- Capa COMPARTIDA (datos, contrato de red y utilidades puras)

    ---------------------------------------------------------------------------
    ARQUITECTURA "CLIENTE-MUSCULO / SERVIDOR-CEREBRO"
    ---------------------------------------------------------------------------
    - shared/  : lo que necesitan LOS DOS lados (constantes, pools de loot,
                 nombres de comandos, helpers sin estado). Se carga en el
                 proceso del servidor Y en el de cada cliente.
    - server/  : la AUTORIDAD. Stock global, precios, restock, transacciones,
                 permadeath. media/lua/server/ se ejecuta en single player, en
                 el servidor interno del modo Anfitrion y en un dedicado; y NO
                 se ejecuta en los clientes conectados. Una sola
                 implementacion = exactamente una autoridad en los tres modos.
    - client/  : el MUSCULO. IA del escuadron (Fase 2) e interfaz (Fase 3).

    REGLA DE ORO DE ESTE MOD: el cliente NUNCA escribe el ModData global ni se
    entrega items a si mismo por iniciativa propia. Pide -> el servidor valida
    -> el servidor descuenta -> el servidor ordena la entrega.

    ---------------------------------------------------------------------------
    POR QUE EL PREFIJO "00_"
    ---------------------------------------------------------------------------
    Kahlua carga media/lua/shared/ por orden alfabetico. Este archivo define la
    tabla global MaurinBombin que el resto de modulos (server/ y client/) dan
    por existente en su cuerpo, asi que tiene que cargar primero.

    ---------------------------------------------------------------------------
    RENDIMIENTO
    ---------------------------------------------------------------------------
    Nada de este archivo se engancha a OnTick/OnPlayerUpdate. Las unicas tablas
    que se instancian aqui son las de configuracion (una vez, al cargar) y las
    del armado del stock (una vez cada restock, o sea cada 3 dias in-game).
============================================================================]]

if MaurinBombin then return end -- guarda anti doble carga (Kahlua puede reejecutar)

MaurinBombin = {}
local MBM = MaurinBombin

MBM.VERSION      = "1.0.0"
MBM.MOD_ID       = "BanditsExpansionPVC"

-- Clave del ModData global. Es la MISMA cadena en cliente y servidor: es el
-- identificador con el que viaja el estado por ModData.transmit/request.
MBM.MODDATA_KEY  = "MaurinBombin_Market"

-- Version del esquema de datos. Si algun dia cambia la forma de data.stock, se
-- sube este numero y el servidor migra o reconstruye en vez de reventar sobre
-- una partida vieja (ver MBMServer.EnsureData).
MBM.SCHEMA       = 1

-- ---------------------------------------------------------------------------
-- IDENTIDAD DEL CLAN (los usara el spawner de la Fase 2; deben coincidir con
-- common/bandits/clans.txt y bandits.txt cuando se anadan alli)
-- ---------------------------------------------------------------------------
-- Numeracion: los cid van en la serie 00x (001 Team PVC, 002 RoadAmbushers) y
-- los bid en centenas por clan (1xx Team PVC, 2xx salteadores, 3xx mercado).
MBM.CLAN_ID      = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de003"  -- cid unico del mercado
MBM.MERCHANT_BID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de301"  -- Maurin Bombin
MBM.GUARD_A_BID  = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de302"  -- guardia con escopeta
MBM.GUARD_B_BID  = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de303"  -- guardia con fusil automatico

-- Roles. Se escriben en el modData PROPIO del zombi (ver MBM.TagNPC): es la
-- unica marca que sobrevive a que Bandits2 borre el brain al morir.
MBM.ROLE_MERCHANT = "merchant"
MBM.ROLE_GUARD    = "guard"

-- ---------------------------------------------------------------------------
-- CONTRATO DE RED
-- Un unico modulo. Los nombres viven aqui para que cliente y servidor no
-- puedan desincronizarse por un typo.
-- ---------------------------------------------------------------------------
MBM.NET = {
    MODULE = "MBMarket",

    -- cliente -> servidor
    C_SYNC    = "RequestSync",   -- "acabo de entrar / abri la UI, mandame el estado"
    C_BUY     = "Buy",           -- {entryId = string, qty = number}
    C_ACK     = "AckDelivery",   -- {txId = string, ok = boolean} (ver ENTREGA DIFERIDA)
    C_NPCDOWN = "NPCDown",       -- {uid = string, role = <ROLE_*>} respaldo de muerte

    -- servidor -> cliente
    S_STATE   = "State",         -- estado publico completo (snapshot)
    S_RESULT  = "BuyResult",     -- {ok, reason, entryId, qty, cost}
    S_DELIVER = "Deliver",       -- {txId, item, qty, cost} orden de entrega firmada
}

-- Codigos de rechazo. El servidor manda CODIGO, no texto: la Fase 3 los
-- traduce con getText(). Asi el servidor no depende del idioma del cliente.
MBM.REASON = {
    OK          = "ok",
    NO_MARKET   = "no_market",   -- el mercado no existe / mercader muerto
    NO_STOCK    = "no_stock",    -- se agoto entre que el cliente vio la lista y compro
    NO_MONEY    = "no_money",    -- Base.Money insuficiente
    TOO_FAR     = "too_far",     -- no esta junto al mercader
    BAD_REQUEST = "bad_request", -- tipos invalidos / entrada inexistente
    BUSY        = "busy",        -- antiflood o transaccion en curso
    FAILED      = "failed",      -- la entrega fallo y se hizo rollback
}

-- ---------------------------------------------------------------------------
-- CONFIGURACION
-- ---------------------------------------------------------------------------
MBM.Config = {
    -- Interruptor maestro del mercado. Lo puede apagar el jugador desde las
    -- opciones de partida (BEP.Market; ver media/sandbox-options.txt).
    -- Apagado: no se monta ningun puesto nuevo. La emisora de 88.5 FM sigue
    -- existiendo en el dial, pero solo emite su identificacion.
    Enabled             = true,
    Debug               = false,

    MoneyItem           = "Base.Money",  -- moneda del mercado (1 item = 1 unidad)

    -- Restock (horas de MUNDO, no del reloj real)
    RestockHours        = 72,    -- 3 dias in-game de ciclo normal
    SoldOutHours        = 24,    -- excepcion: stock global a 0 -> repone manana
    RespawnHours        = 360,   -- 15 dias tras matar al mercader (permadeath)

    -- Transacciones
    PurchaseRange       = 8,     -- casillas maximas entre jugador y mercader
    MaxQtyPerTx         = 5,     -- tope por compra (acota el dano de un cliente hostil)
    BuyCooldownMs       = 400,   -- antiflood por jugador y comando
    SyncCooldownMs      = 2000,
    ReportCooldownMs    = 1000,
    DeliveryTimeoutMs   = 20000, -- si el cliente no confirma, se revierte el stock
    MaxPendingPerPlayer = 3,

    -- Rango en el que se acepta un aviso de muerte reportado por un cliente
    -- (respaldo de OnZombieDead; ver MBMServer.HandleNPCDown).
    ReportRange         = 60,
}

-- ---------------------------------------------------------------------------
-- LOOT POOLS
-- El stock NO es una lista fija: cada restock se sortean `slots` articulos
-- distintos por tramo, con precio y cantidad dentro de su horquilla. Asi dos
-- partidas (o dos restocks) nunca ofrecen lo mismo.
--
--   chance       : % de que el tramo aparezca siquiera en este restock.
--   slots        : cuantos articulos DISTINTOS se sortean del tramo.
--   priceMin/Max : precio unitario en unidades de Base.Money.
--   qtyMin/Max   : unidades en stock de ese articulo.
--
-- Todos los ids estan verificados contra los que ya usa este mod
-- (TacticalBounties.Config.Loot, common/bandits/bandits.txt).
-- ---------------------------------------------------------------------------
MBM.Tiers = {
    COMMON = "common",
    VALUE  = "value",
    RARE   = "rare",
}

MBM.Pools = {
    {
        tier     = MBM.Tiers.COMMON,     -- Comun: consumibles y utilidad
        chance   = 100,
        slots    = 6,
        priceMin = 8,   priceMax = 45,
        qtyMin   = 3,   qtyMax   = 10,
        items = {
            "Base.Bandage",
            "Base.AlcoholBandage",
            "Base.Pills",
            "Base.PillsBeta",
            "Base.HandTorch",
            "Base.HandAxe",
            "Base.HuntingKnife",
            "Base.AlarmClock2",
            "Base.SheetPaper2",
            "Base.Notebook",
        },
    },
    {
        tier     = MBM.Tiers.VALUE,      -- Valioso: armas de mano y medicina seria
        chance   = 100,
        slots    = 3,
        priceMin = 90,  priceMax = 260,
        qtyMin   = 1,   qtyMax   = 3,
        items = {
            "Base.Pistol",
            "Base.Shotgun",
            "Base.VarmintRifle",
            "Base.Machete",
            "Base.Axe",
            "Base.Antibiotics",
            "Base.AntibioticsBox",
            "Base.Molotov",
            "Base.SmokeBomb",
            "Base.WalkieTalkie4",
            "Base.Bag_ALICEpack",
        },
    },
    {
        tier     = MBM.Tiers.RARE,       -- Super raro: no siempre hay, y cuesta
        chance   = 55,
        slots    = 1,
        priceMin = 600, priceMax = 1400,
        qtyMin   = 1,   qtyMax   = 1,
        items = {
            "Base.AssaultRifle",
            "Base.AssaultRifle2",
            "Base.556Box",
            "Base.308Box",
            "Base.Vest_BulletArmy",
            "Base.HamRadio1",
        },
    },
}

-- ---------------------------------------------------------------------------
-- LOG
-- ---------------------------------------------------------------------------
local lastErrorMs = 0

function MBM.Log(msg)
    if MBM.Config.Debug then print("[MaurinBombin] " .. tostring(msg)) end
end

-- Los errores se estrangulan: un fallo dentro de un evento del juego se
-- repetiria miles de veces y llenaria el log del servidor.
function MBM.LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[MaurinBombin][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

-- ---------------------------------------------------------------------------
-- MODO DE JUEGO / AUTORIDAD
--   single player     : isClient()==false, isServer()==false
--   servidor interno  : isClient()==false, isServer()==true   (modo Anfitrion)
--   servidor dedicado : isClient()==false, isServer()==true
--   cliente conectado : isClient()==true
-- ---------------------------------------------------------------------------
function MBM.IsAuthority()
    return not isClient()
end

-- true cuando la autoridad NO comparte proceso con el jugador que compra: hay
-- que delegarle la entrega a su cliente (ver ENTREGA DIFERIDA en el servidor).
function MBM.IsRemoteAuthority()
    return isServer() == true
end

function MBM.IsMultiplayer()
    local world = getWorld()
    return world ~= nil and world:getGameMode() == "Multiplayer"
end

-- ---------------------------------------------------------------------------
-- TIEMPO DE MUNDO EN HORAS
-- Se trabaja en HORAS y no en dias porque el restock tiene tramos de 24 y 72
-- horas y hace falta la fraccion. Mismo patron defensivo que
-- PVCShared.GetWorldAgeDays: no se apuesta a un unico accesor de la API.
-- ---------------------------------------------------------------------------
local WORLD_HOUR_SOURCES = {
    function(gt) return gt:getWorldAgeHours() end,
    function(gt) return gt:getNightsSurvived() * 24 end,
}

local worldHourGetter   -- nil = sin resolver, false = ninguno responde

function MBM.NowHours()
    local ok, gt = pcall(getGameTime)
    if not ok or not gt then return 0 end

    if worldHourGetter then
        local ok2, h = pcall(worldHourGetter, gt)
        if ok2 and type(h) == "number" then return h end
        worldHourGetter = nil    -- dejo de responder: se vuelve a resolver
    elseif worldHourGetter == false then
        return 0
    end

    for i = 1, #WORLD_HOUR_SOURCES do
        local ok2, h = pcall(WORLD_HOUR_SOURCES[i], gt)
        if ok2 and type(h) == "number" then
            worldHourGetter = WORLD_HOUR_SOURCES[i]
            return h
        end
    end

    worldHourGetter = false
    print("[MaurinBombin][ERROR] Ningun accesor de edad del mundo disponible; se asume hora 0.")
    return 0
end

-- ---------------------------------------------------------------------------
-- MODDATA
-- getOrCreate SIEMPRE devuelve la misma tabla viva; leer una clave es O(1) y no
-- itera nada. El esquema lo garantiza el servidor (MBMServer.EnsureData); aqui
-- solo se rellena lo minimo para que un cliente que aun no recibio nada no
-- reviente al leer.
-- ---------------------------------------------------------------------------
function MBM.GetData()
    local data = ModData.getOrCreate(MBM.MODDATA_KEY)
    if not data.stock then data.stock = {} end
    if not data.order then data.order = {} end
    return data
end

-- ---------------------------------------------------------------------------
-- DINERO (Base.Money)
-- SUPUESTO EXPLICITO: 1 item Base.Money = 1 unidad de precio. Base.Money no
-- lleva contador propio en vanilla; si algun mod lo hiciera apilable, este
-- recuento lo subestimaria (nunca lo sobreestima), o sea que falla del lado
-- seguro: como mucho el jugador no puede comprar algo que si podria pagar.
-- ---------------------------------------------------------------------------

-- Cuenta el dinero del jugador. Devuelve nil si la API no responde (por
-- ejemplo, inventario de un jugador remoto aun no replicado): quien llama DEBE
-- distinguir "no tiene dinero" (0) de "no lo se" (nil).
function MBM.CountMoney(player)
    if not player then return nil end
    local okInv, inv = pcall(player.getInventory, player)
    if not okInv or not inv then return nil end

    local ok, n = pcall(inv.getCountTypeRecurse, inv, MBM.Config.MoneyItem)
    if ok and type(n) == "number" then return n end

    -- Respaldo: recorrido manual del contenedor principal.
    local okItems, items = pcall(inv.getItems, inv)
    if not okItems or not items then return nil end
    local count = 0
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local okType, ftype = pcall(it.getFullType, it)
        if okType and ftype == MBM.Config.MoneyItem then count = count + 1 end
    end
    return count
end

-- Retira `amount` unidades. Devuelve (true) solo si se retiraron TODAS; si a
-- mitad se acaba, devuelve (false, retiradas) para que quien llama pueda
-- reembolsar exactamente lo que si se cobro. Nunca deja al jugador pagando a
-- medias.
function MBM.RemoveMoney(player, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true, 0 end
    if not player then return false, 0 end

    local okInv, inv = pcall(player.getInventory, player)
    if not okInv or not inv then return false, 0 end

    local removed = 0
    for _ = 1, amount do
        local ok, item = pcall(inv.getFirstTypeRecurse, inv, MBM.Config.MoneyItem)
        if not ok or not item then break end
        local okRem = pcall(inv.DoRemoveItem, inv, item)
        if not okRem then
            -- Firma alternativa segun build: Remove(InventoryItem).
            okRem = pcall(inv.Remove, inv, item)
        end
        if not okRem then break end
        removed = removed + 1
    end

    return removed == amount, removed
end

-- ---------------------------------------------------------------------------
-- CREACION Y ENTREGA DE ITEMS
-- Cascada de accesores: primero el helper del mod base (que ya resuelve las
-- diferencias entre builds), luego los de vanilla.
-- ---------------------------------------------------------------------------
function MBM.CreateItem(fullType)
    if type(fullType) ~= "string" then return nil end

    if type(BanditCompatibility) == "table" and type(BanditCompatibility.InstanceItem) == "function" then
        local ok, item = pcall(BanditCompatibility.InstanceItem, fullType)
        if ok and item then return item end
    end

    local ok, item = pcall(function() return InventoryItemFactory.CreateItem(fullType) end)
    if ok and item then return item end

    ok, item = pcall(function() return instanceItem(fullType) end)
    if ok and item then return item end

    MBM.LogError("CreateItem", "no se pudo instanciar " .. tostring(fullType))
    return nil
end

-- Entrega `qty` unidades al inventario del jugador. Devuelve cuantas entraron
-- de verdad: si la mitad falla, quien llama decide (el servidor revierte al
-- stock las que no llegaron).
function MBM.GiveItems(player, fullType, qty)
    if not player then return 0 end
    local okInv, inv = pcall(player.getInventory, player)
    if not okInv or not inv then return 0 end

    local given = 0
    for _ = 1, math.floor(tonumber(qty) or 0) do
        local item = MBM.CreateItem(fullType)
        if not item then break end
        local ok = pcall(inv.AddItem, inv, item)
        if not ok then break end
        given = given + 1
    end
    return given
end

-- ---------------------------------------------------------------------------
-- IDENTIFICACION DE LOS NPC DEL MERCADO
--
-- BUG CONOCIDO DEL MOD BASE (ya documentado en client/00_TacticalCore.lua ~307):
-- Bandits2 llama BanditBrain.Remove(bandit) DENTRO de su propio
-- Events.OnZombieDead, y sus handlers se registran antes que los nuestros. O
-- sea: cuando nos toca a nosotros, BanditBrain.Get(zombie) YA devuelve nil. Un
-- anti-loot que dependiera del brain no dispararia NUNCA.
--
-- Solucion: al spawnear (Fase 2) se marca al NPC en SU PROPIO modData con una
-- clave nuestra, que Bandits2 no toca y que sobrevive a la muerte. La lectura
-- del brain queda solo como respaldo.
-- ---------------------------------------------------------------------------
MBM.MODDATA_TAG = "MBMarketRole"
MBM.MODDATA_UID = "MBMarketUid"

function MBM.TagNPC(zombie, role, uid)
    if not zombie then return false end
    local ok, md = pcall(zombie.getModData, zombie)
    if not ok or not md then return false end
    md[MBM.MODDATA_TAG] = role
    if uid then md[MBM.MODDATA_UID] = uid end
    -- Variable de animacion: filtro baratisimo para los ticks de la Fase 2
    -- (getVariableBoolean no baja al modData).
    pcall(zombie.setVariable, zombie, "MBMarketNPC", "true")
    return true
end

-- Devuelve rol y uid del NPC, o nil si no es del mercado. Vale vivo y muerto.
function MBM.GetNPCRole(zombie, brain)
    if not zombie then return nil, nil end

    local ok, md = pcall(zombie.getModData, zombie)
    if ok and md and md[MBM.MODDATA_TAG] then
        return md[MBM.MODDATA_TAG], md[MBM.MODDATA_UID]
    end

    -- Respaldo por brain (solo funciona mientras sigue vivo).
    if type(brain) == "table" then
        if brain.bid == MBM.MERCHANT_BID then return MBM.ROLE_MERCHANT, brain.id end
        if brain.bid == MBM.GUARD_A_BID or brain.bid == MBM.GUARD_B_BID then
            return MBM.ROLE_GUARD, brain.id
        end
    end

    return nil, nil
end

-- ---------------------------------------------------------------------------
-- TIERRA QUEMADA
-- Vacia el inventario del NPC en el instante de la muerte, antes de que el
-- motor materialice el cadaver saqueable.
-- ---------------------------------------------------------------------------
function MBM.StripInventory(zombie)
    if not zombie then return false end
    local ok, inv = pcall(zombie.getInventory, zombie)
    if not ok or not inv then return false end

    local okClear = pcall(inv.removeAllItems, inv)
    if not okClear then
        MBM.LogError("StripInventory", "removeAllItems fallo")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- PACTO CON LOS MUERTOS
--
-- QUE PASA DE VERDAD AQUI (dos correcciones sobre la version anterior)
--   1. setGhostMode NO existe en IsoZombie: esta declarado solo en IsoPlayer.
--      La llamada iba dentro de un pcall, asi que fallaba en silencio y el
--      "modo fantasma" nunca se aplico. Se quito.
--   2. setUseless NO es un interruptor de "no me elijas como objetivo": es la
--      marca de PRIORIDAD DE ACTUALIZACION del motor (el "tiered zombie
--      updates" que se ve en el log). De hecho el propio mod base la escribe
--      en cada tick -- client/BanditUpdate.lua ~400:
--          bandit:setUseless(gameMode ~= "Multiplayer" or IsForceStationary(b))
--      o sea que en single player TODOS los bandidos ya son "useless" y
--      nuestra llamada no aportaba nada.
--
-- Entonces, por que los zombis ya ignoran al mercader? Porque un bandido de
-- este mod ES un IsoZombie (se crea con addZombiesInOutfit), y los zombis no se
-- atacan entre ellos. No hay nada que desactivar: es gratis por construccion.
--
-- Lo que si hay que garantizar es la otra mitad del pacto -- que el MERCADER no
-- ataque a nadie -- y eso no se hace aqui sino con brain.hostile = false, que
-- es la bandera que gatea la busqueda de enemigos del mod base
-- (client/BanditUpdate.lua ~973). Ver MaurinBombinAI.EnforcePact.
--
-- Queda solo limpiar el objetivo que pudiera arrastrar del spawn.
-- ---------------------------------------------------------------------------
function MBM.MakeIgnoredByZombies(zombie)
    if not zombie then return false end
    return pcall(zombie.setTarget, zombie, nil) == true
end

-- ---------------------------------------------------------------------------
-- UTILIDADES PURAS (las usa el servidor al armar el stock y la UI en Fase 3)
-- ---------------------------------------------------------------------------

function MBM.CopyTable(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

-- Suma de unidades en stock. O(n) sobre una decena de entradas y solo se llama
-- en eventos (compra, restock), jamas por frame.
function MBM.TotalUnits(data)
    local total = 0
    if not data or not data.stock then return 0 end
    for _, entry in pairs(data.stock) do
        total = total + (entry.qty or 0)
    end
    return total
end

-- Horas que faltan para el proximo restock (>= 0).
function MBM.HoursToRestock(data)
    if not data or type(data.nextRestockHour) ~= "number" then return 0 end
    local left = data.nextRestockHour - MBM.NowHours()
    if left < 0 then return 0 end
    return left
end

-- true si hay mercado con el que comerciar ahora mismo.
function MBM.IsMarketOpen(data)
    if not data then return false end
    if data.permanentlyKilled then return false end
    return data.merchantAlive == true
end

-- ---------------------------------------------------------------------------
-- EVENTO LUA PROPIO
-- La UI (Fase 3) y la radio se enganchan aqui en vez de sondear el ModData por
-- frame. Se dispara cuando llega estado nuevo del servidor o cambia el local.
-- ---------------------------------------------------------------------------
if type(LuaEventManager) == "table" and type(LuaEventManager.AddEvent) == "function" then
    pcall(LuaEventManager.AddEvent, "OnMBMarketStateChanged")
end

function MBM.FireStateChanged()
    if Events and Events.OnMBMarketStateChanged then
        pcall(function() triggerEvent("OnMBMarketStateChanged") end)
    end
end

-- ---------------------------------------------------------------------------
-- SINCRONIZACION AL CONECTARSE (lado cliente)
-- Este archivo tambien corre en el cliente, asi que el arranque de la
-- sincronizacion vive aqui y no espera a la UI de la Fase 3: cuando el jugador
-- entra al mundo pide el ModData global y ademas manda RequestSync (cinturon y
-- tirantes: si el transmit se perdio, el snapshot dirigido lo cubre).
-- En single player no hay red: el ModData ya esta en memoria.
-- ---------------------------------------------------------------------------
local function OnCreatePlayer(playerIndex)
    if not isClient() then return end
    if playerIndex ~= 0 then return end   -- splitscreen: una sola peticion

    local ok, err = pcall(function()
        ModData.request(MBM.MODDATA_KEY)
        sendClientCommand(getPlayer(), MBM.NET.MODULE, MBM.NET.C_SYNC, {})
    end)
    if not ok then MBM.LogError("OnCreatePlayer/sync", err) end
end

local function OnReceiveGlobalModData(key, data)
    if key ~= MBM.MODDATA_KEY then return end
    MBM.Log("Estado del mercado recibido del servidor")
    MBM.FireStateChanged()
end

Events.OnCreatePlayer.Add(OnCreatePlayer)
Events.OnReceiveGlobalModData.Add(OnReceiveGlobalModData)

MBM.Log("shared cargado v" .. MBM.VERSION)
