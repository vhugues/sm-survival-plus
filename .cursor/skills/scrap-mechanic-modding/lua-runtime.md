# Lua du jeu et accroches

Lua 5.1. Pas de `goto`, pas de `//`, pas de `continue`. `0` est vrai. `dofile` du Mod Manager charge `mod.lua` dans l'environnement du script appelant.

`class()` est fourni par le moteur. `SurvivalGame = class(nil)` peut ne pas avoir de métatable. Une instance retrouve ses méthodes sur la table de classe. Remplacer cette métatable est sûr si les métaméthodes déjà présentes sont recopiées. `function SurvivalGame.foo` n'atteint `__newindex` que la première fois où la clé est créée.

## Deux chargements

L'installateur insère le bloc Mod Manager dans `SurvivalGame.lua` (après le dernier dofile de tête, avant `SurvivalGame = class(nil)`) et dans `SurvivalPlayer.lua`. `ModRegistry.lua` fait un dofile de chaque `Mods/<Nom>/mod.lua`.

Le journal du 7 novembre 2026 le montre : `MechanicCharacter.lua` charge `SurvivalPlayer.lua`, qui charge `ModRegistry.lua`, qui charge `mod.lua`. Le même fichier a déjà tourné dans l'environnement de `SurvivalGame.lua`.

`SurvivalPlus = SurvivalPlus or {}` évite d'effacer l'état au second passage. `Register`, `SP.marked`, les enveloppes et les callbacks réseau doivent tous tolérer d'être rejoués.

`mod.lua` charge ensuite, dans ce même environnement, `Util.lua`, `Loot.lua`, `Editor.lua` et `Hooks.lua`. Chaque chunk commence par `local SP = SurvivalPlus` : `SP` n'est pas global. `log`, `num`, `int` et `str` sont posés sur `SP` par `Util.lua`, puis repris en local. `Register` et le démarrage restent dans `mod.lua`.

## Les fonctions n'ont pas de champs

Le Lua du jeu refuse `fonction.champ`. Le journal `game-20261107-190831.log` contient les deux plantages qui en découlent :

- au chargement, `mod.lua` dans `Arm` : `attempt to index field 'Sv_Load' (a function value)` ;
- à chaque clic sur OUVRIR : `attempt to index field 'server_onFixedUpdate' (a function value)`.

Le message nomme le champ d'où vient la fonction (`Sv_Load`, `server_onFixedUpdate`), puis dit que cette valeur est une fonction. La ligne fautive était `ModManager.Sv_Load._spProbe` et `SurvivalGame.server_onFixedUpdate._sp`.

```lua
-- plante
wrapped._sp = true
if fn._sp then return fn end

-- plante aussi : le bac à sable retire setmetatable et getmetatable
SP.marked = setmetatable( {}, { __mode = "k" } )

-- tient
SP.marked[wrapped] = true
```

`SP.IsMarked` / `SP.Mark` sont le seul marquage à utiliser. `SP.marked` est une table ordinaire : `setmetatable` est `nil` au chargement (`SurvivalPlayer.lua` → `mod.lua`). Un champ sur une table reste valide. Ne pas appeler `getmetatable` ni `setmetatable` sans `type( ... ) == "function"`.

## Callbacks réseau, avant l'instance

Le moteur fige la liste des callbacks quand il crée l'instance du script. Une méthode `sv_*` ou `cl_*` ajoutée au premier tick n'est plus enregistrée. `sendToServer("sv_survivalPlus")` et `sendToClient("cl_spOpen")` partent alors dans le vide, sans erreur.

`mod.lua` s'exécute avant `SurvivalGame = class(nil)`. Il faut donc poser les méthodes pendant le chargement du fichier, pas au premier `server_onFixedUpdate`.

Méthodes réseau de l'éditeur : `cl_spOpen`, `cl_spState`, `cl_spClick`, `cl_spDraft`, `cl_spText`, `cl_spClosed`, `sv_survivalPlus`.

Le dispositif actuel :

1. `SP.WatchEnvironment` pose un `__newindex` sur l'environnement du chunk. À l'affectation `SurvivalGame = class()`, `SP.HookClassTable` ajoute les méthodes et enveloppe celles qui existent déjà.
2. Un line hook (`debug.sethook`) regarde l'environnement de l'appelant via `debug.getinfo` puis `getfenv`. Il rattrape le cas où l'environnement de `mod.lua` n'est pas celui de `SurvivalGame.lua`. Il se retire quand `cl_onChatCommand` et `cl_modMenuButton` sont marqués, ou après 4000 lignes.
3. `SP.Arm` enveloppe encore `UnitManager.sv_onFixedUpdate`, `WorldManager.Cl_OnCreate` et `ModManager.Sv_Load` comme filet.

Dans ce bac à sable la métatable ne se pose pas. `SP.HookClassTable` enveloppe quand même les méthodes déjà présentes par `rawset`, puis revient sans se marquer réussi. Le line hook réessaie jusqu'à ce que `cl_onChatCommand` et `cl_modMenuButton` soient marqués.

## Ouvrir l'éditeur

Le bouton **OUVRIR** utilise `runClient`, pas `run`. L'enveloppe de `cl_modMenuButton` fait `SP.game = self` avant d'appeler le menu, donc `runClient` a l'instance et appelle `SP.ClientOpen`.

`/loot` est traité dans l'enveloppe de `cl_onChatCommand` et ouvre aussi côté client. Il ne passe pas par `sendToServer`.

`SP.pendingOpen` couvre le cas où le bouton arrive avant que `SP.game` soit connu : `client_onCreate` et `client_onFixedUpdate` ouvrent alors la fenêtre.

## Réappliquer le loot

`server_onFixedUpdate` appelle l'ancienne fonction puis `SP.ServerPulse`. C'est ce pouls qui réapplique le profil si une table fille de `LOOT_SOURCES` a changé d'identité. Ne pas logger chaque réapplication : `ModManager.Log` passe par `sm.log.error` et noierait le journal. Une ligne par jeton de révision suffit.
