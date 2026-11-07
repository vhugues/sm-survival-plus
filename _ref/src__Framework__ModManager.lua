-- ModManager.lua
--
-- A tiny mod framework for patched Scrap Mechanic Survival.
--
-- Purpose: let several small script mods live side by side, each with an
-- on/off switch and its own settings, all editable from one in-game menu.
--
-- Settings are stored per world (they live in the save file), server
-- authoritative, and pushed to clients with sm.storage.saveAndSync so the menu
-- and the tools can read them without asking every frame.
--
-- Adding a new mod later means one ModManager.Register call. Nothing else in the
-- framework needs to change, and the menu picks it up automatically.

ModManager = {}

-- Steam Workshop creations, and the list of them the installer generates.
--
-- Both are pcall'd because either can legitimately be absent: the registry is
-- generated at install time and does not exist on a fresh checkout, and a user
-- upgrading from an older Mod Manager will not have Blueprints.lua until the
-- installer has run again. Neither is a reason to take down the whole mod menu,
-- so a missing file leaves the feature switched off and everything else working.
pcall( dofile, "$SURVIVAL_DATA/Scripts/game/ModFramework/BlueprintRegistry.lua" )
pcall( dofile, "$SURVIVAL_DATA/Scripts/game/ModFramework/Blueprints.lua" )

-- Steam Workshop parts packs, same arrangement and for the same reasons. The
-- registry is generated, so it is absent on a fresh checkout and on any machine
-- with no subscriptions; PartPacks.lua is absent for anyone upgrading from a Mod
-- Manager that predates it. Either way the asset packs page simply does not appear.
pcall( dofile, "$SURVIVAL_DATA/Scripts/game/ModFramework/PartPackRegistry.lua" )
pcall( dofile, "$SURVIVAL_DATA/Scripts/game/ModFramework/PartPackState.lua" )
pcall( dofile, "$SURVIVAL_DATA/Scripts/game/ModFramework/PartPacks.lua" )

-- The reserved mod id blueprint buttons travel under.
--
-- Routing them through the existing sv_modAction handler means no new network
-- plumbing and no extra installer surgery: SurvivalGame, SurvivalPlayer,
-- CreativeGame and the tool already forward that one message. A mod cannot
-- collide with this because Register rejects ids starting with "__".
ModManager.BLUEPRINT_MOD_ID = "__blueprints"

-- The same trick for the ASSET PACKS page's on/off button. `actionKey` carries the
-- pack id. Reserved the same way: Register rejects any id starting with "__".
ModManager.PARTPACK_MOD_ID = "__partpacks"

-- The Mod Manager's own version, shown in the menu header so a user reporting a
-- problem can read it off the screen.
--
-- IMPORTANT: this is the version PUBLISHED on Nexus, and it changes only when an
-- update is actually released -- never while iterating locally. Bump it as part
-- of the upload, to one above whatever the mod page currently shows.
ModManager.VERSION = "1.4.8"

