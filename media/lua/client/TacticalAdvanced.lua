--[[==========================================================================
    TacticalAdvanced.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Sprint 2: sistemas de IA de alto nivel que aplican a CUALQUIER clan de
    Bandits2 (no solo Team PVC): moral de escuadra y medico de combate.

    ---------------------------------------------------------------------------
    LO QUE NO SE REIMPLEMENTA A PROPOSITO: "El Breacher"
    ---------------------------------------------------------------------------
    El brief pedia una mecanica para que bandidos con Bandit.Expertise.Breaker
    fuercen ataques contra estructuras cuando el camino esta bloqueado.
    Verificado en el codigo del mod base (client/BanditUpdate.lua, funcion
    ManageCollisions, lineas ~601-880): ESO YA EXISTE. Cuando un Breaker se
    topa con una ventana o puerta barricada, el mod base ya:
      1) cambia de arma a ganzua o soplete de propano segun el material,
      2) encola una tarea Unbarricade / UnbarricadeMetal / Destroy,
      3) esta gateado exactamente por Bandit.HasExpertise(bandit,
         Bandit.Expertise.Breaker) -- el mismo flag que pedia el brief.
    Ademas SandboxVars.Bandits.General_RemoveBarricade viene en `true` por
    defecto (sandbox-options.txt), asi que esta ACTIVO ahora mismo sin tocar
    nada. Reimplementarlo hubiera sido trabajo redundante y con riesgo real de
    pisar la logica nativa (que ya maneja el cambio de arma con cuidado antes
    de atacar). Nealcito (nuestro unico Breaker) ya se beneficia de esto solo.

    ---------------------------------------------------------------------------
    ARQUITECTURA
    ---------------------------------------------------------------------------
    Se registra en el despachador compartido (00_TacticalCore.lua / PVCCore)
    en vez de Events.OnZombieUpdate/OnHitZombie/OnZombieDead propios: el
    filtrado caro (es bandido? brain? distancia al jugador?) ya lo hizo el
    nucleo una sola vez para todos los modulos.

    "LIDER" EN CLANES GENERICOS: el mod base no tiene ningun concepto de
    liderazgo para clanes de asalto normales (confirmado: no existe "leader"
    en ningun lado del codigo; brain.master es sobre propiedad de companions,
    no jerarquia de escuadra). Para clanes genericos definimos nuestro propio
    heuristico honesto: el PRIMER integrante de ese cid que vemos con vida
    queda designado su "lider" informal. Para Team PVC no hace falta adivinar:
    el capitan real es TeamPVC.CAPTAIN_BID (expuesto por TeamPVC_Group.lua).
============================================================================]]

if TacticalAdvanced then return end -- guarda anti doble carga
TacticalAdvanced = {}
local TA = TacticalAdvanced
TA.VERSION = "1.0.0"

local getTimestampMs = getTimestampMs
local getSpecificPlayer = getSpecificPlayer
local ZombRand        = ZombRand
local ZombRandFloat    = ZombRandFloat
local pcall            = pcall
local pairs            = pairs
local math_sqrt        = math.sqrt
local math_min         = math.min

TA.Config = {
    Debug = false,

    Morale = {
        Enabled             = true,
        CasualtyThreshold   = 0.60,   -- 60% de bajas dispara la huida
        FleeSpeedTiles      = 25,     -- hasta donde intentan alejarse por tramo
        FleeRepathMs        = 4000,   -- cada cuanto se les da una nueva orden de huida
    },

    Medic = {
        Enabled       = true,
        Range         = 15,      -- casillas
        HealthPct     = 0.50,    -- cura si el aliado esta por debajo de esto
        HealAmount    = 0.40,    -- vida restaurada (escala 0..~2.6 del mod base)
        IntervalMs    = 3000,
        CooldownMs    = 30000,   -- entre curaciones del mismo medico
    },
}

-- Tablas planas por cid: cero asignaciones por tick, solo se tocan cuando
-- aparece un integrante nuevo o cuando alguien muere (eventos raros).
TA.SquadPeak    = {}   -- [cid] = maximo de integrantes vistos con vida
TA.SquadSeen    = {}   -- [cid] = { [id]=true, ... }  (para no contar dos veces)
TA.SquadLeader  = {}   -- [cid] = id del primer integrante visto (lider informal)

local function TrackSquadMember(cid, id)
    local seen = TA.SquadSeen[cid]
    if not seen then
        seen = {}
        TA.SquadSeen[cid] = seen
    end
    if seen[id] then return end
    seen[id] = true
    TA.SquadPeak[cid] = (TA.SquadPeak[cid] or 0) + 1
    if not TA.SquadLeader[cid] then
        TA.SquadLeader[cid] = id
    end
