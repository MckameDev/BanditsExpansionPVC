--[[==========================================================================
    MaurinBombinRadio.lua
    Ecosistema "MaurinBombin Market" - PRESINTONIA DE 88.5 FM EN EL DIAL

    ---------------------------------------------------------------------------
    QUE HACE AHORA ESTE ARCHIVO (y que hacia antes)
    ---------------------------------------------------------------------------
    ANTES: componia un texto y lo escribia en el chat del jugador a las 12:00 si
    tenia cualquier radio encendida. No era una emisora: no existia en el dial,
    no se podia sintonizar, y sonaba igual estuvieras donde estuvieras.

    AHORA: la emision de verdad la hace una EMISORA registrada en el sistema de
    radio del juego, en server/radio/MaurinBombinChannel.lua (88.5 FM). Este
    archivo solo se encarga de la parte de interfaz: que 88.5 FM aparezca en la
    lista desplegable de emisoras del aparato, junto a las vanilla.

    ---------------------------------------------------------------------------
    POR QUE HACE FALTA ANADIR LA PRESINTONIA A MANO
    ---------------------------------------------------------------------------
    Registrar la emisora la hace SINTONIZABLE (existe en 88.5 y se oye), pero la
    lista desplegable del aparato no se alimenta de las emisoras registradas:
    lee las presintonias del propio dispositivo (deviceData:getDevicePresets()),
    que el motor genera en Java al crear el aparato. Un aparato que ya existia en
    una partida guardada tiene sus presintonias generadas de ANTES de que
    existiera nuestra emisora, asi que jamas la mostraria.

    Por eso, al abrir la ventana de una radio se comprueba si falta nuestra
    presintonia y se anade. Es idempotente y solo corre al abrir la ventana, no
    por frame.

    ---------------------------------------------------------------------------
    POR QUE EN client/
    ---------------------------------------------------------------------------
    Las presintonias son estado del aparato que manipula la interfaz, y
    ISRadioWindow es codigo de cliente. Un servidor dedicado no ejecuta client/,
    pero tampoco tiene ninguna ventana de radio que rellenar.
============================================================================]]

if isServer() then return end            -- un dedicado no ejecuta client/
if MaurinBombinRadio then return end     -- guarda anti doble carga

MaurinBombinRadio = {}
local Radio = MaurinBombinRadio

Radio.VERSION = "2.0.0"

-- Tienen que coincidir con server/radio/MaurinBombinChannel.lua.
Radio.FREQ = 88500
Radio.NAME = "MaurinBombin Market"

Radio.Config = {
    Debug = false,
}

-- ---------------------------------------------------------------------------
-- ALTA DE LA PRESINTONIA
-- ---------------------------------------------------------------------------

-- true si el aparato puede sintonizar nuestra frecuencia. Un walkie-talkie
-- trabaja en 75-150 MHz y una radio FM en 88-108: anadir una presintonia fuera
-- del rango del aparato dejaria una entrada que no se puede sintonizar.
local function SupportsFrequency(deviceData)
    local okMin, minF = pcall(deviceData.getMinChannelRange, deviceData)
    local okMax, maxF = pcall(deviceData.getMaxChannelRange, deviceData)
    if not okMin or not okMax then return false end
    if type(minF) ~= "number" or type(maxF) ~= "number" then return false end
    return Radio.FREQ >= minF and Radio.FREQ <= maxF
end

-- Los televisores usan "frecuencias" de canal (200, 201...) y no tienen nada
-- que hacer con una emisora de FM.
local function IsTelevision(deviceData)
    local ok, isTv = pcall(deviceData.getIsTelevision, deviceData)
    return ok and isTv == true
end

function Radio.EnsurePreset(deviceData)
    if not deviceData then return false end
    if IsTelevision(deviceData) then return false end
    if not SupportsFrequency(deviceData) then return false end

    local okP, presets = pcall(deviceData.getDevicePresets, deviceData)
    if not okP or not presets then return false end

    local okList, list = pcall(presets.getPresets, presets)
    if not okList or not list then return false end

    -- Ya esta? (comparacion por frecuencia: el nombre lo puede editar el jugador)
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local okF, freq = pcall(p.getFrequency, p)
        if okF and freq == Radio.FREQ then return false end
    end

    -- Respeta el tope de presintonias del aparato: si esta lleno, no se pisa
    -- ninguna del jugador.
    local okMax, maxP = pcall(presets.getMaxPresets, presets)
    if okMax and type(maxP) == "number" and list:size() >= maxP then
        if Radio.Config.Debug then
            print("[MaurinBombinRadio] Presintonias llenas, no se anade 88.5 FM.")
        end
        return false
    end

    local okAdd = pcall(presets.addPreset, presets, Radio.NAME, Radio.FREQ)
    if not okAdd then return false end

    -- Que el alta sobreviva a la sesion (y se replique en multijugador).
    pcall(deviceData.transmitPresets, deviceData)

    if Radio.Config.Debug then
        print("[MaurinBombinRadio] 88.5 FM anadida a las presintonias del aparato.")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- ENGANCHE CON LA VENTANA DE RADIO DEL JUEGO BASE
-- Se envuelve ISRadioWindow:readFromObject, que es donde la ventana resuelve
-- self.deviceData a partir del aparato. Se llama al original SIEMPRE y primero:
-- si nuestro anadido fallara, la ventana ya quedo montada igual.
-- ---------------------------------------------------------------------------
local function InstallHook()
    if type(ISRadioWindow) ~= "table" or type(ISRadioWindow.readFromObject) ~= "function" then
        print("[MaurinBombinRadio] AVISO: no se encontro ISRadioWindow; " ..
              "88.5 FM sera sintonizable a mano pero no saldra en la lista.")
        return
    end

    if ISRadioWindow.mbmPresetHook then return end   -- anti doble parcheo
    ISRadioWindow.mbmPresetHook = true

    local original = ISRadioWindow.readFromObject

    function ISRadioWindow:readFromObject(_player, _deviceObject)
        original(self, _player, _deviceObject)

        if not self.deviceData then return end
        local ok, err = pcall(Radio.EnsurePreset, self.deviceData)
        if not ok then
            print("[MaurinBombinRadio][ERROR] EnsurePreset: " .. tostring(err))
            return
        end

        -- Si se anadio, hay que repintar el desplegable: la lista se leyo en el
        -- original, antes de que existiera la entrada nueva.
        if ok and self.modules then
            for i = 1, #self.modules do
                local element = self.modules[i] and self.modules[i].element
                if element and type(element.readPresets) == "function" then
                    pcall(element.readPresets, element)
                end
            end
        end
    end

    print("[MaurinBombinRadio] v" .. Radio.VERSION .. " listo (88.5 FM en el dial).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(InstallHook)
    if not ok then print("[MaurinBombinRadio] INACTIVO por error: " .. tostring(err)) end
end)
