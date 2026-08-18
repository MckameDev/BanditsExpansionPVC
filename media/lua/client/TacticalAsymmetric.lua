--[[==========================================================================
    TacticalAsymmetric.lua
    Sub-mod "Bandits: Tactical Expansion" (Slayer) - Build 42
    Sprint 3: 5 mecanicas de IA asimetrica para bandidos GENERICOS (cualquier
    clan que no sea Team PVC) + la mecanica exclusiva de despedida de
    Evaristo Brea.

    ---------------------------------------------------------------------------
    LAS 6 MECANICAS
    ---------------------------------------------------------------------------
    1) Perfil Tactico Asimetrico: en su primer tick, cada bandido generico
       recibe una tactica fija al azar (25% cada una): FakeSurrender,
       HordeBait, CarSabotage o SmokeAmbush. Team PVC queda AFUERA de este
       sorteo por completo (brain.cid == TeamPVC.CLAN_ID): su IA ya es la
       fija y deliberada de TeamPVC_Group.lua / TacticalAdvanced.lua.
    2) La Ultima Risa (SOLO Evaristo Brea, TeamPVC.EVARISTO_BID): al morir,
       grita su ultima frase y 2.5s despues detona una explosion en el punto
       de su muerte. 100% garantizado, no es un sorteo.
    3) Rendicion Falsa ("El Traicionero", tactica FakeSurrender): con menos
       de 20% de vida o el arma primaria vacia, finge rendirse; si el
       jugador se acerca a menos de 2 casillas, saca un cuchillo y ataca.
    4) Trampa de Horda ("El Carnada", tactica HordeBait): sin linea de vista
       a un jugador atrincherado (edificio/habitacion) a menos de 15
       casillas, dispara un ruido enorme EN la posicion del jugador para
       atraer la horda hacia el en vez de hacia si mismo.
    5) Sabotaje Vehicular ("El Ladron de Motores", tactica CarSabotage):
       localiza un vehiculo a menos de 10 casillas, se lleva la bateria (y
       vacia el tanque) y huye con el botin.
    6) Emboscada de Humo ("El Fantasma", tactica SmokeAmbush): al recibir
       dano o caer bajo 50% de vida, se cubre con una bomba de humo y
       flanquea al jugador mientras dura la cortina (5s).

    ---------------------------------------------------------------------------
    CORRECCIONES SOBRE EL BRIEF ORIGINAL (verificadas contra el codigo real)
    ---------------------------------------------------------------------------
    - "IsoFireManager.Explode" -> el metodo real es en MINUSCULA:
      IsoFireManager.explode(cell, square, power). Confirmado en
      server/ClientCommands.lua y client/LastStand/AReallyCDDAy.lua del
      juego base.
    - "Base.AlarmClock" -> ese item NO EXISTE en esta build (solo existen
      Base.AlarmClock2 y Base.HomeAlarm). El propio brief ofrecia una
      alternativa ("o utiliza addSound()"): usamos addSound() directamente
      sobre la posicion del jugador, sin tirar ningun item -- el mismo
      primitivo de ruido que ya usa el grito de Team PVC (ver la nota larga
      junto a TeamPVC.ShoutCooldown en TeamPVC_Group.lua).
    - Sabotaje vehicular: el flujo del JUGADOR (ISVehiclePartMenu /
      ISUninstallVehiclePart) pasa por ISTimedActionQueue, un sistema
      exclusivo de personajes jugables que la IA de Bandits2 nunca toca. En
      vez de forzar esa integracion, manipulamos el objeto Java de la pieza
      DIRECTAMENTE (getPartById():setInventoryItem(nil) /
      setContainerContentAmount(0)) -- igual de real, mucho mas simple.

    ---------------------------------------------------------------------------
    ARQUITECTURA Y RENDIMIENTO
    ---------------------------------------------------------------------------
    Se registra en el despachador compartido (00_TacticalCore.lua / PVCCore)
    en vez de eventos propios: el filtrado caro (es bandido? brain? distancia
    al jugador?) ya lo hizo el nucleo una sola vez para todos los modulos.
    Reglas duras seguidas en todo el archivo:
      - Nada de tablas nuevas por frame/tick: brain.* solo guarda los pocos
        campos primitivos que necesitan persistir (tactica asignada, flags
        de una sola vez); state[id] (tabla reutilizada, igual que en
        TacticalAdvanced.lua / TacticalQuickWins.lua) guarda cooldowns.
      - Dispatch por tabla (FeatureByTactic[brain.tqwTactic]): UNA sola
        llamada de mecanica por bandido y por tick, no cuatro chequeos.
      - El calculo vectorial del flanqueo de humo (#6) se salta POR COMPLETO
        si el jugador esta a mas de 30 casillas, tal como pidio el brief.
      - Toda llamada de motor que puede fallar entre versiones va en pcall,
        con log limitado a 1 mensaje cada 2s (mismo patron que el resto del
        submod).
============================================================================]]

