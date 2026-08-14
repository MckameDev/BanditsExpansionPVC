--[[==========================================================================
    TeamPVC_Group.lua
    Sub-mod de inyeccion para "Bandits" v2 (Slayer) - Build 42
    Registra el grupo militar de elite ultra-raro "Team PVC" (6 integrantes),
    sus dialogos comicos y un menu de spawn para el modo -debug.

    ---------------------------------------------------------------------------
    TRADUCCION DEL BRIEF A LA API REAL DE BANDITS v2
    ---------------------------------------------------------------------------
    El brief pedia `BanditDefinitions.GroupList`, `BanditSpawner.SpawnGroup()` y
    `bandit:Say()`. Ninguno de los tres existe en Bandits v2 (42.20). Los
    equivalentes reales, verificados en el codigo del mod base, son:

      PEDIDO                        -> REAL
      BanditDefinitions.GroupList   -> BanditCustom.clanData[cid]  (clan)
                                       BanditCustom.banditData[bid] (integrante)
      weight = 1                    -> clan.spawn.spawnChance = 1
      BanditSpawner.SpawnGroup(...) -> sendClientCommand(player, 'Spawner',
                                         'Clan', {cid=..., size=...})
      bandit:Say("texto")           -> bandit:addLineChatElement(texto, r, g, b)
                                       (Bandit.Say solo acepta CLAVES de
                                        Bandit.SoundTab -> audio pregrabado)
      Outfit_ArmyCamo               -> el mod viste por BodyLocation, no por
                                       outfit: clothing.Hat, .Jacket, .Pants...

    Los datos de clan/bandido normalmente se leen de `bandits.txt` y `clans.txt`
    (BanditCustom.Load, en OnGameStart). Aqui inyectamos directamente en las
    tablas Lua ya cargadas: no hace falta distribuir ficheros de texto y no
    tocamos ni un archivo del mod original.

    IMPORTANTE - ORDEN DE CARGA: BanditCustom.Load() vacia banditData y
    clanData. Nuestro OnGameStart se registra DESPUES del suyo (su archivo
    shared/ se carga antes que nuestro client/ porque el mod.info declara
    require=\Bandits2), asi que inyectamos sobre datos ya cargados. Inject()
    es idempotente y el menu de debug la vuelve a llamar por si acaso.
============================================================================]]

if TeamPVC then return end -- guarda anti doble carga
TeamPVC = {}
TeamPVC.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- Locales de motor (resueltos una vez; nada de globales en el camino caliente)
-- ---------------------------------------------------------------------------
local getTimestampMs = getTimestampMs
local ZombRand       = ZombRand
local pcall          = pcall
local pairs          = pairs

-- ---------------------------------------------------------------------------
-- IDENTIFICADORES
-- El cargador de Bandits espera GUIDs y, sobre todo, el cid queda GUARDADO en
-- el brain de cada bandido dentro de la partida. Por eso son constantes fijas:
-- si cambian, los Team PVC ya spawneados se quedan huerfanos.
-- ---------------------------------------------------------------------------
TeamPVC.CLAN_ID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de001"
TeamPVC.MOD_ID  = "BanditsExpansionPVC"

-- ---------------------------------------------------------------------------
-- CONFIGURACION
-- ---------------------------------------------------------------------------
TeamPVC.Config = {
    Debug         = false,

    -- IMPORTANTE: NO usamos el planificador nativo de Bandits (checkEvent) para
    -- el spawn natural, a proposito. Su formula de tamano de grupo es:
    --   groupSize = floor((groupMin + rand) * SandboxVars.Bandits.General_SpawnMultiplier + 0.5)
    -- Con groupMin=groupMax=6 el rand es siempre 0, pero el resultado SIGUE
    -- multiplicandose por General_SpawnMultiplier (slider de sandbox, rango
    -- 0.25 a 4, default 1). Si el jugador lo toca, un clan "de 6" nativo
    -- puede salir incompleto (ej. multiplier=0.5 -> 3 integrantes).
    -- Por eso: (a) el clan se inyecta con spawnChance=0 para que checkEvent()
    -- jamas lo dispare, y (b) implementamos nuestro propio programador
    -- (CheckNaturalSpawn, mas abajo) que respeta la MISMA probabilidad de
    -- disparo (para que el multiplicador siga afectando que TAN SEGUIDO
    -- aparecen), pero llama siempre a SpawnGroup() con size=6 fijo, que no
    -- pasa por esa formula. Resultado: disparen cuando disparen -debug o
    -- natural- siempre son 6.
    SpawnChance   = 1,        -- "1%": misma escala que el clan mas raro del mod base ("Officers")
    DayStart      = 0,        -- disponible desde el dia 0
    DayEnd        = 10000,
    GroupSize     = 6,        -- min = max = 6 -> spawnean los 6, capitan incluido

    -- Icono de llegada en pantalla (el mismo sistema que usa un clan nativo
    -- de Bandits2 al aparecer). SOLO lo dispara spawnType(), el planificador
    -- NATIVO -- nuestro camino de spawn (BanditServer.Spawner.Clan) no pasa
    -- por ahi, asi que lo replicamos a mano. Respeta el mismo sandbox toggle
    -- que usa el mod base para que se sienta igual de "opcional".
    ShowArrivalIcon = true,

    NaturalEnabled= true,     -- false = solo se puede spawnear por el menu debug
    NaturalMinDist= 20,       -- tiles de distancia minima/maxima al jugador
    NaturalMaxDist= 40,       -- para el spawn natural (el del debug es en la casilla elegida)

    BagChance     = 20,       -- % de que un integrante lleve mochila

    -- GRITOS (no "chat"): ver la nota larga en la seccion DIALOGOS mas abajo
    -- sobre por que esto imita al "Q" (Callout) y no al texto tranquilo que
    -- usa TacticalDialogues.lua para reacciones normales de combate.
    ShoutEnabled   = true,
    ShoutCooldownMs= 12000,   -- anti-spam por bandido
    ShoutTickMs    = 1500,    -- presupuesto del chequeo por bandido
    ShoutRange     = 20,      -- solo gritan si el jugador esta a menos de esto
    ShoutSoundRadius = 30,    -- casillas: alcance del RUIDO (puede alertar zombis cercanos)
    ShoutSoundVolume = 6,     -- volumen del ruido, misma escala que usa addSound() en vanilla
}

