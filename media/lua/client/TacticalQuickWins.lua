--[[==========================================================================
    TacticalQuickWins.lua
    Sub-mod de expansion para "Bandits" v2 (Slayer) - Build 42
    Paquete Nivel 1 (Quick Wins): 9 mecanicas tacticas.

    ARQUITECTURA
    ------------
    Este archivo NO modifica ni sobrescribe ningun archivo del mod base.
    Se integra por tres vias, todas publicas:

      1) Eventos del motor  : Events.OnZombieUpdate / OnHitZombie / OnZombieDead
                              (los handlers del mod base son `local`, no se
                              pueden -ni se deben- parchear; registrar handlers
                              propios en el mismo evento es aditivo y seguro).
      2) API publica Bandit : Bandit.AddTask / GetTask / ClearTasks / SetHostile
                              / HasExpertise / GetWeapons ... (tabla global).
      3) Acciones propias   : registramos entradas NUEVAS en la tabla global
                              ZombieActions (prefijo "TQW") que el despachador
                              del mod base (ProcessTask) ejecuta sin saber que
                              son nuestras. Nunca pisamos una accion existente.

    NOTA SOBRE BanditBrain.Update
    -----------------------------
    El brief original pedia parchear `BanditBrain.Update`. En Bandits v2 esa
    funcion NO es el tick de IA: es un simple setter de modData

        function BanditBrain.Update(zombie, brain) zombie:getModData().brain = brain end

    y ademas todas sus invocaciones estan comentadas en el codigo del mod
    (el brain se muta por referencia). Parchearla daria un mod inerte.
    El tick real es OnZombieUpdate, que es el que usamos. Aun asi envolvemos
    BanditBrain.Update con un wrapper pcall defensivo (ver InstallBrainGuard)
    porque otros sub-mods si podrian llamarla y un fallo ahi congelaria el tick.

    RENDIMIENTO
    -----------
    - OnZombieUpdate se dispara por cada zombi y por cada frame. Nuestro handler
      sale en 2 comparaciones para zombis normales.
    - Cada bandido tiene un presupuesto: como maximo una pasada cada
      Config.TickIntervalMs (500 ms por defecto), y ademas cada mecanica tiene
      su propio intervalo largo. En la mayoria de frames no se ejecuta nada.
    - Cero asignaciones de tabla en el camino caliente: el estado por bandido se
      crea una vez y se reutiliza; los buffers de escaneo son tablas globales
      reutilizadas (ver TQW.Scratch), nunca literales dentro de bucles.
    - Circuit breaker: si una mecanica lanza error Config.MaxErrors veces, se
      autodesactiva de forma permanente en esa sesion y el resto sigue vivo.

    MULTIJUGADOR
    ------------
    El mod base ejecuta su IA solo en cliente (isServer() -> return) y usa
    getSpecificPlayer(0). Este sub-mod sigue la misma convencion: pensado para
    Single Player / host. En MP dedicado no hace nada danino, simplemente no
    corre en el servidor.
============================================================================]]

if TQW then return end -- guarda anti doble carga

TQW = {}
TQW.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- Locales de motor (resolver globales una vez, no en cada frame)
-- ---------------------------------------------------------------------------
local getTimestampMs   = getTimestampMs
local getSpecificPlayer= getSpecificPlayer
local getGameTime      = getGameTime
local getWorld         = getWorld
local getCell          = getCell
local ZombRand         = ZombRand
local instanceof       = instanceof
local pcall            = pcall
local pairs            = pairs
local math_floor       = math.floor
local math_sqrt        = math.sqrt
local table_insert     = table.insert
local string_format    = string.format

-- ===========================================================================
-- CONFIGURACION
-- ===========================================================================
TQW.Config = {
    Debug            = false,   -- true = imprime trazas en consola
    ShowChat         = true,    -- lineas de texto sobre la cabeza del bandido
    TickIntervalMs   = 500,     -- presupuesto base por bandido
    MaxErrors        = 3,       -- fallos antes de desactivar una mecanica

    -- #21 Auto-administracion de farmacos
    Meds = {
        Enabled       = true,
        HealthPct     = 0.50,   -- se cura por debajo de este % de vida
        HealAmount    = 0.35,   -- vida recuperada (escala 0..~2.6 del mod base)
        IntervalMs    = 3000,
        CooldownMs    = 45000,  -- entre curaciones del mismo bandido
    },

    -- #16 Cambio a arma corta a quemarropa
    Sidearm = {
        Enabled       = true,
        PanicRange    = 8,      -- si el jugador esta mas cerca que esto, no recarga: desenfunda
        IntervalMs    = 700,
        CooldownMs    = 6000,
    },

    -- #13 Linternas nocturnas
    Torch = {
        Enabled       = true,
        DayLightMax   = 0.30,   -- getDayLightStrength() por debajo = de noche
        IntervalMs    = 10000,
    },

    -- #18 Heridas visibles y cojera
    Limp = {
        Enabled       = true,
        LegHitsToLimp = 2,      -- impactos en piernas para quedar cojo
        HealthPct     = 0.55,   -- o vida por debajo de este %
        IntervalMs    = 1000,
    },

    -- #7 El Negociador / Extorsionador
    Negotiator = {
        Enabled           = true,
        Range             = 3,       -- casillas para iniciar la negociacion
        DemandWindowMs    = 10000,   -- 10s de plazo para tirar lo exigido
        ComplianceRadius  = 4,       -- casillas: que tan cerca del bandido debe caer
        ComplianceGraceMs = 180000,  -- 3 min de tregua real si cumple
        CooldownMs        = 300000,  -- 5 min por bandido entre intentos de negociar
        IntervalMs        = 1000,
    },

    -- #6 El Oportunista / Carronero
    Scavenger = {
        Enabled       = true,
        Radius        = 5,      -- casillas de busqueda de cadaveres
        RetreatTiles  = 12,     -- distancia de huida tras saquear
        IntervalMs    = 4000,
        CooldownMs    = 60000,
    },

    -- #8 El Piromaniaco
    Pyro = {
        Enabled       = true,
        CombatMs      = 180000, -- 3 minutos de combate sostenido
        CombatIdleMs  = 30000,  -- sin ver al jugador este tiempo, se resetea
        MinRange      = 4,      -- no se autoinmola
        MaxRange      = 12,
        IntervalMs    = 2000,
        CooldownMs    = 120000,
    },

    -- #26 Peticion de refuerzos por radio
    Radio = {
        Enabled       = true,
        MinCasualties = 2,      -- bajas del clan que disparan la llamada
        DelayMs       = 120000, -- 2 minutos desde la primera baja
        SquadSize     = 3,
        SpawnDistance = 25,     -- casillas: llegan desde lejos, no encima
        ClanCooldownMs= 600000, -- 10 min por clan
        IntervalMs    = 5000,
    },

    -- #28 Recompensas / Bounties + semilla de items
    Loot = {
        Enabled       = true,
        MedsChance    = 45,     -- % de bandidos que llevan farmacos encima
        MolotovChance = 8,      -- % que llevan un molotov
        RadioChance   = 12,     -- % que llevan radio (= "lider" operativo)
        NoteChance    = 18,     -- % que llevan nota de "Se Busca" / lore
    },
}

