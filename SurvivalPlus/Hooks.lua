-- Survival + / Hooks.lua
--
-- Callbacks reseau et accroches. Pas d'effet au chargement : mod.lua appelle
-- le demarrage apres ces definitions.

local SP = SurvivalPlus
local log, num, int, str = SP.log, SP.num, SP.int, SP.str

--------------------------------------------------------------------------------
-- Branchements. mod.lua est charge avant SurvivalGame = class( nil ), et une
-- deuxieme fois depuis le joueur. Les callbacks reseau sont poses sur la
-- table que class( nil ) renvoie, avant la creation de l'instance.
--------------------------------------------------------------------------------

function SP.SvCommand( self, params, player )
	params = params or {}
	SP.game = self
	log( "sv_survivalPlus", params.cmd or "state" )
	if params.cmd == "open" then
		self.network:sendToClient( player, "cl_spOpen", {} )
		return
	end
	local ok, view = pcall( SP.Handle, params )
	if not ok then
		log( "commande en echec:", view )
		view = { notice = "Echec, voir le journal.", profiles = {}, sources = {}, rows = {} }
	end
	self.network:sendToClient( player, "cl_spState", view )
end

function SP.InstallNetworkMethods( classTable )
	classTable.cl_spOpen = function( self )
		SP.game = self
		SP.ClientOpen( self )
	end
	classTable.cl_spState = function( self, data )
		log( "cl_spState" )
		SP.game = self
		SP.ClientState( self, data )
	end
	classTable.cl_spClick = function( self, name )
		SP.ClientClick( self, name )
	end
	classTable.cl_spDraft = function( self, name, text )
		SP.ClientDraft( self, name, text )
	end
	classTable.cl_spText = function( self, name, text )
		SP.ClientText( self, name, text )
	end
	classTable.cl_spClosed = function( self )
		if self.cl then self.cl.spGui = nil end
	end
	classTable.sv_survivalPlus = SP.SvCommand
end

-- Ces méthodes doivent exister avant que le jeu crée l'instance. Un callback
-- ajouté au premier tick n'est plus enregistré sur le réseau : le bouton et
-- /loot envoient alors un message que personne ne reçoit.
function SP.WrapGameMethod( key, fn )
	if type( fn ) ~= "function" or SP.IsMarked( fn ) then return fn end
	local wrapped
	if key == "server_onFixedUpdate" then
		wrapped = function( self, timeStep )
			SP.game = self
			fn( self, timeStep )
			SP.ServerPulse( self )
		end
	elseif key == "client_onCreate" or key == "client_onFixedUpdate" then
		wrapped = function( self, ... )
			SP.game = self
			local result = fn( self, ... )
			if SP.pendingOpen then
				SP.pendingOpen = false
				SP.ClientOpen( self )
			end
			return result
		end
	elseif key == "bindChatCommands" then
		wrapped = function( self, ... )
			local result = fn( self, ... )
			local ok, err = pcall( sm.game.bindChatCommand, "/loot", {}, "cl_onChatCommand", "Ouvrir l'editeur Survival +" )
			if not ok then log( "commande /loot non liee:", err ) end
			return result
		end
	elseif key == "cl_onChatCommand" then
		wrapped = function( self, params, ... )
			SP.game = self
			if params and params[1] == "/loot" then
				log( "commande /loot" )
				SP.ClientOpen( self )
				return
			end
			return fn( self, params, ... )
		end
	elseif key == "cl_modMenuButton" then
		wrapped = function( self, buttonName )
			SP.game = self
			return fn( self, buttonName )
		end
	else
		return fn
	end
	SP.Mark( wrapped )
	return wrapped
end

