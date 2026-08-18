--[[==========================================================================
    MaurinBombinServer.lua
    Ecosistema "MaurinBombin Market" - Sub-mod Bandits: Tactical Expansion (B42)
    FASE 1 de 3 -- EL CEREBRO: stock global, restock, transacciones, permadeath

    ---------------------------------------------------------------------------
    POR QUE ESTE ARCHIVO ESTA EN server/
    ---------------------------------------------------------------------------
    media/lua/server/ se ejecuta en los TRES modos:
      - single player      (juego y "servidor" en el mismo proceso)
      - anfitrion          (lo ejecuta el servidor interno, proceso aparte)
      - servidor dedicado
    ...y NO se ejecuta en los clientes conectados. Con una sola implementacion
    hay EXACTAMENTE UNA autoridad en cualquier modo, sin ramificar por
    isCoopHost(). Es el mismo reparto que ya usa TacticalSpawnServer.lua.

    ---------------------------------------------------------------------------
    LAS DOS VIAS DE ENTRADA (importante para la Fase 3)
    ---------------------------------------------------------------------------
    En single player los comandos de red NO se enrutan (no hay red). Por eso el
    servidor expone dos puertas a la MISMA logica:

      MULTIJUGADOR : cliente -> sendClientCommand("MBMarket", "Buy", ...)
                     -> Events.OnClientCommand -> MBMServer.HandleBuy

      SINGLE PLAYER: la UI llama DIRECTO a MBMServer.HandleBuy(player, args),
                     porque este archivo vive en el mismo proceso.

    La Fase 3 elige con: if isClient() then sendClientCommand(...) else
    MaurinBombinServer.HandleBuy(getPlayer(), args) end

    ---------------------------------------------------------------------------
    ANTI-CLONACION: EL STOCK SE RESERVA ANTES DE ENTREGAR
    ---------------------------------------------------------------------------
    El agujero clasico de un mercado en MP es que dos jugadores compren "la
    ultima" a la vez, o que un cliente modificado pida la entrega dos veces.
    Aqui la unica fuente de verdad es el ModData del servidor y el orden es
    siempre: validar -> DESCONTAR (reserva) -> entregar -> confirmar.
    Si la entrega no se confirma (cliente caido, inventario lleno, timeout), se
    hace ROLLBACK y la unidad vuelve al stock. Nunca hay dos entregas por una
    sola unidad, y nunca se pierde una unidad por un fallo de red.

    ---------------------------------------------------------------------------
    RENDIMIENTO
    ---------------------------------------------------------------------------
    Cero enganches a OnTick/OnPlayerUpdate. El cerebro late en EveryHours
    (restock, permadeath) y EveryOneMinute (caducidad de transacciones). Las
    unicas tablas que se instancian son las del stock nuevo (cada 3 dias
    in-game) y la de una transaccion pendiente (una por compra).
============================================================================]]

if isClient() then return end            -- un cliente conectado nunca ejecuta esto
if MaurinBombinServer then return end     -- guarda anti doble carga

MaurinBombinServer = {}
local MBMServer = MaurinBombinServer
local MBM       = MaurinBombin

MBMServer.VERSION = "1.0.0"

-- Cache de globales (patron del resto del mod: evita el lookup por nombre en
-- cada llamada dentro de los eventos).
local ZombRand    = ZombRand
local math_floor  = math.floor
local pcall       = pcall
local type        = type
local pairs       = pairs
local tostring    = tostring
local tonumber    = tonumber
local getTimestampMs = getTimestampMs

local NET    = MBM.NET
local REASON = MBM.REASON
local CFG    = MBM.Config

-- ===========================================================================
-- 1. ESTADO PERSISTENTE (ModData)
-- ===========================================================================
--[[
    Esquema de MaurinBombin_Market:

    {
      schema           = 1,
      stock            = { [entryId] = {id, item, tier, price, qty} },
      order            = { entryId, ... },      -- orden estable de listado (UI)
      restockCount     = n,                     -- num. de reposiciones hechas
      lastRestockHour  = horas de mundo,
      nextRestockHour  = horas de mundo,
      soldOut          = bool,                  -- se vacio el stock global
      merchantAlive    = bool,
      permanentlyKilled= bool,                  -- mercader asesinado
      respawnHour      = horas de mundo o nil,  -- cuando puede volver el clan
      location         = {x, y, z} o nil,       -- puesto actual (lo fija Fase 2)
      squad            = { [uid] = role },       -- integrantes vivos registrados
      serial           = n,                      -- sube en cada cambio (la UI compara)
    }
]]

