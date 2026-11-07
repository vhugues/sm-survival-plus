# Mod Manager

Le jeu n'a pas de chargeur de mods pour la Survie. `$SURVIVAL_DATA` pointe toujours vers le dossier Survival de Steam. Un « custom game » ou un écrasement Vortex ne s'applique pas à une sauvegarde Survie déjà créée. Le chargeur réel est le Mod Manager (Nexus mods/37, source `gitlab.com/spawn7224/scrap-mechanic-mods`).

## Cette machine

Le Mod Manager est installé depuis le clone `C:\Users\hugue\gits\scrap-mechanic-mods`, pas par l'installeur Nexus. La clé de registre `HKCU\Software\spawn7224\ScrapMechanicModManager\InstallPath` est absente, et les dossiers Program Files du Mod Manager n'existent pas.

`Install this mod.bat` ne regarde que ce registre et ces dossiers. Sur cette machine il affiche toujours que le Mod Manager n'est pas installé. Ne pas modifier le `.bat` ni `Install-ThisMod.ps1` pour corriger ça : ce sont les fichiers du template, byte pour byte.

Installation qui fonctionne, jeu fermé, depuis n'importe quel répertoire :

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\hugue\gits\scrap-mechanic-mods\tools\Add-Mod.ps1 -Force C:\Users\hugue\gits\sm-less-grind\SurvivalPlus
```

`Add-Mod.ps1` copie le dossier dans `scrap-mechanic-mods\src\Mods\SurvivalPlus`, sauvegarde les mondes dans `%LOCALAPPDATA%\ScrapMechanicModManager\save-backups\`, puis lance `Install-Mod.ps1`. Celui-ci patche le jeu Steam, régénère `ModRegistry.lua` et vide `Cache\Bundle\core_data.cbo`.

Le premier lancement après ce vidage de cache peut se fermer. Relancer le jeu.

`Add-Mod.ps1` affiche l'id capturé par `id\s*=\s*"([^"]+)"`. La première occurrence dans `mod.lua` n'est pas l'id du mod (un repli contient `profile.id = "p0"`). L'id réel est `SP.MOD = "survivalplus"`, passé à `Register` par variable. Ne pas ajouter un faux `id = "survivalplus"` en tête de fichier pour faire plaisir au script.

Jeu : `C:\Program Files (x86)\Steam\steamapps\common\Scrap Mechanic`.
Copie exécutée : `Survival\Scripts\game\Mods\SurvivalPlus\`.
Journaux : `Scrap Mechanic\Logs\game-*.log`. Il n'y a pas de `*.log` utile sous AppData.
Sauvegardes : `%APPDATA%\Axolot Games\Scrap Mechanic\User\User_76561198039867672`.

Une vérification des fichiers Steam annule le patch. Il faut relancer `Add-Mod.ps1`.

## Format d'un mod

`mod.lua` commence par le dofile du framework. Des commentaires peuvent précéder cette ligne. L'installateur réécrit le préfixe `$SURVIVAL_DATA` à l'installation.

```lua
dofile( "$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )

ModManager.Register( {
	id = "survivalplus",
	name = "Survival +",
	description = "...",
	version = "1.0.0",
	enabled = true,
	modes = { "survival" },
	help = "...",
	actions = { ... },
} )
```

- `Register` remplace un mod déjà inscrit avec le même id. Les ids qui commencent par `__` sont réservés.
- `help` est coupé visuellement vers 78 colonnes.
- Une action a `key`, `name` (la phrase affichée) et `button` (un seul mot, le libellé est tronqué).
- `run(player)` s'exécute côté serveur et renvoie le texte de pied de menu, ou nil.
- Si `runClient` est présent, le menu l'appelle à la place de `run`. Il ne reçoit pas le joueur ni l'instance.
- `ModManager.Sv_IsEnabled`, `Sv_GetOption`, `Log(modId, ...)`.
- `Sv_RunAction` refuse l'action si le mod est désactivé (`"<nom> is turned off"`). Une erreur dans `run` est affichée : `That action failed - see the log`.

## Menu et commandes

L'installateur a déjà branché `/mods` dans `SurvivalGame.bindChatCommands` et `SurvivalGame.cl_onChatCommand`. Le menu s'ouvre avec `ModMenuGui.Open(self)`.

Le layout du menu appelle le callback nommé `cl_modMenuButton` sur le script qui a créé la fenêtre (`SurvivalGame`). Le moteur résout ce nom au moment du clic. `cl_modMenuButton` délègue à `ModMenuGui.OnButton`.

`/loot` n'existe pas dans le jeu. Il faut l'ajouter dans l'enveloppe de `bindChatCommands`, pour qu'il soit lié quand le jeu appelle cette fonction (depuis `client_onClientDataUpdate`, canal 1). Certaines commandes de chat ajoutées ailleurs ne partent jamais : le commentaire de l'installateur le signale.

## Journaux

`print()` depuis un script de partie, de joueur ou d'interactable n'arrive pas dans les logs. `ModManager.Log` passe par `sm.log.error`. La ligne apparaît comme :

```text
[Lua] ERROR: [ModLog:survivalplus] ...
```

Le préfixe `ERROR` est le canal de log, pas forcément une panne. Une vraie exception Lua est précédée de `----- Lua Error Traceback -----` et du chemin `Mods\SurvivalPlus\mod.lua`.

Erreur déjà vue, et qui n'est pas Survival + : `PartPackState.lua` introuvable au chargement de `ModManager.lua` depuis `SurvivalPlayer.lua`. Ne pas la confondre avec un échec du mod.
