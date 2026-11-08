-- Survival + / mod.lua
--
-- Editeur de tables de loot pour la Survie. Le fichier commence par le dofile
-- du Mod Manager, exactement comme le template : l'installateur reecrit le
-- prefixe $SURVIVAL_DATA quand il installe le mod.
--
-- Le reste est dans Util.lua, Loot.lua, Editor.lua et Hooks.lua, charges
-- ensuite dans le meme environnement.

dofile( "$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )

SurvivalPlus = SurvivalPlus or {}
local SP = SurvivalPlus

SP.MOD = "survivalplus"
SP.CHANNEL = "survivalPlusProfiles"
SP.PAGE = 6
SP.CATALOG_PAGE = 14
-- Le Lua du jeu refuse fn.champ. Les fonctions déjà enveloppées sont notées ici.
-- Le bac à sable retire setmetatable et rawset : une table ordinaire suffit.
if not SP.marked then
	local marked = {}
	if type( setmetatable ) == "function" then
		local ok, weak = pcall( setmetatable, marked, { __mode = "k" } )
		if ok and type( weak ) == "table" then marked = weak end
	end
	SP.marked = marked
end

function SP.IsMarked( fn )
	return type( fn ) == "function" and SP.marked[fn] == true
end

function SP.Mark( fn )
	if type( fn ) == "function" then SP.marked[fn] = true end
	return fn
end

-- rawset est nil dans ce bac à sable. Une clé déjà dans la table s'écrit
-- sans passer par __newindex. Une clé nouvelle, sous __newindex, retire
-- la métatable le temps de l'écriture : holder[key] = value rappellerait
-- __newindex et bouclerait.
function SP.Write( holder, key, value )
	if type( holder ) ~= "table" then return end
	if type( rawset ) == "function" then
		rawset( holder, key, value )
		return
	end
	if type( rawget ) == "function" then
		local current = rawget( holder, key )
		if current ~= nil then
			holder[key] = value
			return
		end
	end
	local mt = nil
	if type( getmetatable ) == "function" then
		local ok, current = pcall( getmetatable, holder )
		if ok and type( current ) == "table" then mt = current end
	end
	if type( mt ) ~= "table" or mt.__newindex == nil then
		holder[key] = value
		return
	end
	if type( setmetatable ) ~= "function" then return end
	local removedOk = pcall( setmetatable, holder, nil )
	if not removedOk then return end
	holder[key] = value
	pcall( setmetatable, holder, mt )
end


dofile( "$SURVIVAL_DATA/Scripts/game/Mods/SurvivalPlus/Util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/Mods/SurvivalPlus/Loot.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/Mods/SurvivalPlus/Editor.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/Mods/SurvivalPlus/Hooks.lua" )

local log = SP.log

ModManager.Register( {
	id = SP.MOD,
	name = "Survival +",
	description = "Éditeur de loot pour la Survie. Sans profil actif, les drops ne changent pas.",
	version = "1.0.0",
	enabled = true,
	modes = { "survival" },
	help = table.concat( {
		"Survival + règle les tables de loot d'une partie Survie.",
		"Tant qu'aucun profil n'est actif, les drops restent ceux du jeu.",
		"Créez ou dupliquez un profil avant d'éditer. Le profil ne stocke",
		"que des opérations : modifier, retirer, ajouter.",
		"Une ligne vanilla se suit par sa source et son objet. Si l'objet",
		"revient plusieurs fois, le rang de cette occurrence est gardé.",
		"Activez un seul profil pour l'appliquer à ce monde.",
		"Ouvrez l'éditeur avec OUVRIR ou la commande /loot.",
		"Les recettes, le raffinage et les récoltes viendront plus tard.",
	}, "\n" ),
	actions = {
		{
			key = "loot",
			name = "Ouvrir l'editeur de tables de loot",
			button = "OUVRIR",
			-- Cote client : la fenetre s'ouvre ici, sans passer par un callback
			-- reseau qui n'existerait pas encore.
			runClient = function()
				log( "bouton OUVRIR" )
				SP.InstallRuntimeHooks()
				if SP.game then
					SP.ClientOpen( SP.game )
					return nil
				end
				log( "instance absente au bouton OUVRIR" )
				SP.pendingOpen = true
				return "Ouverture de l'editeur..."
			end,
		},
	},
} )

SP.WatchEnvironment()
SP.Arm()
if type( SurvivalGame ) == "table" then
	SP.armNextClass = false
	SP.HookClassTable( SurvivalGame )
else
	SP.armNextClass = true
	SP.InstallClassHook()
end
SP.CaptureMenuOwner()
SP.InstallLootCommand()
