--[[==========================================================================
    MaurinBombinRadio.lua
    Ecosistema "MaurinBombin Market" - FASE 3 de 3
    RADIO LOCAL FM: la emision del mediodia del mercado

    ---------------------------------------------------------------------------
    COMO FUNCIONA
    ---------------------------------------------------------------------------
    Events.EveryHours dispara una vez por hora de mundo; nos quedamos con las
    12:00. Si el mercado esta vivo y el jugador tiene una radio ENCENDIDA (en
    su inventario, en una mochila, o un aparato encendido a pocas casillas), se
    compone la transmision con tres datos reales, no decorativos:

      1. donde esta el puesto ahora mismo (data.location)
      2. sus mejores ofertas (las de mayor valor con stock)
      3. cuanto falta para reponer -- incluida la excepcion de "stock agotado,
         reponemos manana" que definio la Fase 1

    Todo sale del ModData replicado: si el servidor no ha mandado estado, no se
    inventa nada y no se emite.

    ---------------------------------------------------------------------------
    POR QUE EL TEXTO SALE POR addLineChatElement
    ---------------------------------------------------------------------------
    El motor no expone una API para escribir en el canal de radio del chat (lo
    hace ChatManager por dentro, desde Java, a partir de los scripts de
    emisora). addLineChatElement es el UNICO metodo que acepta texto propio y
    ademas es el que ya usa este submod para los dialogos de bandidos
    (ver TacticalDialogues.lua), asi que la voz del mod se mantiene consistente.

    Es una emision LOCAL: este archivo esta en client/, o sea que cada jugador
    resuelve su propia escucha (su radio, su encendido) sin trafico de red.
============================================================================]]

if isServer() then return end          -- un dedicado no ejecuta client/
if MaurinBombinRadio then return end     -- guarda anti doble carga

MaurinBombinRadio = {}
local Radio = MaurinBombinRadio
local MBM   = MaurinBombin

Radio.VERSION = "1.0.0"

local pcall      = pcall
local type       = type
local tostring   = tostring
local instanceof = instanceof

Radio.Config = {
    Hour            = 12,    -- 12:00 PM in-game
    DeviceRange     = 6,     -- casillas: aparatos encendidos del mundo que cuentan
    MaxOffers       = 3,     -- cuantas ofertas se cantan
    TownMaxDist     = 1500,  -- casillas: mas lejos que esto, no hay ciudad de referencia
    SameSpotDist    = 60,    -- casillas: dentro de esto se dice "en", no "al sur de"
    Debug           = false,
}

-- Ciudades vanilla de referencia. No hace falta que el puesto este DENTRO de
-- una: como se canta el rumbo ("al sur de West Point"), basta con la mas
-- cercana dentro de TownMaxDist. Si el puesto improvisado cae mas lejos que
-- eso, se cantan las coordenadas tal cual.
Radio.Towns = {
    {x = 10620, y = 9650,  key = "UI_MBM_TownMuldraugh"},
    {x = 8300,  y = 11700, key = "UI_MBM_TownRosewood"},
    {x = 11550, y = 6800,  key = "UI_MBM_TownWestPoint"},
}

-- ---------------------------------------------------------------------------
-- PUNTOS CARDINALES
-- OJO CON EL EJE Y: en Project Zomboid la Y CRECE HACIA EL SUR (el norte del
-- mapa es y menor). Confundirlo manda a la gente exactamente al lado contrario,
-- que en este juego se paga caro.
--
-- El reparto es de 8 rumbos: una componente "manda" cuando es mas de 2.414
-- veces la otra (la tangente de 67.5 grados, o sea el punto medio entre un
-- rumbo recto y su diagonal); si no, es diagonal.
-- ---------------------------------------------------------------------------
local DIAGONAL_RATIO = 2.414

local function CardinalKey(dx, dy)
    local adx, ady = math.abs(dx), math.abs(dy)

    if adx > ady * DIAGONAL_RATIO then
        return (dx > 0) and "UI_MBM_DirE" or "UI_MBM_DirW"
    end
    if ady > adx * DIAGONAL_RATIO then
        return (dy > 0) and "UI_MBM_DirS" or "UI_MBM_DirN"
    end

    if dy > 0 then
        return (dx > 0) and "UI_MBM_DirSE" or "UI_MBM_DirSW"
    end
    return (dx > 0) and "UI_MBM_DirNE" or "UI_MBM_DirNW"
