--[[==========================================================================
    MaurinBombinAI.lua
    Ecosistema "MaurinBombin Market" - FASE 2 de 3
    IA DEL ESCUADRON MERCANTE (cliente): zona segura, hack de ruido y pacto

    ---------------------------------------------------------------------------
    POR QUE ESTA EN client/
    ---------------------------------------------------------------------------
    El tick de IA del mod base (client/BanditUpdate.lua) es client-side y corta
    con "if isServer() then return end": en el servidor no hay ningun bandido
    que actualizar. Todo lo que lea o escriba el brain, anada tareas o toque el
    arma en las manos tiene que vivir aqui. El SPAWN, en cambio, esta en
    server/MaurinBombinSpawn.lua (un dedicado no ejecuta client/).

    ---------------------------------------------------------------------------
    RENDIMIENTO: SE ENGANCHA A PVCCore, NO A OnZombieUpdate
    ---------------------------------------------------------------------------
    PVCCore ya hace una sola vez por zombi y frame el filtro caro
    (getVariableBoolean("Bandit") + BanditBrain.Get + distancia al jugador) y
    reparte el resultado. Registrarnos ahi en vez de anadir OTRO handler a
    Events.OnZombieUpdate es lo que evita duplicar miles de llamadas a Java por
    segundo. Ver la cabecera de 00_TacticalCore.lua.

    En este archivo NO se instancia ni una tabla por tick: el estado por NPC
    vive en campos del propio brain (prefijo mbm*), igual que hacen los demas
    modulos del submod (tqw*, ta*, pvc*).

    ---------------------------------------------------------------------------
    EL HACK DE RUIDO (lo importante de esta fase)
    ---------------------------------------------------------------------------
    Un puesto fijo que dispara a todo zombi que se acerca seria una fabrica de
    hordas: cada disparo mete un evento de ruido con radio ~70 casillas, y el
    motor tiene que despertar y repathear a cada zombi del vecindario. Con el
    mercado activo durante dias de partida, eso es un sumidero de CPU.

    La solucion es separar las dos cosas que un disparo hace:
      - RUIDO DE GAMEPLAY (el que despierta zombis): vive en el HandWeapon, en
        su radio de sonido. Lo ponemos a 0 en cada tick, asi que cuando el
        motor dispara el radio YA es 0 -- que es la forma practica de "un
        milisegundo antes de disparar": no hay hook de pre-disparo en la API,
        pero si el valor esta puesto de antemano el efecto es identico.
      - AUDIO (lo que oye el jugador): se reproduce aparte por el emisor del
        personaje. getEmitter():playSound() NO alimenta el sistema de ruido
        que alerta zombis -- eso ya esta verificado y documentado en este
        submod (ver TeamPVC_Group.lua ~605, donde ese mismo detalle nos obligo
        a usar addSound() para los gritos). Aqui esa limitacion es justo la
        propiedad que queremos.

    Resultado: se oyen los tiros, no se convoca la ciudad.
============================================================================]]

if isServer() then return end        -- el servidor no simula bandidos
if MaurinBombinAI then return end     -- guarda anti doble carga

MaurinBombinAI = {}
local AI  = MaurinBombinAI
local MBM = MaurinBombin

AI.VERSION = "1.0.0"

local pcall          = pcall
local type           = type
local tostring       = tostring
local pairs          = pairs
local instanceof     = instanceof
local math_floor     = math.floor
local ZombRand       = ZombRand
local getTimestampMs = getTimestampMs

