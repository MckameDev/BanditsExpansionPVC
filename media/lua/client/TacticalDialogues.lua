--[[==========================================================================
    TacticalDialogues.lua
    Sub-mod de expansion para "Bandits" v2 (Slayer) - Build 42
    Idea #27: Comunicaciones y Dialogos Contextuales.

    Los bandidos reaccionan verbalmente en pantalla al contexto de combate:
      - al recibir dano            -> "Me dieron!" / "Cubranme!"
      - al morir un aliado del clan-> "Cayeron a [Nombre]!"
      - al recargar el arma        -> "Cubran el pasillo, estoy recargando!"

    NOTAS DE IMPLEMENTACION (verificadas contra el codigo del mod base v42.20)
    -------------------------------------------------------------------------
    1) Los bandidos NO son IsoSurvivor: son IsoZombie reciclados y marcados con
       la variable booleana "Bandit". El filtro correcto es
       zombie:getVariableBoolean("Bandit").

    2) Bandit.Say(zombie, phrase) NO acepta texto libre: recibe una CLAVE de
       Bandit.SoundTab ("HIT", "RELOADING", "SPOTTED"...) y reproduce audio
       pregrabado + un subtitulo traducido. Para texto propio hay que usar el
       metodo nativo del motor zombie:addLineChatElement(texto, r, g, b), que
       es el mismo que usa el mod base para sus subtitulos.

    3) El identificador de grupo NO es un "GroupID": el brain guarda
       brain.clan (y brain.cid, su gemelo) con el id del clan al que pertenece
       el bandido. Ese es el criterio de "aliado".

    4) No parcheamos nada. Nos colgamos de los mismos eventos publicos del
       motor que usa el mod base (OnZombieUpdate / OnHitZombie / OnZombieDead)
       y leemos su cache publica BanditZombie.GetAllB() para encontrar aliados.
============================================================================]]

if BanditTacticalDialogues then return end -- guarda anti doble carga
BanditTacticalDialogues = {}
local TD = BanditTacticalDialogues

TD.VERSION = "1.1.0"

-- ---------------------------------------------------------------------------
-- Locales de motor (resueltos una vez, no en cada frame)
-- ---------------------------------------------------------------------------
local getTimestampMs = getTimestampMs
local ZombRand       = ZombRand
local pcall          = pcall
local pairs          = pairs
local string_format  = string.format

-- ---------------------------------------------------------------------------
-- Configuracion
-- ---------------------------------------------------------------------------
TD.Config = {
    Enabled       = true,
    CooldownMinMs = 5000,   -- ventana anti-spam por bandido: 5 s ...
    CooldownMaxMs = 10000,  -- ... a 10 s
    HearingRange  = 18,     -- casillas: radio en que un aliado "escucha" una baja
    TickIntervalMs= 400,    -- presupuesto del chequeo de recarga por bandido
    Color         = {r = 0.95, g = 0.35, b = 0.25},
    Debug         = false,
}
TD.Config.HearingRangeSq = TD.Config.HearingRange * TD.Config.HearingRange

-- ---------------------------------------------------------------------------
-- Lineas de dialogo.
-- Tablas estaticas creadas UNA vez al cargar el archivo: jamas se reconstruyen
-- en tiempo de ejecucion, de modo que el GC no ve basura por cada frase.
-- ---------------------------------------------------------------------------
TD.Lines = {
    tookDamage = {
        "Me dieron!",
        "Joder, me dieron!",
        "Cubranme, estoy herido!",
        "Aaagh! Me alcanzo!",
        "Estoy sangrando!",
    },
    reloading = {
        "Cubran el pasillo, estoy recargando!",
        "Sin municion, denme un segundo!",
        "Cambio de cargador! Cubranme!",
        "Recargando! No lo dejen avanzar!",
    },
    -- %s se sustituye por el nombre del aliado caido (brain.fullname)
    allyDied = {
        "Cayeron a %s!",
        "%s ha caido! Nos estan masacrando!",
        "Mataron a %s, hijo de perra!",
        "%s! NO! Acaben con el!",
    },
}

-- ---------------------------------------------------------------------------
-- Estado
-- ---------------------------------------------------------------------------
TD.Enabled   = false
TD.Cooldowns = {}   -- [brain.id] = timestamp en que puede volver a hablar
TD.Reloading = {}   -- [brain.id] = true mientras dura la recarga (anti-repeticion)
TD.NextTick  = {}   -- [brain.id] = timestamp del proximo chequeo de recarga

-- Acciones de tarea del mod base que representan "recargando".
-- Tabla de consulta: mas barata que una cadena de comparaciones.
local RELOAD_ACTIONS = {
    ["Load"]   = true,
    ["Unload"] = true,
    ["Rack"]   = true,
}

-- ---------------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------------
local lastErrorMs = 0