-- ===========================================================================
-- TABLAS ESTATICAS (creadas una vez al cargar; nunca dentro de un bucle)
-- ===========================================================================

-- Items de curacion aceptados, en orden de preferencia.
TQW.MedItems = {
    "Base.Pills",           -- analgesicos
    "Base.PillsAntiDep",
    "Base.PillsBeta",
    "Base.Antibiotics",
    "Base.Bandage",
    "Base.AlcoholBandage",
}

-- Candidatos de radio (se filtran contra el ScriptManager al cargar).
TQW.RadioItems = {
    "Base.WalkieTalkie5",
    "Base.WalkieTalkie4",
    "Base.WalkieTalkie3",
    "Base.HamRadio1",
    "Base.RadioBlack",
}

-- Candidatos de papel para las notas de "Se Busca".
TQW.NoteItems = {
    "Base.Notebook",
    "Base.SheetPaper2",
    "Base.Journal",
}

TQW.MolotovItem = "Base.Molotov"

-- Partes del cuerpo consideradas "pierna" para la cojera (#18).
TQW.LegParts = {
    ["Foot_R"] = true, ["Foot_L"] = true,
    ["LowerLeg_R"] = true, ["LowerLeg_L"] = true,
    ["UpperLeg_R"] = true, ["UpperLeg_L"] = true,
}

-- Lineas de dialogo. Tablas planas: BanditUtils.Choice las indexa directo.
TQW.Lines = {
    meds      = {"Aguanta... me curo y sigo.", "Solo un momento!", "Maldita sea, esto duele."},
    sidearm   = {"A la mierda, pistola!", "Muy cerca, muy cerca!", "No hay tiempo de recargar!"},
    -- %s = nombre del item exigido (getDisplayName() del item elegido, ver
    -- PickDemandItem en Feature_Negotiator)
    negotiate = {
        "No tienes con que dispararme! Tira %s y vive.",
        "Estas seco, verdad? Entrega %s y te dejo ir.",
        "Ni un paso mas. %s al suelo. Ahora.",
        "Puedo matarte o puedes pagarme con %s. Tu decides.",
    },
    scavenge  = {"Este ya no lo necesita.", "Buen botin...", "Vamos, agarra lo que sirva."},
    pyro      = {"Que arda todo!", "Fuego! FUEGO!", "A ver si te gusta el calor!"},
    radio     = {"Base, aqui equipo uno, tenemos bajas!", "Manden refuerzos, YA!", "Nos estan matando, necesitamos apoyo!"},
}

-- Textos de las notas de "Se Busca" (#28). %s = nombre del bandido.
TQW.NoteTemplates = {
    {
        name = "Cartel: SE BUSCA",
        body = "SE BUSCA - VIVO O MUERTO\n\n%s\n\nBuscado por saqueo del deposito de Rosewood y por la muerte de dos de los nuestros.\n\nRECOMPENSA: 4 cajas de municion y un tanque de gasolina.\nEntregar prueba en el puesto del kilometro 12.\n\n- El Contable",
    },
    {
        name = "Carta sin enviar",
        body = "Mama:\n\nSi lees esto es que alguien me encontro antes que tu.\nNo somos los monstruos que dicen en la radio. Al principio solo queriamos comida.\nDespues de lo de la granja... ya no se que somos.\n\nNo vengas a buscarme.\n\n%s",
    },
    {
        name = "Orden del clan",
        body = "ORDEN PERMANENTE - LEER Y QUEMAR\n\n1. Nadie entra al perimetro sin la contrasena.\n2. Los heridos se quedan atras. Sin excepciones.\n3. Si cae uno, se avisa por radio y se replantea. NO se persigue.\n4. El que abandone su puesto responde ante mi.\n\nFirmado: %s",
    },
    {
        name = "Lista de deudas",
        body = "LO QUE ME DEBEN:\n\n- Vic: 200 balas del .308. Muerto. Cobrado.\n- Marta: la escopeta. Se largo al norte.\n- El nuevo: nada todavia. Tiene buena punteria.\n- %s (yo): un tiro en la rodilla que me dieron por cubrirlos a todos.\n\nNadie paga nunca.",
    },
}

-- ===========================================================================
-- ESTADO INTERNO
-- ===========================================================================
TQW.Enabled     = false   -- lo activa Bootstrap() si el mod base esta completo
TQW.State       = {}      -- [banditId] = tabla de estado reutilizada
TQW.ClanDeaths  = {}      -- [cid] = { count, firstMs, lastCallMs }
TQW.Errors      = {}      -- [featureName] = n? de fallos acumulados
TQW.Disabled    = {}      -- [featureName] = true si el breaker salto

-- ===========================================================================
-- UTILIDADES
-- ===========================================================================
local lastLogMs = 0

local function Log(msg)
    if TQW.Config.Debug then print("[TQW] " .. tostring(msg)) end
end

-- Log de errores con limite de frecuencia: un hook roto no debe inundar el log.
local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastLogMs < 1000 then return end
    lastLogMs = now
    print("[TQW][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function Choice(tab)
    local n = #tab
    if n == 0 then return nil end
    return tab[ZombRand(n) + 1]
end

local function Dist2(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end

-- Texto sobre la cabeza del bandido. addLineChatElement es el metodo NATIVO
-- del motor que el propio mod base usa para sus subtitulos.
-- OJO: Bandit.Say() NO sirve para texto libre: solo acepta claves de
-- Bandit.SoundTab (HIT, RELOADING, ...) que mapean a audio pregrabado.
function TQW.Chat(bandit, text)
    if not TQW.Config.ShowChat or not text then return end
    bandit:addLineChatElement(text, 0.9, 0.55, 0.15)
end

-- Estado por bandido. Se crea UNA vez y se reutiliza durante toda su vida.
local function GetState(id)
    local s = TQW.State[id]
    if not s then
        s = {
            nextTick   = 0,
            next       = {},   -- [feature] = timestamp del proximo chequeo
            cooldown   = {},   -- [feature] = timestamp de fin de enfriamiento
            legHits    = 0,
            limping    = false,
            combatFrom = 0,    -- inicio del combate sostenido (#8)
            combatSeen = 0,    -- ultima vez que vio al jugador
        }
        TQW.State[id] = s
    end
    return s
end

-- Ejecuta una mecanica de forma aislada. Si revienta MaxErrors veces,
-- se desactiva ella sola y las demas siguen funcionando.
local function SafeRun(name, fn, bandit, brain, state, now)
    if TQW.Disabled[name] then return end
    local ok, err = pcall(fn, bandit, brain, state, now)
    if not ok then
        local n = (TQW.Errors[name] or 0) + 1
        TQW.Errors[name] = n
        LogError(name, err)
        if n >= TQW.Config.MaxErrors then
            TQW.Disabled[name] = true
            print("[TQW] Mecanica '" .. name .. "' DESACTIVADA tras " .. n .. " errores.")
        end
    end
end

-- Comprueba intervalo propio de la mecanica.
local function Due(state, key, now, interval)
    local t = state.next[key]
    if t and now < t then return false end
    state.next[key] = now + interval
    return true
end

local function OnCooldown(state, key, now)
    local t = state.cooldown[key]
    return t ~= nil and now < t
end

local function SetCooldown(state, key, now, ms)
    state.cooldown[key] = now + ms
end

-- Primer item existente de una lista, dentro del inventario del bandido.
-- getFirstTypeRecurse acepta el fullType ("Base.Pills") y busca tambien dentro
-- de las mochilas; es la forma que usa el Lua vanilla del juego.
local function FindItem(inventory, list)
    for i = 1, #list do
        local item = inventory:getFirstTypeRecurse(list[i])
        if item then return item, list[i] end
    end
    return nil
end

-- ===========================================================================
-- ACCIONES PERSONALIZADAS
-- Se registran como entradas NUEVAS de ZombieActions. El despachador del mod
-- base (ProcessTask) las ejecuta igual que las suyas. Prefijo TQW para
-- garantizar que jamas colisionan con una accion actual o futura del mod base.
-- ===========================================================================
local function RegisterActions()
    ZombieActions = ZombieActions or {}

    -- ---- Usar farmaco / vendaje (#21) ------------------------------------
    ZombieActions.TQWUseMeds = {}
    ZombieActions.TQWUseMeds.onStart = function(zombie, task)
        -- Item "falso" en la mano solo para la animacion; el real se consume
        -- en onComplete. Es el mismo patron que usa ZATimeItem del mod base.
        if task.item then
            local fake = BanditCompatibility.InstanceItem(task.item)
            if fake then zombie:setPrimaryHandItem(fake) end
        end
        return true
    end
    ZombieActions.TQWUseMeds.onWorking = function(zombie, task)
        if task.time <= 0 then return true end
        if zombie:getBumpType() ~= task.anim then
            zombie:setBumpType(task.anim)
        end
        return false
    end
    ZombieActions.TQWUseMeds.onComplete = function(zombie, task)
        zombie:setPrimaryHandItem(nil)

        -- consumir el item real
        local inventory = zombie:getInventory()
        local item = inventory:getFirstTypeRecurse(task.item)
        if item then
            inventory:Remove(item)
            inventory:setDrawDirty(true)
        end

        -- aplicar la curacion (la escala de vida del mod base llega a ~2.6)
        local brain = BanditBrain.Get(zombie)
        local maxHealth = (brain and brain.health) or 1
        local health = zombie:getHealth() + (task.heal or 0.3)
        if health > maxHealth then health = maxHealth end
        zombie:setHealth(health)

        -- re-sincronizar el loot que soltara al morir
        if brain then Bandit.UpdateItemsToSpawnAtDeath(zombie, brain) end

        -- devolver el arma a la mano
        local best = Bandit.GetBestWeapon(zombie)
        if best then Bandit.SetHands(zombie, best) end
        return true
    end

    -- ---- Saquear un cadaver (#6) -----------------------------------------
    -- La accion LootItems del mod base solo mira contenedores de
    -- square:getObjects(); los cadaveres viven en getStaticMovingObjects(),
    -- por eso necesitamos accion propia en lugar de reutilizar la suya.
    ZombieActions.TQWLootBody = {}
    ZombieActions.TQWLootBody.onStart = function(zombie, task)
        return true
    end
    ZombieActions.TQWLootBody.onWorking = function(zombie, task)
        zombie:faceLocationF(task.x, task.y)
        if task.time <= 0 then return true end
        if zombie:getBumpType() ~= task.anim then
            zombie:setBumpType(task.anim)
        end
        return false
    end
    ZombieActions.TQWLootBody.onComplete = function(zombie, task)
        local square = getCell():getGridSquare(task.x, task.y, task.z)
        if not square then return true end

        local zinv = zombie:getInventory()
        local objects = square:getStaticMovingObjects()
        for i = 0, objects:size() - 1 do
            local object = objects:get(i)
            if instanceof(object, "IsoDeadBody") then
                local container = object:getContainer()
                if container and not container:isEmpty() then
                    local items = container:getItems()
                    -- recorrer hacia atras: vamos removiendo de la misma lista
                    for j = items:size() - 1, 0, -1 do
                        local item = items:get(j)
                        if item then
                            container:Remove(item)
                            container:removeItemOnServer(item)
                            zinv:AddItem(item)
                        end
                    end
                    container:setDrawDirty(true)
                end
            end
        end

        local brain = BanditBrain.Get(zombie)
        if brain then Bandit.UpdateItemsToSpawnAtDeath(zombie, brain) end
        return true
    end

    -- ---- Lanzar molotov (#8) ---------------------------------------------
    ZombieActions.TQWMolotov = {}
    ZombieActions.TQWMolotov.onStart = function(zombie, task)
        local fake = BanditCompatibility.InstanceItem(TQW.MolotovItem)
        if fake then zombie:setPrimaryHandItem(fake) end
        zombie:faceLocationF(task.x, task.y)
        return true
    end
    ZombieActions.TQWMolotov.onWorking = function(zombie, task)
        if task.time <= 0 then return true end
        if zombie:getBumpType() ~= task.anim then
            zombie:setBumpType(task.anim)
        end
        return false
    end
    ZombieActions.TQWMolotov.onComplete = function(zombie, task)
        zombie:setPrimaryHandItem(nil)

        -- consumir el molotov
        local inventory = zombie:getInventory()
        local item = inventory:getFirstTypeRecurse(TQW.MolotovItem)
        if item then
            inventory:Remove(item)
            inventory:setDrawDirty(true)
        end

        -- prender fuego en el destino
        local cell = getCell()
        local square = cell:getGridSquare(task.x, task.y, task.z)
        if square then
            -- Firma tomada del Lua vanilla (ClientCommands.lua / SCampfireSystem):
            --   IsoFireManager.StartFire(cell, square, spread, intensity, fuel)
            -- El pcall la aisla por si cambia en una build futura.
            local ok, err = pcall(IsoFireManager.StartFire, cell, square, true, 60, 300)
            if not ok then LogError("StartFire", err) end
        end

        local best = Bandit.GetBestWeapon(zombie)
        if best then Bandit.SetHands(zombie, best) end
        return true
    end

    -- ---- Llamada de refuerzos por radio (#26) ----------------------------
    ZombieActions.TQWRadioCall = {}
    ZombieActions.TQWRadioCall.onStart = function(zombie, task)
        if task.item then
            local fake = BanditCompatibility.InstanceItem(task.item)
            if fake then zombie:setPrimaryHandItem(fake) end
        end
        return true
    end
    ZombieActions.TQWRadioCall.onWorking = function(zombie, task)
        if task.time <= 0 then return true end
        if zombie:getBumpType() ~= task.anim then
            zombie:setBumpType(task.anim)
        end
        return false
    end
    ZombieActions.TQWRadioCall.onComplete = function(zombie, task)
        zombie:setPrimaryHandItem(nil)

        local player = getSpecificPlayer(0)
        if player and task.cid then
            -- API real de spawn del mod base:
            --   modulo 'Spawner', comando 'Clan'  -> BanditServer.Spawner.Clan
            -- (El comando 'SpawnGroup' que aparece en shared/BanditBases/Scenes
            --  es codigo legacy: no existe handler para el en la v42.20.)
            sendClientCommand(player, 'Spawner', 'Clan', {
                cid     = task.cid,
                size    = task.size,
                program = "Bandit",
                x       = task.sx,
                y       = task.sy,
                z       = task.sz,
            })
        end

        local best = Bandit.GetBestWeapon(zombie)
        if best then Bandit.SetHands(zombie, best) end
        return true
    end
end

-- ===========================================================================
-- SEMILLA DE INVENTARIO (#28 y soporte de #21, #8, #26)
-- ===========================================================================
-- Los bandidos nacen con el inventario VIVO vacio (brain.inventory = {} en
-- BanditServerSpawner); todo su botin se genera al morir. Sin esta semilla,
-- las mecanicas que dependen de llevar objetos encima nunca se dispararian.
-- Lo que sembramos aqui tambien acaba en el cadaver, porque
-- Bandit.UpdateItemsToSpawnAtDeath enumera el inventario vivo.
local function SeedInventory(bandit, brain)
    local cfg = TQW.Config.Loot
    if not cfg.Enabled then return end
    if brain.tqwSeeded then return end
    brain.tqwSeeded = true

    local inventory = bandit:getInventory()
    local added = false

    -- Farmacos: los medicos del clan siempre; el resto por probabilidad.
    local medChance = cfg.MedsChance
    if Bandit.HasExpertise(bandit, Bandit.Expertise.Medic) then medChance = 100 end
    if #TQW.MedItems > 0 and ZombRand(100) < medChance then
        local itemType = Choice(TQW.MedItems)
        local item = BanditCompatibility.InstanceItem(itemType)
        if item then inventory:AddItem(item); added = true end
    end

    if ZombRand(100) < cfg.MolotovChance then
        local item = BanditCompatibility.InstanceItem(TQW.MolotovItem)
        if item then inventory:AddItem(item); added = true end
    end

    if #TQW.RadioItems > 0 and ZombRand(100) < cfg.RadioChance then
        local item = BanditCompatibility.InstanceItem(Choice(TQW.RadioItems))
        if item then inventory:AddItem(item); added = true end
    end

    -- Notas de "Se Busca" / lore
    if #TQW.NoteItems > 0 and ZombRand(100) < cfg.NoteChance then
        local item = BanditCompatibility.InstanceItem(Choice(TQW.NoteItems))
        if item then
            local tpl  = Choice(TQW.NoteTemplates)
            local name = brain.fullname or "un desconocido"
            -- Mismo patron que usa el juego al escribir un cuaderno
            -- (ISInventoryPaneContextMenu.onWriteSomethingClick):
            -- addPage + setName + setCustomName. Si el item elegido no
            -- soportara paginas, el pcall degrada a una nota solo renombrada.
            pcall(item.addPage, item, 1, string_format(tpl.body, name))
            item:setName(tpl.name)
            pcall(item.setCustomName, item, true)
            inventory:AddItem(item)
            added = true
        end
    end

    if added then
        Bandit.UpdateItemsToSpawnAtDeath(bandit, brain)
    end
end

-- ===========================================================================
-- MECANICAS
-- ===========================================================================

--[[ #21 - AUTO-ADMINISTRACION DE FARMACOS -----------------------------------
     El mod base ya encola una tarea "Bandage" cuando corresponde (ManageCombat).
     Esto es la capa complementaria: pastillas/analgesicos con recuperacion de
     vida real, fuera del flujo de vendaje.
--]]
local function Feature_Meds(bandit, brain, state, now)
    local cfg = TQW.Config.Meds
    if not cfg.Enabled then return end
    if not Due(state, "meds", now, cfg.IntervalMs) then return end
    if OnCooldown(state, "meds", now) then return end

    local maxHealth = brain.health or 1
    if bandit:getHealth() > maxHealth * cfg.HealthPct then return end

    -- no interrumpir una accion en curso (disparo, recarga, vendaje...)
    if Bandit.HasActionTask(bandit) then return end

    local item, itemType = FindItem(bandit:getInventory(), TQW.MedItems)
    if not item then return end

    SetCooldown(state, "meds", now, cfg.CooldownMs)

    Bandit.ClearTasks(bandit)
    Bandit.AddTask(bandit, {
        action = "TQWUseMeds",
        -- Los nombres de animacion son un vocabulario cerrado (setBumpType).
        -- "BandageUpperBody" es uno de los que usa ZABandage del mod base.
        anim   = "BandageUpperBody",
        item   = itemType,
        heal   = cfg.HealAmount,
        time   = 250,
        lock   = true,
    })
    TQW.Chat(bandit, Choice(TQW.Lines.meds))
    Log("Meds: usando " .. itemType)
end

--[[ #16 - CAMBIO A ARMA CORTA -----------------------------------------------
     IMPORTANTE: el mod base YA cambia al arma secundaria cuando la primaria se
     queda sin balas (ManageCombat, ~lineas 1028 y 1119). Reimplementarlo seria
     duplicar y pelearse con el.
     Lo que aporta esta capa es el matiz que pedia el brief: a quemarropa el
     bandido NO se queda recargando delante del jugador, desenfunda de
     inmediato. Solo actuamos dentro de PanicRange; fuera de eso mandan las
     reglas del mod base.
--]]
local function Feature_Sidearm(bandit, brain, state, now)
    local cfg = TQW.Config.Sidearm
    if not cfg.Enabled then return end
    if not Due(state, "sidearm", now, cfg.IntervalMs) then return end
    if OnCooldown(state, "sidearm", now) then return end

    local weapons = brain.weapons
    if not weapons or not weapons.primary or not weapons.secondary then return end

    local primary, secondary = weapons.primary, weapons.secondary
    if not primary.name or not secondary.name then return end

    -- primaria seca?
    if primary.bulletsLeft and primary.bulletsLeft > 0 then return end
    -- secundaria con balas en recamara?
    if not secondary.bulletsLeft or secondary.bulletsLeft <= 0 then return end
    -- ya la lleva en la mano?
    if bandit:isPrimaryEquipped(secondary.name) then return end

    local player = getSpecificPlayer(0)
    if not player then return end
    local range = cfg.PanicRange
    if Dist2(bandit:getX(), bandit:getY(), player:getX(), player:getY()) > range * range then return end

    SetCooldown(state, "sidearm", now, cfg.CooldownMs)

    -- Reutilizamos el helper del mod base: genera el par Unequip + Equip con
    -- los sonidos y animaciones correctos para cada arma.
    local tasks = BanditPrograms.Weapon.Switch(bandit, secondary.name)
    if not tasks or #tasks == 0 then return end

    Bandit.ClearTasks(bandit)
    for i = 1, #tasks do
        Bandit.AddTask(bandit, tasks[i])
    end
    TQW.Chat(bandit, Choice(TQW.Lines.sidearm))
    Log("Sidearm: cambio de emergencia a " .. secondary.name)
end

--[[ #13 - LINTERNAS NOCTURNAS -----------------------------------------------
     El mod base ya tiene el sistema completo: SandboxVars.Bandits.General_CarryTorches,
     el flag brain.torch y ManageTorch(), que proyecta el cono de luz cada tick.
     Lo unico que falta es que un bandido que lleva linterna encima y NO nacio
     con brain.torch la encienda al anochecer. Eso es lo que hacemos: activar el
     flag que el motor del mod base ya sabe consumir. No duplicamos ni una linea
     del renderizado de luz.
--]]
local function Feature_Torch(bandit, brain, state, now)
    local cfg = TQW.Config.Torch
    if not cfg.Enabled then return end
    if not Due(state, "torch", now, cfg.IntervalMs) then return end

    -- respetamos el ajuste de sandbox del mod base
    if SandboxVars and SandboxVars.Bandits and not SandboxVars.Bandits.General_CarryTorches then
        return
    end

    local dls = getWorld():getClimateManager():getDayLightStrength()
    local isNight = dls < cfg.DayLightMax

    if not isNight then
        if brain.torch and brain.tqwTorch then
            brain.torch = false
            brain.tqwTorch = false
            bandit:setVariable("BanditTorch", false)
        end
        return
    end

    if brain.torch then return end        -- ya la lleva (nuestra o del mod base)
    if not bandit:isOutside() then return end
    if not bandit:getInventory():getFirstTypeRecurse("Base.HandTorch") then return end

    brain.torch   = true
    brain.tqwTorch= true                  -- marca: la encendimos nosotros
    bandit:setVariable("BanditTorch", true)
    Log("Torch: linterna encendida")
end

--[[ #18 - HERIDAS VISIBLES Y COJERA -----------------------------------------
     Los bandidos son IsoZombie reciclados: NO tienen BodyDamage por miembro,
     asi que no existe "salud de las piernas" que consultar, y setLimping() (que
     es de IsoPlayer) no tendria efecto.
     La palanca correcta es la variable "BanditWalkType": el mod base la lee y
     la aplica con setWalkType() en CADA tick (BanditUpdate ~2058), asi que
     escribir la variable si persiste. Contamos los impactos en piernas via
     OnHitZombie, que si entrega el bodyPartType.
--]]
local function Feature_Limp(bandit, brain, state, now)
    local cfg = TQW.Config.Limp
    if not cfg.Enabled then return end
    if not Due(state, "limp", now, cfg.IntervalMs) then return end

    if not state.limping then
        local maxHealth = brain.health or 1
        if state.legHits < cfg.LegHitsToLimp and
           bandit:getHealth() > maxHealth * cfg.HealthPct then
            return
        end
        state.limping = true
        brain.tqwLimping = true
        Log("Limp: bandido cojeando")
    end

    -- Solo forzamos la cojera cuando no hay un desplazamiento tactico en curso;
    -- durante los movimientos de combate manda GetCombatWalktype del mod base
    -- (que por su cuenta ya devuelve "Limp" con vida < 0.8).
    if not Bandit.HasMoveTask(bandit) then
        bandit:setVariable("BanditWalkType", "Limp")
    end
end

--[[ #7 - EL NEGOCIADOR / EXTORSIONADOR --------------------------------------
     Si el jugador esta desarmado o sin municion y a menos de N casillas, el
     bandido baja el arma, exige un ITEM ESPECIFICO que ve en el inventario
     del jugador (no un generico "entrega el equipo"), y de verdad comprueba
     que lo haya tirado cerca antes de perdonarlo.

     COMPROBACION DE CUMPLIMIENTO: guardamos la referencia AL ITEM EXACTO que
     se exigio (state.tqwDemandItem, ver mas abajo). item:getWorldItem()
     devuelve el IsoWorldInventoryObject que lo envuelve si esta tirado en el
     mundo, o nil si sigue en un contenedor (confirmado contra el patron real
     que usa el juego: "if not alarm:getWorldItem() and (alarm:getContainer()
     ~= playerObj:getInventory())" en ISInventoryPaneContextMenu.lua). Si esta
     tirado Y cerca del bandido, se considera pagado.

     OJO: state.tqwDemandItem es una referencia a un objeto vivo del motor, NO
     un numero/booleano simple -- por eso vive en `state` (nuestra tabla de
     runtime, TQW.State) y NUNCA en `brain` (que el mod base serializa a texto
     plano en cada guardado; meter ahi un objeto solo ensuciaria el save).
--]]
local DEMAND_CATEGORY_PRIORITY = {"Weapon", "Ammo", "FirstAid", "Food"}

-- Recorre el inventario del jugador SOLO al arrancar una negociacion (evento
-- raro, gateado por Due()+CooldownMs): un par de tablas chicas aca no pesan.
local function PickDemandItem(player)
    local inv = player:getInventory()
    if not inv then return nil end
    local items = inv:getItems()
    if not items then return nil end
    local n = items:size()
    if n == 0 then return nil end

    for p = 1, #DEMAND_CATEGORY_PRIORITY do
        local cat = DEMAND_CATEGORY_PRIORITY[p]
        local matches, count = {}, 0
        for i = 0, n - 1 do
            local item = items:get(i)
            if item and not item:isEquipped() and item:getDisplayCategory() == cat then
                count = count + 1
                matches[count] = item
            end
        end
        if count > 0 then return matches[ZombRand(count) + 1] end
    end

    -- nada de las categorias preferidas: cualquier cosa no equipada
    local any, count = {}, 0
    for i = 0, n - 1 do
        local item = items:get(i)
        if item and not item:isEquipped() then
            count = count + 1
            any[count] = item
        end
    end
    if count == 0 then return nil end
    return any[ZombRand(count) + 1]
end

local function IsPlayerHelpless(player)
    local item = player:getPrimaryHandItem()
    if not item then return true end
    if not item:IsWeapon() then return true end

    if item:isRanged() then
        -- arma de fuego: sin balas en recamara = indefenso
        local ammo = item:getCurrentAmmoCount()
        return ammo == nil or ammo <= 0
    end
    return false -- lleva un arma cuerpo a cuerpo: no esta indefenso
end

-- Comprueba si el item exigido esta tirado a menos de radius casillas del
-- bandido. Envuelto en pcall: si el item se destruyo/invalido mientras tanto,
-- getWorldItem() sobre una referencia muerta no debe congelar el juego.
local function CheckDemandComplied(bandit, item, radiusSq)
    local ok, worldItem = pcall(item.getWorldItem, item)
    if not ok or not worldItem then return false end

    local ok2, wx, wy = pcall(function() return worldItem:getX(), worldItem:getY() end)
    if not ok2 then return false end

    local dx, dy = wx - bandit:getX(), wy - bandit:getY()
    return (dx * dx + dy * dy) <= radiusSq
end

local function Feature_Negotiator(bandit, brain, state, now)
    local cfg = TQW.Config.Negotiator
    if not cfg.Enabled then return end

    -- Vencimiento del plazo (se comprueba siempre, sin intervalo)
    if brain.tqwHostileUntil and now >= brain.tqwHostileUntil then
        local complied = false
        if state.tqwDemandItem then
            local ok, result = pcall(CheckDemandComplied, bandit, state.tqwDemandItem,
                                      cfg.ComplianceRadius * cfg.ComplianceRadius)
            complied = ok and result
        end

        if complied then
            -- cumplio: tregua bastante mas larga, no vuelve a atacar de una
            brain.tqwHostileUntil = now + cfg.ComplianceGraceMs
            TQW.Chat(bandit, "Buen trato. No dispares y no disparo.")
            Log("Negotiator: cumplio, tregua extendida")
        else
            brain.hostile  = brain.tqwHostileOld  or false
            brain.hostileP = brain.tqwHostilePOld or false
            brain.tqwHostileUntil = nil
            TQW.Chat(bandit, "No entregaste nada. Se acabo la charla.")
            Log("Negotiator: no cumplio, hostilidad restaurada")
        end

        state.tqwDemandItem = nil
        state.tqwDemandName = nil
    end

    if not Due(state, "negotiator", now, cfg.IntervalMs) then return end
    if OnCooldown(state, "negotiator", now) then return end
    if brain.tqwHostileUntil then return end      -- negociacion en curso
    if not Bandit.IsHostile(bandit) then return end

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    local range = cfg.Range
    if Dist2(bandit:getX(), bandit:getY(), player:getX(), player:getY()) > range * range then return end
    if not bandit:CanSee(player) then return end
    if not IsPlayerHelpless(player) then return end

    local demandItem = PickDemandItem(player)
    if not demandItem then return end   -- no lleva nada que valga la pena exigir

    SetCooldown(state, "negotiator", now, cfg.CooldownMs)

    -- guardamos el estado original para poder devolverlo tal cual
    brain.tqwHostileOld  = brain.hostile
    brain.tqwHostilePOld = brain.hostileP
    brain.hostile  = false
    brain.hostileP = false
    brain.tqwHostileUntil = now + cfg.DemandWindowMs

    state.tqwDemandItem = demandItem
    state.tqwDemandName = demandItem:getDisplayName()

    Bandit.ClearTasks(bandit)
    bandit:setTarget(nil)
    bandit:clearAggroList()
    bandit:faceLocationF(player:getX(), player:getY())

    -- ~300 unidades de tarea equivalen a ~5 s a 60 FPS
    Bandit.AddTask(bandit, {action = "Time", anim = "ShiftWeight", time = 300, lock = true})

    local template = Choice(TQW.Lines.negotiate)
    if template then
        TQW.Chat(bandit, string.format(template, state.tqwDemandName))
    end
    Log("Negotiator: exigiendo " .. state.tqwDemandName)
end

--[[ #6 - EL OPORTUNISTA / CARRONERO -----------------------------------------
     Rol: usamos la especialidad Thief que YA existe en el mod base
     (Bandit.Expertise.Thief), en lugar de inventar un rol paralelo que el
     spawner nunca asignaria.
--]]
local function Feature_Scavenger(bandit, brain, state, now)
    local cfg = TQW.Config.Scavenger
    if not cfg.Enabled then return end
    if not Due(state, "scavenger", now, cfg.IntervalMs) then return end
    if OnCooldown(state, "scavenger", now) then return end

    if not Bandit.HasExpertise(bandit, Bandit.Expertise.Thief) then return end
    if Bandit.HasTask(bandit) then return end          -- solo en IDLE
    if Bandit.IsHostile(bandit) and bandit:getTarget() then return end

    local cell = getCell()
    local bx, by, bz = math_floor(bandit:getX()), math_floor(bandit:getY()), math_floor(bandit:getZ())
    local radius = cfg.Radius

    -- Escaneo sin asignaciones: solo escalares, ninguna tabla intermedia.
    local best, bestDist2
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(bx + dx, by + dy, bz)
            if square and square:getDeadBody() then
                local objects = square:getStaticMovingObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoDeadBody") then
                        local container = object:getContainer()
                        if container and not container:isEmpty() then
                            local d2 = dx * dx + dy * dy
                            if not bestDist2 or d2 < bestDist2 then
                                bestDist2 = d2
                                best = square
                            end
                        end
                    end
                end
            end
        end
    end

    if not best then return end
    SetCooldown(state, "scavenger", now, cfg.CooldownMs)

    local lx, ly, lz = best:getX(), best:getY(), best:getZ()
    local dist = math_sqrt(bestDist2)

    if dist > 1.5 then
        local asquare = AdjacentFreeTileFinder.Find(best, bandit)
        if asquare then
            Bandit.AddTask(bandit, BanditUtils.GetMoveTask(
                0, asquare:getX(), asquare:getY(), asquare:getZ(), "Walk", dist, false))
        end
    end

    Bandit.AddTask(bandit, {
        action = "TQWLootBody", anim = "LootLow", time = 200,
        x = lx, y = ly, z = lz,
    })

    -- ...y abandonar la zona: se retira en direccion contraria al jugador.
    local player = getSpecificPlayer(0)
    if player then
        local px, py = player:getX(), player:getY()
        local vx, vy = lx - px, ly - py
        local len = math_sqrt(vx * vx + vy * vy)
        if len > 0.1 then
            local t = cfg.RetreatTiles
            local rx = math_floor(lx + (vx / len) * t)
            local ry = math_floor(ly + (vy / len) * t)
            if cell:getGridSquare(rx, ry, lz) then
                Bandit.AddTask(bandit, BanditUtils.GetMoveTask(0, rx, ry, lz, "Walk", t, false))
            end
        end
    end

    TQW.Chat(bandit, Choice(TQW.Lines.scavenge))
    Log("Scavenger: saqueando cadaver")
end

--[[ #8 - EL PIROMANIACO -----------------------------------------------------
     Rol: no existe una especialidad "piromano" en el mod base, asi que la
     derivamos de forma DETERMINISTA de brain.rnd (el vector de aleatoriedad
     que el spawner asigna a cada bandido). Asi el mismo bandido es siempre
     piromano entre sesiones, sin tocar el spawner ni el formato del brain.
--]]
local function IsPyro(brain)
    -- brain.rnd = {ZombRand(2), ZombRand(10), ZombRand(100), ...}
    return brain.rnd and brain.rnd[3] ~= nil and (brain.rnd[3] % 5) == 0
end

local function Feature_Pyro(bandit, brain, state, now)
    local cfg = TQW.Config.Pyro
    if not cfg.Enabled then return end
    if not Due(state, "pyro", now, cfg.IntervalMs) then return end

    if not IsPyro(brain) then return end
    if not Bandit.IsHostile(bandit) then return end

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    local d2 = Dist2(bandit:getX(), bandit:getY(), player:getX(), player:getY())
    local inSight = d2 <= (cfg.MaxRange * cfg.MaxRange) and bandit:CanSee(player)

    -- cronometro de combate sostenido
    if inSight then
        if state.combatFrom == 0 then state.combatFrom = now end
        state.combatSeen = now
    elseif state.combatFrom ~= 0 and (now - state.combatSeen) > cfg.CombatIdleMs then
        state.combatFrom = 0   -- perdio el contacto: se reinicia el cronometro
        return
    end

    if state.combatFrom == 0 then return end
    if (now - state.combatFrom) < cfg.CombatMs then return end
    if OnCooldown(state, "pyro", now) then return end
    if not inSight then return end

    -- ni muy lejos ni encima suyo
    if d2 < (cfg.MinRange * cfg.MinRange) then return end
    if not bandit:getInventory():getFirstTypeRecurse(TQW.MolotovItem) then return end
    if Bandit.HasActionTask(bandit) then return end

    SetCooldown(state, "pyro", now, cfg.CooldownMs)

    Bandit.ClearTasks(bandit)
    Bandit.AddTask(bandit, {
        -- No hay animacion de lanzamiento en el set de bandidos; "Shove" es la
        -- que mejor lee como brazo que se extiende hacia adelante.
        action = "TQWMolotov", anim = "Shove", time = 120,
        x = math_floor(player:getX()), y = math_floor(player:getY()), z = player:getZ(),
    })
    TQW.Chat(bandit, Choice(TQW.Lines.pyro))
    Log("Pyro: lanzando molotov")
end

--[[ #26 - PETICION DE REFUERZOS POR RADIO -----------------------------------
     "Lider" = el bandido que lleva la radio (el spawner del mod base no tiene
     concepto de jerarquia, asi que el objeto ES el rol).
     El conteo de bajas por clan lo lleva OnZombieDead mas abajo.
--]]
local function Feature_Radio(bandit, brain, state, now)
    local cfg = TQW.Config.Radio
    if not cfg.Enabled then return end
    if not Due(state, "radio", now, cfg.IntervalMs) then return end

    local cid = brain.cid
    if not cid then return end

    local clan = TQW.ClanDeaths[cid]
    if not clan then return end
    if clan.count < cfg.MinCasualties then return end
    if (now - clan.firstMs) < cfg.DelayMs then return end
    if clan.lastCallMs and (now - clan.lastCallMs) < cfg.ClanCooldownMs then return end
    if Bandit.HasActionTask(bandit) then return end

    local item, itemType = FindItem(bandit:getInventory(), TQW.RadioItems)
    if not item then return end

    local player = getSpecificPlayer(0)
    if not player then return end

    clan.lastCallMs = now
    clan.count = 0                -- el contador se reinicia tras pedir apoyo

    -- Punto de llegada: lejos del jugador, en la direccion del bandido.
    local px, py = player:getX(), player:getY()
    local bx, by, bz = bandit:getX(), bandit:getY(), bandit:getZ()
    local vx, vy = bx - px, by - py
    local len = math_sqrt(vx * vx + vy * vy)
    if len < 0.1 then vx, vy, len = 1, 0, 1 end
    local d = cfg.SpawnDistance

    Bandit.ClearTasks(bandit)
    Bandit.AddTask(bandit, {
        -- "Smoke" lleva la mano a la boca: es lo mas parecido a hablar por radio
        -- dentro del set de animaciones que soporta setBumpType.
        action = "TQWRadioCall", anim = "Smoke", time = 200, item = itemType,
        cid = cid, size = cfg.SquadSize,
        sx = math_floor(bx + (vx / len) * d),
        sy = math_floor(by + (vy / len) * d),
        sz = bz,
    })
    TQW.Chat(bandit, Choice(TQW.Lines.radio))
    Log("Radio: pidiendo refuerzos para el clan " .. tostring(cid))
end

-- ===========================================================================
-- REGISTRO DE MECANICAS (array fijo: se recorre con for numerico, sin iteradores)
-- ===========================================================================
local FEATURES = {
    {name = "Meds",       fn = Feature_Meds},
    {name = "Sidearm",    fn = Feature_Sidearm},
    {name = "Torch",      fn = Feature_Torch},
    {name = "Limp",       fn = Feature_Limp},
    {name = "Negotiator", fn = Feature_Negotiator},
    {name = "Scavenger",  fn = Feature_Scavenger},
    {name = "Pyro",       fn = Feature_Pyro},
    {name = "Radio",      fn = Feature_Radio},
}
local FEATURE_COUNT = #FEATURES

-- ===========================================================================
-- HANDLERS DE EVENTOS
-- ===========================================================================

-- Tick principal. El nucleo compartido (00_TacticalCore) ya hizo el trabajo
-- caro una sola vez para los tres modulos: filtrar que sea bandido, sacar el
-- brain, cachear el jugador y descartar por distancia. Aqui solo queda el
-- presupuesto por bandido y el reparto entre mecanicas.
local function OnZombieUpdate(zombie, brain, id, now, dist2, player)
    if not TQW.Enabled then return end

    local state = TQW.State[id]
    if state and now < state.nextTick then return end            -- presupuesto agotado

    state = GetState(id)
    state.nextTick = now + TQW.Config.TickIntervalMs

    -- semilla de inventario: una sola vez en la vida del bandido
    local ok, err = pcall(SeedInventory, zombie, brain)
    if not ok then LogError("SeedInventory", err) end

    for i = 1, FEATURE_COUNT do
        local f = FEATURES[i]
        SafeRun(f.name, f.fn, zombie, brain, state, now)
    end
end

-- Impactos: contamos disparos en las piernas para la cojera (#18) y cortamos
-- cualquier negociacion en curso (#7) -- dispararle a un extorsionador tiene
-- consecuencias inmediatas.
local function OnHitZombie(zombie, brain, id, attacker, bodyPartType, handWeapon)
    if not TQW.Enabled then return end

    local state = GetState(id)

    -- #18: impacto en pierna
    if bodyPartType and BodyPartType then
        for part in pairs(TQW.LegParts) do
            if BodyPartType[part] == bodyPartType then
                state.legHits = state.legHits + 1
                break
            end
        end
    end

    -- #7: se acabo la charla -- le dispararon en plena negociacion
    if brain.tqwHostileUntil then
        brain.hostile  = brain.tqwHostileOld or false
        brain.hostileP = true   -- le dispararon: la hostilidad hacia el jugador vuelve si o si
        brain.tqwHostileUntil = nil
        state.tqwDemandItem = nil
        state.tqwDemandName = nil
        Log("Negotiator: negociacion rota por disparo")
    end
end

-- Muertes: contabilidad de bajas por clan (#26) y limpieza de estado.
local function OnZombieDead(bandit, brain, id)
    if not TQW.Enabled then return end

    local cid = brain.cid
    if cid then
        local clan = TQW.ClanDeaths[cid]
        local now = getTimestampMs()
        if not clan then
            clan = {count = 0, firstMs = now, lastCallMs = nil}
            TQW.ClanDeaths[cid] = clan
        end
        if clan.count == 0 then clan.firstMs = now end
        clan.count = clan.count + 1
        Log("Clan " .. tostring(cid) .. " bajas: " .. clan.count)
    end

    if id then TQW.State[id] = nil end
end

-- Purga periodica: los bandidos que se descargan con el chunk no disparan
-- OnZombieDead. Cada hora de juego soltamos el estado de los que llevan mucho
-- tiempo sin actualizarse, para que la tabla no crezca sin limite.
local function CleanupState()
    local now = getTimestampMs()
    local state = TQW.State
    for id, s in pairs(state) do
        if (now - s.nextTick) > 600000 then   -- 10 min sin ticks
            state[id] = nil
        end
    end
end

-- ===========================================================================
-- GUARDA DEFENSIVA SOBRE BanditBrain.Update
-- ===========================================================================
-- No es el tick de IA (ver cabecera), pero es global y otros sub-mods pueden
-- llamarla. La envolvemos para que un fallo ahi no propague una excepcion al
-- bucle de zombis del motor, que es lo que congela la partida.
local function InstallBrainGuard()
    if not BanditBrain or type(BanditBrain.Update) ~= "function" then return end
    if BanditBrain.tqwGuarded then return end
    BanditBrain.tqwGuarded = true

    local original = BanditBrain.Update
    BanditBrain.Update = function(zombie, brain)
        local ok, err = pcall(original, zombie, brain)
        if not ok then LogError("BanditBrain.Update", err) end
    end
    Log("Guarda instalada sobre BanditBrain.Update")
end

-- ===========================================================================
-- ARRANQUE
-- ===========================================================================

-- Comprobamos una por una las piezas del mod base que realmente usamos. Si
-- falta cualquiera (mod desactivado, version incompatible, orden de carga mal),
-- el sub-mod se queda dormido en silencio en vez de romper la partida.
local function CheckDependencies()
    local missing = {}

    local required = {
        {"Bandit",                     Bandit},
        {"BanditBrain",                BanditBrain},
        {"BanditUtils",                BanditUtils},
        {"BanditPrograms",             BanditPrograms},
        {"BanditCompatibility",        BanditCompatibility},
        {"ZombieActions",              ZombieActions},
        {"AdjacentFreeTileFinder",     AdjacentFreeTileFinder},
    }
    for i = 1, #required do
        if type(required[i][2]) ~= "table" then
            table_insert(missing, required[i][1])
        end
    end
    if #missing > 0 then return missing end

    local functions = {
        {"Bandit.AddTask",            Bandit.AddTask},
        {"Bandit.ClearTasks",         Bandit.ClearTasks},
        {"Bandit.HasTask",            Bandit.HasTask},
        {"Bandit.HasActionTask",      Bandit.HasActionTask},
        {"Bandit.HasMoveTask",        Bandit.HasMoveTask},
        {"Bandit.HasExpertise",       Bandit.HasExpertise},
        {"Bandit.IsHostile",          Bandit.IsHostile},
        {"Bandit.GetBestWeapon",      Bandit.GetBestWeapon},
        {"Bandit.SetHands",           Bandit.SetHands},
        {"Bandit.UpdateItemsToSpawnAtDeath", Bandit.UpdateItemsToSpawnAtDeath},
        {"BanditBrain.Get",           BanditBrain.Get},
        {"BanditUtils.GetMoveTask",   BanditUtils.GetMoveTask},
        {"BanditCompatibility.InstanceItem", BanditCompatibility.InstanceItem},
    }
    for i = 1, #functions do
        if type(functions[i][2]) ~= "function" then
            table_insert(missing, functions[i][1])
        end
    end

    if type(BanditPrograms.Weapon) ~= "table" or
       type(BanditPrograms.Weapon.Switch) ~= "function" then
        table_insert(missing, "BanditPrograms.Weapon.Switch")
    end
    if type(Bandit.Expertise) ~= "table" or Bandit.Expertise.Thief == nil then
        table_insert(missing, "Bandit.Expertise.Thief")
    end

    return missing
end

-- Deja en las listas de items solo los que existen realmente en esta
-- instalacion (build del juego + mods activos). Asi nunca intentamos
-- instanciar un item inexistente en pleno combate.
-- Usamos el propio instanciador del mod base como prueba de existencia:
-- devuelve nil para un fullType desconocido.
local function ValidateItemLists()
    local lists = {TQW.MedItems, TQW.RadioItems, TQW.NoteItems}
    for l = 1, #lists do
        local list = lists[l]
        local write = 1
        for read = 1, #list do
            local fullType = list[read]
            local ok, item = pcall(BanditCompatibility.InstanceItem, fullType)
            if ok and item then
                list[write] = fullType
                write = write + 1
            else
                Log("Item no disponible, descartado: " .. fullType)
            end
        end
        for i = #list, write, -1 do list[i] = nil end
    end
    Log("Items validos -> meds:" .. #TQW.MedItems ..
        " radios:" .. #TQW.RadioItems ..
        " notas:" .. #TQW.NoteItems)
end

local function Bootstrap()
    local missing = CheckDependencies()
    if #missing > 0 then
        print("[TQW] Sub-mod INACTIVO. Falta el mod base Bandits o su API cambio.")
        print("[TQW] No encontrado: " .. table.concat(missing, ", "))
        print("[TQW] Comprueba que el mod 'Bandits' (id=Bandits2) esta activo y se carga ANTES que este sub-mod.")
        return
    end

    local ok, err = pcall(ValidateItemLists)
    if not ok then LogError("ValidateItemLists", err) end

    ok, err = pcall(RegisterActions)
    if not ok then
        LogError("RegisterActions", err)
        print("[TQW] Sub-mod INACTIVO: no se pudieron registrar las acciones.")
        return
    end

    pcall(InstallBrainGuard)

    if type(PVCCore) ~= "table" or type(PVCCore.OnUpdate) ~= "function" then
        print("[TQW] Sub-mod INACTIVO: falta PVCCore (00_TacticalCore.lua).")
        return
    end

    TQW.Enabled = true

    -- despachador compartido: ver 00_TacticalCore.lua
    PVCCore.OnUpdate("TacticalQuickWins", OnZombieUpdate)
    PVCCore.OnHit("TacticalQuickWins", OnHitZombie)
    PVCCore.OnDead("TacticalQuickWins", OnZombieDead)

    Events.EveryHours.Remove(CleanupState)
    Events.EveryHours.Add(CleanupState)

    print("[TQW] Tactical Quick Wins v" .. TQW.VERSION .. " activo (8 mecanicas + botin de trasfondo).")
end

-- El mod base define su API en archivos shared/, que ya estan cargados cuando
-- se ejecutan los client/. Aun asi arrancamos en OnGameStart para que
-- SandboxVars y el ScriptManager esten disponibles y para tolerar cualquier
-- orden de carga entre mods.
Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TQW] Sub-mod INACTIVO por error en el arranque.")
    end
end)