-- ---------------------------------------------------------------------------
-- CONFIGURACION
-- ---------------------------------------------------------------------------
AI.Config = {
    Health          = 50.0,   -- override de vida, una sola vez (primer tick)
    Bullets         = 9999,   -- municion infinita en el cargador logico

    EngageRange     = 10,     -- casillas: distancia a la que un guardia dispara
    DisengageFactor = 1.6,    -- si el objetivo se aleja mas alla, se suelta
    ScanEveryMs     = 750,    -- cadencia del barrido de amenazas por guardia
    ScanCap         = 400,    -- tope duro de zombis inspeccionados por barrido

    HomeTolerance   = 1.5,    -- casillas de deriva toleradas antes de volver
    StaticCheckMs   = 250,    -- cadencia del control de inmovilidad

    AlertRange      = 20,     -- casillas: a quien alcanza la traicion del jugador

    -- Voz del puesto (ver la seccion VOZ DEL PUESTO)
    SpeakCooldownMs = 40000,  -- una frase por NPC cada 40 s reales
    GreetRange      = 6,      -- casillas: el mercader saluda al acercarte
    WarnRange       = 5,      -- casillas: el guardia suelta su advertencia
    CombatLineChance= 12,     -- % de que un disparo venga con frase

    Debug           = false,
}
AI.Config.EngageRangeSq    = AI.Config.EngageRange * AI.Config.EngageRange
AI.Config.DisengageRangeSq = (AI.Config.EngageRange * AI.Config.DisengageFactor) ^ 2
AI.Config.AlertRangeSq     = AI.Config.AlertRange * AI.Config.AlertRange
AI.Config.HomeToleranceSq  = AI.Config.HomeTolerance * AI.Config.HomeTolerance
AI.Config.GreetRangeSq     = AI.Config.GreetRange * AI.Config.GreetRange
AI.Config.WarnRangeSq      = AI.Config.WarnRange * AI.Config.WarnRange

local function Log(msg)
    if AI.Config.Debug then print("[MaurinBombinAI] " .. tostring(msg)) end
end

-- ---------------------------------------------------------------------------
-- VOZ DEL PUESTO
--
-- POR QUE ESTOS DIALOGOS NO HACEN RUIDO
-- Los gritos del Team PVC llaman a addSound() a proposito: son un grito real
-- que puede atraer zombis (ver TeamPVC_Group.lua ~605). Aqui es justo al
-- reves: todo el diseno del mercado consiste en NO despertar a la ciudad (ese
-- es el hack de ruido del arma). Un mercader que berrea cada vez que te acercas
-- tiraria por tierra ese ahorro, asi que las frases son solo texto: se leen,
-- no suenan, y no alimentan el sistema de ruido.
--
-- Todas las frases pasan por getText(): estan traducidas en
-- media/lua/shared/Translate/{ES,EN}/UI.json.
-- ---------------------------------------------------------------------------
AI.Lines = {
    -- Guardias: advertencia rutinaria cuando te acercas al puesto
    guardWarn = {
        "UI_MBM_GuardWarn1", "UI_MBM_GuardWarn2",
        "UI_MBM_GuardWarn3", "UI_MBM_GuardWarn4",
    },
    -- Guardias: el jugador rompio el pacto
    guardBetray = {
        "UI_MBM_GuardBetray1", "UI_MBM_GuardBetray2", "UI_MBM_GuardBetray3",
    },
    -- Guardias: cayo el mercader
    guardAvenge = {
        "UI_MBM_GuardAvenge1", "UI_MBM_GuardAvenge2", "UI_MBM_GuardAvenge3",
    },
    -- Guardias: tiroteando zombis
    guardCombat = {
        "UI_MBM_GuardCombat1", "UI_MBM_GuardCombat2", "UI_MBM_GuardCombat3",
    },
    -- Mercader: saludo la primera vez que te ve
    merchantGreet = {
        "UI_MBM_MerchantGreet1", "UI_MBM_MerchantGreet2", "UI_MBM_MerchantGreet3",
    },
    -- Mercader: charla de mostrador
    merchantIdle = {
        "UI_MBM_MerchantIdle1", "UI_MBM_MerchantIdle2", "UI_MBM_MerchantIdle3",
    },
    -- Mercader: le dispararon
    merchantBetray = {
        "UI_MBM_MerchantBetray1", "UI_MBM_MerchantBetray2",
    },
}

local function Choice(pool)
    local n = #pool
    if n == 0 then return nil end
    return pool[ZombRand(n) + 1]
end

-- Dice una frase del pool respetando el cooldown por NPC. Devuelve true solo si
-- la dijo de verdad, para que quien llama pueda decidir si marcar la frase como
-- "ya usada" (patron de TeamPVC.SpeakLine).
local function Speak(zombie, brain, now, pool, ignoreCooldown)
    if not ignoreCooldown then
        local next = brain.mbmNextLine
        if next and now < next then return false end
    end
    brain.mbmNextLine = now + AI.Config.SpeakCooldownMs

    local key = Choice(pool)
    if not key then return false end

    -- Sin addSound: texto puro. Ver la nota de arriba.
    local ok = pcall(zombie.addLineChatElement, zombie, getText(key), 1, 0.92, 0.6)
    return ok == true
end

