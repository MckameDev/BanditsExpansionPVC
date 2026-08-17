--[[==========================================================================
    TacticalDialogues.lua
    Sub-mod de expansion para "Bandits" v2 (Slayer) - Build 42
    Idea #27: Comunicaciones y Dialogos Contextuales.
    Los bandidos reaccionan verbalmente al recibir dano, al morir un aliado
    del clan, y al recargar el arma.

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

local getTimestampMs = getTimestampMs
local ZombRand       = ZombRand
local pcall          = pcall
local pairs          = pairs

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

-- Guardan CLAVES de traduccion (no texto), resueltas con getText() en el
-- punto de uso (ver media/lua/shared/Translate/EN|ES/BanditsExpansionPVC.json).
TD.Lines = {
    tookDamage = {
        "UI_BEP_TD_Dmg1", "UI_BEP_TD_Dmg2", "UI_BEP_TD_Dmg3", "UI_BEP_TD_Dmg4", "UI_BEP_TD_Dmg5",
    },
    reloading = {
        "UI_BEP_TD_Reload1", "UI_BEP_TD_Reload2", "UI_BEP_TD_Reload3", "UI_BEP_TD_Reload4",
    },
    -- getText(clave, nombre) sustituye %1 por el nombre del aliado caido (brain.fullname)
    allyDied = {
        "UI_BEP_TD_AllyDied1", "UI_BEP_TD_AllyDied2", "UI_BEP_TD_AllyDied3", "UI_BEP_TD_AllyDied4",
    },
}

TD.Enabled   = false
TD.Cooldowns = {}   -- [brain.id] = timestamp en que puede volver a hablar
TD.Reloading = {}   -- [brain.id] = true mientras dura la recarga (anti-repeticion)
TD.NextTick  = {}   -- [brain.id] = timestamp del proximo chequeo de recarga

local RELOAD_ACTIONS = {
    ["Load"]   = true,
    ["Unload"] = true,
    ["Rack"]   = true,
}

local lastErrorMs = 0

local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TacticalDialogues][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function PickLine(pool)
    if not pool or #pool == 0 then return nil end
    return pool[ZombRand(#pool) + 1]
end

function TD.CanSpeak(id)
    local nextAllowed = TD.Cooldowns[id]
    return nextAllowed == nil or getTimestampMs() >= nextAllowed
end

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

-- OnHitZombie es el evento publico del motor; el propio mod base ya lo usa
-- para su reaccion de audio, asi que registrar otro handler aca es aditivo,
-- no lo sustituye.
local function OnHitZombie(zombie, brain, id, attacker, bodyPartType, handWeapon)
    if not TD.Enabled then return end
    if zombie:isDead() then return end

    TD.Say(zombie, id, getText(PickLine(TD.Lines.tookDamage)))
end

-- Recorremos la cache publica de bandidos del mod base (BanditZombie.GetAllB),
-- que ya trae posicion y brain por bandido: no hace falta escanear la celda.
local function BroadcastAllyDeath(deadBandit, deadBrain)
    local clan = deadBrain.clan or deadBrain.cid
    if clan == nil then return end

    local victimName = deadBrain.fullname or getText("UI_BEP_TD_Unknown")
    local line = PickLine(TD.Lines.allyDied)
    if not line then return end
    local text = getText(line, victimName)

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

    if id then
        TD.Cooldowns[id] = nil
        TD.Reloading[id] = nil
        TD.NextTick[id]  = nil
    end
end

-- El mod base no expone un evento de recarga; lo que si expone es la cola de
-- tareas del bandido. Cuando la tarea en curso es Load / Unload / Rack, esta
-- recargando. Marcamos un flag para hablar UNA sola vez por episodio.
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
            TD.Say(zombie, id, getText(PickLine(TD.Lines.reloading)))
        end
    elseif TD.Reloading[id] then
        TD.Reloading[id] = nil   -- termino la recarga: rearmamos el aviso
    end
end

-- Si el mod base no esta (o cambio su API), el sub-mod se queda dormido en
-- silencio en lugar de romper la partida.
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
