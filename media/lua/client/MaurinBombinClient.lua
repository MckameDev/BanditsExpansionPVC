--[[==========================================================================
    MaurinBombinClient.lua
    Ecosistema "MaurinBombin Market" - FASE 3 de 3
    CAPA DE CLIENTE: cache de estado, ejecucion de entregas y feedback

    ---------------------------------------------------------------------------
    QUE HACE ESTE ARCHIVO
    ---------------------------------------------------------------------------
    Es la mitad "musculo" del contrato que definio la Fase 1. El servidor manda
    ordenes; aqui se ejecutan sobre el inventario del jugador local, que es el
    unico inventario que este proceso puede tocar con garantias.

      S_STATE   -> se guarda el snapshot y se avisa a la UI
      S_RESULT  -> feedback en pantalla (compra aceptada o rechazada)
      S_DELIVER -> ENTREGA: cobrar y entregar sobre MI inventario, y confirmar

    ---------------------------------------------------------------------------
    LA ENTREGA ES ATOMICA O NO ES
    ---------------------------------------------------------------------------
    El servidor ya reservo el stock antes de mandar la orden, asi que aqui solo
    puede pasar una de dos cosas: la entrega se completa entera y se confirma
    (ok=true), o no se toca nada y se avisa del fallo (ok=false) para que el
    servidor devuelva las unidades al stock. Nunca se deja al jugador pagando
    sin recibir, ni recibiendo sin pagar. El orden elegido -- comprobar dinero,
    entregar items, cobrar, y deshacer lo hecho ante cualquier fallo -- es lo
    que garantiza eso incluso si el inventario se llena a mitad.

    ---------------------------------------------------------------------------
    SINGLE PLAYER
    ---------------------------------------------------------------------------
    En SP no hay red: MBMClient.RequestBuy llama DIRECTO a
    MaurinBombinServer.HandleBuy (que vive en el mismo proceso y hace la
    transaccion completa alli mismo). Este archivo no ejecuta ninguna entrega
    en SP: solo traduce el resultado a feedback.
============================================================================]]

if isServer() then return end          -- un dedicado no ejecuta client/
if MaurinBombinClient then return end    -- guarda anti doble carga

MaurinBombinClient = {}
local MBMC = MaurinBombinClient
local MBM  = MaurinBombin

MBMC.VERSION = "1.0.0"

local pcall    = pcall
local type     = type
local tostring = tostring

-- Ultimo snapshot recibido del servidor. Es un respaldo del ModData: si el
-- transmit todavia no llego, la UI puede pintar con esto.
MBMC.snapshot = nil

-- ---------------------------------------------------------------------------
-- FEEDBACK EN PANTALLA
-- HaloTextHelper es lo que usa el juego para los avisos flotantes sobre el
-- personaje; si no estuviera disponible se cae al texto de linea, que es lo
-- que ya usa este submod para los dialogos de bandidos.
-- ---------------------------------------------------------------------------
function MBMC.Notify(text, good)
    local player = getPlayer()
    if not player or type(text) ~= "string" then return end

    local r, g, b = 0.9, 0.9, 0.9
    if good == true then r, g, b = 0.4, 1.0, 0.4
    elseif good == false then r, g, b = 1.0, 0.4, 0.4 end

    if type(HaloTextHelper) == "table" and type(HaloTextHelper.addText) == "function" then
        if pcall(HaloTextHelper.addText, player, text, r, g, b) then return end
    end
    pcall(player.addLineChatElement, player, text, r, g, b)
end

-- Traduce un codigo de rechazo del servidor a texto del idioma del jugador.
local REASON_KEY = {
    [MBM.REASON.NO_MARKET]   = "UI_MBM_ErrNoMarket",
    [MBM.REASON.NO_STOCK]    = "UI_MBM_ErrNoStock",
    [MBM.REASON.NO_MONEY]    = "UI_MBM_ErrNoMoney",
    [MBM.REASON.TOO_FAR]     = "UI_MBM_ErrTooFar",
    [MBM.REASON.BAD_REQUEST] = "UI_MBM_ErrBadRequest",
    [MBM.REASON.BUSY]        = "UI_MBM_ErrBusy",
    [MBM.REASON.FAILED]      = "UI_MBM_ErrFailed",
}

function MBMC.ReasonText(reason)
    local key = REASON_KEY[reason]
    if not key then return getText("UI_MBM_ErrFailed") end
    return getText(key)
end

-- ---------------------------------------------------------------------------
-- LECTURA DEL ESTADO
-- Fuente preferente: el ModData global, que el servidor replica con
-- ModData.transmit y que en single player YA es la tabla viva del servidor.
-- El snapshot dirigido solo se usa si el ModData aun esta vacio (cliente recien
-- conectado cuyo transmit no llego todavia).
-- ---------------------------------------------------------------------------