-- ---------------------------------------------------------------------------
-- IDENTIDAD
-- El cliente identifica por brain (que el servidor asigna al crear el bandido
-- y se replica a todos), no por el modData: el modData lo escribe el servidor
-- y no viaja de vuelta. El etiquetado local se hace igualmente en el primer
-- tick para que el OnZombieDead de ESTE cliente pueda reconocer el cadaver.
-- ---------------------------------------------------------------------------
local function RoleOf(brain)
    if brain.bid == MBM.MERCHANT_BID then return MBM.ROLE_MERCHANT end
    if brain.bid == MBM.GUARD_A_BID or brain.bid == MBM.GUARD_B_BID then
        return MBM.ROLE_GUARD
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- PRIMER TICK
-- ---------------------------------------------------------------------------
local function InitNPC(zombie, brain, id, role)
    brain.mbmInit = true

    -- 50.0 de HP. Se hace UNA sola vez a proposito: reaplicarlo por tick los
    -- volveria inmortales (curaria todo el dano recibido) y el permadeath de
    -- la Fase 1 dejaria de poder ocurrir.
    local ok = pcall(zombie.setHealth, zombie, AI.Config.Health)
    if not ok then MBM.LogError("setHealth", "no se pudo fijar la vida") end

    -- Origen del puesto: a esta casilla vuelven si los empujan.
    brain.mbmHomeX = zombie:getX()
    brain.mbmHomeY = zombie:getY()
    brain.mbmHomeZ = zombie:getZ()

    -- Marca local para el anti-loot de este cliente (espejo de la del servidor).
    MBM.TagNPC(zombie, role, tostring(brain.id))

    if role == MBM.ROLE_MERCHANT then
        -- Pacifico de verdad: ni ataca ni es objetivo de los zombis.
        brain.hostile  = false
        brain.hostileP = false
        MBM.MakeIgnoredByZombies(zombie)
    else
        -- Los guardias SI son hostiles en general (tienen que poder tirotear
        -- zombis), pero no al jugador: eso es hostileP.
        brain.hostile  = true
        brain.hostileP = false
    end

    Log("NPC inicializado: rol=" .. tostring(role) .. " id=" .. tostring(id))
end

-- ---------------------------------------------------------------------------
-- PACTO DE NO AGRESION
-- Se reafirma en cada tick porque los programas del mod base pueden reevaluar
-- la hostilidad por su cuenta (por ejemplo al ver al jugador armado).
-- ---------------------------------------------------------------------------
local function EnforcePact(brain, role)
    if brain.mbmBetrayed then
        -- El jugador rompio el pacto: hostiles, pero SIN perseguir (de eso se
        -- encarga EnforceStatic, que los devuelve al puesto).
        brain.hostile  = true
        brain.hostileP = true
        return
    end

    if role == MBM.ROLE_MERCHANT then
        brain.hostile  = false
        brain.hostileP = false
    else
        brain.hostile  = true
        brain.hostileP = false
    end
end

-- ---------------------------------------------------------------------------
-- ZONA SEGURA: INMOVILIDAD
-- No existe un "ForceStationary" en la API del mod base, asi que la
-- inmovilidad se implementa sobre lo que SI existe y ya usa este submod:
--   - si se alejaron del origen -> una unica tarea de movimiento de vuelta
--     (solo si no tienen ya una en curso, para no reencolar por frame);
--   - si estan en casa y aun asi les queda una tarea de movimiento (el
--     programa del mod base intentando perseguir) -> se anula con ClearTasks.
-- ClearTasks solo se llama cuando hay movimiento pendiente y no hay una accion
-- en curso: asi no se corta un disparo ni una recarga a medias.
-- ---------------------------------------------------------------------------
local function EnforceStatic(zombie, brain, now)
    local next = brain.mbmNextStatic
    if next and now < next then return end
    brain.mbmNextStatic = now + AI.Config.StaticCheckMs

    local hx, hy, hz = brain.mbmHomeX, brain.mbmHomeY, brain.mbmHomeZ
    if not hx then return end

    local dx, dy = zombie:getX() - hx, zombie:getY() - hy
    local d2 = dx * dx + dy * dy

    if d2 > AI.Config.HomeToleranceSq then
        -- Empujado (o arrastrado por el pathing): vuelve caminando.
        if Bandit.HasMoveTask(zombie) then return end
        local dist = BanditUtils.DistTo(zombie:getX(), zombie:getY(), hx, hy)
        Bandit.ClearTasks(zombie)
        Bandit.AddTask(zombie, BanditUtils.GetMoveTask(0, math_floor(hx), math_floor(hy),
                                                       math_floor(hz or 0), "Walk", dist, false))
        return
    end

    -- Ya esta en su sitio: cualquier orden de movimiento pendiente es una
    -- persecucion que no queremos.
    if Bandit.HasMoveTask(zombie) and not Bandit.HasActionTask(zombie) then
        Bandit.ClearTasks(zombie)
    end