end

-- Referencia de terreno: si el puesto (o su casilla contigua) es asfalto, se
-- anade "por la carretera". Reutiliza PVCShared.GetGroundType, que es el mismo
-- detector que usa el peaje de Evaristo para orientar las barricadas.
-- Si el chunk no esta cargado en este cliente, getGridSquare devuelve nil y
-- simplemente no se dice nada: nunca se inventa la referencia.
local function IsByTheRoad(loc)
    if type(PVCShared) ~= "table" or type(PVCShared.GetGroundType) ~= "function" then
        return false
    end

    local cell = getCell()
    if not cell then return false end

    local cx, cy, cz = math.floor(loc.x or 0), math.floor(loc.y or 0), math.floor(loc.z or 0)
    for x = cx - 1, cx + 1 do
        for y = cy - 1, cy + 1 do
            local sq = cell:getGridSquare(x, y, cz)
            if sq then
                local ok, ground = pcall(PVCShared.GetGroundType, sq)
                if ok and ground == "street" then return true end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- ESCUCHA: hay una radio encendida?
-- ---------------------------------------------------------------------------
local function IsRadioOn(item)
    if not item then return false end
    if not instanceof(item, "Radio") then return false end

    local okDev, device = pcall(item.getDeviceData, item)
    if not okDev or not device then return false end

    local okOn, on = pcall(device.getIsTurnedOn, device)
    return okOn and on == true
end

-- Inventario del jugador y un nivel de contenedores (la radio dentro de la
-- mochila cuenta; una radio dentro de una bolsa dentro de la mochila, no --
-- caso de borde que no justifica un recorrido recursivo completo cada hora).
local function HasRadioInInventory(player)
    local okInv, inv = pcall(player.getInventory, player)
    if not okInv or not inv then return false end

    local okItems, items = pcall(inv.getItems, inv)
    if not okItems or not items then return false end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if IsRadioOn(item) then return true end

        local okBag, bag = pcall(item.getInventory, item)
        if okBag and bag then
            local okSub, sub = pcall(bag.getItems, bag)
            if okSub and sub then
                for j = 0, sub:size() - 1 do
                    if IsRadioOn(sub:get(j)) then return true end
                end
            end
        end
    end
    return false
end

-- Aparatos del mundo (una radio o un ham puestos sobre una mesa).
local function HasRadioNearby(player)
    local cell = getCell()
    if not cell then return false end

    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local r = Radio.Config.DeviceRange

    for x = px - r, px + r do
        for y = py - r, py + r do
            local sq = cell:getGridSquare(x, y, pz)
            if sq then
                local okObjs, objs = pcall(sq.getObjects, sq)
                if okObjs and objs then
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and instanceof(obj, "IsoRadio") then
                            local okDev, device = pcall(obj.getDeviceData, obj)
                            if okDev and device then
                                local okOn, on = pcall(device.getIsTurnedOn, device)
                                if okOn and on == true then return true end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

function Radio.CanHear(player)
    if not player then return false end
    if HasRadioInInventory(player) then return true end
    local ok, res = pcall(HasRadioNearby, player)
    return ok and res == true
end

-- ---------------------------------------------------------------------------
-- CONTENIDO DE LA EMISION
-- ---------------------------------------------------------------------------

-- Ubicacion legible del puesto: rumbo + ciudad de referencia + (si toca) la
-- carretera. Por ejemplo: "al sur de West Point, por la carretera".
local function WhereText(data)
    local loc = data and data.location
    if type(loc) ~= "table" then return getText("UI_MBM_TownUnknown") end

    -- Ciudad de referencia = la mas cercana, no "la que lo contenga".
    local best, bestD2 = nil, nil
    for i = 1, #Radio.Towns do
        local t = Radio.Towns[i]
        local dx, dy = (loc.x or 0) - t.x, (loc.y or 0) - t.y
        local d2 = dx * dx + dy * dy
        if not bestD2 or d2 < bestD2 then
            best, bestD2 = t, d2
        end
    end

    local place
    local maxD = Radio.Config.TownMaxDist
    if best and bestD2 <= (maxD * maxD) then
        local dx, dy = (loc.x or 0) - best.x, (loc.y or 0) - best.y
        local near = Radio.Config.SameSpotDist

        if bestD2 <= (near * near) then
            -- Practicamente encima: no tiene sentido cantar rumbo.
            place = getText("UI_MBM_RadioAt", getText(best.key))
        else
            place = getText("UI_MBM_RadioNear", getText(CardinalKey(dx, dy)), getText(best.key))
        end
    else
        place = getText("UI_MBM_TownCoords", tostring(math.floor(loc.x or 0)),
                        tostring(math.floor(loc.y or 0)))
    end

    local okRoad, byRoad = pcall(IsByTheRoad, loc)
    if okRoad and byRoad then
        return getText("UI_MBM_RadioRoad", place)
    end
    return place