-- ---------------------------------------------------------------------------
-- ROPA POR BodyLocation
-- Cada clave es un BodyLocation de la lista que usa el mod base
-- (BanditCompatibility.GetBodyLocationsOrdered). Todos los items estan
-- verificados contra media/scripts del juego en B42.
-- ---------------------------------------------------------------------------
local OUTFIT_ARMY_M = {
    Hat                  = "Base.Hat_Army",
    Eyes                 = "Base.Glasses_SafetyGoggles",
    Tshirt               = "Base.Tshirt_CamoGreen",
    Jacket               = "Base.Jacket_ArmyCamoGreen",
    TorsoExtraVestBullet = "Base.Vest_BulletArmy",
    Pants                = "Base.Trousers_CamoGreen",
    Hands                = "Base.Gloves_LeatherGlovesBlack",
    UnderwearBottom      = "Base.Briefs_White",
    Socks                = "Base.Socks_Long_White",
    Shoes                = "Base.Shoes_ArmyBoots",
}

local OUTFIT_ARMY_F = {
    Hat                  = "Base.Hat_Army",
    Eyes                 = "Base.Glasses_SafetyGoggles",
    Tshirt               = "Base.Tshirt_CamoGreen",
    Jacket               = "Base.Jacket_ArmyCamoGreen",
    TorsoExtraVestBullet = "Base.Vest_BulletArmy",
    Pants                = "Base.Trousers_CamoGreen",
    Hands                = "Base.Gloves_LeatherGlovesBlack",
    UnderwearTop         = "Base.Bra_Straps_White",
    UnderwearBottom      = "Base.Underpants_White",
    Socks                = "Base.Socks_Long_White",
    Shoes                = "Base.Shoes_ArmyBoots",
}

local OUTFIT_FIREMAN = {
    Hat             = "Base.Hat_Fireman",
    Tshirt          = "Base.Tshirt_CamoGreen",
    Jacket          = "Base.Jacket_Fireman",
    Pants           = "Base.Trousers_Fireman",
    Hands           = "Base.Gloves_LeatherGlovesBlack",
    UnderwearBottom = "Base.Briefs_White",
    Socks           = "Base.Socks_Long_White",
    Shoes           = "Base.Shoes_Wellies",
}

-- Evaristo: elegante. La boina va en Hat (mismo BodyLocation que un casco).
local OUTFIT_FORMAL = {
    Hat             = "Base.Hat_Beret",
    Shirt           = "Base.Shirt_FormalWhite",
    Neck            = "Base.Tie_Full",
    VestTexture     = "Base.Vest_Waistcoat",
    JacketSuit      = "Base.Suit_Jacket",
    Pants           = "Base.Trousers_Suit",
    UnderwearBottom = "Base.Briefs_White",
    Socks           = "Base.Socks_Ankle_Black",
    Shoes           = "Base.Shoes_Black",
}

-- Mochilas posibles (solo se asigna una al 20%; ver RollBag)
TeamPVC.Bags = {"Base.Bag_ALICEpack", "Base.Bag_DuffelBagTINT"}

-- ---------------------------------------------------------------------------
-- DIALOGOS
-- Pool "aplanado": la frase comica aparece dos veces, asi el peso doble sale
-- gratis con un solo ZombRand y sin construir tablas en tiempo de ejecucion.
-- ---------------------------------------------------------------------------
TeamPVC.Phrases = {
    "Este es el TeamPVC!",
    "Viva PVC y viva Chile!",
    "*Sonidos en chileno*",
    "*Sonidos en chileno*",   -- peso doble, a proposito
}

-- Presentacion: UNA frase propia por integrante, con su nombre, indexada por
-- el mismo GUID que TeamPVC.MemberNames. Se usa una sola vez -- la primera
-- vez que cada bandido grita (ver brain.pvcIntroduced en ShoutRandom) -- y
-- despues pasan al pool generico de arriba como cualquier otro grito.
TeamPVC.MemberIntroLines = {
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"] = "Soy el Capitan Mauricio Murillo y esta es tu ultima advertencia!",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de102"] = "Nealcito Murillo, con hacha y todo, para servirte el auxilio!",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de103"] = "Khris Heartz, la ley acaba de llegar al barrio!",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"] = "Nep Tune al mando, ni se te ocurra correr!",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"] = "Evaristo Wazy, con todo respeto, esto se va a poner feo!",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de106"] = "Gaston Cath reportandose, ya valiste!",
}

-- ===========================================================================
-- UTILIDADES
-- ===========================================================================
local lastErrorMs = 0

local function Log(msg)
    if TeamPVC.Config.Debug then print("[TeamPVC] " .. tostring(msg)) end
end

local function LogError(where, err)
    local now = getTimestampMs()
    if now - lastErrorMs < 2000 then return end
    lastErrorMs = now
    print("[TeamPVC][ERROR] " .. tostring(where) .. ": " .. tostring(err))
