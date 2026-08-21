--[[==========================================================================
    MaurinBombinChannel.lua
    Ecosistema "MaurinBombin Market" - EMISORA DE RADIO REAL (88.5 FM)

    ---------------------------------------------------------------------------
    QUE CAMBIA RESPECTO A LA VERSION ANTERIOR
    ---------------------------------------------------------------------------
    Antes, "la radio del mercado" no era una emisora: era un texto que se
    escribia en el chat si el jugador tenia CUALQUIER radio encendida. Nunca
    aparecia en el dial porque nunca existio como estacion.

    Ahora es una emisora de verdad, registrada en el sistema de radio del juego
    con frecuencia fija 88.5 FM (88500). Existe SIEMPRE, desde el primer dia y
    aunque no haya mercader: se puede sintonizar y sale junto a las emisoras
    vanilla. Cuando el puesto esta montado, a las 12:00 emite la informacion
    completa; cuando no lo hay, emite solo su identificacion.

    ---------------------------------------------------------------------------
    COMO SE REGISTRA (patron de ISWeatherChannel.lua del juego base)
    ---------------------------------------------------------------------------
    El juego base expone dos listas globales en server/radio/ISDynamicRadio.lua:

      DynamicRadio.channels : emisoras a registrar. Se leen UNA vez, dentro del
                              handler de Events.OnLoadRadioScripts del propio
                              ISDynamicRadio. Por eso hay que insertarse en el
                              CUERPO del archivo (al cargar), no dentro de un
                              handler nuestro: nuestro handler correria DESPUES
                              del suyo y la emisora no llegaria a registrarse.
      DynamicRadio.scripts  : guiones con OnEveryHour. Estos si se pueden
                              anadir desde el handler, que es lo que hace
                              WeatherChannel.

    Los ficheros de mods cargan despues que los del juego base, asi que cuando
    se ejecuta este archivo DynamicRadio ya existe.

    ---------------------------------------------------------------------------
    POR QUE EN server/
    ---------------------------------------------------------------------------
    El estado del mercado (ubicacion, stock, si hay mercader vivo) es del
    servidor. El contenido de la emision se compone aqui, junto a los datos, y
    el motor lo replica a quien tenga la radio sintonizada. Es exactamente donde
    el juego base pone su propia emisora de emergencias.

    OJO (limitacion heredada del juego base): el texto se compone con getText()
    en el proceso del SERVIDOR, asi que en multijugador sale en el idioma del
    servidor, no en el de cada cliente. La emisora de emergencias vanilla tiene
    exactamente el mismo comportamiento; no hay API para componer por jugador.
============================================================================]]

if MaurinBombinChannel then return end   -- guarda anti doble carga

MaurinBombinChannel = {}
local Ch = MaurinBombinChannel

Ch.VERSION = "1.0.0"

-- 88.5 FM. Frecuencia LIBRE verificada contra media/radio/RadioData.xml del
-- juego base: alli estan ocupadas 89.4 (Hitz FM), 91.2 (Civilian Radio),
-- 93.2 (LBMW), 94.2 (USR), 95.0 (Classified M1A1), 98.0 (NNR),
-- 101.2 (KnoxTalk) y 107.6 (Unknown Frequency). Ademas coincide con el "88.5
-- FM" que ya decia el texto de la emision.
Ch.FREQ = 88500

-- Identificador estable. Tiene que ser FIJO de por vida: es la clave con la
-- que el motor reconoce la emisora entre partidas y recargas.
Ch.UUID = "MBMK-885000"

Ch.channelUUID = Ch.UUID   -- nombre que espera DynamicRadio.OnEveryHour

Ch.BROADCAST_HOUR = 12     -- las 12:00 del mundo

local COLOR = {r = 0.45, g = 0.85, b = 1.0}

-- ---------------------------------------------------------------------------
-- REGISTRO DE LA EMISORA
-- ---------------------------------------------------------------------------
local function RegisterChannel()
    if type(DynamicRadio) ~= "table" or type(DynamicRadio.channels) ~= "table" then
        print("[MaurinBombinChannel] INACTIVO: no se encontro DynamicRadio.channels.")
        return false
    end

    -- Idempotente: si ya estuviera (recarga de scripts), no se duplica.
    for i = 1, #DynamicRadio.channels do
        if DynamicRadio.channels[i].uuid == Ch.UUID then return true end
    end

    table.insert(DynamicRadio.channels, {
        name     = "MaurinBombin Market",
        freq     = Ch.FREQ,
        category = "Radio",
        uuid     = Ch.UUID,
        register = true,
    })
    return true
end

local registered = RegisterChannel()

-- ---------------------------------------------------------------------------
-- CONTENIDO DE LA EMISION
-- ---------------------------------------------------------------------------
local DIAGONAL_RATIO = 2.414   -- tangente de 67.5 grados: recto vs diagonal

-- Ciudades de referencia. Se canta el rumbo hacia la mas cercana, no hace falta
-- que el puesto este dentro de ninguna.
local TOWNS = {
    {x = 10620, y = 9650,  key = "UI_MBM_TownMuldraugh"},
    {x = 8300,  y = 11700, key = "UI_MBM_TownRosewood"},
    {x = 11550, y = 6800,  key = "UI_MBM_TownWestPoint"},
}

local TOWN_MAX_DIST  = 1500   -- mas lejos que esto: se cantan coordenadas
local SAME_SPOT_DIST = 60     -- dentro de esto: "en", no "al sur de"
local MAX_OFFERS     = 3

-- OJO CON EL EJE Y: en Project Zomboid la Y CRECE HACIA EL SUR. Confundirlo
-- manda al jugador exactamente al lado contrario.
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