end

-- ---------------------------------------------------------------------------
-- HACK DE RUIDO + MUNICION INFINITA
-- ---------------------------------------------------------------------------

-- Silenciado de gameplay: el radio de sonido del arma se pone a 0 ANTES de que
-- el motor pueda disparar. Ver la nota larga de la cabecera.
local function SilenceWeapon(zombie)
    local ok, weapon = pcall(zombie.getPrimaryHandItem, zombie)
    if not ok or not weapon then return nil end
    pcall(weapon.setSoundRadius, weapon, 0)
    return weapon
end

-- Audio real por el emisor del personaje. No alimenta el sistema de ruido, o
-- sea que se oye el disparo y la ciudad no se entera.
local function PlayShotSound(zombie, weapon)
    if not weapon then return end

    local okSnd, sound = pcall(weapon.getSwingSound, weapon)
    if not okSnd or type(sound) ~= "string" or sound == "" then return end

    local okEm, emitter = pcall(zombie.getEmitter, zombie)
    if not okEm or not emitter then return end

    pcall(emitter.playSound, emitter, sound)
end

-- Charla de mostrador. Solo mientras el pacto siga en pie: si le disparaste al
-- puesto, aqui ya no hay cortesias.
local function Chatter(zombie, brain, role, now, player)
    if not player or brain.mbmBetrayed then return end

    local dx, dy = player:getX() - zombie:getX(), player:getY() - zombie:getY()
    local d2 = dx * dx + dy * dy

    if role == MBM.ROLE_MERCHANT then
        if d2 > AI.Config.GreetRangeSq then return end

        -- El saludo solo se marca como dicho si de verdad salio: si el cooldown
        -- lo bloqueo, se reintenta en vez de perderse (patron de TeamPVC).
        if not brain.mbmGreeted then
            if Speak(zombie, brain, now, AI.Lines.merchantGreet) then
                brain.mbmGreeted = true
            end
            return
        end

        Speak(zombie, brain, now, AI.Lines.merchantIdle)
        return
    end

    if d2 > AI.Config.WarnRangeSq then return end
    Speak(zombie, brain, now, AI.Lines.guardWarn)
end

-- Municion infinita + deteccion de disparo.
-- El disparo se detecta porque el motor DECREMENTA bulletsLeft: si el valor
-- bajo respecto al que dejamos nosotros el tick anterior, hubo tiro. Es la
-- unica senal fiable sin hooks de pre-disparo, y no cuesta nada.
local function FeedAmmoAndDetectShot(zombie, brain, weapon, now)
    local weapons = brain.weapons
    local primary = weapons and weapons.primary
    if type(primary) ~= "table" then return end

    local left = primary.bulletsLeft or 0
    local last = brain.mbmLastBullets
    if last and left < last then
        PlayShotSound(zombie, weapon)
        -- De vez en cuando, el guardia comenta la faena.
        if ZombRand(100) < AI.Config.CombatLineChance then
            Speak(zombie, brain, now, AI.Lines.guardCombat)
        end
    end

    primary.bulletsLeft = AI.Config.Bullets
    brain.mbmLastBullets = AI.Config.Bullets
end

-- ---------------------------------------------------------------------------
-- SELECCION DE OBJETIVO (guardias)
-- Barrido acotado y throttleado: solo corre cada ScanEveryMs por guardia, con
-- tope de iteraciones, y PVCCore ya garantiza que el guardia esta a menos de
-- 45 casillas del jugador (si no, no llegamos hasta aqui).
-- ---------------------------------------------------------------------------
local function FindNearbyThreat(zombie)
    local cell = getCell()
    if not cell then return nil end

    local okList, list = pcall(cell.getZombieList, cell)
    if not okList or not list then return nil end

    local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
    local best, bestD2 = nil, AI.Config.EngageRangeSq

    local n = list:size()
    if n > AI.Config.ScanCap then n = AI.Config.ScanCap end

    for i = 0, n - 1 do
        local other = list:get(i)
        -- Ni a si mismo, ni a otros bandidos (el pacto es con los muertos, no
        -- una guerra de clanes), ni a cadaveres.
        if other and other ~= zombie and not other:isDead()
           and not other:getVariableBoolean("Bandit") and other:getZ() == zz then
            local dx, dy = other:getX() - zx, other:getY() - zy
            local d2 = dx * dx + dy * dy
            if d2 < bestD2 then
                best, bestD2 = other, d2
            end
        end
    end

    return best
