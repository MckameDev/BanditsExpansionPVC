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

local getTimestampMs = getTimestampMs
local ZombRand       = ZombRand
local pcall          = pcall
local pairs          = pairs

-- El cargador de Bandits espera GUIDs y, sobre todo, el cid queda GUARDADO en
-- el brain de cada bandido dentro de la partida. Por eso son constantes fijas:
-- si cambian, los Team PVC ya spawneados se quedan huerfanos.
TeamPVC.CLAN_ID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de001"
TeamPVC.MOD_ID  = "BanditsExpansionPVC"

-- El Capitan: TacticalAdvanced.lua lo usa para saber cuando NO tratar la
-- muerte de un integrante de Team PVC como "cayo el lider" generico, sino
-- como el disparador especifico de furia (ver OnSquadmateDeath alla).
TeamPVC.CAPTAIN_BID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"

-- El Chispa (Sprint 2): 7mo integrante, SOLO 20% de probabilidad de venir en
-- el grupo. A proposito NO esta en common/bandits.txt (el archivo que carga
-- el mod base siempre, sin excepcion): si estuviera ahi, GetFromClan(cid)
-- devolveria 7 candidatos permanentes y spawnGroup() elegiria 6-de-7 AL AZAR
-- cada vez -- rompiendo la garantia de "los 6 fijos siempre entran" que ya
-- construimos. En cambio, su perfil se inyecta en BanditCustom.banditData
-- SOLO en el momento del spawn, condicionado al 20% (o forzado al 100% desde
-- el menu debug), y se retira si no toco esta vez. Ver TeamPVC.SpawnGroup.
TeamPVC.CHISPA_BID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de107"

-- Evaristo Brea: TacticalAsymmetric.lua lo usa para filtrar OnZombieDead y
-- disparar "La Ultima Risa" solo en el, nunca en el resto del clan.
TeamPVC.EVARISTO_BID = "9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"

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

    -- El Chispa (Sprint 2): 20% de aparecer como 7mo integrante.
    Chispa = {
        Enabled      = true,
        SpawnChance  = 20,      -- % (0-100)
        SightRange   = 20,      -- casillas: a partir de aca empieza a "verte" para arrancar la mecha
        FuseMs       = 60000,   -- 60s desde que te ve hasta que tira el molotov
    },

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

-- Cada clave es un BodyLocation de la lista que usa el mod base
-- (BanditCompatibility.GetBodyLocationsOrdered). Todos los items estan
-- verificados contra media/scripts del juego en B42.
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

-- El Chispa: mismo uniforme militar que el resto del equipo (reutiliza items
-- ya verificados en vez de arriesgar uno nuevo sin confirmar), sin chapa/hat
-- particular -- lo distinto de el es la mecanica, no el vestuario.
local OUTFIT_CHISPA = {
    Hat                  = "Base.Hat_Army",
    Eyes                 = "Base.Glasses_SafetyGoggles",
    Tshirt               = "Base.Tshirt_CamoGreen",
    Jacket               = "Base.Jacket_ArmyCamoGreen",
    Pants                = "Base.Trousers_CamoGreen",
    Hands                = "Base.Gloves_LeatherGlovesBlack",
    UnderwearBottom      = "Base.Briefs_White",
    Socks                = "Base.Socks_Long_White",
    Shoes                = "Base.Shoes_ArmyBoots",
}

-- Lineas de la cuenta regresiva de El Chispa (la de presentacion va en
-- TeamPVC.MemberIntroLines, junto a la de los otros 6, mas abajo).
-- Guardan CLAVES de traduccion (ver Translate/EN|ES/BanditsExpansionPVC.json),
-- resueltas con getText() en cada punto de uso.
TeamPVC.ChispaLines = {
    warn60  = "UI_BEP_PVC_ChispaWarn60",
    warn30  = "UI_BEP_PVC_ChispaWarn30",
    warn10  = "UI_BEP_PVC_ChispaWarn10",
    warn5   = "UI_BEP_PVC_ChispaWarn5",
    boom    = "UI_BEP_PVC_ChispaBoom",
}

