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

local getTimestampMs   = getTimestampMs
local getSpecificPlayer = getSpecificPlayer
local isServer         = isServer
local pcall            = pcall

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

-- Arrays planos (for numerico, sin iteradores) en vez de tablas indexadas por nombre.
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

-- ---------------------------------------------------------------------------
-- AUTORIDAD DE SPAWN (multijugador)
-- ---------------------------------------------------------------------------
-- Todo lo que CREA cosas en el mundo (spawnear un clan, colocar un bloqueo,
-- registrar un alijo) debe decidirlo UNA sola maquina. Si no, con 4 amigos
-- conectados salen 4 bloqueos y 4 emboscadas para el mismo evento.
--
-- OJO con el modo Anfitrion: NO es como single player. Al hostear, el juego
-- levanta un proceso servidor interno (CoopServer) y tu propia partida se
-- conecta a el COMO CLIENTE. Es decir: el anfitrion tiene isClient() == true.
-- Se deduce del propio Lua del juego (client/JoyPad/ISJoyPadListBox.lua):
--     if not getRemotePlayModeActive() or not isClient() or isCoopHost() then
-- ese "not isClient() or isCoopHost()" solo tiene sentido si un anfitrion
-- puede ser cliente. Por eso un simple "if isClient() then return end" deja
-- el spawn MUERTO en anfitrion: alli todos son clientes y nadie decide.
--
-- Este helper devuelve true en EXACTAMENTE una maquina por partida:
--     single player      -> isClient()==false            -> true
--     anfitrion          -> isClient()==true + isCoopHost() -> true
--     amigo conectado    -> isClient()==true, sin coop    -> false
--     proceso servidor   -> isServer()==true             -> true
function PVCCore.IsSpawnAuthority()
    local okS, srv = pcall(isServer)
    if okS and srv then return true end

    local okC, cli = pcall(isClient)
    if okC and not cli then return true end   -- single player

    -- cliente: solo manda si ademas es el anfitrion de la partida coop
    local okH, host = pcall(isCoopHost)
    return okH and host == true
end

-- ---------------------------------------------------------------------------
-- AUTORIDAD DE MUNDO (para las mecanicas de IA)
-- ---------------------------------------------------------------------------
-- El tick de IA del mod base (client/BanditUpdate.lua) corre en TODOS los
-- clientes a la vez, y NO hay ningun concepto de "este cliente es el dueno de
-- este bandido" (verificado: no existe tal arbitraje en su codigo). Ademas las
-- mutaciones del brain son LOCALES: solo se propagan los pocos campos que
-- alguien manda a mano con Bandit.ForceSyncPart.
--
-- Consecuencia: cualquier mecanica nuestra que CREE algo (spawnear refuerzos,
-- encender fuego, sembrar objetos en el inventario, robar una bateria) se
-- ejecutaria una vez POR JUGADOR CONECTADO. Con 3 amigos: 3 escuadrones de
-- refuerzo, 3 incendios y 3 baterias duplicadas.
--
-- Por eso todo lo que crea o destruye estado del mundo pasa por aqui: lo hace
-- UNA sola maquina (el anfitrion / el servidor). Lo puramente visual
-- (dialogos, gritos, cojera) NO se filtra: es local por naturaleza y cada
-- jugador debe verlo en su pantalla.
--
-- Es un alias intencionado de IsSpawnAuthority: la maquina que manda es la
-- misma; el nombre distinto hace explicito EL PORQUE en cada punto de uso.
PVCCore.IsWorldAuthority = PVCCore.IsSpawnAuthority

-- Azucar para el patron repetido "si no mando yo, no toco el mundo".
function PVCCore.NotWorldAuthority()
    if type(PVCCore.IsWorldAuthority) ~= "function" then return false end
    return not PVCCore.IsWorldAuthority()
end

-- Posicion del jugador SIN llamar a Java (se refresca en cada tick del nucleo)
function PVCCore.GetPlayerPos()
    return playerX, playerY
end

function PVCCore.GetCachedPlayer()
    return cachedPlayer
end

-- Informe unico del recuento real de modulos, en el primer despacho (para
-- entonces todos ya se registraron). `reported` se declara AQUI, antes de la
-- funcion que lo usa: en Lua un local declarado mas abajo no seria visible
-- desde arriba y se leeria como global nil.
local reported = false

