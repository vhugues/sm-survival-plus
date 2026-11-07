---
name: scrap-mechanic-modding
description: Documents how Scrap Mechanic's Mod Manager, Lua 5.1 runtime, loot tables, and the Survival + editor work. Use when editing SurvivalPlus, mod.lua, loot tables, /loot, /mods, installing the mod, reading game logs, or changing Scrap Mechanic survival scripts.
---

# Survival + et Scrap Mechanic

Survival + (id `survivalplus`, dossier `SurvivalPlus`) est un mod Survie chargé par le Scrap Mechanic Mod Manager. La v1 ne stocke que des opérations sur les tables de loot. Les recettes et le raffinage viendront plus tard, comme d'autres familles d'opérations dans le même éditeur.

Le dépôt GitHub less-grind est une source d'idées. Ne pas en reprendre le code ni la structure.

## Quelle référence lire

- Installer, menu `/mods`, format d'un mod, journaux : [mod-manager.md](mod-manager.md)
- Lua 5.1, ordre de chargement, callbacks réseau, accroches de ce mod : [lua-runtime.md](lua-runtime.md)
- Profils, loot, fenêtre d'édition : [loot-editor.md](loot-editor.md)
- L'API moteur (`sm.*`, classes, userdata) et les globales de la Survie : le skill personnel `scrap-mechanic-lua`. Ne pas recopier une signature de mémoire.

## Modifier le mod

1. Éditer uniquement `SurvivalPlus/` dans `sm-less-grind`.
2. Garder la première ligne exécutable : `dofile( "$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )`.
3. Tout ajout de `Register`, d'accroche ou de callback réseau doit supporter deux chargements du même fichier.
4. Ne pas installer tant que le processus `ScrapMechanic` tourne. `Install-Mod.ps1` s'arrête dans ce cas.
5. Après installation, les traces sont dans `Scrap Mechanic\Logs\game-*.log`, lignes `[Lua]`.

## Fichiers à laisser tels quels

- `SurvivalPlus/Install this mod.bat` et `Install-ThisMod.ps1` : copies exactes du template.
- `mod.json` : `author` reste `your name here` tant que l'utilisateur ne publie pas.
- Pas de `recipe.json` dans cette version.
- Ne pas modifier le fichier de plan Cursor.