if TacticalAsymmetric then return end -- guarda anti doble carga
TacticalAsymmetric = {}
local TA2 = TacticalAsymmetric
TA2.VERSION = "1.1.0"

local getTimestampMs = getTimestampMs
local getCell         = getCell
local pcall            = pcall
local math_sqrt        = math.sqrt
local math_floor       = math.floor
local math_abs         = math.abs
local math_min         = math.min
local table_remove     = table.remove
local table_insert     = table.insert
local table_concat     = table.concat

TA2.Tactics = {"FakeSurrender", "HordeBait", "CarSabotage", "SmokeAmbush"}

TA2.Config = {
    Debug = false,

    Evaristo = {
        ExplodeDelayMs = 2500,  -- 2 a 3 segundos, tal como pide el brief
        -- INFORMATIVO: la potencia real la fija el SERVIDOR
        -- (TSS.FxLimits.ExplodePower en server/TacticalSpawnServer.lua). Un
        -- valor que viaja en un paquete de cliente nunca debe dimensionar un
        -- efecto de mundo; este campo queda solo como documentacion del diseno.
        ExplodePower   = 100,   -- misma potencia que usa el juego base
        -- Clave de traduccion (ver Translate/EN|ES/BanditsExpansionPVC.json),
        -- resuelta con getText() en OnEvaristoDead.
        LineKey = "UI_BEP_TA2_EvaristoLastWords",
    },

    FakeSurrender = {
        Enabled       = true,
        HealthPct     = 0.20,  -- <20% de vida dispara la rendicion
        BetrayRange   = 2,     -- casillas: a esta distancia, traiciona
        AccuracyBoost = 4,
    },

    HordeBait = {
        Enabled     = true,
        Range       = 15,      -- casillas, igual que pide el brief
        NoiseRadius = 50,
        NoiseVolume = 10,
        CooldownMs  = 45000,
    },

    CarSabotage = {
        Enabled    = true,
        Range      = 10,       -- casillas
        IntervalMs = 1000,
    },

    SmokeAmbush = {
        Enabled        = true,
        HealthPct      = 0.50,
        DurationMs     = 5000,
        FlankDistance  = 6,
        RepathMs       = 1000,
        MaxFlankDistSq = 30 * 30,  -- mas alla de esto, cero matematica de vectores
    },
}