end

local function Choice(tab)
    local n = #tab
    if n == 0 then return nil end
    return tab[ZombRand(n) + 1]
end

-- Copia superficial: cada integrante necesita SU tabla de ropa, porque el mod
-- base guarda la referencia en el brain y la persiste en el savegame.
local function CopyTable(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

-- ===========================================================================
-- NOMBRES REALES -> DNI de cada integrante
-- ---------------------------------------------------------------------------
-- ADVERTENCIA IMPORTANTE sobre como el mod base maneja los nombres:
--
--   brain.fullname = args.fullname or BanditNames.GenerateName(female)
--                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
-- (server/BanditServerSpawner.lua:418). El campo `general: name` que
-- escribimos en common/bandits/bandits.txt NUNCA se lee para esto -- solo se
-- usa como etiqueta interna del editor de clanes del mod base
-- (BanditCustom.lua). Si no hacemos nada mas, TODOS los Team PVC reciben un
-- nombre aleatorio ("Liam Smith", etc.) en vez de "Capitan Mauricio Murillo".
--
-- Lo que SI sobrevive el spawn es brain.bid = general.bid (el GUID de
-- bandits.txt), asi que lo usamos como clave para corregir el nombre en el
-- primer tick de cada bandido (ver FixIdentity mas abajo).
--
-- Esto es lo que efectivamente arma el DNI: Bandit.UpdateItemsToSpawnAtDeath
-- llama a BanditCompatibility.AddId(zombie, brain.fullname), que crea un
-- Base.IDcard (o IDcard_Female) llamado "ID Card: <nombre>" como botin de
-- muerte -- automatico e INCONDICIONAL para los 6, en cuanto brain.fullname
-- es el correcto. No llevan chapas de identidad puestas (se quitaron: al ser
-- un item referenciado por tipo en `clothing:`, no una instancia propia, el
-- motor no permite grabarles el nombre -- solo el DNI puede llevarlo).
-- ===========================================================================
TeamPVC.MemberNames = {
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"] = "Capitan Mauricio Murillo",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de102"] = "Nealcito Murillo",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de103"] = "Khris Heartz",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"] = "Nep Tune",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"] = "Evaristo Wazy",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de106"] = "Gaston Cath",
}

-- ===========================================================================
-- DEFINICION DE LOS 6 INTEGRANTES
-- ---------------------------------------------------------------------------
-- Campos `general` (los mismos que usa bandits.txt):
--   health / strength / endurance / sight : escala 1..9 (el mod los interpola)
--   exp1..exp3 : especialidades de Bandit.Expertise (0 = ninguna)
-- Campos `ammo`: NUMERO DE CAJAS de municion, no un item. BanditWeapons.Make
-- deduce cargador, calibre y balas a partir del arma.
-- ===========================================================================
local function BuildMembers()
    local m = {}

    -- 1. Capitan Mauricio Murillo -- lider
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Capitan Mauricio Murillo",
            female = false, skin = 2, hairType = 8, beardType = 4, hairColor = 2,
            health = 9, strength = 8, endurance = 8, sight = 9,
            exp1 = Bandit.Expertise.Recon,   -- ojo de halcon + se mueve rapido
            exp2 = Bandit.Expertise.Assasin,
            exp3 = 0,
        },
        clothing = CopyTable(OUTFIT_ARMY_M),
        tint = {},
        -- "VarmintRifle o AssaultRifle": se decide al inyectar (ver nota en TIPS)
        weapons = {primary = Choice({"Base.VarmintRifle", "Base.AssaultRifle"}),
                   secondary = "Base.Pistol",
                   melee = "Base.HuntingKnife"},
        ammo    = {primary = 6, secondary = 4},
        bag     = {name = "Base.Bag_ALICEpack"},
    }

    -- 2. Nealcito Murillo -- bombero
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de102"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Nealcito Murillo",
            female = false, skin = 1, hairType = 5, beardType = 1, hairColor = 1,
            health = 8, strength = 9, endurance = 8, sight = 6,
            exp1 = Bandit.Expertise.Breaker, exp2 = 0, exp3 = 0,
        },
        clothing = CopyTable(OUTFIT_FIREMAN),
        tint = {},
        weapons = {melee = "Base.Axe"},   -- hacha de bombero
        ammo    = {},
        bag     = {name = "Base.Bag_DuffelBagTINT"},
    }

    -- 3. Khris Heartz -- hombre, con sombrero de sheriff oficial
    -- El uniforme es el militar masculino, pero le cambiamos el casco por el
    -- sombrero de sheriff vanilla (Base.Hat_Sheriff, BodyLocation base:hat ->
    -- misma clave "Hat", asi que sustituye al casco en vez de sumarse).
    local khrisOutfit = CopyTable(OUTFIT_ARMY_M)
    khrisOutfit.Hat = "Base.Hat_Sheriff"

    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de103"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Khris Heartz",
            -- hairType 8 = CrewCut en Bandit.maleHairStyles (el 36 anterior era
            -- un indice pensado para la lista femenina, que es distinta)
            female = false, skin = 1, hairType = 8, beardType = 1, hairColor = 3,
            health = 8, strength = 7, endurance = 8, sight = 9,
            exp1 = Bandit.Expertise.Medic, exp2 = 0, exp3 = 0,
        },
        clothing = khrisOutfit,
        tint = {},
        weapons = {primary = "Base.AssaultRifle", melee = "Base.HuntingKnife"},
        ammo    = {primary = 6},
        bag     = {name = "Base.Bag_ALICEpack"},
    }

    -- 4. Nep Tune
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Nep Tune",
            female = true, skin = 3, hairType = 30, beardType = 1, hairColor = 1,
            health = 8, strength = 7, endurance = 8, sight = 8,
            exp1 = Bandit.Expertise.Tracker, exp2 = 0, exp3 = 0,
        },
        clothing = CopyTable(OUTFIT_ARMY_F),
        tint = {},
        weapons = {},   -- se rellena abajo: M9 o JS-2000
        ammo    = {},
        bag     = {name = "Base.Bag_DuffelBagTINT"},
    }
    -- "Base.Pistol (M9) o Base.Shotgun (JS-2000)". La escopeta es arma
    -- primaria y la pistola secundaria: el mod base separa ambos slots.
    if ZombRand(2) == 0 then
        m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"].weapons.secondary = "Base.Pistol"
        m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"].ammo.secondary = 5
    else
        m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"].weapons.primary = "Base.Shotgun"
        m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"].ammo.primary = 4
    end
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"].weapons.melee = "Base.HuntingKnife"

    -- 5. Evaristo Wazy -- el refinado
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Evaristo Wazy",
            female = false, skin = 2, hairType = 27, beardType = 8, hairColor = 1,
            health = 8, strength = 8, endurance = 7, sight = 8,
            exp1 = Bandit.Expertise.Thief, exp2 = 0, exp3 = 0,
        },
        clothing = CopyTable(OUTFIT_FORMAL),
        tint = {},
        weapons = {melee = "Base.Machete"},
        ammo    = {},
        bag     = {name = "Base.Bag_DuffelBagTINT"},
    }

    -- 6. Gaston Cath
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de106"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Gaston Cath",
            female = false, skin = 4, hairType = 24, beardType = 3, hairColor = 4,
            health = 8, strength = 8, endurance = 8, sight = 7,
            exp1 = Bandit.Expertise.Repairman, exp2 = 0, exp3 = 0,
        },
        clothing = CopyTable(OUTFIT_ARMY_M),
        tint = {},
        weapons = {primary = "Base.Shotgun", melee = "Base.HandAxe"},
        ammo    = {primary = 4},
        bag     = {name = "Base.Bag_ALICEpack"},
    }

    return m