end

-- Las "mejores ofertas": primero lo raro, luego lo valioso, y solo con stock.
local TIER_RANK = {}
TIER_RANK[MBM.Tiers.RARE]   = 1
TIER_RANK[MBM.Tiers.VALUE]  = 2
TIER_RANK[MBM.Tiers.COMMON] = 3

local function OffersText()
    local catalog = MaurinBombinClient.GetCatalog()
    if not catalog or #catalog == 0 then return nil end

    -- Copia ordenable: el catalogo original es el orden de listado de la UI y
    -- no se toca. Son una decena de entradas, una vez al dia.
    local sorted = {}
    for i = 1, #catalog do
        local e = catalog[i]
        if e and (e.qty or 0) > 0 then sorted[#sorted + 1] = e end
    end
    if #sorted == 0 then return nil end

    table.sort(sorted, function(a, b)
        local ra = TIER_RANK[a.tier] or 9
        local rb = TIER_RANK[b.tier] or 9
        if ra ~= rb then return ra < rb end
        return (a.price or 0) > (b.price or 0)
    end)

    local parts = {}
    local limit = Radio.Config.MaxOffers
    if #sorted < limit then limit = #sorted end

    for i = 1, limit do
        local e = sorted[i]
        local label = e.item

        local okSm, sm = pcall(getScriptManager)
        if okSm and sm then
            local okScript, script = pcall(sm.getItem, sm, e.item)
            if okScript and script then
                local okName, name = pcall(script.getDisplayName, script)
                if okName and type(name) == "string" and name ~= "" then label = name end
            end
        end

        parts[#parts + 1] = getText("UI_MBM_RadioOfferItem", label, tostring(e.price))
    end

    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- EMISION
-- ---------------------------------------------------------------------------
local function Say(player, text)
    if type(text) ~= "string" or text == "" then return end
    pcall(player.addLineChatElement, player, text, 0.45, 0.85, 1.0)
end

function Radio.Broadcast(player)
    local data = MBM.GetData()
    if not MBM.IsMarketOpen(data) then return false end

    Say(player, getText("UI_MBM_RadioHeader"))
    Say(player, getText("UI_MBM_RadioWhere", WhereText(data)))

    local offers = OffersText()
    if offers then
        Say(player, getText("UI_MBM_RadioOffers", offers))
    else
        Say(player, getText("UI_MBM_RadioNoOffers"))
    end

    -- Mismo texto que el pie de la ventana de trueque: una sola fuente para el
    -- estado de la reposicion (incluida la excepcion de stock agotado). Se
    -- comprueba que la UI este cargada porque este archivo carga ANTES que ella
    -- (orden alfabetico de Kahlua): si la UI fallara al cargar, la radio sigue
    -- emitiendo sin esa linea en vez de romper la emision entera.
    if type(MaurinBombinUI) == "table" and type(MaurinBombinUI.RestockText) == "function" then
        Say(player, MaurinBombinUI.RestockText(data))
    end
    Say(player, getText("UI_MBM_RadioSignOff"))

    return true
end

local function OnEveryHours()
    local ok, err = pcall(function()
        local gt = getGameTime()
        if not gt or gt:getHour() ~= Radio.Config.Hour then return end

        local player = getPlayer()
        if not player or player:isDead() then return end

        if not Radio.CanHear(player) then
            if Radio.Config.Debug then
                print("[MaurinBombinRadio] Emision omitida: sin radio encendida")
            end
            return
        end

        Radio.Broadcast(player)
    end)
    if not ok then MBM.LogError("Radio/EveryHours", err) end
end

Events.EveryHours.Add(OnEveryHours)

print("[MaurinBombinRadio] v" .. Radio.VERSION .. " listo (emision a las " ..
      Radio.Config.Hour .. ":00).")
