--[[==========================================================================
    TacticalBountiesClient.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Enganche de cliente para TacticalBounties (shared/TacticalBounties.lua).

    POR QUE ESTA PARTIDO EN DOS ARCHIVOS
    ------------------------------------
    La deteccion de la muerte del Capitan pasa por PVCCore, que vive en
    media/lua/client/ y se alimenta de Events.OnZombieUpdate/OnZombieDead --
    eventos de la simulacion que corren en el CLIENTE (el propio Bandits2
    ejecuta toda su IA en cliente: sus handlers salen con isServer() -> return).
    Eso es logica de cliente y se queda aqui.

    En cambio la escritura del ModData global y la materializacion del alijo
    tienen que existir tambien en el servidor de un dedicado, que NO ejecuta
    los .lua de client/ (solo los usa para el checksum). Por eso esa parte vive
    en shared/TacticalBounties.lua. Ver la nota larga en ese archivo.
============================================================================]]

if TacticalBountiesClient then return end -- guarda anti doble carga
TacticalBountiesClient = {}

local function Bootstrap()
    if type(TacticalBounties) ~= "table" then
        print("[TacticalBountiesClient] INACTIVO: falta shared/TacticalBounties.lua.")
        return
    end
    if type(PVCCore) ~= "table" or type(PVCCore.OnDead) ~= "function" then
        print("[TacticalBountiesClient] INACTIVO: falta PVCCore (00_TacticalCore.lua).")
        return
    end

    -- El nucleo ya filtro que es un bandido y resolvio brain/id (incluido el
    -- respaldo de brain cuando Bandits2 lo borra en su propio OnZombieDead).
    PVCCore.OnDead("TacticalBounties", TacticalBounties.OnCaptainDeath)

    print("[TacticalBountiesClient] activo (alijo del Capitan enganchado).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        print("[TacticalBountiesClient] INACTIVO por error en el arranque: " .. tostring(err))
    end
end)