local lastErrorMs = 0
local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TacticalAsymmetric][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function Log(msg)
    if TA2.Config.Debug then print("[TacticalAsymmetric] " .. tostring(msg)) end
end

-- Texto sobre la cabeza, SIN ruido de mundo: los bandidos genericos ya
-- hablan asi en TacticalDialogues.lua; mantenemos la misma "voz" para no
-- pisar la identidad exclusiva del grito de Team PVC (que si hace ruido,
-- ver la nota junto a TeamPVC.ShoutCooldown en TeamPVC_Group.lua).
local function SayLine(bandit, text)
    local ok, err = pcall(bandit.addLineChatElement, bandit, text, 0.9, 0.55, 0.15)
    if not ok then LogError("SayLine", err) end
end

local function IsTeamPVC(brain)
    return type(TeamPVC) == "table" and brain.cid == TeamPVC.CLAN_ID
end

-- Reutilizada durante toda la vida del bandido, igual que TA.State/TQW.State
-- en los otros modulos del submod.
TA2.State = {}

local function GetState(id)
    local s = TA2.State[id]
    if not s then
        s = {}
        TA2.State[id] = s
    end
    return s
end

-- #1 -- PERFIL TACTICO ASIMETRICO. Se asigna UNA sola vez por bandido
-- generico, en su primer tick con vida.
-- MULTIJUGADOR: la tactica se deriva de forma DETERMINISTA de brain.rnd, no
-- con un sorteo local. Motivo: el tick de IA del mod base corre en TODOS los
-- clientes a la vez y las mutaciones del brain NO se sincronizan entre ellos
-- (solo se propagan los pocos campos que alguien manda a mano con
-- Bandit.ForceSyncPart). Con ZombRand cada jugador habria sorteado una
-- tactica distinta para el MISMO bandido: uno lo veria fingir rendirse y otro
-- sabotear un coche.
-- brain.rnd lo asigna el SERVIDOR al crear el bandido
-- (server/BanditServerSpawner.lua ~375: brain.rnd = {ZombRand(2), ...}) y
-- viaja dentro del brain que se reparte a todos, asi que todos calculan el
-- mismo indice sin una sola llamada de red y sin ventana de carrera.
-- Es el mismo truco que ya usa IsPyro en TacticalQuickWins.lua.
local function AssignTactic(brain)
    if brain.tqwTactic then return end

    local seed = brain.rnd and brain.rnd[4]
    if not seed then
        -- respaldo: brain.id tambien es estable y comun a todos los clientes
        seed = brain.id
    end
    if not seed then return end   -- sin semilla estable no asignamos nada

    local idx = (math_floor(math_abs(seed)) % #TA2.Tactics) + 1
    brain.tqwTactic = TA2.Tactics[idx]
    Log("Tactica asignada (determinista): " .. tostring(brain.tqwTactic))
end

-- Algunas tacticas necesitan un item concreto para funcionar (cuchillo para
-- la traicion, bomba de humo para la emboscada). Se siembra UNA vez, igual
-- que TQW.SeedInventory -- y termina en el cadaver porque
-- Bandit.UpdateItemsToSpawnAtDeath enumera el inventario vivo.
local function SeedTacticItem(zombie, brain)
    if brain.tqwTacticSeeded then return end
    brain.tqwTacticSeeded = true

    -- MULTIJUGADOR: el flag de arriba es local de cada cliente, asi que sin
    -- esta guarda cada jugador le daria su propio cuchillo/bomba de humo.
    if PVCCore.NotWorldAuthority() then return end

    local itemType
    if brain.tqwTactic == "FakeSurrender" then
        itemType = "Base.HuntingKnife"
    elseif brain.tqwTactic == "SmokeAmbush" then
        itemType = "Base.SmokeBomb"
    else
        return
    end

    local inventory = zombie:getInventory()
    if inventory:getFirstTypeRecurse(itemType) then return end

    local ok, item = pcall(BanditCompatibility.InstanceItem, itemType)
    if ok and item then
        inventory:AddItem(item)
        pcall(Bandit.UpdateItemsToSpawnAtDeath, zombie, brain)
        Log("Item de tactica sembrado: " .. itemType)
    end
end

-- #2 -- LA ULTIMA RISA (Evaristo Brea, exclusivo).
-- La bomba se arma con un timestamp y se revisa en Events.OnTick: no puede
-- detonar en el mismo instante de OnZombieDead sin sentirse instantanea, y
-- el brief pide 2-3s de demora despues de la frase final. La lista casi
-- siempre esta vacia (Evaristo muere una vez por vida de personaje), asi
-- que el costo de este handler es, en la practica, un solo "if" por tick.
TA2.PendingBombs = {}

local function TriggerEvaristoExplosion(x, y, z)
    -- MULTIJUGADOR: una sola explosion, la detona el SERVIDOR.
    -- Antes esto salia por PVCCore.NotWorldAuthority(), lo que dejaba "La
    -- Ultima Risa" sin detonar en un servidor dedicado (alli ningun cliente es
    -- autoridad). Ahora se pide al servidor, que deduplica por posicion: aunque
    -- los cuatro clientes que vieron morir a Evaristo pidan la explosion, se
    -- ejecuta una sola. La potencia la fija el servidor (TSS.FxLimits).
    local player = PVCCore.GetCachedPlayer and PVCCore.GetCachedPlayer() or getSpecificPlayer(0)
    PVCCore.RequestFx(player, "Explode", x, y, z)
    Log("La Ultima Risa: explosion pedida en " .. tostring(x) .. "," .. tostring(y))
end

local function OnTick()
    local n = #TA2.PendingBombs
    if n == 0 then return end
    local now = getTimestampMs()
    for i = n, 1, -1 do
        local bomb = TA2.PendingBombs[i]
        if now >= bomb.atMs then
            local ok, err = pcall(TriggerEvaristoExplosion, bomb.x, bomb.y, bomb.z)
            if not ok then LogError("TriggerEvaristoExplosion", err) end
            table_remove(TA2.PendingBombs, i)
        end
    end
end

local function OnEvaristoDead(zombie, brain)
    local ok, err = pcall(zombie.addLineChatElement, zombie, getText(TA2.Config.Evaristo.LineKey), 1, 0.2, 0.05)
    if not ok then LogError("Evaristo ultima linea", err) end

    local x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
    TA2.PendingBombs[#TA2.PendingBombs + 1] = {
        atMs = getTimestampMs() + TA2.Config.Evaristo.ExplodeDelayMs,
        x = x, y = y, z = z,
    }
    Log("La Ultima Risa: bomba armada")
end

-- #3 -- RENDICION FALSA ("El Traicionero")

-- Igual a BanditBrain.IsOutOfAmmo, pero SOLO sobre el arma primaria (el
-- brief pide especificamente "arma primaria vacia", no ambas como hace la
-- funcion nativa Bandit.IsOutOfAmmo).
local function IsPrimaryEmpty(brain)
    local weapons = brain.weapons
    local p = weapons and weapons.primary
    if not p or not p.name then return false end
    if (p.bulletsLeft or 0) > 0 then return false end
    if not p.type then return true end
    if p.type == "mag" then return (p.magCount or 0) <= 0 end
    if p.type == "nomag" then return (p.ammoCount or 0) <= 0 end
    return false
end

local function Feature_FakeSurrender(zombie, brain, id, now, dist2, player, state)
    local cfg = TA2.Config.FakeSurrender
    if not cfg.Enabled then return end
    if brain.tqwSurrenderBroken then return end -- ya jugo su carta, no se repite

    if not brain.tqwSurrendering then
        if not Bandit.IsHostile(zombie) then return end
        local maxHealth = brain.health or 1
        local lowHealth = zombie:getHealth() < maxHealth * cfg.HealthPct
        if not (lowHealth or IsPrimaryEmpty(brain)) then return end

        brain.tqwSurrendering = true
        brain.hostile  = false
        brain.hostileP = false
        Bandit.ClearTasks(zombie)
        zombie:setTarget(nil)
        zombie:clearAggroList()
        SayLine(zombie, getText("UI_BEP_TA2_SurrenderFake"))
        Log("Rendicion falsa: activada (id=" .. tostring(id) .. ")")
        return
    end

    -- "rendido": mantiene la pose (mismo anim "Surrender" que usa el
    -- programa nativo ZombiePrograms.Bandit.Surrender del mod base,
    -- confirmado real en shared/ZombiePrograms/ZPBandit.lua) y espera
    if not Bandit.HasActionTask(zombie) then
        Bandit.AddTask(zombie, {action = "Time", anim = "Surrender", time = 40})
    end

    local r = cfg.BetrayRange
    if dist2 > (r * r) then return end

    brain.tqwSurrendering = false
    brain.tqwSurrenderBroken = true
    brain.hostile  = true
    brain.hostileP = true
    -- "ataque critico instantaneo": no existe una API de instakill
    -- confirmada; lo representamos con el mismo bonus de precision que ya
    -- usa la Furia de Team PVC (TacticalAdvanced.lua/MakeFurious), para
    -- mantener un unico lenguaje de "combate mejorado" en todo el submod.
    brain.accuracyBoost = math_min(8, (brain.accuracyBoost or 0) + cfg.AccuracyBoost)

    Bandit.ClearTasks(zombie)
    local ok, tasks = pcall(BanditPrograms.Weapon.Switch, zombie, "Base.HuntingKnife")
    if ok and tasks then
        for i = 1, #tasks do Bandit.AddTask(zombie, tasks[i]) end
    end
    zombie:setTarget(player)
    SayLine(zombie, getText("UI_BEP_TA2_SurrenderBetray"))
    Log("Rendicion falsa: TRAICION (id=" .. tostring(id) .. ")")
end

-- #4 -- TRAMPA DE HORDA ("El Carnada")
local function IsPlayerEntrenched(player)
    local square = player:getSquare()
    if not square then return false end
    return square:getBuilding() ~= nil or square:getRoom() ~= nil
end

local function Feature_HordeBait(zombie, brain, id, now, dist2, player, state)
    local cfg = TA2.Config.HordeBait
    if not cfg.Enabled then return end
    if not Bandit.IsHostile(zombie) then return end

    local cd = state.taBaitCooldown
    if cd and now < cd then return end

    if dist2 > (cfg.Range * cfg.Range) then return end

    local ok, canSee = pcall(zombie.CanSee, zombie, player)
    if ok and canSee then return end -- lo tiene a la vista, no hace falta la trampa

    if not IsPlayerEntrenched(player) then return end

    state.taBaitCooldown = now + cfg.CooldownMs

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local ok2, err = pcall(addSound, zombie, px, py, pz, cfg.NoiseRadius, cfg.NoiseVolume)
    if not ok2 then LogError("HordeBait addSound", err) end

    SayLine(zombie, getText("UI_BEP_TA2_HordeBaitTaunt"))
    Log("Trampa de horda: ruido en la posicion del jugador (id=" .. tostring(id) .. ")")
end

-- #5 -- SABOTAJE VEHICULAR ("El Ladron de Motores")
-- NOTA (corregido tras un error real en el log): cell:getVehicles():get(i)
-- revienta con "Object tried to call nil" cuando se llama desde el hilo de
-- actualizacion de zombis (IsoZombie.update -> OnZombieUpdate). El propio
-- Bandits2 JAMAS itera esa lista desde su IA de combate -- en
-- shared/BanditUtils.lua (funcion de disparo, corre en este mismo hilo)
-- usa square:getVehicleContainer() recorriendo casillas cercanas, que es el
-- patron que replicamos aca: confirmado real y probado en ese mismo
-- contexto, a diferencia de cell:getVehicles() que solo aparece usado en un
-- comando de cliente (BanditClientCommands.lua, hilo principal).
local function FindNearestVehicle(bx, by, bz, range)
    local cell = getCell()
    if not cell then return nil end

    local z = math_floor(bz)
    local x0, x1 = math_floor(bx - range), math_floor(bx + range)
    local y0, y1 = math_floor(by - range), math_floor(by + range)
    local rangeSq = range * range

    local best, bestDist2
    for x = x0, x1 do
        for y = y0, y1 do
            local dx, dy = x - bx, y - by
            local d2 = dx * dx + dy * dy
            if d2 <= rangeSq and (not bestDist2 or d2 < bestDist2) then
                local square = cell:getGridSquare(x, y, z)
                local vehicle = square and square:getVehicleContainer()
                if vehicle then
                    best, bestDist2 = vehicle, d2
                end
            end
        end
    end
    return best, bestDist2
end

local function Feature_CarSabotage(zombie, brain, id, now, dist2, player, state)
    local cfg = TA2.Config.CarSabotage
    if not cfg.Enabled then return end
    if brain.tqwSaboteurDone then return end
    if not Bandit.IsHostile(zombie) then return end

    local nextCheck = state.taSaboteurNextTick
    if nextCheck and now < nextCheck then return end
    state.taSaboteurNextTick = now + cfg.IntervalMs

    if Bandit.HasActionTask(zombie) then return end

    local bx, by, bz = zombie:getX(), zombie:getY(), zombie:getZ()
    local vehicle, vDist2 = FindNearestVehicle(bx, by, bz, cfg.Range)
    if not vehicle then return end

    local dist = math_sqrt(vDist2)
    if dist > 1.5 then
        local vsquare = getCell():getGridSquare(math_floor(vehicle:getX()), math_floor(vehicle:getY()), bz)
        if not vsquare then return end
        local asquare = AdjacentFreeTileFinder.Find(vsquare, zombie)
        if asquare then
            Bandit.ClearTasks(zombie)
            local d = BanditUtils.DistTo(bx, by, asquare:getX(), asquare:getY())
            Bandit.AddTask(zombie, BanditUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Run", d, false))
        end
        return
    end

    Bandit.ClearTasks(zombie)
    Bandit.AddTask(zombie, {action = "TA2Sabotage", anim = "LootLow", time = 200, vehicleRef = vehicle})
    Log("Sabotaje vehicular: manipulando vehiculo (id=" .. tostring(id) .. ")")
end

-- Accion custom TA2Sabotage, mismo patron onStart/onWorking/onComplete que
-- TQWUseMeds/TAHealAlly. Al terminar, roba la bateria (o vacia el tanque) y
-- reutiliza TacticalAdvanced.MakeFlee (expuesta publicamente para esto) en
-- vez de duplicar la logica de huida.
local function RegisterActions()
    ZombieActions = ZombieActions or {}

    ZombieActions.TA2Sabotage = {}
    ZombieActions.TA2Sabotage.onStart = function(zombie, task)
        return true
    end
    ZombieActions.TA2Sabotage.onWorking = function(zombie, task)
        if task.time <= 0 then return true end
        if zombie:getBumpType() ~= task.anim then
            zombie:setBumpType(task.anim)
        end
        return false
    end
    ZombieActions.TA2Sabotage.onComplete = function(zombie, task)
        local vehicle = task.vehicleRef
        local brain = BanditBrain.Get(zombie)
        -- MULTIJUGADOR: quitar la bateria del vehiculo y metersela al bandido
        -- es una transferencia de objeto real. Si lo hiciera cada cliente,
        -- CADA UNO generaria su propia copia de la bateria: duplicacion de
        -- items, el peor tipo de bug. Solo la autoridad toca el vehiculo.
        if vehicle and brain and not PVCCore.NotWorldAuthority() then
            local inventory = zombie:getInventory()
            local stole = false

            local ok1, battery = pcall(vehicle.getPartById, vehicle, "Battery")
            if ok1 and battery then
                local ok2, batteryItem = pcall(battery.getInventoryItem, battery)
                if ok2 and batteryItem then
                    pcall(battery.setInventoryItem, battery, nil)
                    inventory:AddItem(batteryItem)
                    stole = true
                end
            end

            local ok3, gasTank = pcall(vehicle.getPartById, vehicle, "GasTank")
            if ok3 and gasTank then
                pcall(gasTank.setContainerContentAmount, gasTank, 0)
            end

            if stole then
                pcall(Bandit.UpdateItemsToSpawnAtDeath, zombie, brain)
            end
            brain.tqwSaboteurDone = true

            if type(TacticalAdvanced) == "table" and TacticalAdvanced.MakeFlee then
                local player = type(PVCCore) == "table" and PVCCore.GetCachedPlayer and PVCCore.GetCachedPlayer()
                pcall(TacticalAdvanced.MakeFlee, zombie, brain, player)
            end
        end

        local best = Bandit.GetBestWeapon(zombie)
        if best then Bandit.SetHands(zombie, best) end
        return true
    end
end

-- #6 -- EMBOSCADA DE HUMO ("El Fantasma")
local function TriggerSmoke(zombie, brain, state, now)
    if brain.tqwSmoked then return end

    -- MULTIJUGADOR: consumir la bomba y crear la humareda son cambios de
    -- mundo -> solo la autoridad. El flanqueo posterior si lo calcula cada
    -- cliente (es movimiento, no creacion).
    if PVCCore.NotWorldAuthority() then return end

    local inventory = zombie:getInventory()
    local item = inventory:getFirstTypeRecurse("Base.SmokeBomb")
    if not item then return end

    brain.tqwSmoked = true
    state.taSmokeUntil = now + TA2.Config.SmokeAmbush.DurationMs

    inventory:Remove(item)
    inventory:setDrawDirty(true)

    -- La humareda la crea el SERVIDOR (una sola, deduplicada por posicion).
    -- El consumo de la bomba sigue siendo local de la autoridad: es una
    -- mutacion del inventario del bandido, no un efecto de mundo.
    local square = zombie:getSquare()
    if square then
        local player = PVCCore.GetCachedPlayer and PVCCore.GetCachedPlayer() or getSpecificPlayer(0)
        PVCCore.RequestFx(player, "Smoke", square:getX(), square:getY(), square:getZ())
    end
    Log("Emboscada de humo: activada")
end

local function Feature_SmokeAmbush(zombie, brain, id, now, dist2, player, state)
    local cfg = TA2.Config.SmokeAmbush
    if not cfg.Enabled then return end

    if not brain.tqwSmoked then
        local maxHealth = brain.health or 1
        if zombie:getHealth() < maxHealth * cfg.HealthPct then
            local ok, err = pcall(TriggerSmoke, zombie, brain, state, now)
            if not ok then LogError("TriggerSmoke", err) end
        end
        return
    end

    if now > (state.taSmokeUntil or 0) then
        brain.tqwSmoked = false -- se acabo el humo; puede volver a usarlo si baja de la mitad otra vez
        return
    end

    -- rendimiento: nada de matematica de vectores mas alla de 30 casillas
    if dist2 > cfg.MaxFlankDistSq then return end
    if not Bandit.IsHostile(zombie) then return end

    local nextRepath = state.taSmokeRepathAt
    if nextRepath and now < nextRepath then return end
    state.taSmokeRepathAt = now + cfg.RepathMs

    local ok, fd = pcall(player.getForwardDirection, player)
    if not ok or not fd then return end
    pcall(fd.setLength, fd, cfg.FlankDistance)

    local tx = math_floor(player:getX() - fd:getX())
    local ty = math_floor(player:getY() - fd:getY())

    local cell = getCell()
    local square = cell and cell:getGridSquare(tx, ty, math_floor(player:getZ()))
    if not square then return end

    Bandit.ClearTasks(zombie)
    local d = BanditUtils.DistTo(zombie:getX(), zombie:getY(), tx, ty)
    Bandit.AddTask(zombie, BanditUtils.GetMoveTask(0, square:getX(), square:getY(), square:getZ(), "Run", d, false))
    Log("Emboscada de humo: flanqueando")
end

-- Disparo inmediato al recibir un golpe (ademas del chequeo de vida por
-- tick, mas abajo): asi la mecanica reacciona al instante ante dano real,
-- no solo cuando el HP ya cayo bajo el umbral.
local function OnHitZombie(zombie, brain, id, attacker, bodyPartType, handWeapon)
    local cfg = TA2.Config.SmokeAmbush
    if not cfg.Enabled then return end
    if brain.tqwTactic ~= "SmokeAmbush" then return end
    if brain.tqwSmoked then return end
    if not Bandit.IsHostile(zombie) then return end

    local state = GetState(id)
    local ok, err = pcall(TriggerSmoke, zombie, brain, state, getTimestampMs())
    if not ok then LogError("TriggerSmoke(hit)", err) end
end

local FeatureByTactic = {
    FakeSurrender = Feature_FakeSurrender,
    HordeBait     = Feature_HordeBait,
    CarSabotage   = Feature_CarSabotage,
    SmokeAmbush   = Feature_SmokeAmbush,
}

local function OnZombieUpdate(zombie, brain, id, now, dist2, player)
    if IsTeamPVC(brain) then return end
    if brain.taFleeing then return end -- moral (TacticalAdvanced) ya lo puso a correr; no le pisamos la orden

    AssignTactic(brain)

    local ok, err = pcall(SeedTacticItem, zombie, brain)
    if not ok then LogError("SeedTacticItem", err) end

    local fn = FeatureByTactic[brain.tqwTactic]
    if fn then
        local state = GetState(id)
        local ok2, err2 = pcall(fn, zombie, brain, id, now, dist2, player, state)
        if not ok2 then LogError(brain.tqwTactic, err2) end
    end
end

local function OnZombieDead(zombie, brain, id)
    -- El estado de runtime del bandido muerto no tiene por que sobrevivirle.
    -- (El barrido horario de PVCCore recoge tambien los que se descargan con el
    -- chunk y nunca llegan a este evento.)
    if id then TA2.State[id] = nil end

    if type(TeamPVC) ~= "table" then return end
    if brain.bid ~= TeamPVC.EVARISTO_BID then return end

    local ok, err = pcall(OnEvaristoDead, zombie, brain)
    if not ok then LogError("OnEvaristoDead", err) end
end

local function CheckDependencies()
    local missing = {}

    local required = {
        {"PVCCore",                PVCCore},
        {"Bandit",                 Bandit},
        {"BanditBrain",            BanditBrain},
        {"BanditUtils",            BanditUtils},
        {"BanditPrograms",         BanditPrograms},
        {"BanditCompatibility",    BanditCompatibility},
        {"AdjacentFreeTileFinder", AdjacentFreeTileFinder},
    }
    for i = 1, #required do
        if type(required[i][2]) ~= "table" then
            table_insert(missing, required[i][1])
        end
    end
    if #missing > 0 then return missing end

    local functions = {
        {"Bandit.AddTask",                   Bandit.AddTask},
        {"Bandit.ClearTasks",                Bandit.ClearTasks},
        {"Bandit.HasActionTask",             Bandit.HasActionTask},
        {"Bandit.IsHostile",                 Bandit.IsHostile},
        {"Bandit.GetBestWeapon",             Bandit.GetBestWeapon},
        {"Bandit.SetHands",                  Bandit.SetHands},
        {"Bandit.UpdateItemsToSpawnAtDeath", Bandit.UpdateItemsToSpawnAtDeath},
        {"BanditBrain.Get",                  BanditBrain.Get},
        {"BanditUtils.GetMoveTask",          BanditUtils.GetMoveTask},
        {"BanditUtils.DistTo",               BanditUtils.DistTo},
        {"BanditCompatibility.InstanceItem", BanditCompatibility.InstanceItem},
        {"PVCCore.OnUpdate",                 PVCCore.OnUpdate},
        {"PVCCore.OnHit",                    PVCCore.OnHit},
        {"PVCCore.OnDead",                   PVCCore.OnDead},
    }
    for i = 1, #functions do
        if type(functions[i][2]) ~= "function" then
            table_insert(missing, functions[i][1])
        end
    end

    if type(BanditPrograms.Weapon) ~= "table" or type(BanditPrograms.Weapon.Switch) ~= "function" then
        table_insert(missing, "BanditPrograms.Weapon.Switch")
    end

    return missing
end

local function Bootstrap()
    local missing = CheckDependencies()
    if #missing > 0 then
        print("[TacticalAsymmetric] INACTIVO. Falta: " .. table_concat(missing, ", "))
        return
    end

    local ok, err = pcall(RegisterActions)
    if not ok then
        LogError("RegisterActions", err)
        print("[TacticalAsymmetric] INACTIVO: no se pudieron registrar las acciones.")
        return
    end

    PVCCore.OnUpdate("TacticalAsymmetric", OnZombieUpdate)
    PVCCore.OnHit("TacticalAsymmetric", OnHitZombie)
    PVCCore.OnDead("TacticalAsymmetric", OnZombieDead)

    if type(PVCCore.RegisterIdTable) == "function" then
        PVCCore.RegisterIdTable("TA2.State", TA2.State)
    end

    Events.OnTick.Remove(OnTick)
    Events.OnTick.Add(OnTick)

    print("[TacticalAsymmetric] v" .. TA2.VERSION .. " activo (4 tacticas asimetricas + La Ultima Risa de Evaristo Brea).")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TacticalAsymmetric] INACTIVO por error en el arranque.")
    end
end)