-- "por la carretera": mismo detector de asfalto que usa el peaje de Evaristo.
-- Si el trozo de mapa no esta cargado, getGridSquare devuelve nil y no se dice
-- nada: nunca se inventa la referencia.
local function IsByTheRoad(loc)
    if type(PVCShared) ~= "table" or type(PVCShared.GetGroundType) ~= "function" then
        return false
    end
    local cell = getCell()
    if not cell then return false end

    local cx = math.floor(loc.x or 0)
    local cy = math.floor(loc.y or 0)
    local cz = math.floor(loc.z or 0)

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

local function WhereText(data)
    local loc = data and data.location
    if type(loc) ~= "table" then return getText("UI_MBM_TownUnknown") end

    local best, bestD2
    for i = 1, #TOWNS do
        local t = TOWNS[i]
        local dx, dy = (loc.x or 0) - t.x, (loc.y or 0) - t.y
        local d2 = dx * dx + dy * dy
        if not bestD2 or d2 < bestD2 then best, bestD2 = t, d2 end
    end

    local place
    if best and bestD2 <= (TOWN_MAX_DIST * TOWN_MAX_DIST) then
        local dx, dy = (loc.x or 0) - best.x, (loc.y or 0) - best.y
        if bestD2 <= (SAME_SPOT_DIST * SAME_SPOT_DIST) then
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

-- Primero lo raro, luego lo caro, y solo lo que tenga existencias.
local TIER_RANK = {}

local function BuildTierRank()
    if not MaurinBombin or not MaurinBombin.Tiers then return end
    TIER_RANK[MaurinBombin.Tiers.RARE]   = 1
    TIER_RANK[MaurinBombin.Tiers.VALUE]  = 2
    TIER_RANK[MaurinBombin.Tiers.COMMON] = 3
end

local function OffersText(data)
    if type(data.order) ~= "table" or type(data.stock) ~= "table" then return nil end

    local sorted = {}
    for i = 1, #data.order do
        local e = data.stock[data.order[i]]
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
    local limit = (#sorted < MAX_OFFERS) and #sorted or MAX_OFFERS

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

-- Mismo texto de reposicion que el pie de la ventana de trueque, pero calculado
-- aqui: MaurinBombinUI vive en client/ y un servidor dedicado no lo ejecuta.
local function RestockText(data)
    if data.soldOut then return getText("UI_MBM_RestockSoldOut") end

    local hours = MaurinBombin.HoursToRestock(data)
    if hours <= 0 then return getText("UI_MBM_RestockNow") end
    if hours < 24 then return getText("UI_MBM_RestockToday") end

    local days = math.floor(hours / 24 + 0.5)
    if days < 1 then days = 1 end
    return getText("UI_MBM_RestockDays", tostring(days))
end

local function AddLine(bc, text)
    if type(text) ~= "string" or text == "" then return end
    bc:AddRadioLine(RadioLine.new(text, COLOR.r, COLOR.g, COLOR.b))
end

-- Emision completa (hay puesto montado).
local function FillMarketBroadcast(bc, data)
    AddLine(bc, getText("UI_MBM_RadioHeader"))
    AddLine(bc, getText("UI_MBM_RadioWhere", WhereText(data)))

    local offers = OffersText(data)
    if offers then
        AddLine(bc, getText("UI_MBM_RadioOffers", offers))
    else
        AddLine(bc, getText("UI_MBM_RadioNoOffers"))
    end

    AddLine(bc, RestockText(data))
    AddLine(bc, getText("UI_MBM_RadioSignOff"))
end

-- Emision de relleno (la emisora existe, pero no hay mercader). Es lo que hace
-- que sintonizar 88.5 nunca suene a emisora muerta.
local function FillOffAirBroadcast(bc, data)
    AddLine(bc, getText("UI_MBM_RadioHeader"))
    if data and data.permanentlyKilled then
        AddLine(bc, getText("UI_MBM_RadioOffAirDead"))
    else
        AddLine(bc, getText("UI_MBM_RadioOffAir"))
    end
    AddLine(bc, getText("UI_MBM_RadioSignOff"))
end

-- ---------------------------------------------------------------------------
-- ENGANCHE CON DynamicRadio
-- ---------------------------------------------------------------------------

-- La firma la fija DynamicRadio.OnEveryHour del juego base:
--     v.OnEveryHour(canal, gametime, radio)
function Ch.OnEveryHour(_channel, _gametime, _radio)
    if not _channel or not _gametime then return end

    local ok, err = pcall(function()
        if _gametime:getHour() ~= Ch.BROADCAST_HOUR then return end
        if type(MaurinBombin) ~= "table" then return end

        local data = MaurinBombin.GetData()
        local bc = RadioBroadCast.new("MBM-" .. tostring(ZombRand(100000, 999999)), -1, -1)

        if MaurinBombin.IsMarketOpen(data) then
            FillMarketBroadcast(bc, data)
        else
            FillOffAirBroadcast(bc, data)
        end

        _channel:setAiringBroadcast(bc)
    end)

    if not ok then
        print("[MaurinBombinChannel][ERROR] OnEveryHour: " .. tostring(err))
    end
end

function Ch.OnLoadRadioScripts()
    BuildTierRank()

    if type(DynamicRadio) ~= "table" or type(DynamicRadio.scripts) ~= "table" then return end

    -- Idempotente, igual que el registro de la emisora.
    for i = 1, #DynamicRadio.scripts do
        if DynamicRadio.scripts[i] == Ch then return end
    end

    table.insert(DynamicRadio.scripts, Ch)
    print("[MaurinBombinChannel] v" .. Ch.VERSION .. " en el aire: 88.5 FM (emision a las " ..
          Ch.BROADCAST_HOUR .. ":00).")
end

if registered then
    Events.OnLoadRadioScripts.Add(Ch.OnLoadRadioScripts)
end
