--[[==========================================================================
    ZPMaurinBombin.lua
    Ecosistema "MaurinBombin Market" - PROGRAMA DE IA DEL PUESTO

    ---------------------------------------------------------------------------
    POR QUE EXISTE ESTE ARCHIVO
    ---------------------------------------------------------------------------
    El escuadron del mercado se spawneaba con program = "Bandit", o sea con
    ZombiePrograms.Bandit (shared/ZombiePrograms/ZPBandit.lua del mod base). Ese
    programa hace EXACTAMENTE lo contrario de lo que queremos:

      - ZPBandit.Prepare llama Bandit.ForceStationary(bandit, false), asi que
        cualquier intento nuestro de fijarlos en el sitio se deshacia solo;
      - ZPBandit.Main es la IA de bandido completa: busca bases de jugador,
        va a encender interruptores de luz, persigue, y usa walkType = "Run".

    Resultado en partida: el mercader y sus guardias se comportaban como una
    banda hostil y se iban corriendo del puesto. La "zona segura" de
    MaurinBombinAI.EnforceStatic peleaba contra eso cada tick (limpiaba las
    tareas de movimiento que ZPBandit acababa de encolar), que es justo el
    tironeo que se veia en pantalla.

    La solucion correcta no es pelear con el programa, es NO USARLO. El
    despachador del mod base (client/BanditUpdate.lua ~1898) resuelve el
    programa por nombre:

        ZombiePrograms[program.name][program.stage](bandit)

    ...y el nombre sale de brain.program.name, que el spawner escribe desde
    args.program (server/BanditServerSpawner.lua ~401). O sea que basta con
    declarar aqui nuestro propio programa y spawnear con
    program = "MaurinBombin" (ver server/MaurinBombinSpawn.lua).

    ---------------------------------------------------------------------------
    POR QUE ESTA EN shared/
    ---------------------------------------------------------------------------
    El servidor escribe el nombre del programa al crear el bandido, pero quien
    lo EJECUTA es el cliente (el tick de IA del mod base es client-side). Si la
    tabla solo existiera en uno de los dos lados, el despachador indexaria nil.
    En shared/ existe en los dos.

    ---------------------------------------------------------------------------
    QUE SIGUE FUNCIONANDO (y por que no hace falta programarlo aqui)
    ---------------------------------------------------------------------------
    En BanditUpdate el programa se consulta AL FINAL, y solo si no hay ya
    tareas pendientes: primero corren el manejo de curacion, ManageCombat y
    ManageCollisions. O sea que los guardias siguen disparando a los zombis por
    la via normal del mod base (gateada por brain.hostile, que
    MaurinBombinAI.EnforcePact mantiene en true para ellos) sin que este
    programa tenga que saber nada de combate.

    Este programa solo responde una cosa: "no tengo ninguna tarea que darte".
    Sin tareas de movimiento, el escuadron se queda donde lo dejaron.
============================================================================]]

ZombiePrograms = ZombiePrograms or {}

ZombiePrograms.MaurinBombin = {}
ZombiePrograms.MaurinBombin.Stages = {}

ZombiePrograms.MaurinBombin.Init = function(bandit)
end

-- Primera etapa tras el spawn. El mod base entra siempre por "Prepare"
-- (brain.program.stage = args.stage or "Prepare").
ZombiePrograms.MaurinBombin.Prepare = function(bandit)
    Bandit.ForceStationary(bandit, true)
    return {status = true, next = "Main", tasks = {}}
end

-- Estado terminal: se queda en "Main" para siempre y nunca devuelve tareas.
-- Se reafirma ForceStationary en cada pasada porque otras mecanicas del mod
-- base pueden reescribir el brain (y porque es una sola asignacion a una tabla
-- que ya esta en memoria: no cuesta nada).
ZombiePrograms.MaurinBombin.Main = function(bandit)
    Bandit.ForceStationary(bandit, true)
    return {status = true, next = "Main", tasks = {}}
end