function SP.HookClassTable( classTable )
	SP.hookedClasses = SP.hookedClasses or {}
	if SP.hookedClasses[classTable] then return end
	SP.InstallNetworkMethods( classTable )
	for _, key in ipairs( { "server_onFixedUpdate", "client_onCreate", "client_onFixedUpdate", "bindChatCommands", "cl_onChatCommand", "cl_modMenuButton" } ) do
		if type( classTable[key] ) == "function" then
			SP.Write( classTable, key, SP.WrapGameMethod( key, classTable[key] ) )
		end
	end
	-- Sans rawset, __newindex ne peut pas écrire une clé nouvelle sans se rappeler.
	if type( getmetatable ) ~= "function" or type( setmetatable ) ~= "function" or type( rawset ) ~= "function" then
		return
	end
	local mtOk, mt = pcall( getmetatable, classTable )
	if not mtOk then
		if not SP.hookFailLogged then
			SP.hookFailLogged = true
			log( "accrochage impossible:", mt )
		end
		return
	end
	local prevNew = type( mt ) == "table" and mt.__newindex or nil
	local newmt = {}
	if type( mt ) == "table" then
		for k, v in pairs( mt ) do newmt[k] = v end
	end
	newmt.__newindex = function( t, k, v )
		if k == "server_onFixedUpdate" or k == "client_onCreate" or k == "client_onFixedUpdate"
			or k == "bindChatCommands" or k == "cl_onChatCommand" or k == "cl_modMenuButton" then
			v = SP.WrapGameMethod( k, v )
		end
		if type( prevNew ) == "function" then
			prevNew( t, k, v )
		elseif type( prevNew ) == "table" then
			prevNew[k] = v
		else
			SP.Write( t, k, v )
		end
	end
	local setOk, setErr = pcall( setmetatable, classTable, newmt )
	if not setOk then
		if not SP.hookFailLogged then
			SP.hookFailLogged = true
			log( "accrochage impossible:", setErr )
		end
		return
	end
	SP.hookedClasses[classTable] = true
	if not SP.classHookLogged then
		SP.classHookLogged = true
		log( "SurvivalGame accroche avant la creation de l'instance" )
	end
end

-- class() est globale. Le prochain class( nil ) est SurvivalGame, juste
-- après le retour de ce fichier. SurvivalPlayer = class( BasePlayer ) ne
-- doit pas recevoir ces méthodes.
function SP.InstallClassHook()
	if type( class ) ~= "function" then
		log( "class() absente, callbacks reseau non poses" )
		return
	end
	if SP.IsMarked( class ) then return end
	local engineClass = class
	local function wrappedClass( base, ... )
		local classTable = engineClass( base, ... )
		if SP.armNextClass and base == nil then
			SP.armNextClass = false
			if type( classTable ) == "table" then
				SP.InstallNetworkMethods( classTable )
				log( "callbacks sv_survivalPlus et cl_spState poses" )
			else
				log( "class() n'a pas rendu une table" )
			end
		end
		return classTable
	end
	SP.Mark( wrappedClass )
	class = wrappedClass
end

-- OnButton reçoit l'instance avant runClient. Le clic OUVRIR peut alors
-- ouvrir la fenêtre sur cette instance.
function SP.CaptureMenuOwner()
	if type( ModMenuGui ) ~= "table" or type( ModMenuGui.OnButton ) ~= "function" then
		log( "ModMenuGui.OnButton absent" )
		return
	end
	if SP.IsMarked( ModMenuGui.OnButton ) then return end
	local previous = ModMenuGui.OnButton
	local function wrapped( owner, buttonName )
		if type( owner ) == "table" then SP.game = owner end
		return previous( owner, buttonName )
	end
	SP.Mark( wrapped )
	ModMenuGui.OnButton = wrapped
end

-- bindChatCommands appelle sm.game.bindChatCommand au démarrage de
-- l'instance. /loot vise cl_spOpen, déjà posé sur la classe.
function SP.InstallLootCommand()
	if sm == nil or sm.game == nil or type( sm.game.bindChatCommand ) ~= "function" then return end
	if SP.IsMarked( sm.game.bindChatCommand ) then return end
	local previous = sm.game.bindChatCommand
	local function wrapped( command, params, callback, help )
		local result = previous( command, params, callback, help )
		if not SP.lootBound then
			SP.lootBound = true
			previous( "/loot", {}, "cl_spOpen", "Ouvrir l'editeur Survival +" )
		end
		return result
	end
	SP.Mark( wrapped )
	sm.game.bindChatCommand = wrapped
end

