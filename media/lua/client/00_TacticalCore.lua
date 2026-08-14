--[[==========================================================================
    00_TacticalCore.lua
    Nucleo compartido del sub-mod "Bandits: Tactical Expansion"

    POR QUE EXISTE ESTE ARCHIVO (rendimiento)
    -----------------------------------------
    Antes, los tres modulos del sub-mod (TacticalDialogues, TacticalQuickWins,
    TeamPVC_Group) registraban CADA UNO su propio handler en
    Events.OnZombieUpdate. Ese evento se dispara una vez por CADA zombi y por
    CADA frame, asi que con 3 handlers el juego pagaba, por zombi y por frame:

        3x  zombie:getVariableBoolean("Bandit")   <- llamada a Java
        3x  BanditBrain.Get(zombie)               <- getModData() a Java
        3x  getSpecificPlayer(0) + calculo de distancia

    Con 150 zombis a 60 FPS eso son ~27.000 llamadas a Java por segundo solo
    para decidir "esto no me interesa".

    Este nucleo hace ese trabajo UNA sola vez por zombi/frame y reparte el
    resultado ya masticado (zombie, brain, id, now, dist2) a los modulos que
    se hayan registrado. Ademas:

      - Cachea el jugador (getSpecificPlayer(0) es una llamada a Java; antes
        cada mecanica la hacia por su cuenta).
      - Descarta por distancia ANTES de llamar a nadie: un bandido a 60
        casillas no necesita dialogos ni chequeos tacticos.
      - Recorre los handlers con for numerico sobre un array fijo: sin
        iteradores, sin asignaciones, cero basura para el GC.

    El prefijo "00_" fuerza que este archivo cargue antes que los demas
    (el juego ordena alfabeticamente), igual que hace el propio mod base con
    sus 00_ImprovedProjectile.lua / 00_TrueCrawl.lua.
============================================================================]]

if PVCCore then return end -- guarda anti doble carga

PVCCore = {}
PVCCore.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- Locales de motor
-- ---------------------------------------------------------------------------
local getTimestampMs   = getTimestampMs
local getSpecificPlayer = getSpecificPlayer
local isServer         = isServer
local pcall            = pcall

-- ---------------------------------------------------------------------------
-- Configuracion
-- ---------------------------------------------------------------------------
PVCCore.Config = {
    -- Mas alla de esta distancia (en casillas) al jugador, ningun modulo se
    -- ejecuta. El mod base ya deja "useless" a los bandidos lejanos; esto
    -- evita que nosotros les gastemos CPU igualmente.
    MaxDistance   = 45,
    -- Cada cuanto refrescamos la referencia al jugador (no cambia casi nunca)
    PlayerCacheMs = 1000,
    Debug         = false,
}
PVCCore.Config.MaxDistanceSq = PVCCore.Config.MaxDistance * PVCCore.Config.MaxDistance

-- ---------------------------------------------------------------------------
-- Registros de handlers (arrays planos: for numerico, sin iteradores)
-- ---------------------------------------------------------------------------
local updateFns, updateCount = {}, 0
local hitFns,    hitCount    = {}, 0
local deadFns,   deadCount   = {}, 0

-- fn(zombie, brain, id, now, dist2, player)
function PVCCore.OnUpdate(name, fn)
    updateCount = updateCount + 1
    updateFns[updateCount] = {name = name, fn = fn}
end

-- fn(zombie, brain, id, attacker, bodyPartType, handWeapon)
function PVCCore.OnHit(name, fn)
    hitCount = hitCount + 1
    hitFns[hitCount] = {name = name, fn = fn}
end

-- fn(zombie, brain, id)
function PVCCore.OnDead(name, fn)
    deadCount = deadCount + 1
    deadFns[deadCount] = {name = name, fn = fn}
end

-- ---------------------------------------------------------------------------
-- Circuit breaker compartido: si un modulo revienta repetidamente se
-- desactiva solo y los demas siguen funcionando.
-- ---------------------------------------------------------------------------
local MAX_ERRORS = 5
local errors   = {}
local disabled = {}
local lastLogMs = 0

local function Report(name, err)
    local now = getTimestampMs()
    if now - lastLogMs > 1000 then
        lastLogMs = now
        print("[PVCCore][ERROR] " .. tostring(name) .. ": " .. tostring(err))
    end
    local n = (errors[name] or 0) + 1
    errors[name] = n
    if n >= MAX_ERRORS then
        disabled[name] = true
        print("[PVCCore] Modulo '" .. tostring(name) .. "' DESACTIVADO tras " .. n .. " errores.")
    end
end

-- ---------------------------------------------------------------------------
-- Cache del jugador
-- ---------------------------------------------------------------------------
local cachedPlayer, playerCacheUntil = nil, 0
local playerX, playerY = 0, 0