-- Pool "aplanado": la frase comica aparece dos veces, asi el peso doble sale
-- gratis con un solo ZombRand y sin construir tablas en tiempo de ejecucion.
TeamPVC.Phrases = {
    "UI_BEP_PVC_Phrase1",
    "UI_BEP_PVC_Phrase2",
    "UI_BEP_PVC_Phrase3",
    "UI_BEP_PVC_Phrase3",   -- peso doble, a proposito
}

-- Presentacion: UNA frase propia por integrante, con su nombre, indexada por
-- el mismo GUID que TeamPVC.MemberNames. Se usa una sola vez -- la primera
-- vez que cada bandido grita (ver brain.pvcIntroduced en ShoutRandom) -- y
-- despues pasan al pool generico de arriba como cualquier otro grito.
TeamPVC.MemberIntroLines = {
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"] = "UI_BEP_PVC_IntroMauricio",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de102"] = "UI_BEP_PVC_IntroNealcito",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de103"] = "UI_BEP_PVC_IntroKhris",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"] = "UI_BEP_PVC_IntroNep",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"] = "UI_BEP_PVC_IntroEvaristo",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de106"] = "UI_BEP_PVC_IntroGaston",
    [TeamPVC.CHISPA_BID]                     = "UI_BEP_PVC_IntroChispa",
}

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
TeamPVC.MemberNames = {
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de101"] = "Capitan Mauricio Murillo",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de102"] = "Nealcito Murillo",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de103"] = "Khris Heartz",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de104"] = "Nep Tune",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"] = "Evaristo Brea",
    ["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de106"] = "Gaston Cath",
    [TeamPVC.CHISPA_BID]                     = "El Chispa",
}

-- Campos `general` (los mismos que usa bandits.txt):
--   health / strength / endurance / sight : escala 1..9 (el mod los interpola)
--   exp1..exp3 : especialidades de Bandit.Expertise (0 = ninguna)
-- Campos `ammo`: NUMERO DE CAJAS de municion, no un item. BanditWeapons.Make
-- deduce cargador, calibre y balas a partir del arma.
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

    -- 5. Evaristo Brea -- el refinado
    m["9f1c7a20-b9c0-4e11-9a3d-7ea55c0de105"] = {
        general = {
            modid = TeamPVC.MOD_ID, cid = TeamPVC.CLAN_ID,
            name = "Evaristo Brea",
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

-- El Chispa (Sprint 2). Perfil separado de BuildMembers() a proposito: no es
-- parte del roster fijo, se construye solo cuando toca inyectarlo (ver nota
-- larga junto a TeamPVC.CHISPA_BID, mas arriba).
-- No lleva arma de fuego -- su "arma" es el molotov que carga en el
-- inventario (FixIdentity/OnZombieUpdate se lo da en el primer tick) y el
-- machete es solo respaldo por si lo enganchan cuerpo a cuerpo antes de la
-- cuenta regresiva.
-- El perfil en si vive en PVCShared.BuildChispaData (shared/), porque quien lo
-- inyecta al spawnear es el servidor.

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

-- Mochilas: 20% si / 80% no, por bandido y por spawn. El perfil del
-- integrante lleva mochila fija, porque el spawner la lee tal cual; la
-- tirada real se hace aqui: envolvemos Bandit.ApplyVisuals, que es global y
-- se ejecuta en el primer tick del bandido ANTES de vestirlo, asi que
-- podemos quitarle la mochila a tiempo (visual + botin al morir). El
-- wrapper llama SIEMPRE al original, incluso si nuestra logica falla.
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

-- GRITOS ("Q" / Shout) -- NO chat de fondo.
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
TeamPVC.ShoutCooldown = {}   -- [brain.id] = timestamp
TeamPVC.ShoutNextTick = {}   -- [brain.id] = timestamp

-- NOTA: hubo un intento de un colaborador (PR de ElWazy) de reemplazar el
-- ruido mundial por bandit:getEmitter():playSound("BanditShout"). Lo dejamos
-- afuera a proposito: "BanditShout" no es un sonido que este definido en
-- ningun script de este mod ni del base (no hay forma de confirmar que
-- suene), y ademas playSound() en el emitter NO dispara el sistema de ruido
-- que alerta zombis -- que es precisamente lo que hace que esto sea un GRITO
-- (como el "Q" del jugador) y no un simple cartel de texto flotante. Si en
-- algun momento se agrega ese sonido al mod, avisen y lo reincorporamos.
-- Nivel bajo: texto + ruido, SIN cooldown. Lo usan tanto SpeakLine (que le
-- agrega el cooldown anti-spam para los gritos "de sabor") como la cuenta
-- regresiva de El Chispa (que NO debe usar ese cooldown compartido: si un
-- aviso cayera justo despues de otro grito, se marcaria como "ya dicho" y se
-- perderia en silencio -- inaceptable para avisos con hora exacta).
local function SayNow(bandit, text)
    local cfg = TeamPVC.Config

    -- 1) texto -- mayusculas, mismo truco que usa el juego para "grito" vs "habla"
    bandit:addLineChatElement(string.upper(text), 1, 0.85, 0.1)

    -- 2) ruido real en el mundo -- esto es lo que hace que sea un GRITO y no
    -- un cartel flotante; aislado en pcall porque toca el sistema de sonido
    -- del motor y no debe congelar el juego si algo cambia en una build futura
    local ok, err = pcall(addSound, bandit, bandit:getX(), bandit:getY(), bandit:getZ(),
                           cfg.ShoutSoundRadius, cfg.ShoutSoundVolume)
    if not ok then LogError("addSound", err) end