local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TacticalDialogues][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function Log(msg)
    if TD.Config.Debug then print("[TacticalDialogues] " .. tostring(msg)) end
end

local function PickLine(pool)
    if not pool or #pool == 0 then return nil end
    return pool[ZombRand(#pool) + 1]
end

function TD.CanSpeak(id)
    local nextAllowed = TD.Cooldowns[id]
    return nextAllowed == nil or getTimestampMs() >= nextAllowed
end

-- Emite una linea de chat sobre la cabeza del bandido, respetando el cooldown.
-- addLineChatElement es el metodo NATIVO del motor (IsoGameCharacter).
function TD.Say(bandit, id, text)
    if not bandit or not text or not id then return end
    if not TD.CanSpeak(id) then return end

    local c = TD.Config.Color
    local ok, err = pcall(bandit.addLineChatElement, bandit, text, c.r, c.g, c.b)
    if not ok then
        LogError("addLineChatElement", err)
        return
    end

    local cfg = TD.Config
    TD.Cooldowns[id] = getTimestampMs()
                     + cfg.CooldownMinMs
                     + ZombRand(cfg.CooldownMaxMs - cfg.CooldownMinMs)
end

-- ---------------------------------------------------------------------------
-- REACCION: recibir dano
-- OnHitZombie es el evento publico del motor; el propio mod base lo usa para
-- su reaccion de audio. Registrar otro handler es aditivo, no lo sustituye.
-- ---------------------------------------------------------------------------
-- El nucleo (00_TacticalCore) ya filtro que es un bandido y nos pasa el brain
-- y el id ya resueltos: aqui no se repite ninguna llamada a Java.
local function OnHitZombie(zombie, brain, id, attacker, bodyPartType, handWeapon)
    if not TD.Enabled then return end
    if zombie:isDead() then return end

    TD.Say(zombie, id, PickLine(TD.Lines.tookDamage))
end

-- ---------------------------------------------------------------------------
-- REACCION: muerte de un aliado del mismo clan
-- Recorremos la cache publica de bandidos del mod base (BanditZombie.GetAllB),
-- que ya trae posicion y brain por bandido: no hace falta escanear la celda.
-- ---------------------------------------------------------------------------
local function BroadcastAllyDeath(deadBandit, deadBrain)
    local clan = deadBrain.clan or deadBrain.cid
    if clan == nil then return end

    local victimName = deadBrain.fullname or "uno de los nuestros"
    local line = PickLine(TD.Lines.allyDied)
    if not line then return end
    local text = string_format(line, victimName)

    local dx0, dy0, dz0 = deadBandit:getX(), deadBandit:getY(), deadBandit:getZ()
    local rangeSq = TD.Config.HearingRangeSq
    local deadId = deadBrain.id

    local bandits = BanditZombie.GetAllB()
    if not bandits then return end

    for id, light in pairs(bandits) do
        local brain = light.brain
        if id ~= deadId and brain and (brain.clan or brain.cid) == clan and light.z == dz0 then
            local dx, dy = light.x - dx0, light.y - dy0
            if (dx * dx + dy * dy) <= rangeSq then
                local ally = BanditZombie.GetInstanceById(id)
                if ally and not ally:isDead() then
                    TD.Say(ally, id, text)
                end
            end
        end
    end
end

local function OnZombieDead(zombie, brain, id)
    if not TD.Enabled then return end

    local ok, err = pcall(BroadcastAllyDeath, zombie, brain)
    if not ok then LogError("BroadcastAllyDeath", err) end

    -- limpieza del estado de este bandido
    if id then
        TD.Cooldowns[id] = nil
        TD.Reloading[id] = nil
        TD.NextTick[id]  = nil
    end
end

-- ---------------------------------------------------------------------------
-- REACCION: recarga de arma
-- El mod base no expone un evento de recarga; lo que si expone es la cola de
-- tareas del bandido. Cuando la tarea en curso es Load / Unload / Rack, esta
-- recargando. Marcamos un flag para hablar UNA sola vez por episodio.
-- ---------------------------------------------------------------------------
local function OnZombieUpdate(zombie, brain, id, now, dist2, player)
    if not TD.Enabled then return end

    -- presupuesto por bandido: el resto de frames sale aqui
    local nextTick = TD.NextTick[id]
    if nextTick and now < nextTick then return end
    TD.NextTick[id] = now + TD.Config.TickIntervalMs

    local tasks = brain.tasks
    local task = tasks and tasks[1]
    local isReloading = task ~= nil and task.action ~= nil and RELOAD_ACTIONS[task.action] == true

    if isReloading then
        if not TD.Reloading[id] then
            TD.Reloading[id] = true
            TD.Say(zombie, id, PickLine(TD.Lines.reloading))
        end
    elseif TD.Reloading[id] then
        TD.Reloading[id] = nil   -- termino la recarga: rearmamos el aviso
    end
end

-- ---------------------------------------------------------------------------
-- ARRANQUE
-- Si el mod base no esta (o cambio su API), el sub-mod se queda dormido en
-- silencio en lugar de romper la partida.
-- ---------------------------------------------------------------------------
local function Bootstrap()
    if not TD.Config.Enabled then return end

    local missing = {}
    if type(PVCCore) ~= "table" or type(PVCCore.OnUpdate) ~= "function" then
        missing[#missing + 1] = "PVCCore (00_TacticalCore.lua)"
    end
    if type(BanditBrain) ~= "table" or type(BanditBrain.Get) ~= "function" then
        missing[#missing + 1] = "BanditBrain.Get"
    end
    if type(BanditZombie) ~= "table" or
       type(BanditZombie.GetAllB) ~= "function" or
       type(BanditZombie.GetInstanceById) ~= "function" then
        missing[#missing + 1] = "BanditZombie.GetAllB / GetInstanceById"
    end

    if #missing > 0 then
        print("[TacticalDialogues] INACTIVO. Falta el mod base Bandits o su API cambio: "
              .. table.concat(missing, ", "))
        return
    end

    TD.Enabled = true

    -- Nos colgamos del despachador compartido en vez de registrar nuestros
    -- propios Events.*: el filtrado pesado se hace una sola vez para los tres
    -- modulos del sub-mod.
    PVCCore.OnUpdate("TacticalDialogues", OnZombieUpdate)
    PVCCore.OnHit("TacticalDialogues", OnHitZombie)
    PVCCore.OnDead("TacticalDialogues", OnZombieDead)

    print("[TacticalDialogues] v" .. TD.VERSION .. " activo (dano / bajas del clan / recarga).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TacticalDialogues] INACTIVO por error en el arranque.")
    end
end)