local function GetPlayer(now)
    if cachedPlayer and now < playerCacheUntil then
        return cachedPlayer
    end
    local p = getSpecificPlayer(0)
    cachedPlayer = p
    playerCacheUntil = now + PVCCore.Config.PlayerCacheMs
    if p then
        playerX, playerY = p:getX(), p:getY()
    end
    return p
end

-- Posicion del jugador SIN llamar a Java (se refresca en cada tick del nucleo)
function PVCCore.GetPlayerPos()
    return playerX, playerY
end

function PVCCore.GetCachedPlayer()
    return cachedPlayer
end

-- ---------------------------------------------------------------------------
-- DESPACHADOR PRINCIPAL
-- Una sola vez por zombi/frame. La ruta rapida (zombi normal) sale en dos
-- comparaciones y una llamada a Java.
-- ---------------------------------------------------------------------------
-- Informe unico del recuento real de modulos, en el primer despacho (para
-- entonces todos ya se registraron). `reported` se declara AQUI, antes de la
-- funcion que lo usa: en Lua un local declarado mas abajo no seria visible
-- desde arriba y se leeria como global nil.
local reported = false

local function OnZombieUpdate(zombie)
    if isServer() then return end
    if updateCount == 0 then return end

    if not reported then
        reported = true
        print("[PVCCore] Modulos registrados: " .. updateCount .. " update, " ..
              hitCount .. " hit, " .. deadCount .. " dead.")
    end

    -- 1) filtro mas barato primero: descarta todos los zombis normales
    if not zombie:getVariableBoolean("Bandit") then return end

    -- 2) brain una sola vez para todos los modulos
    local brain = BanditBrain.Get(zombie)
    if not brain then return end
    local id = brain.id
    if not id then return end

    local now = getTimestampMs()

    -- 3) jugador cacheado + posicion fresca
    local player = GetPlayer(now)
    if not player then return end
    playerX, playerY = player:getX(), player:getY()

    -- 4) descarte por distancia: si esta lejisimos, nadie se entera
    local dx = zombie:getX() - playerX
    local dy = zombie:getY() - playerY
    local dist2 = dx * dx + dy * dy
    if dist2 > PVCCore.Config.MaxDistanceSq then return end

    -- 5) reparto
    for i = 1, updateCount do
        local h = updateFns[i]
        if not disabled[h.name] then
            local ok, err = pcall(h.fn, zombie, brain, id, now, dist2, player)
            if not ok then Report(h.name, err) end
        end
    end
end

local function OnHitZombie(zombie, attacker, bodyPartType, handWeapon)
    if hitCount == 0 then return end
    if not zombie:getVariableBoolean("Bandit") then return end

    local brain = BanditBrain.Get(zombie)
    if not brain then return end
    local id = brain.id
    if not id then return end

    for i = 1, hitCount do
        local h = hitFns[i]
        if not disabled[h.name] then
            local ok, err = pcall(h.fn, zombie, brain, id, attacker, bodyPartType, handWeapon)
            if not ok then Report(h.name, err) end
        end
    end
end

local function OnZombieDead(zombie)
    if deadCount == 0 then return end
    if not zombie:getVariableBoolean("Bandit") then return end

    local brain = BanditBrain.Get(zombie)
    if not brain then return end
    local id = brain.id

    for i = 1, deadCount do
        local h = deadFns[i]
        if not disabled[h.name] then
            local ok, err = pcall(h.fn, zombie, brain, id)
            if not ok then Report(h.name, err) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- ARRANQUE
-- ---------------------------------------------------------------------------
PVCCore.Ready = false

local function Bootstrap()
    if type(BanditBrain) ~= "table" or type(BanditBrain.Get) ~= "function" then
        print("[PVCCore] INACTIVO: no se encontro BanditBrain.Get (mod Bandits ausente?).")
        return
    end

    Events.OnZombieUpdate.Remove(OnZombieUpdate)
    Events.OnZombieUpdate.Add(OnZombieUpdate)

    Events.OnHitZombie.Remove(OnHitZombie)
    Events.OnHitZombie.Add(OnHitZombie)

    Events.OnZombieDead.Remove(OnZombieDead)
    Events.OnZombieDead.Add(OnZombieDead)

    PVCCore.Ready = true

    -- OJO: este archivo carga el PRIMERO (prefijo 00_), asi que su OnGameStart
    -- corre ANTES que el de los modulos. Contar aqui daria siempre 0 y confunde
    -- al leer el log. El recuento real se reporta en el primer despacho.
    print("[PVCCore] v" .. PVCCore.VERSION .. " activo (esperando registro de modulos).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then print("[PVCCore] INACTIVO por error en el arranque: " .. tostring(err)) end
end)
