--[[==========================================================================
    MaurinBombinUI.lua
    Ecosistema "MaurinBombin Market" - FASE 3 de 3
    INTERFAZ DE TRUEQUE: ISPanel + ISScrollingListBox sobre el Mercader

    ---------------------------------------------------------------------------
    QUE ES Y QUE NO ES
    ---------------------------------------------------------------------------
    Esta ventana es un ESPEJO del estado del servidor, no una fuente de verdad.
    No decide precios, no descuenta stock y no entrega nada: solo pinta lo que
    hay en el ModData replicado y manda la peticion de compra por
    MaurinBombinClient.RequestBuy. Si un jugador modificara este archivo, lo
    unico que conseguiria es mentirse a si mismo en pantalla: el cerebro sigue
    validando cada compra (ver la escalera de MBMServer.HandleBuy).

    ---------------------------------------------------------------------------
    REFRESCO POR EVENTO, NO POR FRAME
    ---------------------------------------------------------------------------
    La lista se reconstruye cuando llega estado nuevo (evento propio
    OnMBMarketStateChanged, que dispara la capa shared al recibir el ModData) y
    tras cada compra. En prerender solo hay un chequeo throttleado de "sigue
    habiendo mercado y sigo cerca", que son dos restas.

    ---------------------------------------------------------------------------
    FORMATO DE FILA (lo que pedia el brief)
    ---------------------------------------------------------------------------
        [icono del articulo]  Nombre del articulo        x3
                              [icono Base.Money] Money: 340 / 120
    El precio se pinta en rojo cuando el jugador no llega.
============================================================================]]

if isServer() then return end        -- un dedicado no ejecuta client/
if MaurinBombinUI then return end     -- guarda anti doble carga

MaurinBombinUI = {}
local UI  = MaurinBombinUI
local MBM = MaurinBombin

UI.VERSION = "1.0.0"

local pcall    = pcall
local type     = type
local tostring = tostring

UI.Config = {
    Width          = 460,
    Height         = 380,
    RowHeight      = 42,
    InteractRange  = 4,     -- casillas: distancia para que aparezca la opcion
    -- La ventana se cierra al MISMO radio con el que el servidor acepta compras
    -- (MBM.Config.PurchaseRange). Si fueran distintos, el jugador podria tener
    -- la ventana abierta a una distancia a la que el cerebro ya rechaza todo,
    -- y solo se enteraria al pulsar Comprar.
    CloseRange     = MaurinBombin.Config.PurchaseRange,
    StateCheckMs   = 500,
}

-- ---------------------------------------------------------------------------
-- RECURSOS
-- La textura de Base.Money se saca instanciando el item una vez y pidiendole
-- su icono. El item temporal no entra en ningun contenedor: muere en el GC.
-- ---------------------------------------------------------------------------
local moneyTex = nil
local moneyTexTried = false

local function GetMoneyTexture()
    if moneyTexTried then return moneyTex end
    moneyTexTried = true

    local item = MBM.CreateItem(MBM.Config.MoneyItem)
    if item then
        local ok, tex = pcall(item.getTex, item)
        if ok then moneyTex = tex end
    end
    return moneyTex
end

-- Nombre e icono de un tipo de item, para pintar el catalogo. Se resuelve al
-- refrescar la lista (una decena de entradas), nunca por frame.
local function DescribeItem(fullType)
    local label, tex = fullType, nil

    local okSm, sm = pcall(getScriptManager)
    if okSm and sm then
        local okScript, script = pcall(sm.getItem, sm, fullType)
        if okScript and script then
            local okName, name = pcall(script.getDisplayName, script)
            if okName and type(name) == "string" and name ~= "" then label = name end
        end
    end

    local item = MBM.CreateItem(fullType)
    if item then
        local okTex, t = pcall(item.getTex, item)
        if okTex then tex = t end
        local okName, name = pcall(item.getDisplayName, item)
        if okName and type(name) == "string" and name ~= "" then label = name end
    end

    return label, tex
end

-- ===========================================================================
-- LISTA
-- ===========================================================================
MBMarketList = ISScrollingListBox:derive("MBMarketList")