-- Normaliza/migra el ModData. Es la UNICA funcion que crea claves nuevas: el
-- resto del archivo da por hecho que ya existen.
function MBMServer.EnsureData()
    local data = ModData.getOrCreate(MBM.MODDATA_KEY)

    if data.schema ~= MBM.SCHEMA then
        -- Migracion. Hoy solo hay un esquema, asi que "migrar" es sembrar los
        -- valores por defecto sin tocar lo que ya sea coherente.
        data.schema = MBM.SCHEMA
    end

    if type(data.stock) ~= "table" then data.stock = {} end
    if type(data.order) ~= "table" then data.order = {} end
    if type(data.squad) ~= "table" then data.squad = {} end
    if type(data.serial) ~= "number" then data.serial = 0 end
    if type(data.restockCount) ~= "number" then data.restockCount = 0 end
    if type(data.merchantAlive) ~= "boolean" then data.merchantAlive = false end
    if type(data.permanentlyKilled) ~= "boolean" then data.permanentlyKilled = false end

    if type(data.nextRestockHour) ~= "number" then
        data.nextRestockHour = MBM.NowHours()   -- primera partida: repone ya
    end

    return data
end

-- ===========================================================================
-- 2. DIFUSION DEL ESTADO
-- ===========================================================================

-- Snapshot publico. Se instancia SOLO cuando hay que mandarlo (compra,
-- restock, peticion de sincronizacion), nunca por frame.
function MBMServer.BuildSnapshot(data)
    data = data or MBMServer.EnsureData()

    local stock = {}
    for i = 1, #data.order do
        local id = data.order[i]
        local e  = data.stock[id]
        if e then
            stock[#stock + 1] = {
                id    = e.id,
                item  = e.item,
                tier  = e.tier,
                price = e.price,
                qty   = e.qty,
            }
        end
    end

    return {
        serial          = data.serial,
        stock           = stock,
        open            = MBM.IsMarketOpen(data),
        soldOut         = data.soldOut == true,
        permanentlyKilled = data.permanentlyKilled == true,
        nextRestockHour = data.nextRestockHour,
        respawnHour     = data.respawnHour,
        location        = data.location,
        nowHour         = MBM.NowHours(),
    }
end

-- Publica el estado a todo el mundo.
--   MP  : ModData.transmit (estado completo persistente) + comando de estado
--         (llega al instante y trae el snapshot ya masticado para la UI).
--   SP  : no hay red; basta con disparar el evento local, porque la UI lee la
--         MISMA tabla de ModData en memoria.
function MBMServer.Broadcast(data)
    data = data or MBMServer.EnsureData()
    data.serial = (data.serial or 0) + 1

    if isServer() then
        local ok, err = pcall(function()
            ModData.transmit(MBM.MODDATA_KEY)
            sendServerCommand(NET.MODULE, NET.S_STATE, MBMServer.BuildSnapshot(data))
        end)
        if not ok then MBM.LogError("Broadcast", err) end
    else
        MBM.FireStateChanged()
    end
end

-- Respuesta dirigida a un solo jugador (sincronizacion al conectarse).
local function SendTo(player, command, args)
    if not isServer() then return end   -- en SP la UI lee el ModData directo
    local ok, err = pcall(sendServerCommand, player, NET.MODULE, command, args)
    if not ok then MBM.LogError("SendTo/" .. tostring(command), err) end
end

-- ===========================================================================
-- 3. RESTOCK
-- ===========================================================================