end

local function UpdateTarget(zombie, brain, now, player)
    local next = brain.mbmNextScan
    if next and now < next then return end
    brain.mbmNextScan = now + AI.Config.ScanEveryMs

    -- Si el jugador rompio el pacto, el es la prioridad -- pero se le dispara
    -- desde el puesto, sin salir a buscarlo (EnforceStatic manda).
    if brain.mbmBetrayed and player then
        local dx, dy = player:getX() - zombie:getX(), player:getY() - zombie:getY()
        if (dx * dx + dy * dy) <= AI.Config.EngageRangeSq then
            pcall(zombie.setTarget, zombie, player)
            return
        end
    end

    -- Objetivo actual todavia valido?
    local okT, current = pcall(zombie.getTarget, zombie)
    if okT and current and not current:isDead() then
        local dx, dy = current:getX() - zombie:getX(), current:getY() - zombie:getY()
        if (dx * dx + dy * dy) <= AI.Config.DisengageRangeSq then return end
        pcall(zombie.setTarget, zombie, nil)   -- se alejo: se suelta
    end

    local threat = FindNearbyThreat(zombie)
    if threat then
        pcall(zombie.setTarget, zombie, threat)
    end
end

-- ---------------------------------------------------------------------------
-- TICK PRINCIPAL (lo despacha PVCCore)
-- ---------------------------------------------------------------------------
local function OnUpdate(zombie, brain, id, now, dist2, player)
    if brain.cid ~= MBM.CLAN_ID then return end

    local role = RoleOf(brain)
    if not role then return end

    if not brain.mbmInit then InitNPC(zombie, brain, id, role) end

    EnforcePact(brain, role)
    EnforceStatic(zombie, brain, now)
    Chatter(zombie, brain, role, now, player)

    if role ~= MBM.ROLE_GUARD then return end

    -- El silenciado se aplica en CADA tick, sin throttle: es una sola llamada
    -- a Java y tiene que estar puesto pase lo que pase en el momento del tiro.
    local weapon = SilenceWeapon(zombie)
    FeedAmmoAndDetectShot(zombie, brain, weapon, now)
    UpdateTarget(zombie, brain, now, player)
end

-- ---------------------------------------------------------------------------
-- ROTURA DEL PACTO
-- Si el jugador dispara/golpea a cualquiera del escuadron, todo el puesto se
-- vuelve hostil hacia el. No hay vuelta atras: es una decision del jugador.
-- ---------------------------------------------------------------------------
local function AlertSquad(zombie)
    if type(BanditZombie) ~= "table" or type(BanditZombie.GetAllB) ~= "function" then return end

    local bandits = BanditZombie.GetAllB()
    if not bandits then return end

    local x0, y0, z0 = zombie:getX(), zombie:getY(), zombie:getZ()

    for id, light in pairs(bandits) do
        local other = light.brain
        if other and other.cid == MBM.CLAN_ID and not other.mbmBetrayed and light.z == z0 then
            local dx, dy = light.x - x0, light.y - y0
            if (dx * dx + dy * dy) <= AI.Config.AlertRangeSq then
                other.mbmBetrayed = true
            end
        end
    end
end

local function OnHit(zombie, brain, id, attacker, bodyPartType, handWeapon)
    if brain.cid ~= MBM.CLAN_ID then return end
    if not attacker or not instanceof(attacker, "IsoPlayer") then return end
    if brain.mbmBetrayed then return end

    brain.mbmBetrayed = true
    Log("Pacto roto por el jugador (id=" .. tostring(id) .. ")")

    -- Esta frase ignora el cooldown: es EL momento, no puede comerse un
    -- temporizador de charla.
    local role = RoleOf(brain)
    local pool = (role == MBM.ROLE_MERCHANT) and AI.Lines.merchantBetray or AI.Lines.guardBetray
    Speak(zombie, brain, getTimestampMs(), pool, true)

    local ok, err = pcall(AlertSquad, zombie)
    if not ok then MBM.LogError("AlertSquad", err) end
