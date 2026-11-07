-- ModMenuGui.lua
--
-- The mod manager window: mods listed down the left with enable/disable, and
-- the selected mod's details and settings on the right.
--
-- Scrap Mechanic dispatches GUI callbacks to the script instance that created
-- the GUI, so this module cannot own them. Whichever script opens the menu
-- supplies cl_modMenuButton / cl_modMenuClosed and forwards into here. That is
-- why SurvivalGame, SurvivalPlayer and the tool each carry a thin copy.
--
-- Settings are server authoritative: a click sends to the server, the server
-- saves and syncs, then asks the client to repaint.

dofile( "$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )

ModMenuGui = {}

local LAYOUT      = "$SURVIVAL_DATA/Gui/Layouts/ModMenu.layout"
local MOD_ROWS     = 8   -- must match tools\Generate-ModMenuLayout.ps1
-- SEVEN, not eight. The settings page now shares its height with a description at
-- the top and an ACTIONS block at the bottom, and an eighth row ran into the latter.
-- This must match tools\Generate-ModMenuLayout.ps1: a row the layout does not have is
-- a widget that does not exist, and setting text on one throws.
local CONFIG_ROWS  = 12
local ACTION_SLOTS = 3

-- How many lines of a `help` string fit on the description page at SM_TextSmall.
--
-- MEASURED IN GAME, not calculated: the page renders exactly 25 lines and drops
-- everything after silently. The Item Sorter's 40-line help lost its whole
-- CHAINS section that way, which is the same "cut off mid-sentence" failure this
-- page was built to fix. 24 leaves one line of slack so a descender on the last
-- row is never clipped.
--
-- The answer is pages, not shorter text: capping help at 24 lines would just move
-- the truncation into the source file. If this number ever needs changing,
-- measure it again in game rather than reasoning about pixel heights.
--
-- This is a CEILING, not the page size. HelpPage divides the text evenly across
-- however many pages that ceiling implies, then breaks each page at a blank line,
-- so real pages are usually shorter than this.
local HELP_LINES_PER_PAGE = 24

-- Index of the mod whose settings are shown.
ModMenuGui.selected = 1

-- Is the settings page for that mod open?
--
-- The list and the settings used to share the window, side by side, which is why the
-- list was squeezed into a third of it. They are now two pages: the list gets the
-- full width, and CONFIGURE opens the settings over it.
ModMenuGui.modDetail = false

-- Which page of the mod list, and of the current mod's settings.
--
-- Both lists could silently lose entries before this: the list drew 8 rows and the
-- settings page 7, and anything past that was drawn nowhere and reported nowhere.
-- A third-party mod author would have had no way to know their eighth setting had
-- vanished, which is the worst kind of bug this project keeps finding.
ModMenuGui.modPage = 1
ModMenuGui.cfgPage = 1

-- Which page of the current mod's help is on screen. Reset whenever the page is
-- opened or a different mod is selected, so you never open a fresh mod's help
-- part way down.
ModMenuGui.helpPage = 1

-- Rows on the Workshop creations page. Must match tools\Generate-ModMenuLayout.ps1.
local BP_ROWS = 6

-- Workshop creations page state.
--   bpOpen     the page is up
--   bpPage     which page of the list
--   bpSelected creation id awaiting confirmation, or nil while browsing
ModMenuGui.bpOpen = false
ModMenuGui.bpPage = 1
ModMenuGui.bpSelected = nil

-- Rows on the Workshop asset packs page. Must match
-- tools\Generate-ModMenuLayout.ps1. Fewer than the creations page because a pack
-- row carries a longer note - the part count AND the on/off state.
local AP_ROWS = 5

-- Workshop asset packs page state.
--   apOpen     the page is up
--   apPage     which page of the list
--   apPicked   pack id being looked at in detail, or nil while browsing
--   apRescan   showing the "how to add a new pack" text instead of the list
--
-- There is no toggle and no confirmation, because there is nothing to confirm: a
-- world's pack list lives in its save file and is read before any script runs, so
-- nothing in here can change it. Picking a row shows what that pack is doing in
-- this world and the exact command to change it.
ModMenuGui.apOpen = false
ModMenuGui.apPage = 1
ModMenuGui.apPicked = nil
ModMenuGui.apRescan = false

-- Which page of the HOW TO INSTALL PACKS text is showing. Kept separate from apPage,
-- which belongs to the pack LIST: they are unrelated pages, and sharing one counter
-- left whichever was opened second on a page number it had no reason to be on.
ModMenuGui.apHelpPage = 1

ModMenuGui.status = nil
ModMenuGui.statusTick = nil

local DEFAULT_HINT = "Type /mods in chat to reopen this window"

-- Roughly 15 seconds at the game's 40 ticks a second. Long enough to read a
-- result, short enough that it is not still sitting there later looking current.
local STATUS_TICKS = 40 * 15

local function SetStatus( message )
    ModMenuGui.status = message
    ModMenuGui.statusTick = message and sm.game.getCurrentTick() or nil
end

local function StatusExpired()
    if ModMenuGui.status == nil or ModMenuGui.statusTick == nil then return false end
    local ok, now = pcall( sm.game.getCurrentTick )
    if not ok then return false end
    return ( now - ModMenuGui.statusTick ) > STATUS_TICKS
end

--------------------------------------------------------------------------------
-- The "/mods" hint
--
-- WHY THIS EXISTS: there is no way to put the menu on a key.
--
-- Checked to the bottom rather than assumed. An arbitrary key cannot be bound
-- because the ACTION LIST IS COMPILED INTO THE ENGINE - sm.gui.getKeyBinding only
-- READS a binding so it can be printed on screen, and there is no bindings file to
-- rewrite: not in settings.json, not anywhere in the user folder, not in the
-- registry. Even editing that store would not help, because binding a key has two
-- halves and only the first is data. The second - delivering the action to a script -
-- exists in the engine for Use, Cancel, and a tool's Toggle and Reload, and for
-- nothing else. An invented action would have no route to us.
--
-- The player-level hooks are Use and Cancel, both already meaning something. Tool
-- callbacks need a tool held. A crouch double-tap works technically but nobody would
-- ever discover it.
--
-- So the command stays, and the real problem is that nobody knows it is there. This
-- says so once, quietly, and then never again.
--------------------------------------------------------------------------------

-- Once per game session, not once per world load. A player hopping between worlds
-- does not need telling five times, and a flag that survives a restart would mean a
-- returning player never sees it after a break.
ModMenuGui.hintShown = false

-- Roughly four seconds at 40 ticks. Long enough for the loading messages to stop
-- scrolling, so the hint is not the line that gets buried.
local HINT_DELAY_TICKS = 40 * 4
ModMenuGui.hintTick = nil

local function MaybeShowHint()
    if ModMenuGui.hintShown then return end

    local ok, now = pcall( sm.game.getCurrentTick )
    if not ok then return end

    -- First tick seen: start the clock rather than firing immediately.
    if ModMenuGui.hintTick == nil then
        ModMenuGui.hintTick = now
        return
    end

    if ( now - ModMenuGui.hintTick ) < HINT_DELAY_TICKS then return end

    ModMenuGui.hintShown = true
    -- Chat, not an alert popup: the thing being advertised IS a chat command, so it
    -- appears in the place the player will type it.
    pcall( function()
        sm.gui.chatMessage( "#eeeeeeType #ffdd44/mods#eeeeee to open the Mod Manager." )
    end )
end

--- Called every frame by whichever script owns the HUD, so a stale result can
--- time out while the player just sits and looks at the window. Refresh alone is
--- not enough: it only runs when something is clicked.
function ModMenuGui.Cl_Tick( owner )
    -- Runs whether or not the menu is open - this is the one hook that ticks on the
    -- client from the moment a world loads, which is exactly when the hint is due.
    MaybeShowHint()

    -- THE HEALTH BAR, FOR THE MAP VIEWER. The status panel is
    -- owner.cl.statusPanelGui in SurvivalPlayer - a jsonGui that nothing
    -- outside that file can reach... except this hook, which is INJECTED INTO
    -- SurvivalPlayer.client_onUpdate and receives the SurvivalPlayer itself.
    -- Every in-mod route failed: g_survivalHud does not contain the bar
    -- (0.9.27), sm.gui.hideGui( true ) hides EVERY gui including the map's
    -- own panel (0.9.29-0.9.34). This is the one place the bar can be
    -- handled alone.
    --
    -- Hide: destroy the gui and nil the field - SurvivalPlayer's own
    -- "if self.cl.statusPanelGui then render" guard then skips it.
    -- Restore: recreate with the exact settings SurvivalPlayer.client_onCreate
    -- uses; its per-frame render repopulates the panel by itself.
    if owner.cl ~= nil then
        if g_mapViewerHideHud then
            if owner.cl.statusPanelGui ~= nil then
                pcall( function() owner.cl.statusPanelGui:close() end )
                pcall( function() owner.cl.statusPanelGui:destroy() end )
                owner.cl.statusPanelGui = nil
                if ModManager and ModManager.Log then
                    ModManager.Log( "mapViewer", "status panel hidden (via SurvivalPlayer hook)" )
                end
            end
        elseif owner.cl.statusPanelGui == nil and owner.cl.mapViewerHudWasHidden then
            owner.cl.statusPanelGui = sm.jsonGui.createGui(
                { isHud = true, isInteractive = false, needsCursor = true, layer = "Middle" } )
            if ModManager and ModManager.Log then
                ModManager.Log( "mapViewer", "status panel restored" )
            end
        end
        owner.cl.mapViewerHudWasHidden = g_mapViewerHideHud and true or false
    end

    if owner.cl_modMenu == nil or ModMenuGui.status == nil then return end
    if StatusExpired() then
        SetStatus( nil )
        ModMenuGui.Refresh( owner )
    end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function SelectedMod()
    local mods = ModManager.VisibleMods()
    if #mods == 0 then return nil end
    if ModMenuGui.selected < 1 or ModMenuGui.selected > #mods then
        ModMenuGui.selected = 1
    end
    return mods[ModMenuGui.selected]
end

local function FormatOption( option, value )
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
-- Open / close
--------------------------------------------------------------------------------

--- @param owner script instance that will receive the callbacks; needs .network
--- @param keepState true to leave the page state alone.
---
--- Open normally lands on the mod list, which is right when a player types /mods.
--- OnClose reopens with keepState after unwinding one level, so ESC arrives on the
--- page above rather than being thrown back to the top.
--- Opens the menu already inside one mod's settings.
--
-- For a tool that wants to hand the player its own knobs without making them open
-- the menu, find their mod in the list and press CONFIGURE. The Foliage Eraser's
-- right click uses this: its settings are what people need mid-job, and three
-- clicks to reach a switch is why nobody found "Scenery trees" - it sits on page 2
-- of a page nobody opened.
--
-- BACK still steps out to the mod list, so nothing is lost - it starts a level in
-- rather than replacing the menu.
--
-- @param owner the tool
-- @param modId string  the mod's id, as registered
-- @return true if the mod was found and its settings opened
function ModMenuGui.OpenFor( owner, modId )
	local mods = ModManager.VisibleMods()
	local index = nil
	for i, mod in ipairs( mods ) do
		if mod.id == modId then
			index = i
			break
		end
	end

	-- Not in the list means the mod is off, or not for this game mode. Falling back
	-- to the plain menu is better than doing nothing: the player still gets to the
	-- switch that turns it back on.
	if index == nil then
		ModMenuGui.Open( owner )
		return false
	end

	ModMenuGui.selected  = index
	ModMenuGui.modPage   = math.floor( ( index - 1 ) / MOD_ROWS ) + 1
	ModMenuGui.modDetail = true
	ModMenuGui.cfgPage   = 1
	-- The other overlays share the window, so any of them left open would draw over
	-- the settings we just asked for.
	ModMenuGui.helpOpen  = false
	ModMenuGui.helpPage  = 1
	ModMenuGui.bpOpen    = false
	ModMenuGui.apOpen    = false

	ModMenuGui.Open( owner, true )
	return true
end

function ModMenuGui.Open( owner, keepState )
    if owner.cl_modMenu ~= nil then
        return
    end


    local gui = sm.gui.createGuiFromLayout( LAYOUT, true )
    if gui == nil then
        sm.log.error( "[FoliageEraser] createGuiFromLayout returned nil for " .. LAYOUT )
        return
    end
    owner.cl_modMenu = gui

    gui:setOnCloseCallback( "cl_modMenuClosed" )

    for i = 1, MOD_ROWS do
        gui:setButtonCallback( "ModRow" .. i .. "Select", "cl_modMenuButton" )
        gui:setButtonCallback( "ModRow" .. i .. "Toggle", "cl_modMenuButton" )
        gui:setButtonCallback( "ModRow" .. i .. "Config", "cl_modMenuButton" )
    end
    for i = 1, CONFIG_ROWS do
        gui:setButtonCallback( "CfgRow" .. i .. "Dec",    "cl_modMenuButton" )
        gui:setButtonCallback( "CfgRow" .. i .. "Inc",    "cl_modMenuButton" )
        gui:setButtonCallback( "CfgRow" .. i .. "Toggle", "cl_modMenuButton" )
    end
    for i = 1, ACTION_SLOTS do
        gui:setButtonCallback( "ActionRow" .. i .. "Button", "cl_modMenuButton" )
    end
    gui:setButtonCallback( "Close", "cl_modMenuButton" )
    gui:setButtonCallback( "DetailMore", "cl_modMenuButton" )
    gui:setButtonCallback( "DetailBack", "cl_modMenuButton" )
    gui:setButtonCallback( "ModNext",    "cl_modMenuButton" )
    gui:setButtonCallback( "ModPrev",    "cl_modMenuButton" )
    gui:setButtonCallback( "CfgNext",    "cl_modMenuButton" )
    gui:setButtonCallback( "CfgPrev",    "cl_modMenuButton" )
    gui:setButtonCallback( "HelpClose", "cl_modMenuButton" )
    gui:setButtonCallback( "HelpNext", "cl_modMenuButton" )

    -- The three tabs across the top. TabMods has no page of its own to open - it is
    -- the default view - but it still needs a callback so clicking it comes BACK
    -- from wherever you are.
    gui:setButtonCallback( "TabMods",       "cl_modMenuButton" )
    gui:setButtonCallback( "TabBlueprints", "cl_modMenuButton" )
    gui:setButtonCallback( "TabAssets",     "cl_modMenuButton" )

    gui:setButtonCallback( "OpenBlueprints", "cl_modMenuButton" )
    gui:setButtonCallback( "BpClose",   "cl_modMenuButton" )
    gui:setButtonCallback( "BpNext",    "cl_modMenuButton" )
    gui:setButtonCallback( "BpConfirm", "cl_modMenuButton" )
    gui:setButtonCallback( "BpUndo",    "cl_modMenuButton" )
    -- These two were missing, which is why GET BUILDING TOOLS "did nothing" and
    -- LOG CREATION STATE produced no log: a button with no callback registered
    -- is completely inert, and it looks identical to a broken handler from the
    -- outside. Every Bp* button must be listed here.
    gui:setButtonCallback( "BpTools",   "cl_modMenuButton" )
    gui:setButtonCallback( "BpInspect", "cl_modMenuButton" )
    for i = 1, BP_ROWS do
        gui:setButtonCallback( "BpRow" .. i, "cl_modMenuButton" )
    end

    -- Asset packs page. EVERY Ap* button is listed, for the reason above: an
    -- unregistered callback is inert and indistinguishable from a broken handler.
    gui:setButtonCallback( "OpenAssets", "cl_modMenuButton" )
    gui:setButtonCallback( "ApClose",   "cl_modMenuButton" )
    gui:setButtonCallback( "ApConfirm", "cl_modMenuButton" )
    gui:setButtonCallback( "ApRescan",  "cl_modMenuButton" )
    gui:setButtonCallback( "ApPrev",    "cl_modMenuButton" )
    gui:setButtonCallback( "ApNext",    "cl_modMenuButton" )
    for i = 1, AP_ROWS do
        gui:setButtonCallback( "ApRow" .. i, "cl_modMenuButton" )
    end

    -- Always open on the mod LIST. Leaving modDetail set meant reopening /mods
    -- dropped you straight back inside a mod's settings.
    --
    -- Skipped entirely when reopening after an ESC step-back, or the unwind would be
    -- undone the instant it happened.
    if not keepState then
        ModMenuGui.modDetail = false
        ModMenuGui.modPage = 1
        ModMenuGui.cfgPage = 1
        ModMenuGui.helpOpen = false
        ModMenuGui.helpPage = 1
        ModMenuGui.bpOpen = false
        ModMenuGui.bpPage = 1
        ModMenuGui.bpSelected = nil
        ModMenuGui.apOpen = false
        ModMenuGui.apPage = 1
        ModMenuGui.apPicked = nil
        ModMenuGui.apRescan = false
        ModMenuGui.apHelpPage = 1
        SetStatus( nil )
    end
    gui:open()
    ModMenuGui.Refresh( owner )
end

--- ESC steps BACK one page instead of shutting the whole window.
--
-- The engine gives no way to veto a close: setOnCloseCallback only tells us it has
-- already happened. So the close is allowed, one level of state is unwound, and the
-- menu is reopened - which lands on the page above.
--
-- Only when there IS a page above. On the mod list ESC closes the window, as it
-- should: a menu you cannot escape with ESC would be far worse than one that closes
-- a level early.
--
-- Order matters and runs deepest-first, so ESC unwinds the same way BACK does:
--     help  ->  a mod's settings  ->  the mod list
--     a blueprint's warning  ->  the blueprint list  ->  the mod list
function ModMenuGui.OnClose( owner )
    owner.cl_modMenu = nil

    local stepped = false

    if ModMenuGui.helpOpen then
        ModMenuGui.helpOpen = false
        stepped = true
    elseif ModMenuGui.bpSelected ~= nil then
        ModMenuGui.bpSelected = nil
        stepped = true
    elseif ModMenuGui.apPicked ~= nil then
        ModMenuGui.apPicked = nil
        stepped = true
    elseif ModMenuGui.apRescan then
        ModMenuGui.apRescan = false
        ModMenuGui.apHelpPage = 1
        stepped = true
    elseif ModMenuGui.modDetail then
        ModMenuGui.modDetail = false
        stepped = true
    elseif ModMenuGui.bpOpen or ModMenuGui.apOpen then
        ModMenuGui.bpOpen = false
        ModMenuGui.apOpen = false
        stepped = true
    end

    if not stepped then return end

    -- Reopening from inside a close callback is the one part of this that is not
    -- obviously safe, so it is wrapped: if the engine refuses, the menu simply stays
    -- shut and ESC behaves as it always did, rather than the callback erroring.
    local ok, err = pcall( function() ModMenuGui.Open( owner, true ) end )
    if not ok then
        sm.log.error( "[ModMenu] could not step back on close: " .. tostring( err ) )
    end
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

-- Colours matching the game's own palette: amber for on, muted red for off.
local COLOUR_ON   = sm.color.new( 0.44, 0.80, 0.35 )
local COLOUR_OFF  = sm.color.new( 0.85, 0.35, 0.32 )

-- Hiding is done with setVisible rather than blanking the caption: an empty
-- button still draws its frame, which is what made the menu look like a grid of
-- mystery buttons.
local function Show( gui, name, visible )
    pcall( function() gui:setVisible( name, visible ) end )
end

-- Result of the last action button, shown in the footer line until the menu is
-- reopened. Not per-owner: only one mod menu can be on screen at a time.
--- Cut a help string down to one page, and say how many pages there are.
--
-- Splitting on newlines rather than measuring text is deliberate: every help
-- string in this project is written one array entry per line, already hard
-- wrapped to the panel width, so a line here is exactly a line on screen.
--
-- `page` is clamped rather than rejected. Selecting a shorter mod's help while
-- sitting on page 3 would otherwise paint an empty panel, and an empty panel
-- reads as a crash.
local function HelpPage( help, page )
    local lines = {}
    for line in string.gmatch( help .. "\n", "([^\n]*)\n" ) do
        lines[#lines + 1] = line
    end

    -- Even the pages out before slicing. Cutting at a flat 24 gave the Foliage
    -- Eraser 24 lines on page one and 6 on page two, which reads as a page that
    -- failed to load rather than a page that is simply short.
    local pageCount = math.max( 1, math.ceil( #lines / HELP_LINES_PER_PAGE ) )
    local target    = math.ceil( #lines / pageCount )

    local pages, first = {}, 1
    while first <= #lines do
        local last = math.min( first + target - 1, #lines )

        -- Then back up to a blank line, so a page always ends where a paragraph
        -- does. Without this the Height Adjuster broke directly after the
        -- heading WHAT LIFT MODE CHANGES, stranding it alone at the foot of page
        -- one with its explanation overleaf.
        if last < #lines then
            for i = last, first + 1, -1 do
                if lines[i] == "" then
                    last = i - 1
                    break
                end
            end
        end

        local out = {}
        for i = first, last do out[#out + 1] = lines[i] end
        pages[#pages + 1] = table.concat( out, "\n" )

        -- Swallow the blank line we broke on: a page should not open on a gap.
        first = last + 1
        while lines[first] == "" do first = first + 1 end
    end

    if #pages == 0 then return "", 1 end

    page = math.max( 1, math.min( page or 1, #pages ) )
    return pages[page], #pages
end

--- Hide the whole menu so a full-window page can be drawn over it.
--
-- Both the description page and the Workshop page need this, and they need it to
-- agree. Keeping one list means a widget added to the menu later cannot be hidden
-- by one page and left showing through the other.
--
-- Hide-only by design. Refresh repaints the rows on its way past, and PaintHelp
-- restores the static widgets, so nothing here needs a matching show.
local function HideMenuBehindPage( gui )
	-- Hint is in here because the Workshop page's UNDO button sits in the bottom
	-- left, exactly where the hint text runs, and the two were drawn on top of
	-- each other. Refresh shows it again on its way past.
	-- "Close" is NOT in here. Every tab keeps it, so the window can always be shut
	-- from wherever you are - having to step back to the mod list first was an odd
	-- dead end. The tabs stay visible for the same reason.
	local names = { "Divider", "DetailTitle", "DetailDesc", "DetailLine",
	                "ConfigHeader", "ActionLine", "ActionHeader",
	                "DetailMore", "DetailBack", "OpenBlueprints", "OpenAssets", "Hint",
	                -- The pagers belong to the mod list and the settings page. Left
	                -- showing, they floated in the middle of the Asset Packs page -
	                -- buttons for a list that was not on screen.
	                "ModPrev", "ModNext", "CfgPrev", "CfgNext" }
	for _, n in ipairs( names ) do Show( gui, n, false ) end

	for i = 1, MOD_ROWS do
		Show( gui, "ModRow" .. i .. "Select", false )
		Show( gui, "ModRow" .. i .. "Name",   false )
		Show( gui, "ModRow" .. i .. "Status", false )
		Show( gui, "ModRow" .. i .. "Toggle", false )
		Show( gui, "ModRow" .. i .. "Config", false )
		Show( gui, "ModRow" .. i .. "Line",   false )
	end
	for i = 1, CONFIG_ROWS do
		Show( gui, "CfgRow" .. i .. "Name",   false )
		Show( gui, "CfgRow" .. i .. "Value",  false )
		Show( gui, "CfgRow" .. i .. "Dec",    false )
		Show( gui, "CfgRow" .. i .. "Inc",    false )
		Show( gui, "CfgRow" .. i .. "Toggle", false )
		Show( gui, "CfgRow" .. i .. "Line",   false )
	end
	for i = 1, ACTION_SLOTS do
		Show( gui, "ActionRow" .. i .. "Name",   false )
		Show( gui, "ActionRow" .. i .. "Button", false )
	end
end

--- Is there anything on the Workshop page to show?
local function HaveBlueprints()
	return Blueprints ~= nil and Blueprints.Count() > 0
end

--- Paint the Workshop creations page, in whichever of its two states applies.
--
-- Like the description page, this HIDES the menu rather than covering it - the
-- panel skin is not opaque as a plain sibling. Called last in Refresh, after
-- PaintHelp, so between them they decide what the window actually shows.
--
-- Two states, one panel:
--   browsing   a row per creation, with its part count
--   confirming the warning for the one just picked, and a single button that
--              agrees and places in one go
function ModMenuGui.PaintBlueprints( gui )
	local open = ModMenuGui.bpOpen == true and HaveBlueprints()

	Show( gui, "OpenBlueprints", HaveBlueprints() and not open and not ModMenuGui.helpOpen )

	Show( gui, "BpPanel", open )
	Show( gui, "BpTitle", open )
	Show( gui, "BpClose", open )

	local confirming = open and ModMenuGui.bpSelected ~= nil
	Show( gui, "BpConfirm", confirming )

	-- Two text boxes, one visible at a time. The list's box is short because the rows
	-- sit under it; the warning's runs the full height because it has no rows and a
	-- dozen lines to say. Sharing one box meant the warning was silently cut off
	-- mid-sentence - MyGUI takes the text without complaint and just does not draw
	-- the overflow.
	Show( gui, "BpBody",     open and not confirming )
	Show( gui, "BpBodyFull", confirming )

	local list, pageCount = {}, 1
	if open then
		local all = Blueprints.All()
		pageCount = math.max( 1, math.ceil( #all / BP_ROWS ) )
		ModMenuGui.bpPage = math.max( 1, math.min( ModMenuGui.bpPage, pageCount ) )
		local first = ( ModMenuGui.bpPage - 1 ) * BP_ROWS + 1
		for i = first, math.min( first + BP_ROWS - 1, #all ) do
			list[#list + 1] = all[i]
		end
	end

	-- The rows are the list; they have no place on the warning.
	for i = 1, BP_ROWS do
		local entry = ( not confirming ) and list[i] or nil
		Show( gui, "BpRow" .. i, entry ~= nil )
		Show( gui, "BpRow" .. i .. "Line", entry ~= nil )
		Show( gui, "BpRow" .. i .. "Note", entry ~= nil )
		if entry then
			gui:setText( "BpRow" .. i, entry.name )
			-- Missing parts are the thing worth shouting about: the build will
			-- place with holes in it, and that is not obvious afterwards.
			if ( entry.missing or 0 ) > 0 then
				gui:setText( "BpRow" .. i .. "Note",
					string.format( "%d parts, %d MISSING", entry.parts or 0, entry.missing ) )
			else
				gui:setText( "BpRow" .. i .. "Note", string.format( "%d parts", entry.parts or 0 ) )
			end
		end
	end

	Show( gui, "BpNext", open and not confirming and pageCount > 1 )
	if open and not confirming and pageCount > 1 then
		gui:setText( "BpNext", ( ModMenuGui.bpPage < pageCount ) and "NEXT PAGE" or "START AGAIN" )
	end

	-- Only offered while browsing. On the warning it would sit next to a button
	-- that places a creation, which is a bad place for one that deletes one.
	Show( gui, "BpUndo", open and not confirming )
	Show( gui, "BpTools", open and not confirming )
	Show( gui, "BpInspect", open and not confirming )

	if not open then return end

	-- Hide the menu underneath, for the same reason the description page does:
	-- the panel skin is not opaque as a plain sibling, so without this the mod
	-- list shows straight through the creation list.
	--
	-- This runs AFTER PaintHelp, which has just re-shown all of these because the
	-- help page is closed. Order matters.
	HideMenuBehindPage( gui )

	if confirming then
		local entry = Blueprints.Get( ModMenuGui.bpSelected )
		local name  = entry and entry.name or "That creation"
		gui:setText( "BpTitle", name )

		local lines = {
			"THIS IS A CHEAT",
			"You are about to be handed a finished build that somebody else made. In",
			"Survival that skips every resource and every hour it would have cost to",
			"build it yourself. Nothing will stop you - just be sure it is what you want.",
			"",
			"It drops onto the ground a few steps in front of you. If something is in",
			"the way it is not placed at all, and you will be told so - nothing of",
			"yours is overwritten either way.",
			"",
			"Changed your mind? BACK leaves everything alone. If it lands somewhere",
			"unhelpful, the UNDO button on the list will take it straight back off you.",
		}

		if entry and ( entry.missing or 0 ) > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = string.format(
				"WARNING: %d of its %d parts are not installed. Those blocks will be",
				entry.missing, entry.parts or 0 )
			lines[#lines + 1] = "missing from the build. It probably came from a Workshop parts pack."
		end

		gui:setText( "BpBodyFull", table.concat( lines, "\n" ) )
	else
		gui:setText( "BpTitle", string.format( "Workshop creations   -   page %d of %d",
			ModMenuGui.bpPage, pageCount ) )

		local lines = {
			"Builds you are subscribed to on the Steam Workshop. Pick one to place it.",
			"",
			"Subscribing to something new? Run the installer again - the game cannot",
			"read the Workshop folder by itself, so this list is built when you install.",
		}

		-- The result of the last action, shown HERE rather than in the footer.
		--
		-- Every button on this page reports through the Hint widget, which this
		-- page hides - so pressing GET BUILDING TOOLS looked like it did nothing
		-- at all, when in fact its reply was written somewhere invisible.
		if ModMenuGui.status then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "> " .. ModMenuGui.status
		end

		gui:setText( "BpBody", table.concat( lines, "\n" ) )
	end
end

--- Is there anything on the asset packs page to show?
local function HavePartPacks()
	return PartPacks ~= nil and #PartPacks.All() > 0
end

--- Paint the Workshop asset packs page.
--
-- Same shape as the creations page - one panel, several states, menu hidden
-- underneath rather than covered - because they are the same kind of page and
-- behaving differently would be worse than the duplication.
--
-- Three states:
--   browsing    a row per pack, its part count, and whether it is on
--   confirming  the warning for a pack about to be turned OFF
--   rescan      how to get a newly subscribed pack to show up here
--
-- Only DISABLING asks for agreement. Turning a pack on adds parts and breaks
-- nothing; turning one off takes parts away from builds that already use them.
function ModMenuGui.PaintAssetPacks( gui )
	local open = ModMenuGui.apOpen == true

	Show( gui, "OpenAssets",
		HavePartPacks() and not open and not ModMenuGui.helpOpen and not ModMenuGui.bpOpen )

	Show( gui, "ApPanel", open )
	Show( gui, "ApTitle", open )
	Show( gui, "ApClose", open )

	local detail   = open and ModMenuGui.apPicked ~= nil
	local rescan   = open and not detail and ModMenuGui.apRescan == true
	local browsing = open and not detail and not rescan

	-- ApConfirm is the on/off switch, and it only appears on a pack's own page.
	--
	-- Shown ONLY for a pack this world actually loads. Offering it for a pack that is
	-- not here would be a switch that cannot do anything: what this controls is
	-- whether parts can be CRAFTED, and a pack the world never loaded has no parts
	-- here to craft. The page says so in words instead.
	local canToggle = false
	if detail and PartPacks ~= nil and PartPacks.IsLoadedHere ~= nil then
		canToggle = PartPacks.IsLoadedHere( ModMenuGui.apPicked ) == true
	end

	Show( gui, "ApConfirm", canToggle )
	if canToggle then
		local on = true
		if PartPacks.Cl_IsEnabled ~= nil then
			on = PartPacks.Cl_IsEnabled( ModMenuGui.apPicked ) ~= false
		end
		-- Labelled with what pressing it DOES, not with the current state. "SWITCH
		-- OFF" next to a pack that is on cannot be misread; "ON" next to one can.
		gui:setText( "ApConfirm", on and "SWITCH OFF" or "SWITCH ON" )
	end

	-- Relabelled at runtime. The layout still says "HOW TO ADD A NEW PACK", which
	-- described a narrower page than this now is - it covers Steam, the installer,
	-- the Asset Pack Installer program and the in-game switch.
	Show( gui, "ApRescan",  browsing )
	if browsing then
		gui:setText( "ApRescan", "HOW TO INSTALL PACKS" )
	end

	-- Hidden by default and switched on by whichever page below actually has more
	-- than one page. Doing it the other way round is how pagers leaked onto pages
	-- that did not need them once before.
	Show( gui, "ApPrev", false )
	Show( gui, "ApNext", false )

	-- The short body belongs to the list, where rows sit below it. The tall one
	-- belongs to the pages with no rows. Exactly one is ever visible, or the two
	-- would draw over each other.
	Show( gui, "ApBody",     browsing )
	Show( gui, "ApBodyFull", open and not browsing )

	local list, pageCount = {}, 1
	if browsing then
		-- ONLY packs this world loads. A pack that is not here has no parts here, so
		-- a switch against it could do nothing - it was padding the page with rows
		-- that looked broken. Installing into a world is the installer's job.
		local all = PartPacks.InstalledHere()
		pageCount = math.max( 1, math.ceil( #all / AP_ROWS ) )
		ModMenuGui.apPage = math.max( 1, math.min( ModMenuGui.apPage, pageCount ) )
		local first = ( ModMenuGui.apPage - 1 ) * AP_ROWS + 1
		for i = first, math.min( first + AP_ROWS - 1, #all ) do
			list[#list + 1] = all[i]
		end
	end

	for i = 1, AP_ROWS do
		local pack = list[i]
		Show( gui, "ApRow" .. i, pack ~= nil )
		Show( gui, "ApRow" .. i .. "Line", pack ~= nil )
		Show( gui, "ApRow" .. i .. "Note", pack ~= nil )
		if pack then
			-- Whether the pack is in THIS WORLD, asked of the game itself rather
			-- than guessed: the registry carries one sample part uuid per pack, and
			-- if the engine knows that part, the pack is loaded here.
			local hereNow = PartPacks.IsLoadedHere( pack.id )

			-- Laid out like the CONFIGURE tab, which is what these rows now behave
			-- like: the name on the button, its value in the column to the right.
			-- Every pack listed is in this world, so there is no third state to show.
			local on = true
			if PartPacks.Cl_IsEnabled ~= nil then
				on = PartPacks.Cl_IsEnabled( pack.id ) ~= false
			end

			gui:setText( "ApRow" .. i, tostring( pack.name ) )
			-- The part count used to live here. The value column is worth more as the
			-- pack's STATE, which is what the row is for, and the count is on the
			-- installer's own screen where it helps with the choosing.
			gui:setText( "ApRow" .. i .. "Note", on and "ON" or "OFF" )
		end
	end

	if not open then return end

	-- Hide the menu underneath. Same reason as everywhere else on this screen: the
	-- panel skin is not opaque as a plain sibling.
	HideMenuBehindPage( gui )

	if detail then
		local pack = PartPacks.Get( ModMenuGui.apPicked )
		gui:setText( "ApTitle", pack and pack.name or "That pack" )

		-- The switch lives on THIS page, so its reply has to appear on this page. The
		-- list page shows status the same way; without this, pressing the switch here
		-- would look like it did nothing.
		local body = PartPacks.PackText( ModMenuGui.apPicked )
		if ModMenuGui.status then
			body = body .. "\n\n> " .. ModMenuGui.status
		end
		gui:setText( "ApBodyFull", body )
	elseif rescan then
		-- Paged with the SAME helper the mod description pages use, so the guide
		-- breaks at a paragraph rather than mid-sentence, and so this page behaves
		-- like every other long page in the menu. Before this it simply ran off the
		-- bottom: MyGUI accepts overlong text and quietly declines to draw it.
		-- Ask for the count first, then clamp, then ask for the page. Requesting a
		-- page past the end returns nothing at all, which draws as a blank screen.
		local _, pageCount = HelpPage( PartPacks.RescanText(), 1 )
		ModMenuGui.apHelpPage = math.max( 1, math.min( ModMenuGui.apHelpPage, pageCount ) )

		local body = HelpPage( PartPacks.RescanText(), ModMenuGui.apHelpPage )

		local heading = "How to install asset packs"
		if pageCount > 1 then
			heading = string.format( "%s   -   page %d of %d",
				heading, ModMenuGui.apHelpPage, pageCount )
		end

		gui:setText( "ApTitle", heading )
		gui:setText( "ApBodyFull", body )

		Show( gui, "ApPrev", ModMenuGui.apHelpPage > 1 )
		Show( gui, "ApNext", ModMenuGui.apHelpPage < pageCount )
	else
		-- The page number appears ONLY when there is more than one page. "page 1 of 1"
		-- is noise, and it was sitting next to counts the box below then repeated -
		-- the same fact three times on one screen.
		local heading = "Asset packs in this world"
		if pageCount > 1 then
			heading = string.format( "%s   -   page %d of %d",
				heading, ModMenuGui.apPage, pageCount )
		end
		gui:setText( "ApTitle", heading )

		Show( gui, "ApPrev", ModMenuGui.apPage > 1 )
		Show( gui, "ApNext", ModMenuGui.apPage < pageCount )

		local body = PartPacks.ListText()

		-- Results are shown HERE, not in the footer: this page hides the Hint
		-- widget, and a reply written into a hidden widget looks like a button
		-- that did nothing. That exact bug cost a test cycle on the other page.
		if ModMenuGui.status then
			body = body .. "\n\n> " .. ModMenuGui.status
		end

		gui:setText( "ApBody", body )
	end
end

--- Show or hide the full-description page, and the button that opens it.
--
-- The page HIDES THE MENU rather than covering it. Drawing a panel over the top
-- was the obvious approach and it did not work: the background skin is not
-- opaque as a plain sibling widget, so the description landed on top of the mod
-- list and both were unreadable. Hiding what is underneath needs no skin to
-- behave, and it is what makes this read as a page rather than an overlay.
--
-- Called LAST in Refresh on purpose - it overrides whatever the rest of the
-- paint just decided to show.
function ModMenuGui.PaintHelp( gui, mod )
    local help = mod and ( mod.help or nil ) or nil
    local open = ModMenuGui.helpOpen == true and help ~= nil

    local pageText, pageCount = "", 1
    if open then
        pageText, pageCount = HelpPage( help, ModMenuGui.helpPage )
    end

    Show( gui, "DetailMore", help ~= nil and not open )

    Show( gui, "HelpPanel", open )
    Show( gui, "HelpTitle", open )
    Show( gui, "HelpBody",  open )
    Show( gui, "HelpClose", open )

    -- NEXT PAGE only exists when there IS a next page. On a one-page description
    -- it would just be a button that appears to do nothing.
    Show( gui, "HelpNext", open and pageCount > 1 )

    -- CLOSE stays, even while reading. It used to be hidden so a misclick could not
    -- shut the whole window, but now that every page keeps CLOSE, hiding it on one
    -- page is the surprising behaviour. BACK sits apart from it in the footer.
    Show( gui, "Close", true )

    -- SHOW as well as hide, BUT ONLY ON THE SETTINGS PAGE.
    --
    -- These are static widgets that nothing else in Refresh ever shows, so hiding
    -- them without a matching show hid them for good: after one visit to a help page
    -- a mod's title and description stayed blank until the menu was reopened.
    --
    -- The `modDetail` guard is what stops that fix causing a worse one. Showing them
    -- unconditionally drew the selected mod's title and description STRAIGHT OVER the
    -- mod list, because this runs on the list page too - which is exactly the
    -- overlapping text in the screenshot. They belong to the settings page and must
    -- only come back when that page is the one on screen.
    local onSettings = ModMenuGui.modDetail == true
    local menuWidgets = { "Divider", "DetailTitle", "DetailDesc", "DetailLine",
                          "ConfigHeader", "ActionLine" }
    for _, name in ipairs( menuWidgets ) do
        Show( gui, name, onSettings and not open )
    end

    -- Everything else this page covers is hidden by the shared helper, so the
    -- description page and the Workshop page cannot drift apart and leave a
    -- widget showing through one of them. ActionHeader is in there too: it is
    -- hide-only, because whether ACTIONS belongs on screen depends on the mod
    -- having any, which Refresh decides above.
    if open then HideMenuBehindPage( gui ) end

    if open then
        -- The page counter goes in the title so it is the first thing read, and
        -- it is left off entirely when there is only one page - "page 1 of 1"
        -- tells nobody anything.
        local title = mod.name or ""
        if pageCount > 1 then
            title = string.format( "%s   -   page %d of %d",
                title, ModMenuGui.helpPage, pageCount )
        end
        gui:setText( "HelpTitle", title )
        gui:setText( "HelpBody", pageText )
        gui:setText( "HelpNext", ( ModMenuGui.helpPage < pageCount ) and "NEXT PAGE" or "START AGAIN" )
    end
end

function ModMenuGui.Refresh( owner, params )
    local message = params and params.message or nil
    if message then
        SetStatus( message )
        -- With the menu closed the HUD alert is the only way to be seen. With it
        -- open the alert draws underneath and expires unread, which is the whole
        -- reason for the footer line below.
        if owner.cl_modMenu == nil then
            pcall( function() sm.gui.displayAlertText( message, 5 ) end )
        end
    end

    local gui = owner.cl_modMenu
    if gui == nil then return end

    local mods    = ModManager.VisibleMods()
    local enabled = 0
    for _, mod in ipairs( mods ) do
        if ModManager.Cl_IsEnabled( mod.id ) then enabled = enabled + 1 end
    end
    gui:setText( "ModCount", string.format( "%d installed, %d on", #mods, enabled ) )

    -- Version readouts exist for troubleshooting: when someone reports a problem,
    -- these are the two numbers worth knowing, and this saves asking them to go
    -- looking for either.
    gui:setText( "ManagerVersion", "Mod Manager v" .. tostring( ModManager.VERSION or "?" ) )

    -- Which tab is showing. Marked in the caption rather than by swapping skins,
    -- because a widget's skin is fixed in the layout and cannot be changed at
    -- runtime - so the highlight has to be something the text can carry.
    local onBlueprints = ModMenuGui.bpOpen == true
    local onAssets     = ModMenuGui.apOpen == true
    local onMods       = not onBlueprints and not onAssets
    pcall( function()
        gui:setText( "TabMods",       onMods       and "- MODS -"        or "MODS" )
        gui:setText( "TabBlueprints", onBlueprints and "- BLUEPRINTS -"  or "BLUEPRINTS" )
        gui:setText( "TabAssets",     onAssets     and "- ASSET PACKS -" or "ASSET PACKS" )
    end )

    -- The mod list and a mod's settings are two PAGES now, not two columns, so only
    -- one of them is on screen. This is what freed the list to use the full width.
    local listing = onMods and not ModMenuGui.modDetail

    -- Which slice of the list is on screen. Clamped rather than trusted: removing a
    -- mod while sitting on the last page would otherwise leave the page number past
    -- the end and the list looking empty.
    local modPages = math.max( 1, math.ceil( #mods / MOD_ROWS ) )
    ModMenuGui.modPage = math.max( 1, math.min( ModMenuGui.modPage, modPages ) )
    local modFirst = ( ModMenuGui.modPage - 1 ) * MOD_ROWS

    Show( gui, "ModPrev", listing and ModMenuGui.modPage > 1 )
    Show( gui, "ModNext", listing and ModMenuGui.modPage < modPages )

    for i = 1, MOD_ROWS do
        local mod  = mods[modFirst + i]
        local used = listing and mod ~= nil

        Show( gui, "ModRow" .. i .. "Name",   used )
        Show( gui, "ModRow" .. i .. "Status", used )
        Show( gui, "ModRow" .. i .. "Toggle", used )
        Show( gui, "ModRow" .. i .. "Config", used )
        -- The separator under each row, as the game's own option rows have. Hidden
        -- with its row, or a list of four mods trails eight lines into empty space.
        Show( gui, "ModRow" .. i .. "Line",   used )
        Show( gui, "ModRow" .. i .. "Select", false )

        if used then
            local on = ModManager.Cl_IsEnabled( mod.id )
            -- No "> " marker any more. It marked the row whose settings filled the
            -- right-hand column, and there is no such column - every row is equal
            -- until you open one.
            gui:setText( "ModRow" .. i .. "Name", mod.name )
            gui:setText( "ModRow" .. i .. "Status", on and "ON" or "OFF" )
            gui:setText( "ModRow" .. i .. "Toggle", on and "TURN OFF" or "TURN ON" )
            pcall( function()
                gui:setColor( "ModRow" .. i .. "Status", on and COLOUR_ON or COLOUR_OFF )
            end )
        end
    end

    -- The settings page's widgets, hidden unless it is open. Painted below as
    -- before; this just decides whether any of it is on screen.
    local showDetail = onMods and ModMenuGui.modDetail
    Show( gui, "DetailTitle", showDetail )
    Show( gui, "DetailDesc",  showDetail )
    Show( gui, "DetailMore",  showDetail )
    Show( gui, "DetailBack",  showDetail )
    if not showDetail then
        Show( gui, "ConfigHeader", false )
        Show( gui, "ActionHeader", false )
        -- Hidden HERE as well as inside the settings painting, which this branch
        -- skips entirely. Without it they kept whatever state they last had and
        -- appeared on the Blueprints and Asset Packs pages.
        Show( gui, "CfgPrev", false )
        Show( gui, "CfgNext", false )
        for i = 1, CONFIG_ROWS do
            Show( gui, "CfgRow" .. i .. "Name",   false )
            Show( gui, "CfgRow" .. i .. "Value",  false )
            Show( gui, "CfgRow" .. i .. "Dec",    false )
            Show( gui, "CfgRow" .. i .. "Inc",    false )
            Show( gui, "CfgRow" .. i .. "Toggle", false )
            Show( gui, "CfgRow" .. i .. "Line",   false )
        end
        for i = 1, ACTION_SLOTS do
            Show( gui, "ActionRow" .. i .. "Name",   false )
            Show( gui, "ActionRow" .. i .. "Button", false )
        end
        ModMenuGui.PaintHelp( gui, nil )
        ModMenuGui.PaintBlueprints( gui )
        ModMenuGui.PaintAssetPacks( gui )
        return
    end
    Show( gui, "ConfigHeader", true )

    -- Right: the selected mod's details and settings.
    local mod = SelectedMod()
    if mod == nil then
        gui:setText( "DetailTitle", "No mods installed" )
        gui:setText( "DetailDesc", "" )
        gui:setText( "ConfigHeader", "" )
        for i = 1, CONFIG_ROWS do
            Show( gui, "CfgRow" .. i .. "Name",   false )
            Show( gui, "CfgRow" .. i .. "Value",  false )
            Show( gui, "CfgRow" .. i .. "Dec",    false )
            Show( gui, "CfgRow" .. i .. "Inc",    false )
            Show( gui, "CfgRow" .. i .. "Toggle", false )
            Show( gui, "CfgRow" .. i .. "Line",   false )
        end
        Show( gui, "ActionHeader", false )
        for i = 1, ACTION_SLOTS do
            Show( gui, "ActionRow" .. i .. "Name", false )
            Show( gui, "ActionRow" .. i .. "Button", false )
        end
        ModMenuGui.PaintHelp( gui, nil )
        return
    end

    -- Version rides on the mod's name rather than sitting in its own column: on
    -- its own row it read as a stray label with the name repeated.
    -- A mod that declares no version simply shows its name -- third-party mods
    -- written against the older framework have no version field, and printing
    -- "v?" at the user would be noise.
    gui:setText( "DetailTitle",
        mod.version and ( mod.name .. "  v" .. tostring( mod.version ) ) or mod.name )
    gui:setText( "DetailDesc", mod.description or "" )
    -- NAME THE MOD IN THE HEADING.
    --
    -- A bare "SETTINGS" was fine when the only way here was to pick a mod from the
    -- list, because you had just chosen it. Right click now opens straight onto this
    -- page, so it can be the first thing on screen, and it has to say what it
    -- belongs to. Upper case to match the game's own section headers.
    local cfgTitle = string.upper( mod.name or "MOD" ) .. " SETTINGS"
    gui:setText( "ConfigHeader", ( #mod.options > 0 ) and cfgTitle or
        ( string.upper( mod.name or "MOD" ) .. " HAS NO SETTINGS" ) )

    -- Same slicing as the mod list. A mod with more settings than fit gets pages
    -- rather than losing them, which is what a third-party author needs: the manager
    -- must not put a ceiling on how configurable someone else's mod can be.
    local cfgPages = math.max( 1, math.ceil( #mod.options / CONFIG_ROWS ) )
    ModMenuGui.cfgPage = math.max( 1, math.min( ModMenuGui.cfgPage, cfgPages ) )
    local cfgFirst = ( ModMenuGui.cfgPage - 1 ) * CONFIG_ROWS

    Show( gui, "CfgPrev", ModMenuGui.cfgPage > 1 )
    Show( gui, "CfgNext", ModMenuGui.cfgPage < cfgPages )
    if cfgPages > 1 then
        gui:setText( "ConfigHeader", string.format( "%s   -   page %d of %d",
            cfgTitle, ModMenuGui.cfgPage, cfgPages ) )
    end

    for i = 1, CONFIG_ROWS do
        local option = mod.options[cfgFirst + i]

        if option == nil then
            Show( gui, "CfgRow" .. i .. "Name",   false )
            Show( gui, "CfgRow" .. i .. "Value",  false )
            Show( gui, "CfgRow" .. i .. "Dec",    false )
            Show( gui, "CfgRow" .. i .. "Inc",    false )
            Show( gui, "CfgRow" .. i .. "Toggle", false )
            Show( gui, "CfgRow" .. i .. "Line",   false )
        else
            local value    = ModManager.Cl_GetOption( mod.id, option.key )
            local isToggle = ( option.type == "bool" )

            Show( gui, "CfgRow" .. i .. "Name",   true )
            gui:setText( "CfgRow" .. i .. "Name", option.name )

            -- An on/off setting gets a single button showing its current state.
            -- A number gets its value plus minus/plus.
            Show( gui, "CfgRow" .. i .. "Toggle", isToggle )
            Show( gui, "CfgRow" .. i .. "Value",  not isToggle )
            Show( gui, "CfgRow" .. i .. "Dec",    not isToggle )
            Show( gui, "CfgRow" .. i .. "Inc",    not isToggle )

            if isToggle then
                gui:setText( "CfgRow" .. i .. "Toggle", value and "ON" or "OFF" )
            else
                gui:setText( "CfgRow" .. i .. "Value", FormatOption( option, value ) )
                gui:setText( "CfgRow" .. i .. "Dec", "-" )
                gui:setText( "CfgRow" .. i .. "Inc", "+" )
            end
        end
    end

    -- Shown explicitly, because the other pages hide it and nothing else would ever
    -- bring it back. Same trap that once left the mod title blank for good after a
    -- single visit to a help page.
    --
    -- NOT on the settings page. It sits on the footer line, where the last ACTIONS
    -- row now lives, and the two were printed on top of each other. The hint belongs
    -- to the list, which is where a player arrives and might not know about /mods.
    Show( gui, "Hint", not ModMenuGui.modDetail )

    if StatusExpired() then SetStatus( nil ) end
    if ModMenuGui.status then
        gui:setText( "Hint", ModMenuGui.status )
        pcall( function() gui:setColor( "Hint", sm.color.new( 1.0, 0.83, 0.29 ) ) end )
    else
        gui:setText( "Hint", DEFAULT_HINT )
        pcall( function() gui:setColor( "Hint", sm.color.new( 0.55, 0.55, 0.55 ) ) end )
    end

    -- This mod's own actions. `name` is a sentence explaining what it does and
    -- `button` is the short verb on the button itself. Cramming the whole label
    -- onto the button clipped it -- "CLEAR GHOST BEACONS" did not come close to
    -- fitting -- and left nowhere to say what it was for.
    Show( gui, "ActionHeader", #mod.actions > 0 )
    for i = 1, ACTION_SLOTS do
        local action = mod.actions[i]
        Show( gui, "ActionRow" .. i .. "Name", action ~= nil )
        Show( gui, "ActionRow" .. i .. "Button", action ~= nil )
        if action then
            gui:setText( "ActionRow" .. i .. "Name", action.name or "" )
            gui:setText( "ActionRow" .. i .. "Button", action.button or "RUN" )
        end
    end

    -- LAST, and it has to stay last. PaintHelp's job is to override whatever the
    -- rest of this function just decided to show, so anything painted after it
    -- puts its own widgets straight back on screen.
    --
    -- That is exactly what went wrong: this call used to sit above the settings
    -- loop, and the settings and action rows below re-showed themselves on top of
    -- the description. It looked correct only because the first mod it was tested
    -- on -- the Item Sorter -- has no settings and no actions, so there was
    -- nothing to re-show. The Foliage Eraser, with eight settings and a button,
    -- exposed it immediately.
    ModMenuGui.PaintHelp( gui, mod )

    -- Last of all. The Workshop pages cover the description page as well as the
    -- menu, so they have to have the final say on what is visible.
    --
    -- Blueprints first, then asset packs. Only one can be open at a time - each
    -- entry button hides while the other page is up - so the order only matters for
    -- who wins if a bug ever opened both, and the later call wins.
    ModMenuGui.PaintBlueprints( gui )
    ModMenuGui.PaintAssetPacks( gui )
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

function ModMenuGui.OnButton( owner, buttonName )
    if buttonName == "Close" then
        if owner.cl_modMenu then owner.cl_modMenu:close() end
        return
    end

    -- The full-description page. BACK returns to the menu rather than closing it,
    -- so reading about a mod does not lose your place.
    if buttonName == "DetailMore" then
        ModMenuGui.helpOpen = true
        ModMenuGui.helpPage = 1
        ModMenuGui.Refresh( owner )
        return
    end
    if buttonName == "HelpClose" then
        ModMenuGui.helpOpen = false
        ModMenuGui.helpPage = 1
        ModMenuGui.Refresh( owner )
        return
    end

    --------------------------------------------------------------------------
    -- Workshop creations
    --
    -- Handled before the generic "any other button closes the page" rule below,
    -- so the page's own buttons do not dismiss it.
    --------------------------------------------------------------------------
    if buttonName == "OpenBlueprints" then
        ModMenuGui.helpOpen = false
        ModMenuGui.bpOpen = true
        ModMenuGui.bpPage = 1
        ModMenuGui.bpSelected = nil
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "BpClose" then
        -- From the warning, BACK returns to the list rather than leaving the
        -- page: changing your mind about one creation is not a reason to lose
        -- your place in the list.
        if ModMenuGui.bpSelected ~= nil then
            ModMenuGui.bpSelected = nil
        else
            ModMenuGui.bpOpen = false
        end
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "BpNext" then
        ModMenuGui.bpPage = ModMenuGui.bpPage + 1
        local total = ( Blueprints and Blueprints.Count() ) or 0
        local pages = math.max( 1, math.ceil( total / BP_ROWS ) )
        if ModMenuGui.bpPage > pages then ModMenuGui.bpPage = 1 end
        ModMenuGui.Refresh( owner )
        return
    end

    local bpIndex = string.match( buttonName, "^BpRow(%d+)$" )
    if bpIndex then
        local all = ( Blueprints and Blueprints.All() ) or {}
        local i = ( ModMenuGui.bpPage - 1 ) * BP_ROWS + tonumber( bpIndex )
        local entry = all[i]
        if entry then
            ModMenuGui.bpSelected = entry.id
            ModMenuGui.Refresh( owner )
        end
        return
    end

    if buttonName == "BpConfirm" then
        local id = ModMenuGui.bpSelected
        ModMenuGui.bpSelected = nil
        if id then
            -- Agreeing and placing are one click here and two steps on the
            -- server; the consent is recorded per world before anything spawns.
            owner.network:sendToServer( "sv_modAction",
                { modId = ModManager.BLUEPRINT_MOD_ID, actionKey = id } )
        end
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "BpUndo" then
        owner.network:sendToServer( "sv_modAction",
            { modId = ModManager.BLUEPRINT_MOD_ID, actionKey = "__remove" } )
        return
    end

    if buttonName == "BpTools" then
        owner.network:sendToServer( "sv_modAction",
            { modId = ModManager.BLUEPRINT_MOD_ID, actionKey = "__tools" } )
        return
    end

    if buttonName == "BpInspect" then
        owner.network:sendToServer( "sv_modAction",
            { modId = ModManager.BLUEPRINT_MOD_ID, actionKey = "__inspect" } )
        return
    end

    ----------------------------------------------------------------------------
    -- Workshop asset packs page
    ----------------------------------------------------------------------------

    ----------------------------------------------------------------------------
    -- The tabs
    --
    -- Each one closes whatever else is open and shows its own section, so a tab
    -- always means the same thing wherever you press it. MODS is the default view,
    -- so it simply closes the others.
    ----------------------------------------------------------------------------

    if buttonName == "TabMods" then
        ModMenuGui.bpOpen    = false
        ModMenuGui.apOpen    = false
        ModMenuGui.helpOpen  = false
        -- Also steps out of a mod's settings, so MODS always means "the mod list"
        -- no matter how deep you are.
        ModMenuGui.modDetail = false
        SetStatus( nil )
        ModMenuGui.Refresh( owner )
        return
    end

    -- Paging STEPS, it no longer wraps. A single wrapping button meant that on page
    -- three of three the only way back to page two was all the way round. Each button
    -- is hidden at the end it cannot pass, so clamping here is enough.
    if buttonName == "ModNext" or buttonName == "ModPrev" then
        local pages = math.max( 1, math.ceil( #ModManager.VisibleMods() / MOD_ROWS ) )
        local step  = ( buttonName == "ModNext" ) and 1 or -1
        ModMenuGui.modPage = math.max( 1, math.min( ModMenuGui.modPage + step, pages ) )
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "CfgNext" or buttonName == "CfgPrev" then
        local mod   = SelectedMod()
        local pages = math.max( 1, math.ceil( ( ( mod and #mod.options ) or 0 ) / CONFIG_ROWS ) )
        local step  = ( buttonName == "CfgNext" ) and 1 or -1
        ModMenuGui.cfgPage = math.max( 1, math.min( ModMenuGui.cfgPage + step, pages ) )
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "DetailBack" then
        ModMenuGui.modDetail = false
        SetStatus( nil )
        ModMenuGui.Refresh( owner )
        return
    end

    local cfgIndex = string.match( buttonName, "^ModRow(%d+)Config$" )
    if cfgIndex then
        -- Row number PLUS the page offset. On page two this would otherwise open
        -- the settings for the wrong mod entirely.
        local idx = ( ModMenuGui.modPage - 1 ) * MOD_ROWS + tonumber( cfgIndex )
        local mod = ModManager.VisibleMods()[idx]
        if mod then
            ModMenuGui.selected  = idx
            ModMenuGui.cfgPage   = 1
            ModMenuGui.modDetail = true
            ModMenuGui.helpPage  = 1
            SetStatus( nil )
            ModMenuGui.Refresh( owner )
        end
        return
    end

    if buttonName == "TabBlueprints" then
        ModMenuGui.apOpen   = false
        ModMenuGui.helpOpen = false
        ModMenuGui.bpOpen   = true
        ModMenuGui.bpPage   = 1
        ModMenuGui.bpSelected = nil
        SetStatus( nil )
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "TabAssets" then
        ModMenuGui.bpOpen   = false
        ModMenuGui.helpOpen = false
        ModMenuGui.apOpen   = true
        ModMenuGui.apPage   = 1
        ModMenuGui.apPicked = nil
        ModMenuGui.apRescan = false
        ModMenuGui.apHelpPage = 1
        SetStatus( nil )
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "OpenAssets" then
        ModMenuGui.apOpen   = true
        ModMenuGui.apPage   = 1
        ModMenuGui.apPicked = nil
        ModMenuGui.apRescan = false
        ModMenuGui.apHelpPage = 1
        SetStatus( nil )
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "ApClose" then
        -- BACK steps out of a sub-page first rather than closing the whole thing,
        -- so opening a pack's detail by accident is one press from undone.
        if ModMenuGui.apPicked ~= nil then
            ModMenuGui.apPicked = nil
        elseif ModMenuGui.apRescan then
            ModMenuGui.apRescan = false
        ModMenuGui.apHelpPage = 1
        else
            ModMenuGui.apOpen = false
        end
        ModMenuGui.Refresh( owner )
        return
    end

    if buttonName == "ApConfirm" then
        -- Switch this pack on or off for this world. The server owns the state and
        -- syncs it back, so the page is NOT redrawn from a guess here - the reply
        -- arrives as a status message and the redraw reads the real value.
        if ModMenuGui.apPicked ~= nil then
            owner.network:sendToServer( "sv_modAction",
                { modId = ModManager.PARTPACK_MOD_ID, actionKey = ModMenuGui.apPicked } )
        end
        return
    end

    if buttonName == "ApRescan" then
        ModMenuGui.apRescan = true
        -- Always open the guide at page one, however it was left last time.
        ModMenuGui.apHelpPage = 1
        ModMenuGui.Refresh( owner )
        return
    end

    -- One pair of pagers serving two pages. Which one they step depends on where you
    -- are, because the guide and the pack list are never on screen together.
    if buttonName == "ApNext" or buttonName == "ApPrev" then
        local step = ( buttonName == "ApNext" ) and 1 or -1

        if ModMenuGui.apRescan then
            ModMenuGui.apHelpPage = math.max( 1, ModMenuGui.apHelpPage + step )
        else
            ModMenuGui.apPage = math.max( 1, ModMenuGui.apPage + step )
        end

        -- Only the lower bound is clamped here. The upper one is applied by the
        -- paint, which is the only place that knows how many pages there are, and
        -- NEXT is hidden on the last page regardless.
        ModMenuGui.Refresh( owner )
        return
    end

    local apIndex = string.match( buttonName, "^ApRow(%d+)$" )
    if apIndex then
        -- The ROW is the switch, exactly like a yes/no row on the CONFIGURE tab.
        -- Opening a detail page first to reach a button was a click and a page for
        -- something that is simply on or off.
        local all  = ( PartPacks and PartPacks.InstalledHere() ) or {}
        local i    = ( ModMenuGui.apPage - 1 ) * AP_ROWS + tonumber( apIndex )
        local pack = all[i]
        if pack then
            owner.network:sendToServer( "sv_modAction",
                { modId = ModManager.PARTPACK_MOD_ID, actionKey = pack.id } )
        end
        return
    end

    -- NEXT PAGE wraps back to the first page instead of greying out at the end.
    -- The button relabels itself to START AGAIN on the last page, so the wrap is
    -- announced rather than surprising, and there is no dead control on screen.
    if buttonName == "HelpNext" then
        ModMenuGui.helpPage = ModMenuGui.helpPage + 1
        local mod = SelectedMod()
        if mod and mod.help then
            local _, pageCount = HelpPage( mod.help, 1 )
            if ModMenuGui.helpPage > pageCount then ModMenuGui.helpPage = 1 end
        else
            ModMenuGui.helpPage = 1
        end
        ModMenuGui.Refresh( owner )
        return
    end

    -- Any other button means the reader has moved on; never leave a page up over
    -- a menu the player is now driving underneath. Page numbers reset with it, so
    -- the next thing opened always starts at the beginning.
    ModMenuGui.helpOpen = false
    ModMenuGui.helpPage = 1
    ModMenuGui.bpOpen = false
    ModMenuGui.bpPage = 1
    ModMenuGui.bpSelected = nil

    -- Action buttons belong to the selected mod, so a mod's buttons disappear
    -- along with the mod rather than living permanently in the manager.
    local actionIndex = string.match( buttonName, "^ActionRow(%d+)Button$" )
    if actionIndex then
        local mod = SelectedMod()
        if mod == nil then return end
        local action = mod.actions[tonumber( actionIndex )]
        if action == nil then return end

        -- Two dispatch routes.
        --
        -- Preferred: the mod gives the action a `run` function, and every button
        -- travels through the one generic "sv_modAction" handler, which each
        -- menu owner already has. A mod needs no game-file patching for its
        -- buttons to work -- which is what makes third-party mods possible at
        -- all. Before this, an action's `network` name had to exist as a method
        -- on SurvivalGame and SurvivalPlayer, so only mods shipped with the
        -- installer could have working buttons.
        --
        -- Legacy: an explicit `network` name, still honoured for any mod that
        -- provides its own handler.
        -- runClient executes HERE, on the client, touching no network. It
        -- exists because some of the game's power is client-only - sm.camera
        -- above all - and a server-run action can never reach it. First user:
        -- the Map Viewer's bird's-eye toggle.
        if action.runClient ~= nil then
            local okc, msg = pcall( action.runClient, sm.localPlayer.getPlayer() )
            if not okc then
                sm.log.error( "[ModMenu] client action '" .. tostring( action.key ) .. "' failed: " .. tostring( msg ) )
                msg = "That action hit an error - see the log."
            end
            if type( msg ) == "string" then
                ModMenuGui.actionResult = msg
            end
            ModMenuGui.Refresh( owner )
        elseif action.run ~= nil then
            owner.network:sendToServer( "sv_modAction", { modId = mod.id, actionKey = action.key } )
        elseif action.network ~= nil then
            owner.network:sendToServer( action.network, { modId = mod.id } )
        end
        return
    end

    -- Left-hand list: select a mod, or toggle it on/off.
    local modIndex, modAction = string.match( buttonName, "^ModRow(%d+)(%a+)$" )
    if modIndex then
        -- Same offset. Toggling a row on page two must toggle the mod on page two.
    local mod = ModManager.VisibleMods()[( ModMenuGui.modPage - 1 ) * MOD_ROWS + tonumber( modIndex )]
        if mod == nil then return end

        if modAction == "Select" then
            -- Drop the previous result: it belonged to the mod being left, and
            -- reading it under a different mod's settings is misleading.
            if ModMenuGui.selected ~= tonumber( modIndex ) then SetStatus( nil ) end
            ModMenuGui.selected = tonumber( modIndex )
            ModMenuGui.Refresh( owner )
        elseif modAction == "Toggle" then
            ModMenuGui.selected = tonumber( modIndex )
            owner.network:sendToServer( "sv_setModOption", {
                modId = mod.id,
                key   = "__enabled",
                value = not ModManager.Cl_IsEnabled( mod.id )
            } )
        end
        return
    end

    -- Right-hand settings.
    local cfgIndex, cfgAction = string.match( buttonName, "^CfgRow(%d+)(%a+)$" )
    if cfgIndex == nil then return end

    local mod = SelectedMod()
    if mod == nil then return end

    -- The ROW number plus the page offset, not the row number alone. Without the
    -- offset, clicking the first row on page two would edit the first setting on page
    -- one - a control that silently changes something other than the thing next to it,
    -- which is worse than one that does nothing at all.
    local option = mod.options[( ModMenuGui.cfgPage - 1 ) * CONFIG_ROWS + tonumber( cfgIndex )]
    if option == nil then return end

    local newValue

    if option.type == "bool" then
        -- One button that flips the current value, rather than separate ON and
        -- OFF buttons where neither looks like the active state.
        if cfgAction ~= "Toggle" then return end
        newValue = not ( ModManager.Cl_GetOption( mod.id, option.key ) == true )
    else
        if cfgAction ~= "Inc" and cfgAction ~= "Dec" then return end
        local step  = option.step or 1
        local value = ( ModManager.Cl_GetOption( mod.id, option.key ) or 0 )
                      + ( ( cfgAction == "Inc" ) and step or -step )
        if option.min and value < option.min then value = option.min end
        if option.max and value > option.max then value = option.max end
        newValue = value
    end

    owner.network:sendToServer( "sv_setModOption", {
        modId = mod.id,
        key   = option.key,
        value = newValue
    } )
end