-- Sorteo sin repeticion dentro de un tramo: se copia la lista de candidatos y
-- se van sacando. La copia es de 6-11 strings y ocurre 1 vez cada 3 dias.
local function PickDistinct(items, count)
    local pool = {}
    for i = 1, #items do pool[i] = items[i] end

    local picked = {}
    for _ = 1, count do
        local n = #pool
        if n == 0 then break end
        local idx = ZombRand(n) + 1
        picked[#picked + 1] = pool[idx]
        pool[idx] = pool[n]     -- swap-remove: O(1) y no deja huecos
        pool[n]   = nil
    end
    return picked
end

local function RandRange(minV, maxV)
    if maxV <= minV then return minV end
    return minV + ZombRand(maxV - minV + 1)
end

-- Arma un inventario nuevo desde los pools. Sustituye al anterior por
-- completo: lo que no se vendio se lo lleva el mercader.
function MBMServer.Restock(reason)
    local data = MBMServer.EnsureData()

    -- Con el mercader muerto no hay a quien reponerle nada.
    if data.permanentlyKilled then
        MBM.Log("Restock omitido: mercado en permadeath")
        return false
    end

    local stock, order = {}, {}
    local serialSeed = (data.restockCount or 0) + 1

    for p = 1, #MBM.Pools do
        local pool = MBM.Pools[p]
        if ZombRand(100) < (pool.chance or 100) then
            local chosen = PickDistinct(pool.items, pool.slots or 1)
            for c = 1, #chosen do
                -- Id estable y unico dentro del restock: la UI y el comando de
                -- compra viajan con este id, nunca con un indice de lista (un
                -- indice se desplaza al agotarse un articulo y el jugador
                -- acabaria comprando otra cosa).
                local entryId = "r" .. serialSeed .. "_" .. pool.tier .. "_" .. c
                stock[entryId] = {
                    id    = entryId,
                    item  = chosen[c],
                    tier  = pool.tier,
                    price = RandRange(pool.priceMin, pool.priceMax),
                    qty   = RandRange(pool.qtyMin, pool.qtyMax),
                }
                order[#order + 1] = entryId
            end
        end
    end

    data.stock           = stock
    data.order           = order
    data.restockCount    = serialSeed
    data.lastRestockHour = MBM.NowHours()
    data.soldOut         = false
    data.nextRestockHour = data.lastRestockHour + CFG.RestockHours

    MBMServer.Broadcast(data)
    print("[MaurinBombin] Restock (" .. tostring(reason or "ciclo") .. "): " ..
          #order .. " articulos, proximo en " .. CFG.RestockHours .. "h de mundo.")
    return true
end

-- Excepcion del brief: si el stock global llega a 0, el temporizador de 3 dias
-- se SOBREESCRIBE y la reposicion pasa a manana.
local function CheckSoldOut(data)
    if data.soldOut then return end
    if MBM.TotalUnits(data) > 0 then return end

    data.soldOut         = true
    data.nextRestockHour = MBM.NowHours() + CFG.SoldOutHours
    print("[MaurinBombin] Stock agotado: reposicion adelantada a " ..
          CFG.SoldOutHours .. "h de mundo.")
end

-- Latido horario: reposicion y fin del permadeath. EveryHours es un evento de
-- reloj de mundo, o sea que respeta la velocidad de tiempo del sandbox.
local function OnEveryHours()
    local ok, err = pcall(function()
        local data = MBMServer.EnsureData()
        local now  = MBM.NowHours()

        -- Fin del castigo: el clan puede volver a aparecer (el spawner de la
        -- Fase 2 consulta MBMServer.IsMarketAllowed antes de intentarlo).
        if data.permanentlyKilled and type(data.respawnHour) == "number"
           and now >= data.respawnHour then
            data.permanentlyKilled = false
            data.respawnHour       = nil
            data.nextRestockHour   = now      -- al reaparecer, con genero fresco
            print("[MaurinBombin] Han pasado 15 dias: el mercado puede volver a aparecer.")
            MBMServer.Broadcast(data)
        end

        if not data.permanentlyKilled and now >= (data.nextRestockHour or 0) then
            MBMServer.Restock(data.soldOut and "agotado" or "ciclo")
        end
    end)
    if not ok then MBM.LogError("OnEveryHours", err) end
end

-- ===========================================================================
-- 4. TRANSACCIONES
-- ===========================================================================

-- Antiflood por jugador y comando (misma tabla plana que usa
-- TacticalSpawnServer: se purga en el barrido lento).
local netLimit = {}

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
    if last and (now - last) < (cooldownMs or CFG.BuyCooldownMs) then return false end
    perPlayer[command] = now
    return true
end

-- Proximidad al puesto. Si la Fase 2 aun no registro la ubicacion (mercado no
-- spawneado en este arranque), no se puede comprobar: se deja pasar y se
-- confia en las demas barreras (stock, dinero, antiflood). Ese caso solo
-- ocurre antes de que exista mercader, y sin mercader IsMarketOpen ya corta.
local function NearMarket(player, data)
    local loc = data.location
    if type(loc) ~= "table" then return true end
    if not player then return false end

    local ok, px, py = pcall(function() return player:getX(), player:getY() end)
    if not ok then return false end

    local dx, dy = px - (loc.x or 0), py - (loc.y or 0)
    local r = CFG.PurchaseRange
    return (dx * dx + dy * dy) <= (r * r)
end

-- --- Transacciones en vuelo (entrega diferida) -----------------------------
-- Solo se usan cuando la autoridad NO comparte proceso con el comprador
-- (dedicado, o clientes del modo anfitrion). Ver la nota de arquitectura.
local pending      = {}   -- [txId] = {user, entryId, item, qty, cost, ms}
local pendingCount = {}   -- [user] = num. de transacciones en vuelo
local txSeq        = 0

local function NewTxId(user)
    txSeq = txSeq + 1
    return tostring(user) .. "#" .. txSeq
end

-- Devuelve las unidades al stock. Se llama cuando la entrega falla o caduca.
local function RollbackStock(data, entryId, qty)
    local entry = data.stock[entryId]
    if entry then
        entry.qty = (entry.qty or 0) + qty
        if data.soldOut then
            -- Volvio a haber genero: se restablece el ciclo normal.
            data.soldOut = false
            data.nextRestockHour = (data.lastRestockHour or MBM.NowHours()) + CFG.RestockHours
        end
    end
    -- Si la entrada ya no existe (hubo restock entre medias), la unidad
    -- simplemente se pierde: reinsertarla en un catalogo nuevo confundiria al
    -- jugador y abriria un vector de inyeccion de articulos arbitrarios.
end

local function ClosePending(txId)
    local tx = pending[txId]
    if not tx then return nil end
    pending[txId] = nil
    local n = (pendingCount[tx.user] or 1) - 1
    pendingCount[tx.user] = (n > 0) and n or nil
    return tx
end

-- Caducidad. EveryOneMinute es tiempo de mundo, pero el timeout se mide en ms
-- reales: si el jugador se desconecto a mitad de compra, la unidad vuelve al
-- stock aunque el reloj del mundo este parado por pausa.
local function PurgePending()
    local ok, err = pcall(function()
        local now  = getTimestampMs()
        local data = MBMServer.EnsureData()
        local dirty = false

        for txId, tx in pairs(pending) do
            if (now - tx.ms) > CFG.DeliveryTimeoutMs then
                RollbackStock(data, tx.entryId, tx.qty)
                ClosePending(txId)
                dirty = true
                MBM.Log("Transaccion " .. txId .. " caducada: stock devuelto")
            end
        end

        -- Purga del antiflood: una entrada por jugador y comando, no debe
        -- acumularse durante toda la vida del servidor.
        for name, cmds in pairs(netLimit) do
            local empty = true
            for cmd, ms in pairs(cmds) do
                if (now - ms) > 60000 then cmds[cmd] = nil else empty = false end
            end
            if empty then netLimit[name] = nil end
        end

        if dirty then MBMServer.Broadcast(data) end
    end)
    if not ok then MBM.LogError("PurgePending", err) end
end

-- --- Resultado al comprador ------------------------------------------------
local function Reply(player, ok, reason, entryId, qty, cost)
    if isServer() then
        SendTo(player, NET.S_RESULT, {
            ok = ok, reason = reason, entryId = entryId, qty = qty, cost = cost,
        })
    end
    -- En SP el valor de retorno de HandleBuy es la respuesta (la UI lo lee).
    return ok, reason
end

-- ---------------------------------------------------------------------------
-- HandleBuy: EL punto autoritativo de compra.
-- Escalera de validacion (todo paquete es hostil hasta probar lo contrario):
--   1. tipos      -> nada de strings donde se esperan cantidades
--   2. antiflood  -> por jugador y comando
--   3. mercado    -> existe y no esta en permadeath
--   4. proximidad -> el jugador esta junto al puesto
--   5. stock      -> hay unidades AHORA (no cuando el cliente miro la lista)
--   6. dinero     -> Base.Money suficiente
-- Recien entonces: descontar stock (reserva) -> cobrar -> entregar.
-- ---------------------------------------------------------------------------
function MBMServer.HandleBuy(player, args)
    if not player then return false, REASON.BAD_REQUEST end
    if type(args) ~= "table" then return Reply(player, false, REASON.BAD_REQUEST) end

    local entryId = args.entryId
    local qty     = math_floor(tonumber(args.qty) or 0)
    if type(entryId) ~= "string" or qty < 1 then
        return Reply(player, false, REASON.BAD_REQUEST, entryId, qty)
    end
    if qty > CFG.MaxQtyPerTx then qty = CFG.MaxQtyPerTx end

    if not PassRateLimit(player, NET.C_BUY, CFG.BuyCooldownMs) then
        return Reply(player, false, REASON.BUSY, entryId, qty)
    end

    local user = PlayerName(player)
    if (pendingCount[user] or 0) >= CFG.MaxPendingPerPlayer then
        return Reply(player, false, REASON.BUSY, entryId, qty)
    end

    local data = MBMServer.EnsureData()

    if not MBM.IsMarketOpen(data) then
        return Reply(player, false, REASON.NO_MARKET, entryId, qty)
    end
    if not NearMarket(player, data) then
        return Reply(player, false, REASON.TOO_FAR, entryId, qty)
    end

    local entry = data.stock[entryId]
    if not entry or (entry.qty or 0) <= 0 then
        return Reply(player, false, REASON.NO_STOCK, entryId, qty)
    end
    if qty > entry.qty then qty = entry.qty end

    local cost = entry.price * qty

    -- Comprobacion de dinero del lado del servidor. CountMoney puede devolver
    -- nil si el inventario del jugador remoto todavia no esta replicado en
    -- este proceso; en ese caso NO se rechaza (bloquearia compras legitimas):
    -- se delega el cobro al cliente, que responde ok=false si no puede pagar y
    -- entonces se hace rollback. El stock, que es el recurso escaso y global,
    -- ya quedo reservado, asi que nadie puede clonarlo por esta via.
    local money = MBM.CountMoney(player)
    if money ~= nil and money < cost then
        return Reply(player, false, REASON.NO_MONEY, entryId, qty, cost)
    end

    -- ---- RESERVA: se descuenta ANTES de entregar ----
    entry.qty = entry.qty - qty
    CheckSoldOut(data)

    -- ---- Entrega ----
    if not MBM.IsRemoteAuthority() then
        -- Single player: mismo proceso, transaccion atomica de verdad.
        local paid, taken = MBM.RemoveMoney(player, cost)
        if not paid then
            -- Cobro a medias (dinero repartido en contenedores que no se
            -- pudieron tocar): se reembolsa lo retirado y se anula todo.
            if (taken or 0) > 0 then MBM.GiveItems(player, CFG.MoneyItem, taken) end
            RollbackStock(data, entryId, qty)
            MBMServer.Broadcast(data)
            return Reply(player, false, REASON.NO_MONEY, entryId, qty, cost)
        end

        local given = MBM.GiveItems(player, entry.item, qty)
        if given < qty then
            -- Entrega parcial: se devuelve al stock lo que no llego y se
            -- reembolsa su parte proporcional.
            local missing = qty - given
            RollbackStock(data, entryId, missing)
            MBM.GiveItems(player, CFG.MoneyItem, missing * entry.price)
            MBM.LogError("HandleBuy", "entrega parcial de " .. tostring(entry.item))
        end

        MBMServer.Broadcast(data)
        return Reply(player, given > 0, given > 0 and REASON.OK or REASON.FAILED,
                     entryId, given, given * entry.price)
    end

    -- Multijugador: ENTREGA DIFERIDA. El servidor no puede manipular con
    -- garantias el inventario de un jugador remoto, asi que firma una orden de
    -- entrega de un solo uso y el cliente la ejecuta sobre SU inventario. La
    -- orden solo existe porque el servidor ya valido y ya reservo el stock: un
    -- cliente no puede fabricarla ni repetirla (el txId se cierra al primer
    -- ACK; ver HandleAck).
    local txId = NewTxId(user)
    pending[txId] = {
        user    = user,
        entryId = entryId,
        item    = entry.item,
        qty     = qty,
        cost    = cost,
        ms      = getTimestampMs(),
    }
    pendingCount[user] = (pendingCount[user] or 0) + 1

    MBMServer.Broadcast(data)
    SendTo(player, NET.S_DELIVER, {
        txId = txId, item = entry.item, qty = qty, cost = cost, entryId = entryId,
    })
    return true, REASON.OK
end

-- Confirmacion del cliente sobre una orden de entrega.
function MBMServer.HandleAck(player, args)
    if not player or type(args) ~= "table" then return end
    local txId = args.txId
    if type(txId) ~= "string" then return end

    local tx = pending[txId]
    if not tx then return end                       -- caducada, o ACK repetido
    if tx.user ~= PlayerName(player) then           -- ACK de otro jugador: fuera
        MBM.LogError("HandleAck", "txId ajeno de " .. PlayerName(player))
        return
    end

    ClosePending(txId)

    if args.ok == true then
        MBM.Log("Transaccion " .. txId .. " confirmada")
        return
    end

    -- El cliente no pudo pagar o no pudo recibir: la unidad vuelve al stock.
    local data = MBMServer.EnsureData()
    RollbackStock(data, tx.entryId, tx.qty)
    MBMServer.Broadcast(data)
    Reply(player, false, REASON.FAILED, tx.entryId, tx.qty, tx.cost)
end

-- ===========================================================================
-- 5. PERMADEATH Y TIERRA QUEMADA
-- ===========================================================================

-- API para la Fase 2: el spawner avisa de donde quedo el puesto y quienes son
-- sus integrantes. Sin esto no hay comprobacion de proximidad ni validacion de
-- los avisos de muerte.
function MBMServer.RegisterMarket(x, y, z, members)
    local data = MBMServer.EnsureData()

    data.location      = {x = math_floor(x or 0), y = math_floor(y or 0), z = math_floor(z or 0)}
    data.merchantAlive = true
    data.squad         = {}
    -- Sello para el modo dinamico del planificador (Fase 2): marca "hubo
    -- mercado en esta hora", que es desde donde se cuenta el tiempo sin el.
    data.lastMarketHour = MBM.NowHours()

    if type(members) == "table" then
        for uid, role in pairs(members) do
            data.squad[uid] = role
        end
    end

    -- Puesto nuevo, genero fresco si tocaba.
    if MBM.TotalUnits(data) <= 0 then
        MBMServer.Restock("apertura")
    else
        MBMServer.Broadcast(data)
    end

    print("[MaurinBombin] Mercado registrado en " .. tostring(data.location.x) ..
          "," .. tostring(data.location.y))
    return true
end

-- Lo consulta el planificador de spawn de la Fase 2 antes de intentar nada.
function MBMServer.IsMarketAllowed()
    local data = MBMServer.EnsureData()
    if data.permanentlyKilled then return false end
    if data.merchantAlive then return false end   -- ya hay uno vivo por ahi
    return true
end

-- Nucleo de la muerte de un integrante. Se llama desde OnZombieDead (via
-- directa) y desde el aviso de un cliente (respaldo validado).
function MBMServer.KillMember(role, uid)
    if role ~= MBM.ROLE_MERCHANT and role ~= MBM.ROLE_GUARD then return false end

    local data = MBMServer.EnsureData()
    if uid then data.squad[uid] = nil end

    if role ~= MBM.ROLE_MERCHANT then
        -- Guardia: no cambia el estado del mercado, pero su equipo tampoco se
        -- saquea (el vaciado ya lo hizo quien llamo).
        return true
    end

    if data.permanentlyKilled then return false end   -- ya estaba registrado

    data.merchantAlive     = false
    data.permanentlyKilled = true
    data.lastMarketHour    = MBM.NowHours()   -- desde aqui cuenta el tiempo sin mercado
    data.respawnHour       = MBM.NowHours() + CFG.RespawnHours
    data.nextRestockHour   = data.respawnHour
    data.stock             = {}     -- sin mercader no hay catalogo
    data.order             = {}
    data.soldOut           = false
    data.location          = nil

    MBMServer.Broadcast(data)
    print("[MaurinBombin] Mercader asesinado. El mercado vuelve en " ..
          math_floor(CFG.RespawnHours / 24) .. " dias de mundo.")
    return true
end

-- ---------------------------------------------------------------------------
-- Events.OnZombieDead: tierra quemada.
-- Se vacia el inventario EN EL ACTO, antes de que el motor materialice el
-- cadaver saqueable. La identificacion NO depende del brain: Bandits2 lo borra
-- en su propio handler de este mismo evento y sus handlers corren primero (ver
-- la nota larga en 00_MaurinBombinShared.lua / MBM.GetNPCRole).
-- ---------------------------------------------------------------------------
local function OnZombieDead(zombie)
    if not zombie then return end

    local ok, err = pcall(function()
        local role, uid = MBM.GetNPCRole(zombie)
        if not role then return end

        MBM.StripInventory(zombie)          -- no sueltan absolutamente nada
        MBMServer.KillMember(role, uid)
    end)
    if not ok then MBM.LogError("OnZombieDead", err) end
end

-- Respaldo por red: si en un dedicado el evento de muerte no llegara a
-- dispararse en el proceso del servidor, el cliente que lo presencio lo avisa.
-- El aviso NO se cree a ciegas: el uid tiene que estar en el escuadron
-- registrado por la Fase 2 y el jugador tiene que estar cerca. Como el uid se
-- borra al procesarlo, un aviso repetido no hace nada.
function MBMServer.HandleNPCDown(player, args)
    if not player or type(args) ~= "table" then return end
    local uid = args.uid
    if type(uid) ~= "string" then return end
    if not PassRateLimit(player, NET.C_NPCDOWN, CFG.ReportCooldownMs) then return end

    local data = MBMServer.EnsureData()
    local role = data.squad[uid]
    if not role then return end                     -- uid desconocido: se ignora

    local loc = data.location
    if type(loc) == "table" then
        local okPos, px, py = pcall(function() return player:getX(), player:getY() end)
        if not okPos then return end
        local dx, dy = px - (loc.x or 0), py - (loc.y or 0)
        if (dx * dx + dy * dy) > (CFG.ReportRange * CFG.ReportRange) then return end
    end

    MBMServer.KillMember(role, uid)
end

-- ===========================================================================
-- 6. COMANDOS DE CLIENTE
-- ===========================================================================
local function onClientCommand(module, command, player, args)
    if module ~= NET.MODULE then return end
    if not player then return end

    if command == NET.C_SYNC then
        if not PassRateLimit(player, NET.C_SYNC, CFG.SyncCooldownMs) then return end
        local data = MBMServer.EnsureData()
        pcall(ModData.transmit, MBM.MODDATA_KEY)
        SendTo(player, NET.S_STATE, MBMServer.BuildSnapshot(data))

    elseif command == NET.C_BUY then
        pcall(MBMServer.HandleBuy, player, args)

    elseif command == NET.C_ACK then
        pcall(MBMServer.HandleAck, player, args)

    elseif command == NET.C_NPCDOWN then
        pcall(MBMServer.HandleNPCDown, player, args)
    end
end

-- ===========================================================================
-- 7. ARRANQUE
-- ===========================================================================
local initDone = false

function MBMServer.Init()
    if initDone then return end    -- se engancha a dos eventos: el primero manda
    initDone = true

    local data = MBMServer.EnsureData()

    -- Un reinicio del servidor no deja mercaderes vivos: los NPC no persisten
    -- como entidades del mod, los vuelve a crear el spawner de la Fase 2. Si
    -- no se limpiase, IsMarketAllowed diria "ya hay uno" para siempre.
    if data.merchantAlive then
        data.merchantAlive = false
        data.location      = nil
        data.squad         = {}
    end

    -- Primer arranque en una partida ya empezada: nada de reponer con fecha
    -- antigua, se cuenta desde ahora.
    if type(data.nextRestockHour) ~= "number" or data.nextRestockHour <= 0 then
        data.nextRestockHour = MBM.NowHours()
    end

    Events.EveryHours.Remove(OnEveryHours)
    Events.EveryHours.Add(OnEveryHours)

    Events.EveryOneMinute.Remove(PurgePending)
    Events.EveryOneMinute.Add(PurgePending)

    Events.OnZombieDead.Remove(OnZombieDead)
    Events.OnZombieDead.Add(OnZombieDead)

    Events.OnClientCommand.Remove(onClientCommand)
    Events.OnClientCommand.Add(onClientCommand)

    print("[MaurinBombinServer] v" .. MBMServer.VERSION ..
          " activo (stock: " .. MBM.TotalUnits(data) .. " unidades, " ..
          (data.permanentlyKilled and "mercader MUERTO" or "mercader disponible") .. ")")
end

-- Se engancha a los dos eventos de arranque porque cual llega primero depende
-- del modo: en un dedicado el ModData global se inicializa antes de que el
-- mundo termine de levantar, y en single player pasa al reves. MBMServer.Init
-- es idempotente (initDone), asi que el segundo aviso no hace nada.
local function Bootstrap()
    local ok, err = pcall(MBMServer.Init)
    if not ok then MBM.LogError("Init", err) end
end

Events.OnInitGlobalModData.Add(Bootstrap)
Events.OnGameStart.Add(Bootstrap)