-- Diagnostic logging, for EVERY mod.
--
-- One call writes one line into the game's own log file (Scrap Mechanic\Logs\
-- game-*.log), tagged so the lines can be found among the engine's own noise:
--
--   ModManager.Log( "mapViewer", "seat spawned at", pos )
--     ->  [ModLog:mapViewer] seat spawned at (12.0, -3.5, 40.2)
--
-- Works on both server and client, costs nothing when things go right, and
-- turns "the button does nothing" into a readable story of exactly how far
-- the code got before it stopped. Every mod should narrate its key steps and
-- every caught error through this.
-- sm.log.error, NOT print: print() from game/player/interactable scripts never
-- reaches the log files (proven 19 Aug 2026 - a whole test session of print
-- calls left nothing), while sm.log.error lines land as "[Lua] ERROR: ...".
-- The Blueprints diagnostics made the same choice for the same reason.
function ModManager.Log( modId, ... )
	local parts = {}
	for i = 1, select( "#", ... ) do
		parts[#parts + 1] = tostring( select( i, ... ) )
	end
	local line = "[ModLog:" .. tostring( modId ) .. "] " .. table.concat( parts, " " )
	if sm.log and sm.log.error then sm.log.error( line ) else print( line ) end
end

-- Storage channel for all mod settings in this world.
local STORAGE_CHANNEL_MOD_MANAGER = "smModManagerSettings"

-- Registry of mod definitions, in display order.
ModManager.mods = {}
ModManager.modsById = {}

-- Server-side settings cache: { [modId] = { enabled = bool, options = {...} } }
ModManager.sv_settings = nil

-- Client-side mirror of the same table.
ModManager.cl_settings = nil

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

--- Register a mod with the manager.
--
-- definition = {
--     id          = "foliageEraser",         -- unique key, no spaces
--     name        = "Foliage Eraser",        -- shown in the menu
--     description = "Delete decorative plants by clicking them.",
--     version     = "1.0.2",                 -- optional, shown in the menu
--     enabled     = true,                    -- default on/off
--     options     = {
--         {
--             key     = "radius",
--             name    = "Erase size",
--             type    = "number",
--             default = 1.5,
--             min     = 0.5,
--             max     = 12.0,
--             step    = 0.5,
--             suffix  = " blocks"
--         },
--         {
--             key     = "trees",
--             name    = "Include scenery trees",
--             type    = "bool",
--             default = false
--         }
--     }
-- }
--------------------------------------------------------------------------------
-- Game mode
--
-- Scrap Mechanic has no sm.game.getMode(), but it does not need one: each mode
-- runs its own game script out of its own script root --
--
--   Survival        Survival\Scripts\game\SurvivalGame.lua
--   Creative and    Data\Scripts\game\CreativeGame.lua
--     Custom Games
--   Challenge       ChallengeData\Scripts\game\...
--
-- so whichever one boots IS the mode. The installer patches a SetMode call into
-- each host it installs to, which is more reliable than sniffing globals.
--------------------------------------------------------------------------------

ModManager.mode = "survival"

function ModManager.SetMode( mode )
	ModManager.mode = mode
end

--- Should this mod be shown and given out in the mode we are currently in?
--
-- A mod with no `modes` field shows everywhere. That keeps mods written before
-- this existed working, and it is the right default for anything genuinely
-- mode-agnostic.
function ModManager.IsForCurrentMode( mod )
	if mod == nil then return false end
	if mod.modes == nil then return true end

	for _, mode in ipairs( mod.modes ) do
		if mode == ModManager.mode then return true end
	end
	return false
end

--- Should this mod's `tool` be handed to the player in the mode we are in?
--
-- Separate from IsForCurrentMode because "this mod runs here" and "this mod
-- gives you its item for free here" are different questions. A mod whose item
-- is CRAFTABLE wants to run in Survival but must not be handed over there, or
-- the recipe is pointless.
--
-- No `toolModes` means hand it out wherever the mod runs, which is what every
-- mod written before this did.
function ModManager.GivesToolInMode( mod )
	if mod == nil or mod.tool == nil then return false end
	if mod.toolModes == nil then return true end

	for _, mode in ipairs( mod.toolModes ) do
		if mode == ModManager.mode then return true end
	end
	return false
end

--- The mods to show in the menu: registered, and applicable to this mode.
function ModManager.VisibleMods()
	local visible = {}
	for _, mod in ipairs( ModManager.mods ) do
		if ModManager.IsForCurrentMode( mod ) then
			visible[#visible + 1] = mod
		end
	end
	return visible
end

function ModManager.Register( definition )
	assert( definition and definition.id, "ModManager.Register needs an id" )

	-- Ids beginning with "__" are reserved for the framework's own menu entries,
	-- which travel through the same action dispatch as real mods. A third-party
	-- mod claiming one would have its buttons swallowed by the framework, so this
	-- is refused loudly rather than producing a mod whose buttons quietly do
	-- something else entirely.
	assert( string.sub( definition.id, 1, 2 ) ~= "__",
		"ModManager.Register: ids starting with __ are reserved (got '" ..
		tostring( definition.id ) .. "')" )

	definition.options = definition.options or {}
	definition.actions = definition.actions or {}

	-- EVERY MOD WITH A TOOL gets a GIVE TOOL button in its panel (user rule,
	-- 30 Aug): the free hand-out now happens ONCE per player per save, so a
	-- player who loses the tool needs a way back - the craftbot recipe where
	-- the mod ships one, and this button always. Added here so no mod has to
	-- remember to declare it.
	if definition.tool ~= nil then
		local hasGive = false
		for _, a in ipairs( definition.actions ) do
			if a.key == "__giveTool" then hasGive = true break end
		end
		if not hasGive then
			definition.actions[#definition.actions + 1] = {
				key = "__giveTool",
				name = "Lost the tool? Put one back in your inventory",
				button = "GIVE TOOL",
				run = function( player )
					return ModManager.Sv_GiveToolNow( definition.id, player )
				end,
			}
		end
	end

	-- Re-registering replaces the previous definition rather than being ignored.
	-- Silently keeping the first one meant a stale duplicate elsewhere could pin
	-- the mod to an out-of-date option list, with no error to show for it.
	local existing = ModManager.modsById[definition.id]
	if existing then
		for i, mod in ipairs( ModManager.mods ) do
			if mod.id == definition.id then
				ModManager.mods[i] = definition
				break
			end
		end
		ModManager.modsById[definition.id] = definition
		return definition
	end

	definition.options = definition.options or {}
	definition.actions = definition.actions or {}
	if definition.enabled == nil then
		definition.enabled = true
	end

	ModManager.mods[#ModManager.mods + 1] = definition
	ModManager.modsById[definition.id] = definition

	return definition
end

--- Build a fresh settings table from every registered mod's defaults.
local function BuildDefaults()
	local settings = {}
	for _, mod in ipairs( ModManager.mods ) do
		local entry = { enabled = mod.enabled, options = {} }
		for _, option in ipairs( mod.options ) do
			entry.options[option.key] = option.default
		end
		settings[mod.id] = entry
	end
	return settings
end

--- Fill in anything missing, so a mod added after the world was created still
--- gets its defaults rather than nil.
local function ApplyMissingDefaults( settings )
	local changed = false
	for _, mod in ipairs( ModManager.mods ) do
		if settings[mod.id] == nil then
			settings[mod.id] = { enabled = mod.enabled, options = {} }
			changed = true
		end
		local entry = settings[mod.id]
		entry.options = entry.options or {}
		if entry.enabled == nil then
			entry.enabled = mod.enabled
			changed = true
		end
		for _, option in ipairs( mod.options ) do
			if entry.options[option.key] == nil then
				entry.options[option.key] = option.default
				changed = true
			end
		end
	end
	return changed
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

function ModManager.Sv_Load()
	local stored = sm.storage.load( STORAGE_CHANNEL_MOD_MANAGER )
	if stored == nil then
		stored = BuildDefaults()
		sm.storage.saveAndSync( STORAGE_CHANNEL_MOD_MANAGER, stored )
	elseif ApplyMissingDefaults( stored ) then
		sm.storage.saveAndSync( STORAGE_CHANNEL_MOD_MANAGER, stored )
	end
	ModManager.sv_settings = stored
	return stored
end

function ModManager.Sv_Save()
	if ModManager.sv_settings then
		sm.storage.saveAndSync( STORAGE_CHANNEL_MOD_MANAGER, ModManager.sv_settings )
	end
end

function ModManager.Sv_IsEnabled( modId )
	local settings = ModManager.sv_settings or ModManager.Sv_Load()
	local entry = settings[modId]
	return entry ~= nil and entry.enabled == true
end

function ModManager.Sv_GetOption( modId, optionKey )
	local settings = ModManager.sv_settings or ModManager.Sv_Load()
	local entry = settings[modId]

	-- Note the explicit nil check on the VALUE, not just on the entry. An option
	-- added after this world was first saved has no stored value yet, and
	-- returning nil for it made every new category read as "off".
	if entry and entry.options and entry.options[optionKey] ~= nil then
		return entry.options[optionKey]
	end

	local mod = ModManager.modsById[modId]
	if mod then
		for _, option in ipairs( mod.options ) do
			if option.key == optionKey then
				return option.default
			end
		end
	end
	return nil
end

function ModManager.Sv_SetEnabled( modId, enabled )
	local settings = ModManager.sv_settings or ModManager.Sv_Load()
	if settings[modId] == nil then return false end
	settings[modId].enabled = enabled == true
	ModManager.Sv_Save()
	return true
end

function ModManager.Sv_SetOption( modId, optionKey, value )
	local settings = ModManager.sv_settings or ModManager.Sv_Load()
	local entry = settings[modId]
	if entry == nil then return false end

	local mod = ModManager.modsById[modId]
	if mod then
		for _, option in ipairs( mod.options ) do
			if option.key == optionKey then
				if option.type == "number" then
					value = tonumber( value )
					if value == nil then return false end
					if option.min and value < option.min then value = option.min end
					if option.max and value > option.max then value = option.max end
				elseif option.type == "bool" then
					value = value == true or value == "true" or value == 1
				end
				entry.options = entry.options or {}
				entry.options[optionKey] = value
				ModManager.Sv_Save()
				return true
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------

function ModManager.Cl_Get()
	-- saveAndSync mirrors the channel to clients, so a plain load works here.
	ModManager.cl_settings = sm.storage.load( STORAGE_CHANNEL_MOD_MANAGER ) or BuildDefaults()
	return ModManager.cl_settings
end

function ModManager.Cl_IsEnabled( modId )
	local settings = ModManager.Cl_Get()
	local entry = settings[modId]
	return entry ~= nil and entry.enabled == true
end

function ModManager.Cl_GetOption( modId, optionKey )
	local settings = ModManager.Cl_Get()
	local entry = settings[modId]
	if entry and entry.options and entry.options[optionKey] ~= nil then
		return entry.options[optionKey]
	end
	local mod = ModManager.modsById[modId]
	if mod then
		for _, option in ipairs( mod.options ) do
			if option.key == optionKey then
				return option.default
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Display helpers, shared by the menu and the chat commands
--------------------------------------------------------------------------------

function ModManager.FormatOptionValue( mod, option, value )
	if option.type == "bool" then
		return value and "ON" or "OFF"
	end
	local text
	if option.step and option.step < 1 then
		text = string.format( "%.1f", value or 0 )
	else
		text = string.format( "%d", math.floor( ( value or 0 ) + 0.5 ) )
	end
	return text .. ( option.suffix or "" )
end

--------------------------------------------------------------------------------
-- Tools
--
-- A mod may declare `tool = "<uuid>"`. The framework hands that item out while
-- the mod is on and takes it back when it is off. Doing it here rather than in
-- the mod keeps the behaviour identical for every future mod, and means the
-- manager never needs to know what any particular mod's tool does.
--------------------------------------------------------------------------------

function ModManager.Sv_SyncTools( player )
	if player == nil then return end

	local inventory = player:getInventory()
	if inventory == nil then return end

	for _, mod in ipairs( ModManager.mods ) do
		-- A mod for another game mode must not have its tool pushed into the
		-- player's inventory here, or a Creative-only tool would turn up in a
		-- Survival save.
		if mod.tool and ModManager.IsForCurrentMode( mod )
				and ModManager.GivesToolInMode( mod ) then
			local uuid = sm.uuid.new( mod.tool )
			local held = sm.container.totalQuantity( inventory, uuid )
			local on = ModManager.Sv_IsEnabled( mod.id )

			if on and held == 0 then
				-- ONCE PER PLAYER PER SAVE. "held == 0" alone made an
				-- endless supply: store the tool in a chest and every
				-- login handed out another (user report, 30 Aug). The
				-- given-flag persists with the settings, so a stored
				-- tool stays the only one. Replacements come from the
				-- craftbot recipe or the GIVE TOOL button in /mods.
				if not ModManager.Sv_ToolGiven( mod.id, player ) then
					sm.container.beginTransaction()
					sm.container.collect( inventory, uuid, 1, false )
					sm.container.endTransaction()
					ModManager.Sv_MarkToolGiven( mod.id, player, true )
				end
			elseif not on and held > 0 then
				sm.container.beginTransaction()
				sm.container.spend( inventory, uuid, held, true )
				sm.container.endTransaction()
				-- the framework took this one back, so switching the mod
				-- on again is allowed to hand it out again
				ModManager.Sv_MarkToolGiven( mod.id, player, false )
			end
		end
	end
end

--- Has this player already received this mod's free tool in this save?
function ModManager.Sv_ToolGiven( modId, player )
	local settings = ModManager.sv_settings or ModManager.Sv_Load()
	local entry = settings[modId]
	if entry == nil or entry.toolGiven == nil then return false end
	return entry.toolGiven[tostring( player.id )] == true
end

function ModManager.Sv_MarkToolGiven( modId, player, given )
	local settings = ModManager.sv_settings or ModManager.Sv_Load()
	local entry = settings[modId]
	if entry == nil then return end
	entry.toolGiven = entry.toolGiven or {}
	entry.toolGiven[tostring( player.id )] = ( given and true ) or nil
	ModManager.Sv_Save()
end

--- The GIVE TOOL button: one tool, on request, into the inventory.
function ModManager.Sv_GiveToolNow( modId, player )
	local mod = ModManager.modsById[modId]
	if mod == nil or mod.tool == nil then return "This mod has no tool" end
	if player == nil then return "Could not find your character" end
	if not ModManager.Sv_IsEnabled( modId ) then
		return "Turn the mod on first - its tool only exists while the mod is on"
	end
	local inventory = player:getInventory()
	if inventory == nil then return "Could not reach your inventory" end
	local uuid = sm.uuid.new( mod.tool )
	if sm.container.totalQuantity( inventory, uuid ) > 0 then
		return "The tool is already in your inventory"
	end
	sm.container.beginTransaction()
	sm.container.collect( inventory, uuid, 1, false )
	local ok = sm.container.endTransaction()
	if ok == false then return "No room in your inventory" end
	ModManager.Sv_MarkToolGiven( modId, player, true )
	return "Tool added to your inventory"
end

--- Apply a settings change coming from the menu, for any mod.
function ModManager.Sv_ApplyChange( params )
	if params == nil or params.modId == nil then return end

	if params.key == "__enabled" then
		ModManager.Sv_SetEnabled( params.modId, params.value == true )
		for _, p in ipairs( sm.player.getAllPlayers() ) do
			ModManager.Sv_SyncTools( p )
		end
	else
		ModManager.Sv_SetOption( params.modId, params.key, params.value )
	end
end

--- Run a mod's menu action. Server side.
--
-- The single entry point every action button goes through. Each menu owner
-- (SurvivalGame, SurvivalPlayer, and any mod's tool) has one `sv_modAction`
-- method that forwards to this, so a mod can add buttons without any of them
-- knowing the mod exists.
--
-- @return string|nil message to show the player
function ModManager.Sv_RunAction( modId, actionKey, player )
	-- Blueprint buttons ride this same message rather than adding a second
	-- network route. `actionKey` carries the creation id, or one of the two verbs
	-- below.
	-- Asset pack on/off. Whether a pack's parts can be CRAFTED in this world is the
	-- only part of it we control; whether they exist is the world's save, which
	-- nothing in game can write.
	if modId == ModManager.PARTPACK_MOD_ID then
		if PartPacks == nil or PartPacks.Sv_Toggle == nil then
			return "Asset packs are not installed"
		end

		return PartPacks.Sv_Toggle( actionKey )
	end

	if modId == ModManager.BLUEPRINT_MOD_ID then
		if Blueprints == nil then return "Workshop creations are not installed" end

		if actionKey == "__remove" then
			return Blueprints.Sv_RemoveLast( player )
		end

		if actionKey == "__tools" then
			return Blueprints.Sv_GiveTools( player )
		end

		if actionKey == "__inspect" then
			return Blueprints.Sv_Inspect( player )
		end

		-- Accepting the warning and placing are one click for the player, but two
		-- steps here: the consent has to be written before Sv_Place will act, and
		-- it is written per world so it sticks for next time.
		if not Blueprints.Sv_HasAccepted( actionKey ) then
			Blueprints.Sv_Accept( actionKey )
		end
		return Blueprints.Sv_Place( actionKey, player )
	end

	local mod = ModManager.modsById[modId]
	if mod == nil then return "That mod is not installed" end

	if not ModManager.Sv_IsEnabled( modId ) then
		return mod.name .. " is turned off"
	end

	for _, action in ipairs( mod.actions ) do
		if action.key == actionKey then
			if type( action.run ) ~= "function" then return nil end

			-- A third-party mod's code is not trusted to be correct. An error in
			-- it must not take down the menu for every other mod.
			local ok, result, message = pcall( action.run, player )
			if not ok then
				sm.log.error( "[ModManager] action '" .. tostring( actionKey ) ..
					"' in mod '" .. tostring( modId ) .. "' failed: " .. tostring( result ) )
				return "That action failed - see the log"
			end

			-- Tolerate either `return message` or `return ok, message`.
			if type( result ) == "string" then return result end
			return message
		end
	end

	return nil
end

function ModManager.GetOptionDefinition( modId, optionKey )
	local mod = ModManager.modsById[modId]
	if mod == nil then return nil end
	for _, option in ipairs( mod.options ) do
		if option.key == optionKey then
			return option
		end
	end
	return nil
end