end

-- ===========================================================================
-- INYECCION EN LAS TABLAS DEL MOD BASE
-- ===========================================================================
TeamPVC.Injected = false

function TeamPVC.Inject(quiet)
    -- nil checks estrictos: si el mod base no esta, no hacemos nada
    if type(BanditCustom) ~= "table" then
        print("[TeamPVC] INACTIVO: BanditCustom no existe (mod Bandits desactivado?).")
        return false
    end
    if type(BanditCustom.clanData) ~= "table" or type(BanditCustom.banditData) ~= "table" then
        print("[TeamPVC] INACTIVO: BanditCustom.clanData/banditData no disponibles.")
        return false
    end
    if type(Bandit) ~= "table" or type(Bandit.Expertise) ~= "table" then
        print("[TeamPVC] INACTIVO: la tabla Bandit.Expertise no existe.")
        return false
    end

    local cfg = TeamPVC.Config

    -- --- CLAN ---------------------------------------------------------------
    -- Estructura identica a la de clans.txt. `spawn` es lo que lee
    -- checkEvent()/spawnType() del planificador NATIVO... salvo spawnChance,
    -- que dejamos en 0 a proposito (ver el comentario largo en TeamPVC.Config
    -- sobre por que el planificador nativo no garantiza 6/6). groupMin/groupMax
    -- se dejan en 6 solo por documentacion / compatibilidad con spawnGroup(),
    -- que SI seguimos usando (via nuestro propio CheckNaturalSpawn).
    BanditCustom.clanData[TeamPVC.CLAN_ID] = {
        general = {name = "TeamPVC_Elite"},
        spawn = {
            friendly    = false,   -- hostiles al jugador
            companion   = false,
            defenders   = false,
            campers     = false,
            assault     = true,    -- programa "Bandit": van a por ti
            wanderer    = false,
            roadblock   = false,
            dayStart    = cfg.DayStart,
            dayEnd      = cfg.DayEnd,
            spawnChance = 0,        -- SIEMPRE 0: ver nota arriba, el nativo no es size-safe
            groupMin    = cfg.GroupSize,
            groupMax    = cfg.GroupSize,
            zone        = 0,
        },
    }

    -- --- INTEGRANTES --------------------------------------------------------
    local members = BuildMembers()
    local count = 0
    for bid, data in pairs(members) do
        BanditCustom.banditData[bid] = data
        count = count + 1
    end

    TeamPVC.Injected = true
    if not quiet then
        print("[TeamPVC] Clan 'TeamPVC_Elite' inyectado con " .. count ..
              " integrantes (spawnChance=" .. tostring(cfg.SpawnChance) .. ").")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- RE-INYECCION AUTOMATICA
-- ---------------------------------------------------------------------------
-- El flag TeamPVC.Injected NO basta como garantia: BanditCustom.Load() hace
--     BanditCustom.banditData = {} ; BanditCustom.clanData = {}
-- y se ejecuta varias veces por partida. En single player, el mod base la
-- llama desde Events.OnServerStarted (BanditServerCustom.lua), que corre
-- DESPUES de nuestro OnGameStart: nuestra inyeccion queda borrada y
-- spawnGroup() aborta con "if not clan then return end" -> no spawnea nada.
--
-- EnsureInjected comprueba la realidad (que el clan siga en la tabla) en vez
-- de fiarse del flag, y reinyecta si hace falta.
function TeamPVC.EnsureInjected()
    if type(BanditCustom) ~= "table" or type(BanditCustom.clanData) ~= "table" then
        return false
    end
    if BanditCustom.clanData[TeamPVC.CLAN_ID] then return true end
    -- se perdio: reinyectamos en silencio
    return TeamPVC.Inject(true)
