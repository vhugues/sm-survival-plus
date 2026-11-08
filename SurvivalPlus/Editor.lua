-- Survival + / Editor.lua
--
-- Fenetre d'edition. Les lignes sont construites ici, puis envoyees a sm.jsonGui.

local SP = SurvivalPlus
local log, num, int, str = SP.log, SP.num, SP.int, SP.str

--------------------------------------------------------------------------------
-- Fenetre. Les lignes sont construites ici, puis envoyees a sm.jsonGui.
--------------------------------------------------------------------------------

function SP.ClientEnsure( self )
	self.cl = self.cl or {}
	if self.cl.sp == nil then
		self.cl.sp = {
			screen = "profiles",
			profileId = "",
			source = "",
			roll = 1,
			profilePage = 1,
			sourcePage = 1,
			rowPage = 1,
			catalogPage = 1,
			search = "",
			sourceSearch = "",
			sourceGroup = "",
			draftName = "",
			editItem = "",
			editOccurrence = 0,
			editAdd = "",
			buttons = {},
			view = {},
		}
	end
	return self.cl.sp
end

function SP.ClientParams( self, cmd, extra )
	local state = SP.ClientEnsure( self )
	state.req = ( state.req or 0 ) + 1
	local params = {
		cmd = cmd or "state",
		req = state.req,
		profileId = state.profileId or "",
		source = state.source or "",
		roll = state.roll or 1,
		search = state.search or "",
		catalogPage = state.catalogPage or 1,
		name = state.draftName or "",
		editItem = state.editItem or "",
		editOccurrence = state.editOccurrence or 0,
		editAdd = state.editAdd or "",
		wantCatalog = state.screen == "add",
	}
	if type( extra ) == "table" then
		for key, value in pairs( extra ) do
			if key ~= "localCmd" and key ~= "screen" and key ~= "cmd" then
				params[key] = value
			end
		end
	end
	return params
end

function SP.ClientOpen( self )
	SP.InstallRuntimeHooks()
	local state = SP.ClientEnsure( self )
	if self.cl.spGui == nil and sm.jsonGui and sm.jsonGui.createGui then
		local ok, gui = pcall( sm.jsonGui.createGui, { isInteractive = true, bNeedsCursor = true } )
		if ok and gui ~= nil then
			self.cl.spGui = gui
			log( "creation de la fenetre" )
			pcall( function() gui:setOnCloseCallback( "cl_spClosed" ) end )
		else
			log( "creation de la fenetre en echec:", gui )
		end
	end
	if self.cl.spGui == nil then return end
	SP.ClientRender( self, state.view or {} )
	self.network:sendToServer( "sv_survivalPlus", SP.ClientParams( self, "state" ) )
end

function SP.ClientState( self, data )
	if type( data ) ~= "table" then return end
	local state = SP.ClientEnsure( self )
	if type( data.req ) == "number" and type( state.req ) == "number" and data.req > 0 and data.req < state.req then
		return
	end
	state.view = data
	if type( data.profileId ) == "string" then state.profileId = data.profileId end
	if type( data.source ) == "string" then state.source = data.source end
	if type( data.roll ) == "number" then state.roll = data.roll end
	if type( data.screen ) == "string" and data.screen ~= "" then state.screen = data.screen end
	if data.clearEdit == true then
		state.screen = data.screen or "editor"
		state.editItem = ""
		state.editOccurrence = 0
		state.editAdd = ""
	end
	if self.cl.spGui == nil then
		SP.ClientOpen( self )
		return
	end
	SP.ClientRender( self, data )
end

