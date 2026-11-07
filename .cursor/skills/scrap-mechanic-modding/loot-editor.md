# Loot et éditeur

Sans profil actif, ou si le mod est désactivé dans `/mods`, les drops restent ceux du jeu. On n'édite rien tant qu'un profil n'existe pas.

## Sauvegarde

Canal `sm.storage` : la chaîne `"survivalPlusProfiles"`. Les canaux numériques vanilla occupent 10–101, ne pas en prendre un. Le Mod Manager utilise `"smModManagerSettings"`. `load` et `save` acceptent une chaîne.

Le contenu est du JSON pur : pas de fonction, pas de userdata. Un uuid est stocké par `tostring(uuid)` et relu avec `sm.uuid.new`.

```lua
{
  activeId = "p1", -- ou nil
  nextId, nextAdd, revision,
  profiles = {
    { id = "pN", name = "...", ops = { } },
  },
}
```

Créer = opérations vides, donc l'affichage est le vanilla. Dupliquer = copie des opérations. Activer applique. Réactiver le même profil le désactive et restaure le vanilla. Supprimer retire le profil. Un seul profil est actif.

## Opérations

Un profil ne copie pas les tables. Il ne contient que des opérations.

- `update` : `kind`, `source`, `item`, `occurrence`, `before = { weight, quantity }`, `after = { weight, quantity }`. Les valeurs `before` sont lues au moment de l'édition.
- `remove` : mêmes clés d'identité plus `before`. La ligne s'affiche comme supprimée.
- `add` : `kind`, `id = "aN"`, `source`, `roll`, `item`, `weight`, `quantity`.

Clé d'une ligne vanilla : source + uuid. Si le même uuid revient plusieurs fois dans la source, on ajoute le rang d'occurrence : le compte de cet uuid sur toute la source, dans l'ordre de parcours, pas l'index de ligne du fichier. `uuid == nil` (« Rien ») utilise l'id réservé `none` plus ce rang. Une entrée `line.table` utilise `table:<nom>`.

Une opération dont l'uuid a disparu du vanilla reste orpheline. Elle n'est pas recollée sur une autre ligne. Les orphelins s'affichent sur le tirage 1.

Réécriture d'une ligne vanilla : écrire ou mettre à jour un `update`. Si `after` redevient égal au vanilla, l'opération est retirée. Supprimer une ligne vanilla écrit un `remove`. Supprimer une ligne ajoutée retire son `add`. Restaurer retire l'opération.

Poids arrondi à 2 décimales, minimum 0. Quantité : nombre, `{ min, max }` ou `{ min, avg, max }`, convertie vers la forme tableau du jeu à l'application.

## Application sur LOOT_SOURCES

Fichier du jeu : `Survival/Scripts/game/survival_loot.lua`. Une source a la forme :

```lua
{ loot = {
  { list = { { uuid, weight, quantity }, ... }, count },
  ...
} }
```

Chaque entrée de `loot` est un tirage indépendant. Le poids est relatif dans sa liste (`weight or 1`). `quantity` nil vaut 1. `SolveValue` résout un nombre ou `{ min, avg, max }` / `{ min, max }`. `uuid` nil signifie ne rien donner. `assert(item.quantity)` ne plante pas sur 0, car 0 est vrai.

Le snapshot vanilla est pris une fois, avant toute mutation. On rejoue les opérations sur une copie profonde. Si `survival_loot.lua` est rechargé et réécrit `LOOT_SOURCES` (`LOOT_SOURCES = LOOT_SOURCES or {}` puis réaffectation de chaque clé), on ne refait pas le snapshot. On détecte le remplacement d'une table fille par identité et on réapplique.

Ordre d'application : les `update` mutent les entrées sur place d'abord ; les `remove` utilisent l'index tirage:ligne calculé sur la copie vanilla avant mutation ; les `add` sont ajoutés après la reconstruction, pour ne pas être emportés par les retraits. Une liste vide est valide : `SelectOne` renvoie nil.

`SelectLoot` est global. Haybot l'appelle sans refaire le dofile : le jeu compte sur un environnement partagé. Si l'identité de `SelectLoot` change, on le ré-enveloppe. Ne pas supposer qu'un patch posé sur l'ancienne table survit au dofile.

Groupes de sources, dans cet ordre de test : `crate` → Caisses, puis `chest` / `locker` / `cabinet` / `bigbox` / `amber` → Coffres, `mineral` / `minable` / `quartz` / `voxel` / `mud` → Minerais, `bot` / `woc` / `glowbug` → Robots, sinon Autres. Le préfixe `lootsource_` est retiré pour l'étiquette. Tester `crate` avant `chest`, et `chest` avant `bot`.

## Fenêtre

`sm.jsonGui.createGui( { isInteractive = true, bNeedsCursor = true } )`, puis `:render(table)` et `:setOnCloseCallback` / `:close()`. `render` affiche la fenêtre. Il n'y a pas d'appel `open` séparé.

Le schéma vient de `DigitalSign.gui` : `Type`, `Skin`, `Caption`, `Childs`, `x`, `y`, `width`, `height`, `LayoutRule` (`Vertical` ou `Horizontal`), `onClick`, `onTextEdit`, `onTextEnter`. Les callbacks arrivent sur le script qui a créé la fenêtre : `(self, name)` pour un clic, `(self, name, text)` pour le texte. Il n'existe pas de `getText` fiable. Le bouton Créer retombe sur `Profil pN` si `onTextEdit` n'a pas fourni le nom.

Peaux présentes : `TextBox`, `PrimaryButton`, `SecondaryButton`, `EditBoxEmpty`, `PanelEmpty`, `ImageBox`, `BackgroundInteractableWide`.

Icône : `sm.gui.getItemIconFromUuid` donne `ImageResource`, `ImageGroup`, `ImageName`. Titre : `sm.shape.getShapeTitle` peut renvoyer une clé `#{...}`. Ne pas couper ces clés. Les appels d'icône et de titre sont dans un `pcall`.

Écrans : profils, éditeur (sources à gauche, un tirage à droite), édition d'une ligne, ajout. Fenêtre 760×620. Colonne des sources 250 px. Pagination `SP.PAGE = 6`. Les libellés courts `Prec.` et `Suiv.` tiennent dans cette colonne. `Retour` est la navigation. Sur une ligne, les boutons sont `Suppr` et `Restaure`. Une ligne ajoutée n'a que `Suppr`.

États affichés : inchangé, modifié (avant → après), ajouté, supprimé, orphelin.

Les listes de profils, de sources et de lignes sont paginées côté client : le serveur envoie la liste complète de la source et du tirage choisis. Le catalogue `ITEMS` (environ 1500 entrées) est paginé côté serveur, 6 par page, et n'est mis en cache qu'une fois `ITEMS` devenu une table. Un compteur `req` fait ignorer une réponse réseau périmée.

La vue renvoyée par `Handle` reprend `profileId`, `source`, `roll`, `rolls`, `profiles`, `sources`, `rows` (légendes déjà construites, quantités aplaties), `enabled`, `notice`, `req`. Elle inclut `edit` quand une ligne est en édition, et la page de catalogue seulement si l'écran client est `add`.