function MBMarketList:doDrawItem(y, item, alt)
    local entry = item.item
    local h = self.itemheight
    if not entry then return y + h end

    local w = self:getWidth()

    if self.selected == item.index then
        self:drawRect(0, y, w, h - 1, 0.35, 0.35, 0.55, 0.55)
    elseif alt then
        self:drawRect(0, y, w, h - 1, 0.10, 1.0, 1.0, 1.0)
    end
    self:drawRectBorder(0, y, w, h - 1, 0.30, 0.45, 0.45, 0.45)

    -- icono del articulo
    if entry.tex then
        self:drawTextureScaledAspect(entry.tex, 4, y + 5, 30, 30, 1, 1, 1, 1)
    end

    -- nombre + unidades disponibles
    self:drawText(entry.label, 40, y + 3, 1, 1, 1, 1, UIFont.Small)
    self:drawTextRight("x" .. tostring(entry.qty), w - 8, y + 3, 0.75, 0.75, 0.75, 1, UIFont.Small)

    -- [icono Money] Money: <dinero jugador> / <coste>
    local money = self.playerMoney or 0
    local affordable = money >= (entry.price or 0)
    local px = 40

    if self.moneyTex then
        self:drawTextureScaledAspect(self.moneyTex, px, y + 21, 14, 14, 1, 1, 1, 1)
        px = px + 18
    end

    local text = getText("UI_MBM_MoneyLine", tostring(money), tostring(entry.price))
    if affordable then
        self:drawText(text, px, y + 21, 0.55, 1.0, 0.55, 1, UIFont.Small)
    else
        self:drawText(text, px, y + 21, 1.0, 0.45, 0.45, 1, UIFont.Small)
    end

    return y + h
end

-- ===========================================================================
-- PANEL
-- ===========================================================================
MBMarketPanel = ISPanel:derive("MBMarketPanel")
MBMarketPanel.instance = nil

function MBMarketPanel:new(x, y, width, height, player)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.player         = player
    o.backgroundColor= {r = 0, g = 0, b = 0, a = 0.85}
    o.borderColor    = {r = 0.55, g = 0.45, b = 0.15, a = 1}
    o.moveWithMouse  = true
    o.nextCheck      = 0

    return o
end

function MBMarketPanel:createChildren()
    ISPanel.createChildren(self)

    local pad   = 10
    local top   = 34
    local btnH  = 25
    local listH = self.height - top - btnH - pad * 3

    self.list = MBMarketList:new(pad, top, self.width - pad * 2, listH)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight   = MaurinBombinUI.Config.RowHeight
    self.list.selected     = 0
    self.list.font         = UIFont.Small
    self.list.drawBorder   = true
    self.list.moneyTex     = GetMoneyTexture()
    self.list.playerMoney  = 0
    self:addChild(self.list)

    local btnW = 110
    self.buyBtn = ISButton:new(pad, self.height - btnH - pad, btnW, btnH,
                               getText("UI_MBM_Buy"), self, MBMarketPanel.onOptionMouseDown)
    self.buyBtn.internal = "BUY"
    self.buyBtn:initialise()
    self.buyBtn:instantiate()
    self.buyBtn:setEnable(false)
    self:addChild(self.buyBtn)

    self.closeBtn = ISButton:new(self.width - btnW - pad, self.height - btnH - pad, btnW, btnH,
                                 getText("UI_MBM_Close"), self, MBMarketPanel.onOptionMouseDown)
    self.closeBtn.internal = "CLOSE"
    self.closeBtn:initialise()
    self.closeBtn:instantiate()
    self:addChild(self.closeBtn)

    self:refresh()
end

function MBMarketPanel:onOptionMouseDown(button)
    if button.internal == "CLOSE" then
        self:close()
        return
    end

    if button.internal == "BUY" then
        local row = self.list.items[self.list.selected]
        local entry = row and row.item
        if not entry then return end

        -- Una unidad por clic. El servidor acota igualmente con MaxQtyPerTx:
        -- la UI no es quien pone ese limite.
        MaurinBombinClient.RequestBuy(entry.id, 1)

        -- En multijugador el estado real llega por red; se refresca ya para que
        -- el boton se apague si era la ultima unidad conocida, y otra vez
        -- cuando llegue el estado bueno (OnMBMarketStateChanged).
        self:refresh()
    end
end