-- Devuelve un array {id, item, tier, price, qty} en orden de catalogo, y los
-- metadatos del mercado. Se instancia una tabla por llamada: se llama al abrir
-- la UI y al refrescarla, nunca por frame.
function MBMC.GetCatalog()
    local data = MBM.GetData()

    if data.order and #data.order > 0 then
        local out = {}
        for i = 1, #data.order do
            local entry = data.stock[data.order[i]]
            if entry then out[#out + 1] = entry end
        end
        return out, data
    end

    local snap = MBMC.snapshot
    if snap and type(snap.stock) == "table" and #snap.stock > 0 then
        return snap.stock, snap
    end

    return {}, data
end

-- Dinero del jugador local. Aqui CountMoney nunca devuelve nil (es MI
-- inventario, siempre esta cargado), pero se normaliza igualmente.
function MBMC.GetMoney()
    return MBM.CountMoney(getPlayer()) or 0
end

-- ---------------------------------------------------------------------------
-- PETICION DE COMPRA
-- Unico punto por el que la UI habla con el cerebro. Ramifica por modo porque
-- en single player los comandos de red no se enrutan.
-- ---------------------------------------------------------------------------
function MBMC.RequestBuy(entryId, qty)
    if type(entryId) ~= "string" then return false end
    qty = math.floor(tonumber(qty) or 1)
    if qty < 1 then qty = 1 end

    if isClient() then
        local ok, err = pcall(sendClientCommand, getPlayer(), MBM.NET.MODULE, MBM.NET.C_BUY,
                              {entryId = entryId, qty = qty})
        if not ok then
            MBM.LogError("RequestBuy", err)
            return false
        end
        return true
    end

    -- Single player: el cerebro esta en este mismo proceso.
    if type(MaurinBombinServer) ~= "table" then
        MBMC.Notify(getText("UI_MBM_ErrNoMarket"), false)
        return false
    end

    local ok, accepted, reason = pcall(MaurinBombinServer.HandleBuy, getPlayer(),
                                       {entryId = entryId, qty = qty})
    if not ok then
        MBM.LogError("HandleBuy(SP)", accepted)
        return false
    end

    if accepted then
        MBMC.Notify(getText("UI_MBM_BuyOk"), true)
    else
        MBMC.Notify(MBMC.ReasonText(reason), false)
    end

    MBM.FireStateChanged()
    return accepted == true
end

-- ---------------------------------------------------------------------------
-- EJECUCION DE UNA ORDEN DE ENTREGA (solo multijugador)
-- ---------------------------------------------------------------------------

-- Entrega llevando la cuenta de las instancias creadas, para poder deshacerlas
-- si algo falla despues. La tabla `created` la aporta quien llama.
local function GiveTracked(player, fullType, qty, created)
    local okInv, inv = pcall(player.getInventory, player)
    if not okInv or not inv then return 0 end

    local given = 0
    for _ = 1, qty do
        local item = MBM.CreateItem(fullType)
        if not item then break end
        if not pcall(inv.AddItem, inv, item) then break end
        created[#created + 1] = item
        given = given + 1
    end
    return given
end

local function UndoItems(player, created)
    local okInv, inv = pcall(player.getInventory, player)
    if not okInv or not inv then return end
    for i = 1, #created do
        local item = created[i]
        if not pcall(inv.DoRemoveItem, inv, item) then
            pcall(inv.Remove, inv, item)
        end
    end
end

local function Ack(txId, ok)
    local okSend, err = pcall(sendClientCommand, getPlayer(), MBM.NET.MODULE, MBM.NET.C_ACK,
                              {txId = txId, ok = ok == true})
    if not okSend then MBM.LogError("Ack", err) end
end

local function ExecuteDelivery(args)
    local player = getPlayer()
    if not player then return end

    local txId = args.txId
    local cost = math.floor(tonumber(args.cost) or 0)
    local qty  = math.floor(tonumber(args.qty) or 0)

    if type(txId) ~= "string" or type(args.item) ~= "string" or qty < 1 then
        MBM.LogError("ExecuteDelivery", "orden malformada")
        return
    end

    -- 1. Comprobacion previa: si no alcanza, no se toca nada.
    local money = MBM.CountMoney(player) or 0
    if money < cost then
        Ack(txId, false)
        MBMC.Notify(getText("UI_MBM_ErrNoMoney"), false)
        return
    end

    -- 2. Entrega. Si no cabe todo, se deshace lo entregado.
    local created = {}
    local given = GiveTracked(player, args.item, qty, created)
    if given < qty then
        UndoItems(player, created)
        Ack(txId, false)
        MBMC.Notify(getText("UI_MBM_ErrFailed"), false)
        return
    end

    -- 3. Cobro. Si falla a mitad, se devuelve lo cobrado Y se retiran los items.
    local paid, taken = MBM.RemoveMoney(player, cost)
    if not paid then
        if (taken or 0) > 0 then MBM.GiveItems(player, MBM.Config.MoneyItem, taken) end
        UndoItems(player, created)
        Ack(txId, false)
        MBMC.Notify(getText("UI_MBM_ErrNoMoney"), false)
        return
    end

    Ack(txId, true)
    MBMC.Notify(getText("UI_MBM_BuyOk"), true)
end

-- ---------------------------------------------------------------------------
-- COMANDOS DEL SERVIDOR
-- ---------------------------------------------------------------------------
local function onServerCommand(module, command, args)
    if module ~= MBM.NET.MODULE then return end

    if command == MBM.NET.S_STATE then
        MBMC.snapshot = args
        MBM.FireStateChanged()

    elseif command == MBM.NET.S_RESULT then
        if type(args) ~= "table" then return end
        if args.ok == true then
            MBMC.Notify(getText("UI_MBM_BuyOk"), true)
        else
            MBMC.Notify(MBMC.ReasonText(args.reason), false)
        end
        MBM.FireStateChanged()

    elseif command == MBM.NET.S_DELIVER then
        if type(args) ~= "table" then return end
        local ok, err = pcall(ExecuteDelivery, args)
        if not ok then
            MBM.LogError("ExecuteDelivery", err)
            -- Si nuestra propia ejecucion revento, se avisa como fallo para que
            -- el servidor devuelva el stock en vez de esperar al timeout.
            if type(args.txId) == "string" then Ack(args.txId, false) end
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)

MBM.Log("cliente cargado v" .. MBMC.VERSION)