function SP.ClientClick( self, name )
	local state = self.cl and self.cl.sp
	if state == nil or state.buttons == nil then return end
	local action = state.buttons[name]
	if action == nil then return end

	if action.profileId ~= nil then state.profileId = action.profileId end
	if action.source ~= nil then state.source = action.source end
	if action.roll ~= nil then state.roll = action.roll end
	if action.profilePage ~= nil then state.profilePage = action.profilePage end
	if action.sourcePage ~= nil then state.sourcePage = action.sourcePage end
	if action.sourceGroup ~= nil then state.sourceGroup = action.sourceGroup end
	if action.sourceSearch ~= nil then state.sourceSearch = action.sourceSearch end
	if action.rowPage ~= nil then state.rowPage = action.rowPage end
	if action.catalogPage ~= nil then state.catalogPage = action.catalogPage end
	if action.search ~= nil then state.search = action.search end
	if action.editItem ~= nil then state.editItem = action.editItem end
	if action.editOccurrence ~= nil then state.editOccurrence = action.editOccurrence end
	if action.editAdd ~= nil then state.editAdd = action.editAdd end
	if action.screen ~= nil then state.screen = action.screen end

	if action.localCmd == "close" then
		if self.cl.spGui ~= nil then pcall( function() self.cl.spGui:close() end ) end
		self.cl.spGui = nil
		return
	end
	if action.localCmd == "render" then
		SP.ClientRender( self, state.view or {} )
		return
	end
	self.network:sendToServer( "sv_survivalPlus", SP.ClientParams( self, action.cmd or "state", action ) )
end

function SP.ClientDraft( self, name, text )
	local state = self.cl and self.cl.sp
	if state == nil then return end
	text = text or ""
	if name == "profileName" then state.draftName = text end
	if name == "search" then state.search = text end
	if name == "sourceSearch" then state.sourceSearch = text end
end

function SP.ClientText( self, name, text )
	local state = self.cl and self.cl.sp
	if state == nil then return end
	text = text or ""
	if name == "profileName" then
		state.draftName = text
		self.network:sendToServer( "sv_survivalPlus", SP.ClientParams( self, "create", { name = text } ) )
	elseif name == "search" then
		state.search = text
		state.catalogPage = 1
		self.network:sendToServer( "sv_survivalPlus", SP.ClientParams( self, "state" ) )
	elseif name == "sourceSearch" then
		state.sourceSearch = text
		state.sourcePage = 1
		SP.ClientRender( self, state.view or {} )
	elseif name == "weight" or name == "qtyMin" or name == "qtyMax" then
		local value = tonumber( text )
		if value == nil then return end
		local extra = {}
		extra[name] = value
		self.network:sendToServer( "sv_survivalPlus", SP.ClientParams( self, "set", extra ) )
	end
end