function SP.WatchEnvironment()
	if SP.envWatched then return end
	SP.envWatched = true
	local env = nil
	if type( getfenv ) == "function" then
		-- Le niveau 1 doit être une fonction Lua. pcall(getfenv, 1) viserait pcall.
		local envOk, current = pcall( function() return getfenv( 1 ) end )
		if envOk and type( current ) == "table" then env = current end
	end
	if type( env ) == "table" and type( getmetatable ) == "function" and type( setmetatable ) == "function" and type( rawset ) == "function" then
		local mtOk, mt = pcall( getmetatable, env )
		if not mtOk then mt = nil end
		if not ( type( mt ) == "table" and mt._spEnv ) then
			local prevNew = type( mt ) == "table" and mt.__newindex or nil
			local newmt = { _spEnv = true }
			if type( mt ) == "table" then
				for k, v in pairs( mt ) do
					if newmt[k] == nil then newmt[k] = v end
				end
			end
			if newmt.__index == nil then newmt.__index = _G end
			newmt.__newindex = function( t, k, v )
				if type( prevNew ) == "function" then
					prevNew( t, k, v )
				elseif type( prevNew ) == "table" then
					prevNew[k] = v
				else
					SP.Write( t, k, v )
				end
				if k == "SurvivalGame" and type( v ) == "table" then
					local hookOk, hookErr = pcall( SP.HookClassTable, v )
					if not hookOk then log( "accrochage impossible:", hookErr ) end
				end
			end
			local setOk, setErr = pcall( setmetatable, env, newmt )
			if not setOk then log( "surveillance de l'environnement impossible:", setErr ) end
		end
	elseif type( env ) == "table" and not SP.metaSkipLogged then
		SP.metaSkipLogged = true
		log( "metatables ou rawset indisponibles, accrochage par le suivi de chargement" )
	end
	if not ( debug and debug.sethook ) then return end
	local lines = 0
	local function callerEnv( level )
		if debug.getinfo then
			local infoOk, info = pcall( debug.getinfo, level, "f" )
			if infoOk and type( info ) == "table" and type( info.func ) == "function" then
				local envOk, caller = pcall( getfenv, info.func )
				if envOk and type( caller ) == "table" then return caller end
			end
		end
		local envOk, caller = pcall( getfenv, level )
		if envOk and type( caller ) == "table" then return caller end
		return nil
	end
	local hookOk, hookErr = pcall( debug.sethook, function()
		lines = lines + 1
		local classTable = nil
		if type( SurvivalGame ) == "table" then classTable = SurvivalGame end
		for level = 2, 5 do
			local caller = callerEnv( level )
			if type( caller ) == "table" and type( caller.SurvivalGame ) == "table" then
				classTable = caller.SurvivalGame
				break
			end
		end
		if type( classTable ) == "table" then
			pcall( SP.HookClassTable, classTable )
			local chat = classTable.cl_onChatCommand
			local button = classTable.cl_modMenuButton
			if SP.IsMarked( chat ) and SP.IsMarked( button ) then
				debug.sethook()
				return
			end
		end
		if lines > 4000 then debug.sethook() end
	end, "l" )
	if not hookOk then log( "suivi du chargement impossible:", hookErr ) end
end

function SP.WrapMethod( holder, key, factory )
	if type( holder ) ~= "table" or type( holder[key] ) ~= "function" then return end
	if SP.IsMarked( holder[key] ) then return end
	local previous = holder[key]
	local function wrapped( ... )
		return factory( previous, ... )
	end
	SP.Mark( wrapped )
	holder[key] = wrapped
end

function SP.InstallRuntimeHooks()
	if type( SurvivalGame ) ~= "table" then return end
	SP.InstallNetworkMethods( SurvivalGame )
	for _, key in ipairs( { "server_onFixedUpdate", "client_onCreate", "client_onFixedUpdate", "bindChatCommands", "cl_onChatCommand", "cl_modMenuButton" } ) do
		if type( SurvivalGame[key] ) == "function" and not SP.IsMarked( SurvivalGame[key] ) then
			SP.Write( SurvivalGame, key, SP.WrapGameMethod( key, SurvivalGame[key] ) )
		end
	end
	if not SP.hooksLogged then
		SP.hooksLogged = true
		log( "Branchements SurvivalGame en place" )
		log( "sv_survivalPlus sur la classe:", type( SurvivalGame.sv_survivalPlus ) )
	end
end

function SP.Arm()
	SP.WrapMethod( UnitManager, "sv_onFixedUpdate", function( previous, ... )
		SP.InstallRuntimeHooks()
		SP.ServerPulse( SP.game )
		return previous( ... )
	end )
	SP.WrapMethod( WorldManager, "Cl_OnCreate", function( previous, ... )
		SP.InstallRuntimeHooks()
		return previous( ... )
	end )
	if ModManager and type( ModManager.Sv_Load ) == "function" and not SP.IsMarked( ModManager.Sv_Load ) then
		local previous = ModManager.Sv_Load
		local function wrapped( ... )
			local result = previous( ... )
			SP.InstallRuntimeHooks()
			return result
		end
		SP.Mark( wrapped )
		ModManager.Sv_Load = wrapped
	end
end