-- Reconstruye la lista desde el catalogo replicado.
function MBMarketPanel:refresh()
    if not self.list then return end

    local catalog, data = MaurinBombinClient.GetCatalog()
    local money = MaurinBombinClient.GetMoney()

    local previous = self.list.selected
    self.list:clear()
    self.list.playerMoney = money

    for i = 1, #catalog do
        local e = catalog[i]
        if e and (e.qty or 0) > 0 then
            local label, tex = DescribeItem(e.item)
            self.list:addItem(label, {
                id    = e.id,
                item  = e.item,
                label = label,
                tex   = tex,
                price = e.price,
                qty   = e.qty,
                tier  = e.tier,
            })
        end
    end

    if previous and previous > 0 and previous <= #self.list.items then
        self.list.selected = previous
    end

    -- Pie: cuanto falta para la proxima reposicion.
    self.footer = MaurinBombinUI.RestockText(data)

    if self.buyBtn then
        local row = self.list.items[self.list.selected]
        local entry = row and row.item
        self.buyBtn:setEnable(entry ~= nil and money >= (entry.price or 0))
    end
end

-- El boton se habilita segun la fila seleccionada. Se evalua en prerender y no
-- en onMouseDown porque el clic que cambia la seleccion lo consume la lista
-- (es un hijo), no el panel: el panel nunca se enteraria. Son dos lecturas de
-- tabla y un setEnable, sin instanciar nada.
function MBMarketPanel:updateBuyButton()
    if not self.buyBtn or not self.list then return end
    local row = self.list.items[self.list.selected]
    local entry = row and row.item
    self.buyBtn:setEnable(entry ~= nil and (self.list.playerMoney or 0) >= (entry.price or 0))
end

function MBMarketPanel:prerender()
    ISPanel.prerender(self)
    self:updateBuyButton()

    self:drawText(getText("UI_MBM_Title"), 12, 8, 1, 0.85, 0.35, 1, UIFont.Medium)
    self:drawRect(0, 30, self.width, 1, 0.6, 0.55, 0.45, 0.35)

    if self.footer then
        self:drawText(self.footer, 12, self.height - 48, 0.8, 0.8, 0.8, 1, UIFont.Small)
    end

    -- Chequeo barato y throttleado: si el mercado murio o me aleje, se cierra.
    local now = getTimestampMs()
    if now < self.nextCheck then return end
    self.nextCheck = now + MaurinBombinUI.Config.StateCheckMs

    local data = MBM.GetData()
    if not MBM.IsMarketOpen(data) then
        self:close()
        return
    end

    local loc = data.location
    local player = self.player
    if loc and player then
        local dx, dy = player:getX() - (loc.x or 0), player:getY() - (loc.y or 0)
        local r = MaurinBombinUI.Config.CloseRange
        if (dx * dx + dy * dy) > (r * r) then self:close() end
    end
end

function MBMarketPanel:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if MBMarketPanel.instance == self then MBMarketPanel.instance = nil end
end

-- ---------------------------------------------------------------------------
-- TEXTO DEL PIE / RADIO
-- Se expone porque la radio (MaurinBombinRadio.lua) dice exactamente lo mismo.
-- ---------------------------------------------------------------------------
function UI.RestockText(data)
    if not data then return "" end

    if data.soldOut then return getText("UI_MBM_RestockSoldOut") end

    local hours = MBM.HoursToRestock(data)
    if hours <= 0 then return getText("UI_MBM_RestockNow") end
    if hours < 24 then return getText("UI_MBM_RestockToday") end

    local days = math.floor(hours / 24 + 0.5)
    if days < 1 then days = 1 end
    return getText("UI_MBM_RestockDays", tostring(days))
end

-- ---------------------------------------------------------------------------
-- APERTURA
-- ---------------------------------------------------------------------------
function UI.Open(player)
    if MBMarketPanel.instance then
        MBMarketPanel.instance:close()
    end

    local w, h = UI.Config.Width, UI.Config.Height
    local x = (getCore():getScreenWidth() - w) / 2
    local y = (getCore():getScreenHeight() - h) / 2

    local panel = MBMarketPanel:new(x, y, w, h, player)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()

    MBMarketPanel.instance = panel
    return panel
end