end

local function SpeakLine(bandit, id, now, text)
    local cd = TeamPVC.ShoutCooldown[id]
    if cd and now < cd then return false end

    SayNow(bandit, text)
    TeamPVC.ShoutCooldown[id] = now + TeamPVC.Config.ShoutCooldownMs
    return true
end

-- La PRIMERA vez que un bandido grita, usa su linea de presentacion propia
-- (TeamPVC.MemberIntroLines) en vez del pool generico. brain.pvcIntroduced
-- solo se marca si SpeakLine confirma que la dijo -- si el cooldown la
-- bloqueo, se reintenta en el proximo grito en vez de perderse para siempre.
local function ShoutRandom(bandit, brain, id, now)
    local isIntro = not brain.pvcIntroduced
    local key = isIntro and TeamPVC.MemberIntroLines[brain.bid] or nil
    key = key or Choice(TeamPVC.Phrases)
    if not key then return end

    if SpeakLine(bandit, id, now, getText(key)) and isIntro then
        brain.pvcIntroduced = true
    end
end

-- IDENTIDAD: corrige el nombre real (ver TeamPVC.MemberNames mas arriba) y
-- regenera el DNI de muerte con ese nombre. Se ejecuta UNA sola vez por
-- bandido (brain.pvcNameFixed), en el primer tick tras el spawn.
local function FixIdentity(zombie, brain)
    brain.pvcNameFixed = true

    local realName = TeamPVC.MemberNames[brain.bid]
    if not realName then return end   -- bid desconocido: no tocamos nada

    brain.fullname = realName

    -- El Chispa necesita su molotov GARANTIZADO (no es cuestion de suerte
    -- como en el resto del mod: sin el, su cuenta regresiva no tiene con que
    -- terminar). Se lo damos aca, en el mismo tick unico de "recien spawneo".
    -- MULTIJUGADOR: el nombre (brain.fullname, arriba) SI se corrige en cada
    -- cliente a proposito -- es cosmetico y cada jugador debe verlo bien.
    -- El molotov NO: es un objeto real y brain.pvcNameFixed es local de cada
    -- cliente, asi que sin la guarda El Chispa acabaria con un molotov por
    -- jugador conectado. Lo entrega solo la autoridad.
    if brain.bid == TeamPVC.CHISPA_BID and not PVCCore.NotWorldAuthority() then
        local ok, item = pcall(BanditCompatibility.InstanceItem, "Base.Molotov")
        if ok and item then
            zombie:getInventory():AddItem(item)
        else
            LogError("Molotov de El Chispa", item)
        end
    end

    -- Bandit.ApplyVisuals ya llamo a UpdateItemsToSpawnAtDeath durante el
    -- spawn con el nombre aleatorio original; hay que rehacerlo con el
    -- nombre correcto para que el DNI (Base.IDcard) diga lo que corresponde.
    -- De paso, esto tambien registra el molotov recien agregado como botin
    -- de muerte (UpdateItemsToSpawnAtDeath escanea el inventario en vivo).
    if type(Bandit) == "table" and type(Bandit.UpdateItemsToSpawnAtDeath) == "function" then
        Bandit.UpdateItemsToSpawnAtDeath(zombie, brain)
    end

    Log("Identidad corregida: " .. realName)