end

-- Envolvemos BanditCustom.Load para reinyectar en cuanto termine, sea quien
-- sea quien la llame (OnGameStart, OnServerStarted, el editor del mod base...).
-- El original se ejecuta SIEMPRE, pase lo que pase con lo nuestro.
local function InstallLoadHook()
    if type(BanditCustom) ~= "table" or type(BanditCustom.Load) ~= "function" then
        print("[TeamPVC] AVISO: no se encontro BanditCustom.Load; la reinyeccion")
        print("[TeamPVC]        automatica queda desactivada.")
        return
    end
    if BanditCustom.pvcLoadHook then return end   -- idempotente
    BanditCustom.pvcLoadHook = true

    local original = BanditCustom.Load
    BanditCustom.Load = function(...)
        local ok, err = pcall(original, ...)
        if not ok then LogError("BanditCustom.Load", err) end

        local ok2, err2 = pcall(TeamPVC.Inject, true)
        if not ok2 then LogError("re-Inject tras Load", err2) end
    end
    Log("Hook de reinyeccion instalado sobre BanditCustom.Load")
end

-- ===========================================================================
-- MOCHILAS: 20% SI / 80% NO, POR BANDIDO Y POR SPAWN
-- ---------------------------------------------------------------------------
-- El perfil del integrante lleva mochila fija, porque el spawner la lee tal
-- cual. La tirada real se hace aqui: envolvemos Bandit.ApplyVisuals, que es
-- global y se ejecuta en el primer tick del bandido ANTES de vestirlo, asi que
-- podemos quitarle la mochila a tiempo (visual + botin al morir).
-- El wrapper llama SIEMPRE al original, incluso si nuestra logica falla.
-- ===========================================================================
local function RollBag(brain)
    if brain.pvcBagRolled then return end
    brain.pvcBagRolled = true

    if ZombRand(100) < TeamPVC.Config.BagChance then
        -- se queda con mochila; variamos el modelo
        brain.bag = {name = Choice(TeamPVC.Bags)}
    else
        brain.bag = nil   -- 80%: sin nada a la espalda
    end
end

local function InstallBagHook()
    if type(Bandit) ~= "table" or type(Bandit.ApplyVisuals) ~= "function" then
        print("[TeamPVC] AVISO: Bandit.ApplyVisuals no encontrado; las mochilas")
        print("[TeamPVC]        quedaran fijas segun el perfil de cada integrante.")
        return
    end
    if Bandit.pvcBagHook then return end   -- idempotente
    Bandit.pvcBagHook = true

    local original = Bandit.ApplyVisuals
    Bandit.ApplyVisuals = function(bandit, brain)
        if brain and brain.cid == TeamPVC.CLAN_ID then
            local ok, err = pcall(RollBag, brain)
            if not ok then LogError("RollBag", err) end
        end
        -- el original SIEMPRE se ejecuta, pase lo que pase con lo nuestro
        local ok, err = pcall(original, bandit, brain)
        if not ok then LogError("Bandit.ApplyVisuals", err) end
    end
    Log("Hook de mochilas instalado sobre Bandit.ApplyVisuals")
end