end

local lastErrorMs = 0
local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TacticalAdvanced][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function Log(msg)
    if TA.Config.Debug then print("[TacticalAdvanced] " .. tostring(msg)) end
end

-- Grito simple: mismo primitivo que usa el mod base para sus subtitulos
-- (zombie:addLineChatElement), sin cooldown propio -- estos son eventos
-- raros y unicos (muerte del lider), no hace falta throttlear.
local function Shout(bandit, text, r, g, b)
    local ok, err = pcall(bandit.addLineChatElement, bandit, text, r or 1, g or 0.2, b or 0.1)
    if not ok then LogError("Shout", err) end
end

-- #1 -- SISTEMA DE MORAL Y FURIA

-- Huida: apaga la hostilidad (lo que consulta ManageCombat del mod base para
-- decidir si atacar, confirmado ya por el propio Negociador de TacticalQuickWins,
-- que depende de este mismo mecanismo) y los manda lejos del jugador.
local function MakeFlee(zombie, brain, player)
    if brain.taFleeing then return end
    brain.taFleeing = true
    brain.hostile  = false
    brain.hostileP = false

    Bandit.ClearTasks(zombie)
    zombie:setTarget(nil)
    zombie:clearAggroList()

    Log("Moral: bandido huyendo (cid=" .. tostring(brain.cid) .. ")")
end
-- Expuesta en la tabla publica: TacticalAsymmetric.lua la reutiliza para el
-- saboteador de vehiculos (huye tras robar) en vez de duplicar esta logica.
TA.MakeFlee = MakeFlee

-- Se llama periodicamente (no solo al activarse la huida) para mantenerlos
-- corriendo: una sola orden de movimiento no alcanza para "desaparecer del
-- mapa", asi que se les da una nueva cada vez que terminan la anterior.
local function KeepFleeing(zombie, brain, state, now, player)
    if not brain.taFleeing then return end
    if Bandit.HasMoveTask(zombie) then return end

    local next = state.taFleeRepathAt
    if next and now < next then return end
    state.taFleeRepathAt = now + TA.Config.Morale.FleeRepathMs

    local px, py = player and player:getX() or zombie:getX(), player and player:getY() or zombie:getY()
    local bx, by, bz = zombie:getX(), zombie:getY(), zombie:getZ()
    local vx, vy = bx - px, by - py
    local len = math_sqrt(vx * vx + vy * vy)
    if len < 0.1 then vx, vy, len = 1, 0, 1 end

    local t = TA.Config.Morale.FleeSpeedTiles
    local tx = math.floor(bx + (vx / len) * t)
    local ty = math.floor(by + (vy / len) * t)

    local cell = getCell()
    local square = cell:getGridSquare(tx, ty, bz)
    if not square then square = zombie:getSquare() end
    if not square then return end

    local dist = t
    Bandit.AddTask(zombie, BanditUtils.GetMoveTask(0, square:getX(), square:getY(), square:getZ(), "Run", dist, false))
end

-- Furia: EXCLUSIVO de Team PVC cuando cae el Capitan. Nunca huyen; en cambio
-- suben su precision (no existe sistema de "cobertura" que ignorar en este
-- motor -- verificado, ManageCombat no tiene ese concepto) y cortan cualquier
-- negociacion en curso, porque en furia no se negocia.
local function MakeFurious(zombie, brain)
    if brain.taFurious then return end
    brain.taFurious = true
    brain.hostile  = true
    brain.hostileP = true
    brain.tqwHostileUntil = nil   -- corta cualquier negociacion de TacticalQuickWins en curso

    brain.accuracyBoost = math_min(8, (brain.accuracyBoost or 0) + 3)

    Log("Furia: Team PVC entra en furia (id=" .. tostring(brain.id) .. ")")
end

-- Reaccion a una muerte: decide si dispara huida (clanes normales) o furia
-- (Team PVC, solo si cayo el Capitan). Envuelto en pcall por el dispatcher.
local function OnSquadmateDeath(deadZombie, deadBrain, deadId)
    local cid = deadBrain.cid
    if not cid then return end

    local isTeamPVC = (type(TeamPVC) == "table" and cid == TeamPVC.CLAN_ID)
    local isCaptain = isTeamPVC and type(TeamPVC.CAPTAIN_BID) == "string"
                       and deadBrain.bid == TeamPVC.CAPTAIN_BID

    if isTeamPVC and not isCaptain then
        -- Team PVC nunca huye por bajas normales; solo la muerte del
        -- Capitan dispara algo (furia). El resto de las muertes no activan
        -- ni huida ni furia.
        return
    end

    -- cuenta cuantos quedan vivos de este cid
    local alive, survivors = 0, {}
    local all = BanditZombie.GetAllB()
    if not all then return end
    for id, light in pairs(all) do
        if id ~= deadId and light.brain and light.brain.cid == cid then
            local zombie = BanditZombie.GetInstanceById(id)
            if zombie and not zombie:isDead() then
                alive = alive + 1
                survivors[alive] = {zombie = zombie, brain = light.brain}
            end
        end
    end
    if alive == 0 then return end   -- no queda nadie a quien avisar

    if isTeamPVC and isCaptain then
        local player = getSpecificPlayer(0)
        local shouted = false
        for i = 1, alive do
            local ok, err = pcall(MakeFurious, survivors[i].zombie, survivors[i].brain)
            if not ok then LogError("MakeFurious", err) end
            if not shouted then
                Shout(survivors[i].zombie, getText("BEP_TA_CaptainDown"), 1, 0.1, 0.1)
                shouted = true
            end
        end
        return
    end

    -- clan generico: decide por lider caido o por umbral de bajas
    local peak = TA.SquadPeak[cid] or (alive + 1)
    local casualtyPct = 1 - (alive / peak)
    local leaderDied = (TA.SquadLeader[cid] == deadId)

    if not (leaderDied or casualtyPct >= TA.Config.Morale.CasualtyThreshold) then
        return
    end

    local player = getSpecificPlayer(0)
    for i = 1, alive do
        local ok, err = pcall(MakeFlee, survivors[i].zombie, survivors[i].brain, player)
        if not ok then LogError("MakeFlee", err) end
    end
end

local function OnZombieDead(zombie, brain, id)
    if not TA.Config.Morale.Enabled then return end
    if not brain or not brain.cid then return end

    TrackSquadMember(brain.cid, id)  -- por si nunca lo vimos vivo (poco probable, pero defensivo)

    local ok, err = pcall(OnSquadmateDeath, zombie, brain, id)
    if not ok then LogError("OnSquadmateDeath", err) end

    local seen = TA.SquadSeen[brain.cid]
    if seen then seen[id] = nil end
end

-- #2 -- EL MEDICO DE COMBATE
local function Feature_Medic(bandit, brain, id, now, dist2, player, state)
    local cfg = TA.Config.Medic
    if not cfg.Enabled then return end
    if not Bandit.HasExpertise(bandit, Bandit.Expertise.Medic) then return end

    local nextCheck = state.taMedicNextTick
    if nextCheck and now < nextCheck then return end
    state.taMedicNextTick = now + cfg.IntervalMs

    local cd = state.taMedicCooldown
    if cd and now < cd then return end

    if Bandit.HasActionTask(bandit) then return end   -- no interrumpe otra accion

    local cid = brain.cid
    local bx, by, bz = bandit:getX(), bandit:getY(), bandit:getZ()
    local rangeSq = cfg.Range * cfg.Range

    local best, bestBrain, bestDist2
    local all = BanditZombie.GetAllB()
    if not all then return end
    for otherId, light in pairs(all) do
        if otherId ~= id and light.brain and light.brain.cid == cid and light.z == bz then
            local dx, dy = light.x - bx, light.y - by
            local d2 = dx * dx + dy * dy
            if d2 <= rangeSq and (not bestDist2 or d2 < bestDist2) then
                local maxHealth = light.brain.health or 1
                local ally = BanditZombie.GetInstanceById(otherId)
                if ally and not ally:isDead() and ally:getHealth() < maxHealth * cfg.HealthPct then
                    best, bestBrain, bestDist2 = ally, light.brain, d2
                end
            end
        end
    end
    if not best then return end

    state.taMedicCooldown = now + cfg.CooldownMs

    Bandit.ClearTasks(bandit)

    local dist = math_sqrt(bestDist2)
    if dist > 1.5 then
        local asquare = AdjacentFreeTileFinder.Find(best:getSquare(), bandit)
        if asquare then
            local d = BanditUtils.DistTo(bx, by, asquare:getX(), asquare:getY())
            Bandit.AddTask(bandit, BanditUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Run", d, false))
        end
    end

    -- targetRef guarda la referencia directa al zombi aliado, no su id: no
    -- necesitamos recalcular nada (BanditBrain.Get(ally) alcanza para todo lo
    -- que hace falta en la accion, ver TAHealAlly.onComplete mas abajo).
    Bandit.AddTask(bandit, {
        action = "TAHealAlly", anim = "BandageUpperBody", time = 200,
        targetRef = best,
        healAmount = cfg.HealAmount,
    })
    Log("Medico: curando aliado a " .. string.format("%.1f", dist) .. " casillas")
end

-- Accion custom TAHealAlly, mismo patron que TQWUseMeds (mod base via
-- Bandit.AddTask/ZombieActions); prefijo TA para no pisar ninguna accion
-- existente ni futura del mod base.
local function RegisterActions()
    ZombieActions = ZombieActions or {}

    ZombieActions.TAHealAlly = {}
    ZombieActions.TAHealAlly.onStart = function(zombie, task)
        return true
    end
    ZombieActions.TAHealAlly.onWorking = function(zombie, task)
        if task.time <= 0 then return true end
        if zombie:getBumpType() ~= task.anim then
            zombie:setBumpType(task.anim)
        end
        return false
    end
    ZombieActions.TAHealAlly.onComplete = function(zombie, task)
        -- Guardamos la referencia directa al aliado (task.targetRef) en vez de
        -- solo su id: BanditZombie.GetInstanceById() puede fallar si el cache
        -- se reconstruyo (Events.EveryOneMinute.flush del mod base) entre que
        -- se encolo la tarea y que termino. La referencia Java sigue siendo
        -- valida aunque el indice haya cambiado.
        local ally = task.targetRef
        if not ally or ally:isDead() then
            local best = Bandit.GetBestWeapon(zombie)
            if best then Bandit.SetHands(zombie, best) end
            return true
        end

        local allyBrain = BanditBrain.Get(ally)
        if allyBrain then
            local maxHealth = allyBrain.health or 1
            local health = ally:getHealth() + (task.healAmount or 0.4)
            if health > maxHealth then health = maxHealth end
            ally:setHealth(health)
        end

        local best = Bandit.GetBestWeapon(zombie)
        if best then Bandit.SetHands(zombie, best) end
        return true
    end
end

TA.State = {}   -- [id] = tabla de estado reutilizada por bandido

local function GetState(id)
    local s = TA.State[id]
    if not s then
        s = {}
        TA.State[id] = s
    end
    return s
end

local function OnZombieUpdate(zombie, brain, id, now, dist2, player)
    if not brain.cid then return end

    TrackSquadMember(brain.cid, id)

    local state = GetState(id)

    if brain.taFleeing then
        local ok, err = pcall(KeepFleeing, zombie, brain, state, now, player)
        if not ok then LogError("KeepFleeing", err) end
        return   -- un bandido huyendo no hace ninguna otra mecanica
    end

    local ok, err = pcall(Feature_Medic, zombie, brain, id, now, dist2, player, state)
    if not ok then LogError("Feature_Medic", err) end
end

local function CleanupState()
    -- barrido de baja frecuencia: bandidos que se descargaron sin pasar por
    -- OnZombieDead (chunk descargado, etc.)
    local now = getTimestampMs()
    for cid, seen in pairs(TA.SquadSeen) do
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        if n == 0 then TA.SquadSeen[cid] = nil end
    end
end

local function CheckDependencies()
    local missing = {}
    local required = {
        {"PVCCore",        PVCCore},
        {"Bandit",         Bandit},
        {"BanditBrain",    BanditBrain},
        {"BanditZombie",   BanditZombie},
        {"BanditUtils",    BanditUtils},
        {"AdjacentFreeTileFinder", AdjacentFreeTileFinder},
    }
    for i = 1, #required do
        if type(required[i][2]) ~= "table" then
            missing[#missing + 1] = required[i][1]
        end
    end
    if type(Bandit) == "table" and type(Bandit.Expertise) ~= "table" then
        missing[#missing + 1] = "Bandit.Expertise"
    end
    return missing
end

local function Bootstrap()
    local missing = CheckDependencies()
    if #missing > 0 then
        print("[TacticalAdvanced] INACTIVO. Falta: " .. table.concat(missing, ", "))
        return
    end

    local ok, err = pcall(RegisterActions)
    if not ok then
        LogError("RegisterActions", err)
        print("[TacticalAdvanced] INACTIVO: no se pudieron registrar las acciones.")
        return
    end

    PVCCore.OnUpdate("TacticalAdvanced", OnZombieUpdate)
    PVCCore.OnDead("TacticalAdvanced", OnZombieDead)

    Events.EveryHours.Remove(CleanupState)
    Events.EveryHours.Add(CleanupState)

    print("[TacticalAdvanced] v" .. TA.VERSION .. " activo (moral/furia + medico de combate).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TacticalAdvanced] INACTIVO por error en el arranque.")
    end
end)