end

-- EL CHISPA -- cuenta regresiva (maquina de estados por temporizador).
-- Estado por bandido en una tabla propia (no en `brain`: son timestamps y
-- flags de una secuencia de combate puntual, no algo que tenga sentido
-- persistir en el save -- mismo criterio que TQW.State en TacticalQuickWins).
TeamPVC.ChispaState = {}   -- [id] = {startMs, w60, w30, w10, w5, done}

local function GetChispaState(id)
    local s = TeamPVC.ChispaState[id]
    if not s then
        s = {startMs = nil, w60 = false, w30 = false, w10 = false, w5 = false, done = false}
        TeamPVC.ChispaState[id] = s
    end
    return s
end

local function Feature_Chispa(zombie, brain, id, now, dist2, player)
    if brain.bid ~= TeamPVC.CHISPA_BID then return end
    local cfg = TeamPVC.Config.Chispa
    if not cfg.Enabled then return end

    local cs = GetChispaState(id)
    if cs.done then return end

    if not cs.startMs then
        -- todavia no arranco la mecha: espera a que sea hostil y lo vea
        if not Bandit.IsHostile(zombie) then return end
        local r = cfg.SightRange
        if dist2 > (r * r) then return end
        if not zombie:CanSee(player) then return end

        cs.startMs = now
        Log("El Chispa: mecha encendida")
        -- sigue de largo: el primer aviso (w60) se dispara YA, mas abajo,
        -- porque remaining = FuseMs - 0 = FuseMs siempre cumple "<= 60000"
    end

    local remaining = cfg.FuseMs - (now - cs.startMs)

    if remaining <= 0 then
        cs.done = true
        SayNow(zombie, getText(TeamPVC.ChispaLines.boom))

        -- reutiliza la accion TQWMolotov ya construida en TacticalQuickWins.lua
        -- (feature #8, El Piromaniaco) en vez de duplicar logica de lanzamiento.
        if type(ZombieActions) == "table" and type(ZombieActions.TQWMolotov) == "table" then
            Bandit.ClearTasks(zombie)
            Bandit.AddTask(zombie, {
                action = "TQWMolotov", anim = "Shove", time = 120,
                x = math.floor(player:getX()), y = math.floor(player:getY()), z = player:getZ(),
            })
        else
            LogError("Feature_Chispa", "ZombieActions.TQWMolotov no disponible (TacticalQuickWins.lua no cargo?)")
        end
        return
    end

    -- cada aviso se dice UNA sola vez, en orden descendente. SayNow (sin
    -- cooldown): un aviso con hora exacta no puede perderse por spam ajeno.
    if not cs.w60 and remaining <= 60000 then
        cs.w60 = true
        SayNow(zombie, getText(TeamPVC.ChispaLines.warn60))
    elseif not cs.w30 and remaining <= 30000 then
        cs.w30 = true
        SayNow(zombie, getText(TeamPVC.ChispaLines.warn30))
    elseif not cs.w10 and remaining <= 10000 then
        cs.w10 = true
        SayNow(zombie, getText(TeamPVC.ChispaLines.warn10))
    elseif not cs.w5 and remaining <= 5000 then
        cs.w5 = true
        SayNow(zombie, getText(TeamPVC.ChispaLines.warn5))
    end
end

-- El nucleo ya filtro bandido + brain + id + distancia al jugador, y nos pasa
-- dist2 ya calculado: aqui solo queda la logica propia de Team PVC.
local function OnZombieUpdate(zombie, brain, id, now, dist2, player)
    if brain.cid ~= TeamPVC.CLAN_ID then return end

    if not brain.pvcNameFixed then
        local ok, err = pcall(FixIdentity, zombie, brain)
        if not ok then LogError("FixIdentity", err) end
    end

    -- La cuenta regresiva de El Chispa NO depende de ShoutEnabled: es una
    -- mecanica de juego, no decoracion de chat.
    local ok2, err2 = pcall(Feature_Chispa, zombie, brain, id, now, dist2, player)
    if not ok2 then LogError("Feature_Chispa", err2) end

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
        TeamPVC.ChispaState[id]   = nil
    end
end

-- Icono de llegada (replica getIconDataByProgram + el aviso de
-- BanditEventMarkerHandler que server/BanditServerSpawner.lua dispara SOLO
-- desde spawnType(), el planificador nativo -- inalcanzable desde aca por
-- ser `local`). Los valores (media/ui/raid.png, radio, duracion) son los
-- mismos que usa el mod base para clanes "Bandit" hostiles.
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

-- La tirada de El Chispa vivia aqui; ahora la hace PVCShared.RollChispa desde
-- el servidor (server/TacticalSpawnServer.lua). Ver la nota de reparto
-- cliente/servidor en 00_TacticalShared.lua.

-- Pide el spawn a la AUTORIDAD. En single player el server/ corre en el mismo
-- proceso, asi que el comando se atiende igual sin red.
-- forceChispa: true fuerza el 20% de El Chispa a 100% (boton de debug).
function TeamPVC.SpawnGroup(square, forceChispa)
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

    -- MULTIJUGADOR: la tirada de El Chispa y el spawn los hace el SERVIDOR
    -- (server/TacticalSpawnServer.lua). Si los hiciera el cliente, cada
    -- jugador conectado inyectaria su propio perfil en BanditCustom.banditData
    -- y sortearia su propio tamano de grupo, desincronizando el clan.
    -- Aqui solo se pide; la autoridad decide.
    sendClientCommand(player, 'BEPSpawn', 'TeamPVCHere', {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        forceChispa = forceChispa and true or false,
    })

    local ok2, err = pcall(ShowArrivalMarker, square)
    if not ok2 then LogError("ShowArrivalMarker", err) end

    print("[TeamPVC] Spawn solicitado al servidor en " ..
          square:getX() .. "," .. square:getY() .. "," .. square:getZ() ..
          " (forzar El Chispa: " .. tostring(forceChispa and true or false) .. ")")
    return true
end

-- Spawn natural propio (reemplaza a checkEvent() del mod base): misma
-- cadencia que el planificador nativo (Events.EveryTenMinutes) y la misma
-- formula de probabilidad de DISPARO (spawnChance * SpawnMultiplier / 6),
-- para que el slider de sandbox del jugador siga controlando que tan seguido
-- aparecen. Lo unico que cambiamos es que, al disparar, llamamos a
-- SpawnGroup() con size=6 fijo -- nunca pasa por la formula de TAMANO nativa.

-- Punto de aparicion a distancia del jugador (no literalmente encima). No es
-- tan sofisticado como generateSpawnPointUniform del mod base (esa funcion es
-- local a su archivo server/ y no es alcanzable desde aqui); si la casilla
-- elegida no existe (chunk no cargado), caemos en la casilla del jugador, que
-- por definicion siempre es valida.
-- El planificador natural (elegir cuando y donde aparece el escuadron) ya NO
-- vive aqui: lo hace CheckTeamPVCSpawn en server/TacticalSpawnServer.lua.
-- Motivo: media/lua/server/ se ejecuta en single player, en el servidor
-- interno del modo Anfitrion y en un dedicado, pero nunca en un cliente
-- conectado -- eso da "exactamente una autoridad" en los tres modos. La
-- version anterior, con "if isClient() then return end", dejaba el spawn
-- MUERTO en Anfitrion, porque alli el anfitrion tambien es cliente.

local function OnSpawnHere(worldobjects, square)
    local ok, err = pcall(TeamPVC.SpawnGroup, square)
    if not ok then LogError("SpawnGroup", err) end
end

local function OnSpawnAtPlayer(worldobjects)
    local ok, err = pcall(TeamPVC.SpawnGroup, nil)
    if not ok then LogError("SpawnGroup", err) end
end

-- forceChispa=true: el 20% de El Chispa pasa a 100%, para poder probar la
-- cuenta regresiva de inmediato sin tener que reintentar el spawn varias veces.
local function OnSpawnWithChispa(worldobjects)
    local ok, err = pcall(TeamPVC.SpawnGroup, nil, true)
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
    print("Integrantes con cid   : " .. members .. " (6 fijos + El Chispa si toco esta vez)")

    -- bandidos Team PVC realmente vivos en el mundo, y si ya tienen el
    -- nombre real corregido (ver FixIdentity / TeamPVC.MemberNames)
    local alive, banditsTotal, named = 0, 0, 0
    if type(BanditZombie) == "table" and BanditZombie.GetAllB then
        local all = BanditZombie.GetAllB()
        if all then
            for zid, light in pairs(all) do
                banditsTotal = banditsTotal + 1
                if light.brain and light.brain.cid == TeamPVC.CLAN_ID then
                    alive = alive + 1
                    local expected = TeamPVC.MemberNames[light.brain.bid]
                    local tag = "?"
                    if expected then
                        tag = (light.brain.fullname == expected) and "OK" or "PENDIENTE"
                        if light.brain.fullname == expected then named = named + 1 end
                    end
                    local extra = ""
                    if light.brain.bid == TeamPVC.CHISPA_BID then
                        local cs = TeamPVC.ChispaState[zid]
                        if cs and cs.startMs then
                            local remaining = math.max(0, TeamPVC.Config.Chispa.FuseMs - (getTimestampMs() - cs.startMs))
                            extra = " (mecha: " .. string.format("%.0f", remaining / 1000) .. "s restantes)"
                        else
                            extra = " (mecha aun no encendida)"
                        end
                    end
                    print("    - " .. tostring(light.brain.fullname) .. "  [" .. tag .. "]" .. extra)
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

    local parent  = context:addOption(getText("UI_BEP_PVC_DebugMenu"), worldobjects, nil)
    local subMenu = context:getNew(context)
    context:addSubMenu(parent, subMenu)

    subMenu:addOption(getText("UI_BEP_PVC_DebugSpawnElite"), worldobjects, OnSpawnAtPlayer)
    subMenu:addOption(getText("UI_BEP_PVC_DebugSpawnChispa"), worldobjects, OnSpawnWithChispa)
    if square then
        subMenu:addOption(getText("UI_BEP_PVC_DebugSpawnHere"), worldobjects, OnSpawnHere, square)
    end
    subMenu:addOption(getText("UI_BEP_PVC_DebugReinject"), worldobjects, OnReinject)
    subMenu:addOption(getText("UI_BEP_PVC_DebugDiagnose"), worldobjects, OnDiagnose)
end

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

    -- El spawn natural lo programa el servidor (CheckTeamPVCSpawn en
    -- server/TacticalSpawnServer.lua); aqui no se registra nada.

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