-- BUG REAL encontrado en el log (ver TacticalAsymmetric.lua/"La Ultima
-- Risa" que jamas disparaba): Bandits2 (media/lua/client/BanditUpdate.lua,
-- funcion OnZombieDead, ~linea 2349) llama BanditBrain.Remove(bandit) --
-- que pone modData.brain = nil -- DENTRO de su propio Events.OnZombieDead.
-- Como Bandits2 es el mod requerido, sus archivos cargan y registran ese
-- handler ANTES que los nuestros, y Kahlua invoca los handlers de un mismo
-- evento en orden de registro. O sea: para cuando llega nuestro
-- Events.OnZombieDead, BanditBrain.Get(zombie) YA da nil siempre, y todo lo
-- que dependia de la muerte (Furia de Team PVC, limpieza de TeamPVC,
-- La Ultima Risa de Evaristo) se saltaba en silencio -- sin error, porque
-- "if not brain then return end" simplemente corta ahi.
-- Arreglo: guardamos la ULTIMA copia de brain vista con vida (se actualiza
-- en cada OnZombieUpdate, que corre constantemente mientras el bandido esta
-- vivo) y la usamos como respaldo si la muerte ya la borro. La clave es
-- zombie:getPersistentOutfitID() -- el mismo valor crudo que Bandits2 usa
-- para fijar brain.id al crear el bandido (server/BanditServerSpawner.lua,
-- banditize()), y que sigue siendo legible en el zombi aunque modData.brain
-- ya no exista.
local lastBrainById = {}

local function OnZombieUpdate(zombie)
    if isServer() then return end
    if updateCount == 0 then return end

    if not reported then
        reported = true
        print("[PVCCore] Modulos registrados: " .. updateCount .. " update, " ..
              hitCount .. " hit, " .. deadCount .. " dead.")
    end

    -- filtro mas barato primero: descarta todos los zombis normales
    if not zombie:getVariableBoolean("Bandit") then return end

    local brain = BanditBrain.Get(zombie)
    if not brain then return end
    local id = brain.id
    if not id then return end

    lastBrainById[id] = brain -- respaldo para OnZombieDead, ver la nota larga mas arriba

    local now = getTimestampMs()

    local player = GetPlayer(now)
    if not player then return end
    playerX, playerY = player:getX(), player:getY()

    -- descarte por distancia: si esta lejisimos, nadie se entera
    local dx = zombie:getX() - playerX
    local dy = zombie:getY() - playerY
    local dist2 = dx * dx + dy * dy
    if dist2 > PVCCore.Config.MaxDistanceSq then return end

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

    -- Bandits2 ya pudo haber borrado modData.brain en su propio handler de
    -- este mismo evento (ver la nota larga junto a lastBrainById): si es
    -- asi, recuperamos la ultima copia vista con vida en vez de rendirnos.
    local brain = BanditBrain.Get(zombie)
    local id
    if brain then
        id = brain.id
    else
        local ok, outfitId = pcall(zombie.getPersistentOutfitID, zombie)
        id = ok and outfitId or nil
        brain = id and lastBrainById[id]
    end
    if not brain or not id then return end

    for i = 1, deadCount do
        local h = deadFns[i]
        if not disabled[h.name] then
            local ok, err = pcall(h.fn, zombie, brain, id)
            if not ok then Report(h.name, err) end
        end
    end

    lastBrainById[id] = nil
end

-- Barrido de baja frecuencia: bandidos que jamas pasaron por nuestro
-- OnZombieDead (ej. chunk descargado para siempre) no deberian dejar su
-- respaldo en lastBrainById creciendo sin limite durante una partida larga.
local function CleanupBrainCache()
    if type(BanditZombie) ~= "table" or type(BanditZombie.GetAllB) ~= "function" then return end
    local alive = BanditZombie.GetAllB()
    if not alive then return end
    for id in pairs(lastBrainById) do
        if not alive[id] then lastBrainById[id] = nil end
    end
end

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

    Events.EveryHours.Remove(CleanupBrainCache)
    Events.EveryHours.Add(CleanupBrainCache)

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