function SP.ClientRender( self, data )
	if self.cl == nil or self.cl.spGui == nil then return end
	local state = SP.ClientEnsure( self )
	data = data or {}
	if state.screen == "edit" then state.screen = "editor" end
	local buttons = {}
	local seq = 0

	local function widgetName( prefix )
		seq = seq + 1
		return prefix .. tostring( seq )
	end

	local function label( caption, width, align, colour, font )
		local widget = {
			Type = "TextBox", Skin = "TextBox", Name = widgetName( "t" ),
			Caption = tostring( caption or "" ), FontName = font or "SM_HeaderTiny",
			TextAlign = align or "Left", NeedKey = false, NeedMouse = false,
			Childs = {}, width = width, height = 22, x = 0, y = 0,
		}
		if colour ~= nil then widget.TextColour = colour end
		return widget
	end

	local function button( caption, width, action, skin )
		local name = widgetName( "b" )
		buttons[name] = action
		return {
			Type = "Button", Skin = skin or "SecondaryButton", Name = name,
			Caption = tostring( caption or "" ), FontName = "SM_Button",
			TextAlign = "Center", NeedKey = true, NeedMouse = true,
			onClick = "cl_spClick", Childs = {},
			width = width, height = 26, x = 0, y = 0,
		}
	end

	local function editBox( name, caption, width )
		return {
			Type = "EditBox", Skin = "EditBoxEmpty", Name = name,
			Caption = tostring( caption or "" ), FontName = "SM_HeaderTiny",
			TextAlign = "Left", NeedKey = true, NeedMouse = true,
			MaxTextLength = 40, onTextEdit = "cl_spDraft", onTextEnter = "cl_spText",
			Childs = {}, width = width, height = 24, x = 0, y = 0,
		}
	end

	local function row( children, width, height )
		return {
			Type = "Widget", Skin = "PanelEmpty", Name = widgetName( "h" ),
			LayoutRule = "Horizontal", NeedMouse = true, NeedKey = false,
			Childs = children, width = width or 720, height = height or 28, x = 0, y = 0,
		}
	end

	local function column( children, width, height )
		return {
			Type = "Widget", Skin = "PanelEmpty", Name = widgetName( "v" ),
			LayoutRule = "Vertical", NeedMouse = true, NeedKey = false,
			Childs = children, width = width, height = height or 400, x = 0, y = 0,
		}
	end

	local function spacer( width, height )
		if width < 1 then width = 1 end
		return {
			Type = "Widget", Skin = "PanelEmpty", Name = widgetName( "s" ),
			NeedKey = false, NeedMouse = false, Childs = {},
			width = width, height = height or 22, x = 0, y = 0,
		}
	end

	local function iconOf( itemId )
		if type( itemId ) ~= "string" or itemId == "" or itemId == "none" then return nil end
		if string.sub( itemId, 1, 6 ) == "table:" then return nil end
		if sm.gui == nil or sm.gui.getItemIconFromUuid == nil or sm.uuid == nil then return nil end
		local parsedOk, uuid = pcall( sm.uuid.new, itemId )
		if not parsedOk or uuid == nil then return nil end
		local iconOk, resource, group, image = pcall( sm.gui.getItemIconFromUuid, uuid )
		if not iconOk or type( resource ) ~= "string" or resource == "" then return nil end
		return {
			Type = "ImageBox", Skin = "ImageBox", Name = widgetName( "i" ),
			NeedKey = false, NeedMouse = false, Childs = {},
			ImageResource = resource, ImageGroup = group or "", ImageName = image or "",
			width = 22, height = 22, x = 0, y = 0,
		}
	end

	local function iconSlot( itemId )
		local icon = iconOf( itemId )
		if icon then return icon end
		return spacer( 22, 22 )
	end

	local function pager( page, pages, keyName, width, remote )
		local function step( value )
			local action = {}
			if remote then action.cmd = "state" else action.localCmd = "render" end
			action[keyName] = value
			return action
		end
		if pages <= 1 then
			return label( string.format( "%d / %d", page, pages ), width or 160, "Left", "1 1 1 0.55" )
		end
		local children = {}
		if page > 1 then children[#children + 1] = button( "Prec.", 64, step( page - 1 ) ) end
		children[#children + 1] = label( string.format( "%d / %d", page, pages ), 70, "Center" )
		if page < pages then children[#children + 1] = button( "Suiv.", 64, step( page + 1 ) ) end
		return row( children, width or 220, 28 )
	end

	local function fitCount( height, chrome )
		local count = math.floor( ( height - chrome ) / 28 )
		if count < 4 then count = 4 end
		if count > 16 then count = 16 end
		return count
	end

	local function clipCount( width )
		local count = math.floor( width / 8 )
		if count < 8 then count = 8 end
		if count > 48 then count = 48 end
		return count
	end

	local stateColour = {
		modifie = "1 0.82 0.35 1",
		ajoute = "0.45 0.95 0.55 1",
		supprime = "1 0.45 0.42 1",
		orphelin = "0.75 0.55 1 1",
	}

	local function stateWord( kind )
		if kind == nil or kind == "" or kind == "inchange" then return "" end
		return SP.StateLabel( kind )
	end

	local function editMatches( edit )
		if type( edit ) ~= "table" then return false end
		if ( state.editAdd or "" ) ~= "" then
			return ( edit.addId or "" ) == state.editAdd
		end
		if ( state.editItem or "" ) == "" then return false end
		return edit.item == state.editItem and ( edit.occurrence or 0 ) == ( state.editOccurrence or 0 )
	end

	local function rowOpen( entry )
		if ( state.editAdd or "" ) ~= "" then
			return ( entry.addId or "" ) == state.editAdd
		end
		if ( state.editItem or "" ) == "" then return false end
		return entry.item == state.editItem and ( entry.occurrence or 0 ) == ( state.editOccurrence or 0 )
	end

	local viewW, viewH = 1280, 720
	if sm.jsonGui ~= nil and sm.jsonGui.getViewSize ~= nil then
		local sizeOk, width, height = pcall( sm.jsonGui.getViewSize )
		if sizeOk and type( width ) == "number" and type( height ) == "number" and width > 200 and height > 200 then
			viewW, viewH = width, height
		end
	end
	local winW = math.floor( math.min( 1040, viewW - 32 ) )
	local winH = math.floor( math.min( 680, viewH - 24 ) )
	local barW = winW - 24

	local children = {}
	local ready = type( data.profiles ) == "table"
	local titleGap = barW - 300
	if titleGap < 1 then titleGap = 1 end
	children[#children + 1] = row( {
		label( "Survival +", 200, "Left", nil, "SM_GameName" ),
		spacer( titleGap, 22 ),
		button( "Fermer", 100, { localCmd = "close" } ),
	}, barW, 28 )

	if not ready then
		children[#children + 1] = label( "Chargement des profils de ce monde...", barW, "Left" )
	elseif state.screen == "profiles" then
		local activeName = "aucun, le loot reste vanilla"
		for _, profile in ipairs( data.profiles ) do
			if profile.active then activeName = profile.name end
		end
		children[#children + 1] = label( "Profil actif : " .. activeName, barW, "Left", nil, "SM_Label" )
		if data.enabled == false then
			children[#children + 1] = label( "Mod désactivé : les drops restent vanilla.", barW, "Left" )
		end
		if data.notice ~= nil and data.notice ~= "" then
			children[#children + 1] = label( data.notice, barW, "Left" )
		end
		local nameW = barW - 112
		if nameW < 1 then nameW = 1 end
		children[#children + 1] = row( {
			editBox( "profileName", state.draftName or "", nameW ),
			button( "Créer", 100, { cmd = "create" }, "PrimaryButton" ),
		}, barW, 28 )
		local slice, page, pages = SP.PageSlice( data.profiles, state.profilePage or 1, SP.PAGE )
		state.profilePage = page
		if #data.profiles == 0 then
			children[#children + 1] = label( "Aucun profil. Créez-en un pour commencer.", barW, "Left" )
		end
		local actionW = 100
		local profileW = barW - ( actionW * 3 ) - 12
		if profileW < 1 then profileW = 1 end
		for _, profile in ipairs( slice ) do
			local mark = profile.active and "* " or ""
			children[#children + 1] = row( {
				button( SP.Clip( mark .. profile.name .. " (" .. tostring( profile.count ) .. ")", clipCount( profileW ) ), profileW, {
					cmd = "state", screen = "editor", profileId = profile.id, source = "", roll = 1, rowPage = 1,
					editItem = "", editOccurrence = 0, editAdd = "",
				} ),
				button( profile.active and "Désactiver" or "Activer", actionW, { cmd = "activate", targetId = profile.id } ),
				button( "Dupliquer", actionW, { cmd = "duplicate", targetId = profile.id } ),
				button( "Supprimer", actionW, { cmd = "delete", targetId = profile.id } ),
			}, barW, 28 )
		end
		children[#children + 1] = pager( page, pages, "profilePage", barW, false )
	elseif state.screen == "add" then
		children[#children + 1] = label( "Ajouter une ligne au tirage " .. tostring( state.roll or 1 ), barW, "Left", nil, "SM_Label" )
		local searchW = barW - 112
		if searchW < 1 then searchW = 1 end
		children[#children + 1] = row( {
			editBox( "search", state.search or "", searchW ),
			button( "Chercher", 100, { cmd = "state", catalogPage = 1 } ),
		}, barW, 28 )
		local catalog = data.catalog or {}
		if #catalog == 0 then
			children[#children + 1] = label( "Aucun objet pour cette recherche.", barW, "Left" )
		end
		local half = math.floor( ( barW - 8 ) / 2 )
		local index = 1
		while index <= #catalog do
			local line = {}
			local function place( entry )
				local icon = iconOf( entry.item )
				local buttonW = half - 4
				if icon then
					line[#line + 1] = icon
					buttonW = half - 28
				end
				line[#line + 1] = button( SP.Clip( entry.label, clipCount( buttonW ) ), buttonW, {
					cmd = "add", item = entry.item, screen = "editor",
				} )
			end
			place( catalog[index] )
			if catalog[index + 1] ~= nil then place( catalog[index + 1] ) end
			children[#children + 1] = row( line, barW, 28 )
			index = index + 2
		end
		local page = data.catalogPage or 1
		local pages = data.catalogPages or 1
		local nav = {}
		if page > 1 then nav[#nav + 1] = button( "Prec.", 64, { cmd = "state", catalogPage = page - 1 } ) end
		local countText = string.format( "%d / %d", page, pages )
		if type( data.catalogCount ) == "number" then
			countText = countText .. "   " .. tostring( data.catalogCount )
		end
		nav[#nav + 1] = label( countText, 160, "Center" )
		if page < pages then nav[#nav + 1] = button( "Suiv.", 64, { cmd = "state", catalogPage = page + 1 } ) end
		children[#children + 1] = row( nav, barW, 28 )
		children[#children + 1] = button( "Retour", 100, { localCmd = "render", screen = "editor" } )
	else
		local profileName = "Profil"
		local active = false
		for _, profile in ipairs( data.profiles or {} ) do
			if profile.id == state.profileId then
				profileName = profile.name
				active = profile.active
			end
		end
		local headGap = barW - 480
		if headGap < 1 then headGap = 1 end
		children[#children + 1] = row( {
			label( profileName .. ( active and "  (actif)" or "  (inactif)" ), 280, "Left", nil, "SM_Label" ),
			spacer( headGap, 22 ),
			button( "Profils", 90, {
				localCmd = "render", screen = "profiles", editItem = "", editOccurrence = 0, editAdd = "",
			} ),
			button( active and "Désactiver" or "Activer", 110, { cmd = "activate", targetId = state.profileId } ),
		}, barW, 28 )
		if data.enabled == false then
			children[#children + 1] = label( "Mod désactivé : les drops restent vanilla.", barW, "Left" )
		end
		if data.notice ~= nil and data.notice ~= "" then
			children[#children + 1] = label( data.notice, barW, "Left" )
		end

		local groups = {
			{ id = "", caption = "Tous" },
			{ id = "Robots", caption = "Robots" },
			{ id = "Coffres", caption = "Coffres" },
			{ id = "Caisses", caption = "Caisses" },
			{ id = "Minerais", caption = "Minerais" },
			{ id = "Autres", caption = "Autres" },
		}
		local groupW = math.floor( barW / #groups )
		if groupW < 1 then groupW = 1 end
		local groupRow = {}
		for _, group in ipairs( groups ) do
			local skin = "SecondaryButton"
			if ( state.sourceGroup or "" ) == group.id then skin = "PrimaryButton" end
			groupRow[#groupRow + 1] = button( group.caption, groupW, {
				localCmd = "render", sourceGroup = group.id, sourcePage = 1,
			}, skin )
		end
		children[#children + 1] = row( groupRow, barW, 28 )

		local editing = ( state.editAdd or "" ) ~= "" or ( state.editItem or "" ) ~= ""
		local edit = data.edit
		local matched = editing and editMatches( edit )
		local editable = false
		if matched and edit.orphan ~= true and edit.state ~= "supprime" and edit.state ~= "orphelin" then
			editable = true
		end
		local dockH = 0
		if matched and editable then
			dockH = 140
		elseif matched then
			dockH = 84
		elseif editing then
			dockH = 28
		end
		local extraLines = 0
		if data.enabled == false then extraLines = extraLines + 1 end
		if data.notice ~= nil and data.notice ~= "" then extraLines = extraLines + 1 end
		local listH = winH - ( 28 + 28 + 28 + extraLines * 22 ) - dockH - 16
		if listH < 1 then listH = 1 end

		local leftW = 280
		if barW < 860 then leftW = 230 end
		local rightW = barW - leftW - 8
		if rightW < 420 then
			leftW = math.floor( barW * 0.34 )
			if leftW < 1 then leftW = 1 end
			if leftW > barW - 9 then leftW = barW - 9 end
			if leftW < 1 then leftW = 1 end
			rightW = barW - leftW - 8
			if rightW < 1 then rightW = 1 end
		end

		local iconW, weightW, pctW, qtyW, stateW = 22, 112, 48, 76, 88
		local nameW = rightW - ( iconW + weightW + pctW + qtyW + stateW + 8 )
		if nameW < 96 then
			weightW, pctW, qtyW, stateW = 78, 40, 56, 70
			nameW = rightW - ( iconW + weightW + pctW + qtyW + stateW + 8 )
		end
		if nameW < 1 then nameW = 1 end

		local filtered = {}
		local query = string.lower( state.sourceSearch or "" )
		local wanted = state.sourceGroup or ""
		for _, source in ipairs( data.sources or {} ) do
			local title = source.title or source.label or source.name or ""
			local groupOk = wanted == "" or source.group == wanted
			local textOk = query == "" or string.find( string.lower( title ), query, 1, true ) ~= nil
				or string.find( string.lower( source.name or "" ), query, 1, true ) ~= nil
			if groupOk and textOk then
				filtered[#filtered + 1] = source
			end
		end

		local left = {}
		left[#left + 1] = label( string.format( "Sources %d", #filtered ), leftW - 4, "Left", nil, "SM_Label" )
		local filterW = leftW - 84
		if filterW < 1 then filterW = 1 end
		left[#left + 1] = row( {
			editBox( "sourceSearch", state.sourceSearch or "", filterW ),
			button( "Filtrer", 72, { localCmd = "render", sourcePage = 1 } ),
		}, leftW, 28 )
		local sourceCount = fitCount( listH, 22 + 28 + 28 )
		local sourceSlice, sourcePage, sourcePages = SP.PageSlice( filtered, state.sourcePage or 1, sourceCount )
		state.sourcePage = sourcePage
		if #filtered == 0 then
			left[#left + 1] = label( "Aucune source.", leftW - 4, "Left" )
		end
		local showGroup = wanted == "" and leftW >= 240
		for _, source in ipairs( sourceSlice ) do
			local title = source.title or source.label or source.name or "?"
			local skin = "SecondaryButton"
			if source.name == state.source then skin = "PrimaryButton" end
			local openSource = {
				cmd = "state", source = source.name, roll = 1, rowPage = 1, screen = "editor",
				editItem = "", editOccurrence = 0, editAdd = "",
			}
			local line = {}
			local buttonW = leftW - 4
			if showGroup then
				line[#line + 1] = label( source.group or "", 68, "Left", "1 1 1 0.55" )
				buttonW = leftW - 76
			end
			line[#line + 1] = button( SP.Clip( title, clipCount( buttonW ) ), buttonW, openSource, skin )
			left[#left + 1] = row( line, leftW, 28 )
		end
		left[#left + 1] = pager( sourcePage, sourcePages, "sourcePage", leftW, false )

		local right = {}
		if state.source == "" then
			right[#right + 1] = label( "Choisissez une source.", rightW - 4, "Left", nil, "SM_Label" )
		else
			local sourceTitle = state.source
			for _, source in ipairs( data.sources or {} ) do
				if source.name == state.source then
					sourceTitle = source.title or source.label or source.name
				end
			end
			right[#right + 1] = label( SP.Clip( sourceTitle, clipCount( rightW ) ), rightW - 4, "Left", nil, "SM_Label" )
			local rolls = data.rolls or 1
			local currentRoll = data.roll or state.roll or 1
			local rollNav = {}
			if rolls <= 8 then
				local index = 1
				while index <= rolls do
					local skin = "SecondaryButton"
					if index == currentRoll then skin = "PrimaryButton" end
					rollNav[#rollNav + 1] = button( tostring( index ), 36, {
						cmd = "state", roll = index, rowPage = 1,
					}, skin )
					index = index + 1
				end
			else
				if currentRoll > 1 then
					rollNav[#rollNav + 1] = button( "Prec.", 64, { cmd = "state", roll = currentRoll - 1, rowPage = 1 } )
				end
				rollNav[#rollNav + 1] = label( string.format( "%d / %d", currentRoll, rolls ), 70, "Center" )
				if currentRoll < rolls then
					rollNav[#rollNav + 1] = button( "Suiv.", 64, { cmd = "state", roll = currentRoll + 1, rowPage = 1 } )
				end
			end
			rollNav[#rollNav + 1] = button( "Ajouter", 90, {
				cmd = "state", screen = "add", catalogPage = 1, search = "",
			}, "PrimaryButton" )
			right[#right + 1] = row( rollNav, rightW, 28 )
			right[#right + 1] = row( {
				spacer( iconW, 22 ),
				label( "Objet", nameW, "Left", "1 1 1 0.55" ),
				label( "Poids", weightW, "Right", "1 1 1 0.55" ),
				label( "%", pctW, "Right", "1 1 1 0.55" ),
				label( "Qté", qtyW, "Right", "1 1 1 0.55" ),
				label( "État", stateW, "Left", "1 1 1 0.55" ),
			}, rightW, 22 )

			local rowCount = fitCount( listH, 22 + 28 + 22 + 28 )
			local rowSlice, rowPage, rowPages = SP.PageSlice( data.rows or {}, state.rowPage or 1, rowCount )
			state.rowPage = rowPage
			if #( data.rows or {} ) == 0 then
				right[#right + 1] = label( "Aucune ligne dans ce tirage.", rightW - 4, "Left" )
			end
			for _, entry in ipairs( rowSlice ) do
				local colour = stateColour[entry.state]
				local skin = "SecondaryButton"
				if rowOpen( entry ) then skin = "PrimaryButton" end
				right[#right + 1] = row( {
					iconSlot( entry.item ),
					button( SP.Clip( entry.label or "?", clipCount( nameW ) ), nameW, {
						cmd = "state", screen = "editor",
						editItem = entry.item, editOccurrence = entry.occurrence or 0, editAdd = entry.addId or "",
					}, skin ),
					label( entry.weightText or "", weightW, "Right", colour ),
					label( entry.percentText or "", pctW, "Right", colour ),
					label( entry.qtyText or "", qtyW, "Right", colour ),
					label( stateWord( entry.state ), stateW, "Left", colour ),
				}, rightW, 28 )
			end
			right[#right + 1] = pager( rowPage, rowPages, "rowPage", rightW, false )
		end

		children[#children + 1] = row( {
			column( left, leftW, listH ),
			column( right, rightW, listH ),
		}, barW, listH )

		if editing and not matched then
			children[#children + 1] = label( "Chargement de la ligne...", barW, "Left" )
		elseif matched then
			local rank = ( edit.occurrence or 0 ) > 1 and ( " #" .. tostring( edit.occurrence ) ) or ""
			local colour = stateColour[edit.state]
			children[#children + 1] = row( {
				iconSlot( edit.item ),
				label( ( edit.label or "?" ) .. rank, barW - 220, "Left", colour, "SM_Label" ),
				label( stateWord( edit.state ), 160, "Right", colour ),
			}, barW, 28 )
			if edit.orphan or edit.state == "orphelin" then
				children[#children + 1] = label( "Cette ligne n'existe plus dans le loot du jeu.", barW, "Left" )
			elseif edit.state == "supprime" then
				children[#children + 1] = label( string.format(
					"Supprimée. Avant : poids %.2f, qté %s",
					edit.beforeWeight or 0, SP.Span( edit.beforeMin, edit.beforeMax )
				), barW, "Left" )
			elseif edit.state == "ajoute" then
				children[#children + 1] = label( string.format(
					"Ajoutée. Poids %.2f, qté %s",
					edit.weight or 0, SP.Span( edit.qtyMin, edit.qtyMax )
				), barW, "Left" )
			else
				children[#children + 1] = label( string.format(
					"Avant : poids %.2f, qté %s    Après : poids %.2f, qté %s",
					edit.beforeWeight or 0, SP.Span( edit.beforeMin, edit.beforeMax ),
					edit.weight or 0, SP.Span( edit.qtyMin, edit.qtyMax )
				), barW, "Left" )
			end
			if editable then
				local stepW = 64
				if barW < 760 then stepW = 48 end
				children[#children + 1] = row( {
					label( "Poids", 56, "Left" ),
					button( "-0.25", stepW, { cmd = "set", weightDelta = -0.25 } ),
					button( "-0.05", stepW, { cmd = "set", weightDelta = -0.05 } ),
					editBox( "weight", string.format( "%.2f", edit.weight or 0 ), 72 ),
					button( "+0.05", stepW, { cmd = "set", weightDelta = 0.05 } ),
					button( "+0.25", stepW, { cmd = "set", weightDelta = 0.25 } ),
				}, barW, 28 )
				children[#children + 1] = row( {
					label( "Qté min", 64, "Left" ),
					button( "-1", 44, { cmd = "set", qtyMinDelta = -1 } ),
					editBox( "qtyMin", tostring( edit.qtyMin or 1 ), 52 ),
					button( "+1", 44, { cmd = "set", qtyMinDelta = 1 } ),
					label( "Qté max", 64, "Left" ),
					button( "-1", 44, { cmd = "set", qtyMaxDelta = -1 } ),
					editBox( "qtyMax", tostring( edit.qtyMax or 1 ), 52 ),
					button( "+1", 44, { cmd = "set", qtyMaxDelta = 1 } ),
				}, barW, 28 )
			end
			local actions = {}
			if edit.state ~= "supprime" and edit.state ~= "orphelin" then
				actions[#actions + 1] = button( "Supprimer", 110, { cmd = "remove" } )
			end
			if edit.state == "modifie" or edit.state == "supprime" or edit.state == "orphelin" then
				actions[#actions + 1] = button( "Restaurer", 110, { cmd = "restore" } )
			end
			actions[#actions + 1] = button( "Retour", 100, {
				localCmd = "render", screen = "editor", editItem = "", editOccurrence = 0, editAdd = "",
			} )
			children[#children + 1] = row( actions, barW, 28 )
		end
	end

	state.buttons = buttons
	local tree = {
		Anchor = "Center", Type = "Widget", Skin = "BackgroundInteractableWide",
		Name = "SurvivalPlusRoot", LayoutRule = "Vertical",
		NeedMouse = true, NeedKey = true, InheritsPick = true,
		width = winW, height = winH, x = 0, y = 0, Childs = children,
	}
	local ok, err = pcall( function() self.cl.spGui:render( tree ) end )
	if not ok then
		log( "affichage en echec:", err )
	end
end