-- Refresco reactivo: la capa shared dispara este evento al recibir estado nuevo.
local function OnStateChanged()
    local panel = MBMarketPanel.instance
    if not panel then return end
    local ok, err = pcall(panel.refresh, panel)
    if not ok then MBM.LogError("UI.refresh", err) end
end

-- ---------------------------------------------------------------------------
-- MENU CONTEXTUAL SOBRE EL MERCADER
-- El clic derecho del mundo no entrega personajes, solo objetos de la casilla,
-- asi que se busca al mercader entre los zombis cargados alrededor del punto
-- pinchado. Solo ocurre al abrir un menu contextual: no es un coste por frame.
-- ---------------------------------------------------------------------------
local function FindMerchantNear(x, y, z, range)
    local cell = getCell()
    if not cell then return nil end

    local okList, list = pcall(cell.getZombieList, cell)
    if not okList or not list then return nil end

    local r2 = range * range
    local n = list:size()
    if n > 400 then n = 400 end

    for i = 0, n - 1 do
        local z2 = list:get(i)
        if z2 and not z2:isDead() and z2:getZ() == z then
            local dx, dy = z2:getX() - x, z2:getY() - y
            if (dx * dx + dy * dy) <= r2 then
                local brain = BanditBrain and BanditBrain.Get and BanditBrain.Get(z2)
                if brain and brain.cid == MBM.CLAN_ID and brain.bid == MBM.MERCHANT_BID then
                    return z2
                end
            end
        end
    end
    return nil
end

local function OnTradeClick(worldobjects, player)
    local ok, err = pcall(UI.Open, player)
    if not ok then MBM.LogError("UI.Open", err) end
end

-- Spawn manual del puesto. Solo con -debug, y en multijugador el servidor
-- ademas exige privilegios de admin (ver MaurinBombinSpawn.lua): esto es solo
-- el disparador, la puerta esta del otro lado.
local function OnDebugSpawnHere(worldobjects, square)
    local ok, err = pcall(function()
        local x = square and square:getX()
        local y = square and square:getY()
        local z = square and square:getZ()

        if isClient() then
            sendClientCommand(getPlayer(), MBM.NET.MODULE, "SpawnHere", {x = x, y = y, z = z})
            return
        end

        -- Single player: los comandos no se enrutan, se llama al planificador.
        if type(MaurinBombinSpawn) == "table" then
            MaurinBombinSpawn.SpawnMarket(getPlayer(), square or getPlayer():getSquare(),
                                          "spawn manual (debug)")
        end
    end)
    if not ok then MBM.LogError("DebugSpawnHere", err) end
end

local function OnFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    if not context then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    -- Menu de debug: se ofrece antes de cualquier comprobacion de mercado,
    -- porque justamente sirve para crearlo cuando no lo hay.
    if isDebugEnabled and isDebugEnabled() then
        local square = player:getSquare()
        if worldobjects then
            for i = 1, #worldobjects do
                local o = worldobjects[i]
                if o and o.getSquare then
                    local sq = o:getSquare()
                    if sq then
                        square = sq
                        break
                    end
                end
            end
        end

        local parent  = context:addOption(getText("UI_MBM_DebugMenu"), worldobjects, nil)
        local subMenu = context:getNew(context)
        context:addSubMenu(parent, subMenu)
        subMenu:addOption(getText("UI_MBM_DebugSpawnHere"), worldobjects, OnDebugSpawnHere, square)
    end

    -- Sin mercado vivo no hay nada que ofrecer (y evita el barrido de zombis).
    local data = MBM.GetData()
    if not MBM.IsMarketOpen(data) then return end

    local merchant = FindMerchantNear(player:getX(), player:getY(), player:getZ(),
                                      UI.Config.InteractRange)
    if not merchant then return end

    context:addOption(getText("UI_MBM_ContextTrade"), worldobjects, OnTradeClick, player)
end

-- ---------------------------------------------------------------------------
-- REGISTRO
-- ---------------------------------------------------------------------------
Events.OnFillWorldObjectContextMenu.Add(OnFillWorldObjectContextMenu)

Events.OnGameStart.Add(function()
    if Events.OnMBMarketStateChanged then
        Events.OnMBMarketStateChanged.Add(OnStateChanged)
    end
    print("[MaurinBombinUI] v" .. UI.VERSION .. " listo.")
end)