-- ===========================================================================
-- GRITOS ("Q" / Shout) -- NO chat de fondo
-- ---------------------------------------------------------------------------
-- Pediste que esto se sienta como cuando el JUGADOR aprieta Q (keybind
-- "Shout"), no como el murmullo de fondo que ya generan otros bandidos via
-- TacticalDialogues.lua. Verificado en el Lua del propio juego:
--
--   Q -> ISDPadWheels.onShout() -> playerObj:Callout()
--
-- `Callout()` es un metodo del motor SIN parametros: elige al azar una de
-- tres frases FIJAS ("Hey!"/"Over here!"/"Hey you!", definidas en
-- IG_UI.json) y no acepta texto propio. Osea que no existe forma de
-- reproducir "Callout()" literal con nuestras frases chilenas -- el motor no
-- lo permite. Lo que SI podemos (y debemos) copiar es la SUSTANCIA de un
-- grito, que Callout() tiene y nuestro texto anterior no tenia:
--
--   1) Texto en MAYUSCULAS: el propio juego usa este truco para distinguir
--      un grito de un dialogo tranquilo (compara en IG_UI.json
--      "IGUI_PlayerText_Callout1"="Hey!" contra la variante
--      "...Callout1New"="HEY!", la que se usa para el grito real).
--   2) RUIDO en el mundo: gritar no es silencioso, alerta a los zombis
--      cercanos. Usamos el mismo `addSound(personaje, x, y, z, radio,
--      volumen)` global que usa TODO el juego vanilla para esto (cavar,
--      barricar, romper cosas -- ver shared/TimedActions/*.lua). Antes
--      nuestras frases eran solo texto decorativo; ahora tienen el mismo
--      peso de gameplay que un grito real (puede atraer zombis).
--
-- El texto en si se sigue mostrando con addLineChatElement porque es el
-- UNICO metodo del motor que acepta texto propio sobre la cabeza de un
-- personaje (confirmado: no aparece ni una vez en el Lua vanilla del juego,
-- solo lo usa el propio Bandit.Say() del mod base para sus subtitulos -- no
-- tiene relacion con la ventana de chat multijugador de ISChat.lua).
-- ===========================================================================
TeamPVC.ShoutCooldown = {}   -- [brain.id] = timestamp
TeamPVC.ShoutNextTick = {}   -- [brain.id] = timestamp

-- Dice `text` respetando el cooldown anti-spam. Devuelve true solo si
-- realmente se dijo (false si el cooldown la trago) -- lo necesitamos para no
-- marcar la presentacion como "ya usada" si nunca llego a salir de la boca.
local function SpeakLine(bandit, id, now, text)
    local cd = TeamPVC.ShoutCooldown[id]
    if cd and now < cd then return false end

    local cfg = TeamPVC.Config

    -- 1) texto -- mayusculas, mismo truco que usa el juego para "grito" vs "habla"
    bandit:addLineChatElement(string.upper(text), 1, 0.85, 0.1)

    -- 2) ruido real en el mundo -- esto es lo que hace que sea un GRITO y no
    -- un cartel flotante; aislado en pcall porque toca el sistema de sonido
    -- del motor y no debe congelar el juego si algo cambia en una build futura
    local ok, err = pcall(addSound, bandit, bandit:getX(), bandit:getY(), bandit:getZ(),
                           cfg.ShoutSoundRadius, cfg.ShoutSoundVolume)
    if not ok then LogError("addSound", err) end

    TeamPVC.ShoutCooldown[id] = now + cfg.ShoutCooldownMs
    return true
end

-- La PRIMERA vez que un bandido grita, usa su linea de presentacion propia
-- (TeamPVC.MemberIntroLines) en vez del pool generico. brain.pvcIntroduced
-- solo se marca si SpeakLine confirma que la dijo -- si el cooldown la
-- bloqueo, se reintenta en el proximo grito en vez de perderse para siempre.
local function ShoutRandom(bandit, brain, id, now)
    local isIntro = not brain.pvcIntroduced
    local text = isIntro and TeamPVC.MemberIntroLines[brain.bid] or nil
    text = text or Choice(TeamPVC.Phrases)
    if not text then return end

    if SpeakLine(bandit, id, now, text) and isIntro then
        brain.pvcIntroduced = true
    end
end

-- ---------------------------------------------------------------------------
-- IDENTIDAD: corrige el nombre real (ver TeamPVC.MemberNames mas arriba) y
-- regenera el DNI de muerte con ese nombre. Se ejecuta UNA sola vez por
-- bandido (brain.pvcNameFixed), en el primer tick tras el spawn.
-- ---------------------------------------------------------------------------
local function FixIdentity(zombie, brain)
    brain.pvcNameFixed = true

    local realName = TeamPVC.MemberNames[brain.bid]
    if not realName then return end   -- bid desconocido: no tocamos nada

    brain.fullname = realName

    -- Bandit.ApplyVisuals ya llamo a UpdateItemsToSpawnAtDeath durante el
    -- spawn con el nombre aleatorio original; hay que rehacerlo con el
    -- nombre correcto para que el DNI (Base.IDcard) diga lo que corresponde.
    if type(Bandit) == "table" and type(Bandit.UpdateItemsToSpawnAtDeath) == "function" then
        Bandit.UpdateItemsToSpawnAtDeath(zombie, brain)
    end

    Log("Identidad corregida: " .. realName)
end

-- El nucleo ya filtro bandido + brain + id + distancia al jugador, y nos pasa
-- dist2 ya calculado: aqui solo queda la logica propia de Team PVC.
local function OnZombieUpdate(zombie, brain, id, now, dist2, player)
    if brain.cid ~= TeamPVC.CLAN_ID then return end

    if not brain.pvcNameFixed then
        local ok, err = pcall(FixIdentity, zombie, brain)
        if not ok then LogError("FixIdentity", err) end
    end

    if not TeamPVC.Config.ShoutEnabled then return end

    local nextTick = TeamPVC.ShoutNextTick[id]
    if nextTick and now < nextTick then return end
    TeamPVC.ShoutNextTick[id] = now + TeamPVC.Config.ShoutTickMs

    -- solo gritan en combate (hostiles) y con el jugador cerca
    if not Bandit.IsHostile(zombie) then return end
    if player:isDead() then return end

    local r = TeamPVC.Config.ShoutRange
    if dist2 > (r * r) then return end

    ShoutRandom(zombie, brain, id, now)
end

-- Al recibir dano sueltan frase con mas ganas (saltandose el intervalo, pero
-- nunca el cooldown anti-spam).
local function OnHitZombie(zombie, brain, id, attacker, bodyPartType, handWeapon)
    if not TeamPVC.Config.ShoutEnabled then return end
    if brain.cid ~= TeamPVC.CLAN_ID then return end
    if zombie:isDead() then return end

    ShoutRandom(zombie, brain, id, getTimestampMs())
end

local function OnZombieDead(zombie, brain, id)
    if id then
        TeamPVC.ShoutCooldown[id] = nil
        TeamPVC.ShoutNextTick[id] = nil
    end
end

-- ===========================================================================
-- ICONO DE LLEGADA (replica getIconDataByProgram + el aviso de
-- BanditEventMarkerHandler que server/BanditServerSpawner.lua dispara SOLO
-- desde spawnType(), el planificador nativo -- inalcanzable desde aca por
-- ser `local`). Los valores (media/ui/raid.png, radio, duracion) son los
-- mismos que usa el mod base para clanes "Bandit" hostiles.
-- ===========================================================================
local function ShowArrivalMarker(square)
    if not TeamPVC.Config.ShowArrivalIcon then return end
    if not (SandboxVars.Bandits and SandboxVars.Bandits.General_ArrivalIcon) then return end
    if type(BanditEventMarkerHandler) ~= "table" or type(BanditEventMarkerHandler.set) ~= "function" then
        return
    end

    local ok, err = pcall(BanditEventMarkerHandler.set,
        getRandomUUID(),
        "media/ui/raid.png",
        1800,                              -- misma duracion que usa el mod base
        square:getX(), square:getY(),
        {r = 1, g = 0.5, b = 0.5},         -- rojo: hostil, igual que un clan Bandit normal
        "Hostile Team PVC")
    if not ok then LogError("ShowArrivalMarker", err) end
end

-- ===========================================================================
-- SPAWN
-- ===========================================================================
-- Equivalente real de BanditSpawner.SpawnGroup(): un comando de cliente que
-- atiende BanditServer.Spawner.Clan (funciona igual en SP, donde el lua de
-- server/ corre en el mismo proceso).
function TeamPVC.SpawnGroup(square)
    local player = getSpecificPlayer(0)
    if not player then return false end

    -- Comprobamos la REALIDAD (que el clan siga en las tablas del mod base),
    -- no el flag: si BanditCustom.Load() lo borro, aqui se reinyecta solo.
    -- Sin esto, spawnGroup() del mod base aborta en "if not clan then return"
    -- y no aparece absolutamente nada, sin ningun error.
    if not TeamPVC.EnsureInjected() then
        print("[TeamPVC] No se pudo inyectar el clan; spawn cancelado.")
        return false
    end

    square = square or player:getSquare()
    if not square then
        print("[TeamPVC] No hay casilla valida para spawnear.")
        return false
    end

    sendClientCommand(player, 'Spawner', 'Clan', {
        cid     = TeamPVC.CLAN_ID,
        size    = TeamPVC.Config.GroupSize,
        program = "Bandit",       -- IA de asalto
        x       = square:getX(),
        y       = square:getY(),
        z       = square:getZ(),
    })

    local ok, err = pcall(ShowArrivalMarker, square)
    if not ok then LogError("ShowArrivalMarker", err) end

    print("[TeamPVC] Solicitado spawn de " .. TeamPVC.Config.GroupSize ..
          " integrantes en " .. square:getX() .. "," .. square:getY() .. "," .. square:getZ())
    return true
end

-- ===========================================================================
-- SPAWN NATURAL PROPIO (reemplaza a checkEvent() del mod base)
-- ---------------------------------------------------------------------------
-- Misma cadencia que el planificador nativo (Events.EveryTenMinutes) y la
-- misma formula de probabilidad de DISPARO (spawnChance * SpawnMultiplier / 6),
-- para que el slider de sandbox del jugador siga controlando que tan seguido
-- aparecen. Lo unico que cambiamos es que, al disparar, llamamos a
-- SpawnGroup() con size=6 fijo -- nunca pasa por la formula de TAMANO nativa.
-- ===========================================================================

-- Punto de aparicion a distancia del jugador (no literalmente encima). No es
-- tan sofisticado como generateSpawnPointUniform del mod base (esa funcion es
-- local a su archivo server/ y no es alcanzable desde aqui); si la casilla
-- elegida no existe (chunk no cargado), caemos en la casilla del jugador, que
-- por definicion siempre es valida.
local function PickNaturalSquare(player)
    local cfg = TeamPVC.Config
    local dist = cfg.NaturalMinDist + ZombRand(cfg.NaturalMaxDist - cfg.NaturalMinDist)
    local angle = ZombRandFloat(0, 2 * math.pi)
    local x = math.floor(player:getX() + math.cos(angle) * dist)
    local y = math.floor(player:getY() + math.sin(angle) * dist)
    local z = player:getZ()

    local square = getCell():getGridSquare(x, y, z)
    if square then return square end
    return player:getSquare()
end

local function CheckNaturalSpawn()
    local cfg = TeamPVC.Config
    if not cfg.NaturalEnabled then return end
    if isClient() then return end   -- igual que el planificador nativo: solo decide el host/servidor
    -- (SpawnGroup ya llama a EnsureInjected, asi que no hace falta comprobarlo aqui)

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    local day = getGameTime():getWorldAgeHours() / 24
    if day < cfg.DayStart or day > cfg.DayEnd then return end

    local multiplier = (SandboxVars.Bandits and SandboxVars.Bandits.General_SpawnMultiplier) or 1
    local chance = cfg.SpawnChance * multiplier / 6
    if ZombRandFloat(0, 100) >= chance then return end

    local square = PickNaturalSquare(player)
    print("[TeamPVC] Spawn natural disparado (dia " .. string.format("%.1f", day) .. ").")
    TeamPVC.SpawnGroup(square)
end

-- ===========================================================================
-- MENU DE DEBUG
-- ===========================================================================
local function OnSpawnHere(worldobjects, square)
    local ok, err = pcall(TeamPVC.SpawnGroup, square)
    if not ok then LogError("SpawnGroup", err) end
end

local function OnSpawnAtPlayer(worldobjects)
    local ok, err = pcall(TeamPVC.SpawnGroup, nil)
    if not ok then LogError("SpawnGroup", err) end
end

local function OnReinject(worldobjects)
    local ok, err = pcall(TeamPVC.Inject)
    if not ok then LogError("Inject", err) end
end

-- Diagnostico: vuelca a consola el estado real de cada eslabon de la cadena
-- (inyeccion -> datos del clan -> integrantes -> bandidos vivos en el mundo).
-- Sirve para saber EN QUE PASO se rompe el spawn, en vez de adivinar.
function TeamPVC.Diagnose()
    print("========== DIAGNOSTICO TEAM PVC ==========")
    print("Inyectado (flag)      : " .. tostring(TeamPVC.Injected))
    print("PVCCore presente      : " .. tostring(type(PVCCore) == "table" and PVCCore.Ready))

    if type(BanditCustom) ~= "table" then
        print("BanditCustom          : NO EXISTE -> el mod Bandits no esta cargado")
        print("==========================================")
        return
    end

    local clan = BanditCustom.clanData and BanditCustom.clanData[TeamPVC.CLAN_ID]
    print("Clan en clanData      : " .. tostring(clan ~= nil))
    print("Hook de reinyeccion   : " .. tostring(BanditCustom.pvcLoadHook == true))
    if clan and clan.spawn then
        print("  groupMin/Max        : " .. tostring(clan.spawn.groupMin) .. "/" .. tostring(clan.spawn.groupMax))
        print("  friendly            : " .. tostring(clan.spawn.friendly))
    end

    -- integrantes registrados con nuestro cid
    local members = 0
    if BanditCustom.banditData then
        for _, data in pairs(BanditCustom.banditData) do
            if data.general and data.general.cid == TeamPVC.CLAN_ID then
                members = members + 1
            end
        end
    end
    print("Integrantes con cid   : " .. members .. " (esperado 6)")

    -- bandidos Team PVC realmente vivos en el mundo, y si ya tienen el
    -- nombre real corregido (ver FixIdentity / TeamPVC.MemberNames)
    local alive, banditsTotal, named = 0, 0, 0
    if type(BanditZombie) == "table" and BanditZombie.GetAllB then
        local all = BanditZombie.GetAllB()
        if all then
            for _, light in pairs(all) do
                banditsTotal = banditsTotal + 1
                if light.brain and light.brain.cid == TeamPVC.CLAN_ID then
                    alive = alive + 1
                    local expected = TeamPVC.MemberNames[light.brain.bid]
                    local tag = "?"
                    if expected then
                        tag = (light.brain.fullname == expected) and "OK" or "PENDIENTE"
                        if light.brain.fullname == expected then named = named + 1 end
                    end
                    print("    - " .. tostring(light.brain.fullname) .. "  [" .. tag .. "]")
                end
            end
        end
    end
    print("Bandidos en el mundo  : " .. banditsTotal .. " (de cualquier clan)")
    print("  de ellos Team PVC   : " .. alive .. " (con nombre correcto: " .. named .. ")")

    -- API de spawn del mod base
    print("BanditServer.Spawner  : " ..
          tostring(type(BanditServer) == "table" and type(BanditServer.Spawner) == "table"))
    print("==========================================")
end

local function OnDiagnose(worldobjects)
    local ok, err = pcall(TeamPVC.Diagnose)
    if not ok then LogError("Diagnose", err) end
end

local function OnFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    -- Solo en modo -debug, tal y como pide el brief.
    if not isDebugEnabled or not isDebugEnabled() then return end
    if not context then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    -- casilla bajo el cursor (si el click fue sobre un objeto del mundo)
    local square
    if worldobjects then
        for i = 1, #worldobjects do
            local o = worldobjects[i]
            if o and o.getSquare then
                square = o:getSquare()
                if square then break end
            end
        end
    end

    local parent  = context:addOption("[DEBUG] Team PVC", worldobjects, nil)
    local subMenu = context:getNew(context)
    context:addSubMenu(parent, subMenu)

    subMenu:addOption("Spawn Team PVC (Elite)", worldobjects, OnSpawnAtPlayer)
    if square then
        subMenu:addOption("Spawn Team PVC aqui (casilla)", worldobjects, OnSpawnHere, square)
    end
    subMenu:addOption("Re-inyectar definicion del clan", worldobjects, OnReinject)
    subMenu:addOption("Diagnostico (ver consola)", worldobjects, OnDiagnose)
end

-- ===========================================================================
-- ARRANQUE
-- ===========================================================================
local function Bootstrap()
    if not TeamPVC.Inject() then return end

    -- Debe instalarse SIEMPRE: es lo que sobrevive al BanditCustom.Load() que
    -- el mod base ejecuta en OnServerStarted, despues de este arranque.
    InstallLoadHook()

    InstallBagHook()

    if TeamPVC.Config.ShoutEnabled then
        if type(PVCCore) == "table" and type(PVCCore.OnUpdate) == "function" then
            -- despachador compartido: ver 00_TacticalCore.lua
            PVCCore.OnUpdate("TeamPVC", OnZombieUpdate)
            PVCCore.OnHit("TeamPVC", OnHitZombie)
            PVCCore.OnDead("TeamPVC", OnZombieDead)
        else
            print("[TeamPVC] AVISO: falta PVCCore (00_TacticalCore.lua); gritos desactivados.")
        end
    end

    if TeamPVC.Config.NaturalEnabled then
        Events.EveryTenMinutes.Remove(CheckNaturalSpawn)
        Events.EveryTenMinutes.Add(CheckNaturalSpawn)
    end

    print("[TeamPVC] v" .. TeamPVC.VERSION .. " listo. Menu de debug disponible con -debug.")
end

Events.OnGameStart.Add(function()
    local ok, err = pcall(Bootstrap)
    if not ok then
        LogError("Bootstrap", err)
        print("[TeamPVC] INACTIVO por error en el arranque.")
    end
end)

-- El menu contextual se registra siempre: se autocomprueba isDebugEnabled()
-- en cada apertura, asi que no depende de que el arranque haya ido bien.
Events.OnFillWorldObjectContextMenu.Add(OnFillWorldObjectContextMenu)