end

-- Cae el mercader: los guardias que lo vean gritan y dejan de respetar el pacto
-- (mataste el negocio, ya no hay nada que proteger salvo el orgullo).
local function AvengeMerchant(deadZombie)
    if type(BanditZombie) ~= "table" or type(BanditZombie.GetAllB) ~= "function" then return end

    local bandits = BanditZombie.GetAllB()
    if not bandits then return end

    local x0, y0, z0 = deadZombie:getX(), deadZombie:getY(), deadZombie:getZ()
    local now = getTimestampMs()

    for id, light in pairs(bandits) do
        local other = light.brain
        if other and other.cid == MBM.CLAN_ID and other.bid ~= MBM.MERCHANT_BID
           and light.z == z0 then
            local dx, dy = light.x - x0, light.y - y0
            if (dx * dx + dy * dy) <= AI.Config.AlertRangeSq then
                other.mbmBetrayed = true
                local guard = BanditZombie.GetInstanceById(id)
                if guard and not guard:isDead() then
                    Speak(guard, other, now, AI.Lines.guardAvenge, true)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- MUERTE
-- El vaciado de inventario es un ESPEJO local del que ya hace el servidor
-- (Fase 1): en single player y en anfitrion evita cualquier ventana en la que
-- el cadaver pudiera quedar saqueable, y en un dedicado el aviso por red es el
-- respaldo por si el evento no llegara a dispararse en el proceso servidor.
-- El servidor solo lo acepta si el uid esta en el escuadron registrado.
-- ---------------------------------------------------------------------------
local function OnDead(zombie, brain, id)
    if brain.cid ~= MBM.CLAN_ID then return end

    local role = RoleOf(brain)
    if not role then return end

    MBM.StripInventory(zombie)

    if role == MBM.ROLE_MERCHANT then
        local okAvenge, errAvenge = pcall(AvengeMerchant, zombie)
        if not okAvenge then MBM.LogError("AvengeMerchant", errAvenge) end
    end

    if isClient() then
        local ok, err = pcall(sendClientCommand, getPlayer(), MBM.NET.MODULE, MBM.NET.C_NPCDOWN,
                              {uid = tostring(brain.id), role = role})
        if not ok then MBM.LogError("NPCDown", err) end
    end
end

-- ---------------------------------------------------------------------------
-- REGISTRO
-- Se comprueba primero que este todo lo que usamos del mod base y del nucleo:
-- si falta algo, el modulo se declara INACTIVO por consola en vez de reventar
-- una vez por zombi y por frame.
-- ---------------------------------------------------------------------------
local function MissingDependencies()
    local missing = {}

    local required = {
        {"MaurinBombin",   MaurinBombin},
        {"PVCCore",        PVCCore},
        {"Bandit",         Bandit},
        {"BanditUtils",    BanditUtils},
    }
    for i = 1, #required do
        if type(required[i][2]) ~= "table" then missing[#missing + 1] = required[i][1] end
    end
    if #missing > 0 then return missing end

    local functions = {
        {"Bandit.AddTask",          Bandit.AddTask},
        {"Bandit.ClearTasks",       Bandit.ClearTasks},
        {"Bandit.HasMoveTask",      Bandit.HasMoveTask},
        {"Bandit.HasActionTask",    Bandit.HasActionTask},
        {"BanditUtils.GetMoveTask", BanditUtils.GetMoveTask},
        {"BanditUtils.DistTo",      BanditUtils.DistTo},
        {"PVCCore.OnUpdate",        PVCCore.OnUpdate},
        {"PVCCore.OnHit",           PVCCore.OnHit},
        {"PVCCore.OnDead",          PVCCore.OnDead},
    }
    for i = 1, #functions do
        if type(functions[i][2]) ~= "function" then missing[#missing + 1] = functions[i][1] end
    end

    return missing
end

local function Register()
    local missing = MissingDependencies()
    if #missing > 0 then
        print("[MaurinBombinAI] INACTIVO: faltan dependencias -> " .. table.concat(missing, ", "))
        return
    end

    PVCCore.OnUpdate("MaurinBombinAI", OnUpdate)
    PVCCore.OnHit("MaurinBombinAI",    OnHit)
    PVCCore.OnDead("MaurinBombinAI",   OnDead)

    print("[MaurinBombinAI] v" .. AI.VERSION .. " registrado en PVCCore.")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Register)
    if not ok then MBM.LogError("Register", err) end
end)
