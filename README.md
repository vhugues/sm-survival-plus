# Survival +

Editeur de tables de loot pour une partie Survie de Scrap Mechanic. Le mod ne change aucun chiffre tant qu'un profil n'est pas actif. Les recettes, le raffinage et les récoltes ne font pas partie de cette version.

Le jeu n'a pas de chargeur de mods pour la Survie. Survival + se charge avec le [Scrap Mechanic Mod Manager](https://www.nexusmods.com/scrapmechanic/mods/37) (1.4.7 ou plus récent), y compris sur un monde déjà créé.

## Installation

1. Installez le Mod Manager, jeu fermé.
2. Extrayez cette archive et ouvrez le dossier `SurvivalPlus`.
3. Lancez `Install this mod.bat`. Le script trouve le Mod Manager tout seul. Il refuse de continuer si Scrap Mechanic est ouvert.
4. Relancez le jeu, ouvrez le monde, tapez `/mods` et laissez **Survival +** activé.

Le premier lancement après l'installation peut se fermer pendant que le jeu reconstruit son cache. Relancez : c'est le comportement décrit par l'auteur du Mod Manager.

En multijoueur, tout le monde doit avoir les mêmes mods. Une vérification des fichiers Steam annule le patch du Mod Manager : relancez ensuite `Install this mod.bat`.

Dans `mod.json`, le champ `author` vaut `your name here`. Remplacez-le par votre nom avant une publication.

## Dans le jeu

`/mods` garde l'interrupteur du mod et le bouton **OUVRIR**. `/loot` ouvre le même éditeur. Les deux passent par la partie : elle envoie l'ouverture au joueur qui l'a demandée.

Sans profil, il n'y a rien à éditer et les drops restent ceux du jeu.

- **Créer** un profil vide. Les lignes affichées sont le loot vanilla.
- **Dupliquer** copie les opérations sous un nouveau nom.
- **Activer** applique ce profil. Un seul profil est actif. Réappuyer le désactive et le loot redevient vanilla.
- **Supprimer** retire le profil.

Un profil ne contient pas une copie des tables. Il contient des opérations :

- **update** — une ligne vanilla, avec le poids et la quantité d'avant et d'après
- **remove** — une ligne vanilla retirée, avec ses valeurs d'origine
- **add** — une ligne qui n'est pas dans le vanilla

Une ligne vanilla est identifiée par la source et l'objet. Quand le même objet apparaît plusieurs fois (les component kits du Farmbot, ou « Rien »), le rang de cette occurrence fait partie de la clé. Si une mise à jour du jeu retire l'objet, l'opération reste affichée comme orpheline et n'est pas recollée sur une autre ligne.

À gauche, les sources (robots, coffres, caisses, minerais, autres). À droite, un tirage à la fois : nom, icône quand le jeu en fournit une, poids, pourcentage dans le tirage, quantité, puis l'état inchangé, modifié, ajouté ou supprimé.

Les profils sont enregistrés dans la sauvegarde du monde.
