-- Survival + / Loot.lua
--
-- Profils, snapshot vanilla, operations et commandes.

local SP = SurvivalPlus
local log, num, int, str = SP.log, SP.num, SP.int, SP.str

local GROUP_ORDER = { Robots = 1, Coffres = 2, Caisses = 3, Minerais = 4, Autres = 5 }

--------------------------------------------------------------------------------
-- Sauvegarde du monde. Canal texte, distinct des canaux numeriques du jeu.
--------------------------------------------------------------------------------

function SP.Load()
	if SP.cache then return SP.cache end
	local data = nil
	local ok, stored = pcall( sm.storage.load, SP.CHANNEL )
	if ok and type( stored ) == "table" then data = stored end
	if type( data ) ~= "table" then
		data = {}
	end
	if type( data.profiles ) ~= "table" then data.profiles = {} end
	data.nextId = int( data.nextId, 1 )
	data.nextAdd = int( data.nextAdd, 1 )
	data.revision = int( data.revision, 0 )
	if data.activeId ~= nil and type( data.activeId ) ~= "string" then data.activeId = nil end
	for _, profile in ipairs( data.profiles ) do
		if type( profile.ops ) ~= "table" then profile.ops = {} end
		if type( profile.name ) ~= "string" or profile.name == "" then profile.name = "Profil" end
		if type( profile.id ) ~= "string" then profile.id = "p0" end
	end
	SP.cache = data
	return data
end

function SP.FindProfile( data, id )
	if type( id ) ~= "string" or id == "" then return nil end
	for _, profile in ipairs( data.profiles ) do
		if profile.id == id then return profile end
	end
	return nil
end

function SP.Save()
	local data = SP.Load()
	data.revision = int( data.revision, 0 ) + 1
	local ok, err = pcall( sm.storage.save, SP.CHANNEL, data )
	if not ok then
		log( "sauvegarde en echec:", err )
	end
	SP.appliedToken = nil
	SP.EnsureApplied()
end

--------------------------------------------------------------------------------
-- Loot : snapshot vanilla, puis operations du profil actif.
--------------------------------------------------------------------------------

function SP.Walk( source )
	local rows = {}
	local counts = {}
	if type( source ) ~= "table" or type( source.loot ) ~= "table" then return rows end
	for slotIndex, slot in ipairs( source.loot ) do
		if type( slot ) == "table" then
			for lineIndex, line in ipairs( slot.list or {} ) do
				local item = SP.LineId( line )
				counts[item] = ( counts[item] or 0 ) + 1
				rows[#rows + 1] = {
					slot = slotIndex,
					line = lineIndex,
					item = item,
					occurrence = counts[item],
					weight = line.weight or 1,
					quantity = SP.NormalizeQty( line.quantity ),
				}
			end
		end
	end
	return rows
end

function SP.CaptureVanilla()
	if SP.vanilla then return end
	if type( LOOT_SOURCES ) ~= "table" or next( LOOT_SOURCES ) == nil then
		local ok, err = pcall( dofile, "$SURVIVAL_DATA/Scripts/game/survival_loot.lua" )
		if not ok then
			log( "lecture du loot vanilla en echec:", err )
		end
	end
	if type( LOOT_SOURCES ) ~= "table" or next( LOOT_SOURCES ) == nil then return end
	SP.vanilla = SP.Copy( LOOT_SOURCES )
	local count = 0
	for _ in pairs( SP.vanilla ) do count = count + 1 end
	log( "Snapshot vanilla,", count, "sources" )
end

function SP.ApplySource( vanillaSource, ops, sourceName )
	local copy = SP.Copy( vanillaSource )
	if type( copy ) ~= "table" or type( copy.loot ) ~= "table" then return copy end
	local walk = SP.Walk( copy )

	local function findRow( item, occurrence )
		for _, row in ipairs( walk ) do
			if row.item == item and row.occurrence == occurrence then return row end
		end
		return nil
	end

	local removed = {}
	for _, op in ipairs( ops ) do
		if op.source == sourceName and op.kind == "update" and type( op.after ) == "table" then
			local row = findRow( op.item, op.occurrence )
			local slot = row and copy.loot[row.slot]
			local entry = slot and slot.list and slot.list[row.line]
			if entry then
				entry.weight = op.after.weight
				entry.quantity = SP.ToGameQty( op.after.quantity )
			end
		elseif op.source == sourceName and op.kind == "remove" then
			local row = findRow( op.item, op.occurrence )
			if row then removed[row.slot .. ":" .. row.line] = true end
		end
	end

	for slotIndex, slot in ipairs( copy.loot ) do
		local kept = {}
		for lineIndex, entry in ipairs( slot.list or {} ) do
			if not removed[slotIndex .. ":" .. lineIndex] then
				kept[#kept + 1] = entry
			end
		end
		slot.list = kept
	end

	for _, op in ipairs( ops ) do
		if op.kind == "add" and op.source == sourceName then
			local roll = int( op.roll, 1 )
			if roll < 1 then roll = 1 end
			while #copy.loot < roll do
				copy.loot[#copy.loot + 1] = { list = {} }
			end
			local slot = copy.loot[roll]
			slot.list = slot.list or {}
			local uuid = nil
			if type( op.item ) == "string" and op.item ~= "none" and string.sub( op.item, 1, 6 ) ~= "table:" then
				local parsedOk, parsed = pcall( sm.uuid.new, op.item )
				if parsedOk then
					uuid = parsed
				else
					log( "uuid ignore:", op.item )
				end
			end
			slot.list[#slot.list + 1] = {
				uuid = uuid,
				weight = op.weight or 1,
				quantity = SP.ToGameQty( op.quantity or 1 ),
			}
		end
	end
	return copy
end

function SP.LootStillPatched()
	if SP.appliedRefs == nil or type( LOOT_SOURCES ) ~= "table" then return false end
	for name, ref in pairs( SP.appliedRefs ) do
		if LOOT_SOURCES[name] ~= ref then return false end
	end
	return true
end

function SP.ActiveProfile()
	local enabled = true
	if ModManager and ModManager.Sv_IsEnabled then
		local ok, result = pcall( ModManager.Sv_IsEnabled, SP.MOD )
		if ok then enabled = result == true end
	end
	if not enabled then return nil, false end
	local data = SP.Load()
	return SP.FindProfile( data, data.activeId ), true
end

function SP.EnsureApplied()
	SP.CaptureVanilla()
	if SP.vanilla == nil or type( LOOT_SOURCES ) ~= "table" then return end
	local profile, enabled = SP.ActiveProfile()
	local data = SP.Load()
	local token = ( enabled and data.activeId or "" ) .. ":" .. tostring( data.revision or 0 )
	if SP.appliedToken == token and SP.LootStillPatched() then return end

	local ops = profile and profile.ops or {}
	SP.appliedRefs = {}
	for name, vanilla in pairs( SP.vanilla ) do
		if type( vanilla ) == "table" then
			LOOT_SOURCES[name] = SP.ApplySource( vanilla, ops, name )
			SP.appliedRefs[name] = LOOT_SOURCES[name]
		end
	end
	SP.appliedToken = token
	if SP.lastLoggedToken ~= token then
		SP.lastLoggedToken = token
		if profile then
			log( "Profil applique:", profile.name )
		else
			log( "Aucun profil actif, loot vanilla" )
		end
	end
end

function SP.EnsureSelectHook()
	if type( SelectLoot ) ~= "function" then return end
	if SP.hookedSelect == SelectLoot then return end
	local previous = SelectLoot
	local function wrapped( ... )
		SP.EnsureApplied()
		return previous( ... )
	end
	SP.hookedSelect = wrapped
	SelectLoot = wrapped
	local env = getfenv and getfenv( 1 )
	if type( env ) == "table" then env.SelectLoot = wrapped end
	if type( _G ) == "table" and _G ~= env then
		SP.Write( _G, "SelectLoot", wrapped )
	end
end

function SP.ServerPulse( game )
	if game ~= nil and game.sv == nil then return end
	if game ~= nil then SP.game = game end
	SP.EnsureSelectHook()
	SP.EnsureApplied()
	if SP.pendingPlayer and SP.game and SP.game.network then
		local player = SP.pendingPlayer
		SP.pendingPlayer = nil
		SP.game.network:sendToClient( player, "cl_spOpen", {} )
	end
end

--------------------------------------------------------------------------------
-- Operations
--------------------------------------------------------------------------------

function SP.FindKeyed( ops, source, item, occurrence )
	local found = nil
	for _, op in ipairs( ops ) do
		if op.source == source and op.item == item and op.occurrence == occurrence
			and ( op.kind == "update" or op.kind == "remove" ) then
			found = op
		end
	end
	return found
end

function SP.DeleteWhere( ops, pred )
	for index = #ops, 1, -1 do
		if pred( ops[index] ) then table.remove( ops, index ) end
	end
end

function SP.VanillaRow( sourceName, item, occurrence )
	local source = SP.vanilla and SP.vanilla[sourceName]
	if source == nil then return nil end
	for _, row in ipairs( SP.Walk( source ) ) do
		if row.item == item and row.occurrence == occurrence then return row end
	end
	return nil
end

function SP.CurrentLine( profile, sourceName, item, occurrence, addId )
	if type( addId ) == "string" and addId ~= "" then
		for _, op in ipairs( profile.ops ) do
			if op.kind == "add" and op.id == addId then
				return { weight = op.weight or 1, quantity = SP.NormalizeQty( op.quantity or 1 ), kind = "add" }
			end
		end
		return nil
	end
	local base = SP.VanillaRow( sourceName, item, occurrence )
	if base == nil then return nil end
	local op = SP.FindKeyed( profile.ops, sourceName, item, occurrence )
	if op and op.kind == "remove" then
		return { weight = base.weight, quantity = base.quantity, kind = "remove", base = base }
	end
	if op and op.kind == "update" and type( op.after ) == "table" then
		return {
			weight = op.after.weight,
			quantity = SP.NormalizeQty( op.after.quantity ),
			kind = "update",
			base = base,
		}
	end
	return { weight = base.weight, quantity = base.quantity, kind = "vanilla", base = base }
end

function SP.MutateLine( profile, sourceName, item, occurrence, addId, weight, quantity )
	if type( addId ) == "string" and addId ~= "" then
		for _, op in ipairs( profile.ops ) do
			if op.kind == "add" and op.id == addId then
				if weight ~= nil then op.weight = weight end
				if quantity ~= nil then op.quantity = quantity end
				return true
			end
		end
		return false
	end
	local base = SP.VanillaRow( sourceName, item, occurrence )
	if base == nil then return false end
	local op = SP.FindKeyed( profile.ops, sourceName, item, occurrence )
	if op and op.kind == "remove" then return false end
	local before = { weight = base.weight, quantity = SP.Copy( base.quantity ) }
	local after = {
		weight = weight ~= nil and weight or ( op and op.after and op.after.weight or base.weight ),
		quantity = quantity ~= nil and quantity or ( op and op.after and op.after.quantity or base.quantity ),
	}
	if SP.SameNumber( after.weight, before.weight ) and SP.FormatQty( after.quantity ) == SP.FormatQty( before.quantity ) then
		SP.DeleteWhere( profile.ops, function( entry )
			return entry.kind == "update" and entry.source == sourceName and entry.item == item and entry.occurrence == occurrence
		end )
		return true
	end
	if op and op.kind == "update" then
		op.before = op.before or before
		op.after = after
	else
		profile.ops[#profile.ops + 1] = {
			kind = "update",
			source = sourceName,
			item = item,
			occurrence = occurrence,
			before = before,
			after = after,
		}
	end
	return true
end

function SP.RemoveLine( profile, sourceName, item, occurrence, addId )
	if type( addId ) == "string" and addId ~= "" then
		SP.DeleteWhere( profile.ops, function( entry )
			return entry.kind == "add" and entry.id == addId
		end )
		return true
	end
	local base = SP.VanillaRow( sourceName, item, occurrence )
	if base == nil then return false end
	SP.DeleteWhere( profile.ops, function( entry )
		return entry.kind == "update" and entry.source == sourceName and entry.item == item and entry.occurrence == occurrence
	end )
	if SP.FindKeyed( profile.ops, sourceName, item, occurrence ) == nil then
		profile.ops[#profile.ops + 1] = {
			kind = "remove",
			source = sourceName,
			item = item,
			occurrence = occurrence,
			before = { weight = base.weight, quantity = SP.Copy( base.quantity ) },
		}
	end
	return true
end

function SP.RestoreLine( profile, sourceName, item, occurrence, addId )
	if type( addId ) == "string" and addId ~= "" then
		SP.DeleteWhere( profile.ops, function( entry )
			return entry.kind == "add" and entry.id == addId
		end )
		return true
	end
	SP.DeleteWhere( profile.ops, function( entry )
		return entry.source == sourceName and entry.item == item and entry.occurrence == occurrence
			and ( entry.kind == "update" or entry.kind == "remove" )
	end )
	return true
end

function SP.RollCount( sourceName )
	local source = SP.vanilla and SP.vanilla[sourceName]
	if type( source ) == "table" and type( source.loot ) == "table" and #source.loot > 0 then
		return #source.loot
	end
	return 1
end

function SP.BuildRows( sourceName, roll, ops )
	local rows = {}
	local present = {}
	local vanilla = SP.vanilla and SP.vanilla[sourceName]
	local walk = SP.Walk( vanilla )
	for _, row in ipairs( walk ) do
		present[row.item .. "#" .. tostring( row.occurrence )] = true
		if row.slot == roll then
			local op = SP.FindKeyed( ops, sourceName, row.item, row.occurrence )
			local state = "inchange"
			local weight = row.weight
			local quantity = row.quantity
			if op and op.kind == "remove" then
				state = "supprime"
			elseif op and op.kind == "update" and type( op.after ) == "table" then
				state = "modifie"
				weight = op.after.weight
				quantity = SP.NormalizeQty( op.after.quantity )
			end
			rows[#rows + 1] = {
				item = row.item,
				occurrence = row.occurrence,
				addId = "",
				label = SP.ItemLabel( row.item ),
				weight = weight or 0,
				beforeWeight = row.weight or 0,
				quantity = quantity,
				beforeQuantity = row.quantity,
				state = state,
			}
		end
	end
	for _, op in ipairs( ops ) do
		if op.kind == "add" and op.source == sourceName and int( op.roll, 1 ) == roll then
			rows[#rows + 1] = {
				item = op.item,
				occurrence = 0,
				addId = op.id,
				label = SP.ItemLabel( op.item ),
				weight = op.weight or 1,
				beforeWeight = 0,
				quantity = SP.NormalizeQty( op.quantity or 1 ),
				beforeQuantity = 1,
				state = "ajoute",
			}
		end
	end
	if roll == 1 then
		for _, op in ipairs( ops ) do
			if op.source == sourceName and ( op.kind == "update" or op.kind == "remove" ) then
				local key = tostring( op.item ) .. "#" .. tostring( op.occurrence )
				if not present[key] then
					local quantity = op.before and op.before.quantity or 1
					local weight = op.before and op.before.weight or 0
					if op.kind == "update" and type( op.after ) == "table" then
						quantity = op.after.quantity or quantity
						weight = op.after.weight or weight
					end
					rows[#rows + 1] = {
						item = op.item,
						occurrence = op.occurrence or 1,
						addId = "",
						label = SP.ItemLabel( op.item ),
						weight = weight,
						beforeWeight = op.before and op.before.weight or 0,
						quantity = SP.NormalizeQty( quantity ),
						beforeQuantity = SP.NormalizeQty( op.before and op.before.quantity or 1 ),
						state = "orphelin",
					}
				end
			end
		end
	end

	local sum = 0
	for _, row in ipairs( rows ) do
		if row.state ~= "supprime" and row.state ~= "orphelin" then
			sum = sum + ( row.weight or 0 )
		end
	end
	for _, row in ipairs( rows ) do
		if sum > 0 and row.state ~= "supprime" and row.state ~= "orphelin" then
			row.percent = ( row.weight or 0 ) / sum * 100
		else
			row.percent = 0
		end
		if row.state == "modifie" and not SP.SameNumber( row.beforeWeight, row.weight ) then
			row.weightText = string.format( "%.2f > %.2f", row.beforeWeight or 0, row.weight or 0 )
		else
			row.weightText = string.format( "%.2f", row.weight or 0 )
		end
		if row.state == "supprime" or row.state == "orphelin" then
			row.percentText = ""
		else
			row.percentText = string.format( "%d%%", math.floor( ( row.percent or 0 ) + 0.5 ) )
		end
		if row.state == "modifie" and SP.FormatQty( row.beforeQuantity ) ~= SP.FormatQty( row.quantity ) then
			row.qtyText = SP.FormatQty( row.beforeQuantity ) .. " > " .. SP.FormatQty( row.quantity )
		else
			row.qtyText = SP.FormatQty( row.quantity )
		end
		row.caption = SP.RowCaption( row )
		row.quantity = nil
		row.beforeQuantity = nil
	end
	return rows
end

function SP.RowCaption( row )
	local weight
	if row.state == "modifie" and not SP.SameNumber( row.beforeWeight, row.weight ) then
		weight = string.format( "%.2f -> %.2f", row.beforeWeight or 0, row.weight or 0 )
	else
		weight = string.format( "%.2f", row.weight or 0 )
	end
	local percent = ""
	if row.state ~= "supprime" and row.state ~= "orphelin" then
		percent = string.format( " %d%%", math.floor( ( row.percent or 0 ) + 0.5 ) )
	end
	local quantity
	if row.state == "modifie" and SP.FormatQty( row.beforeQuantity ) ~= SP.FormatQty( row.quantity ) then
		quantity = SP.FormatQty( row.beforeQuantity ) .. " -> " .. SP.FormatQty( row.quantity )
	else
		quantity = SP.FormatQty( row.quantity )
	end
	local rank = ""
	if ( row.occurrence or 0 ) > 1 then rank = " #" .. tostring( row.occurrence ) end
	return SP.Clip( row.label or "?", 22 ) .. rank .. "  " .. weight .. percent .. "  x" .. quantity .. "  " .. SP.StateLabel( row.state )
end

function SP.SourceList()
	local list = {}
	if SP.vanilla == nil then return list end
	for name, source in pairs( SP.vanilla ) do
		if type( source ) == "table" and type( source.loot ) == "table" then
			local group = SP.GroupOf( name )
			list[#list + 1] = {
				name = name,
				group = group,
				title = SP.SourceLabel( name ),
				label = group .. "  " .. SP.SourceLabel( name ),
				rolls = SP.RollCount( name ),
			}
		end
	end
	table.sort( list, function( a, b )
		local left = GROUP_ORDER[a.group] or 9
		local right = GROUP_ORDER[b.group] or 9
		if left ~= right then return left < right end
		return a.label < b.label
	end )
	return list
end

function SP.Catalog()
	if SP.catalog then return SP.catalog end
	SP.CaptureVanilla()
	local seen = {}
	local list = {}
	local function add( itemId )
		if type( itemId ) ~= "string" or itemId == "" or itemId == "none" then return end
		if string.sub( itemId, 1, 6 ) == "table:" then return end
		if seen[itemId] then return end
		seen[itemId] = true
		list[#list + 1] = { item = itemId, label = SP.ItemLabel( itemId ) }
	end
	if SP.vanilla then
		for _, source in pairs( SP.vanilla ) do
			for _, row in ipairs( SP.Walk( source ) ) do
				add( row.item )
			end
		end
	end
	if type( ITEMS ) == "table" then
		for _, id in pairs( ITEMS ) do
			add( SP.UuidString( id ) )
		end
	end
	table.sort( list, function( a, b ) return a.label < b.label end )
	if type( ITEMS ) == "table" then SP.catalog = list end
	return list
end

function SP.PageSlice( list, page, size )
	list = list or {}
	local pages = math.max( 1, math.ceil( #list / size ) )
	if page < 1 then page = 1 end
	if page > pages then page = pages end
	local slice = {}
	local first = ( page - 1 ) * size + 1
	for index = first, math.min( #list, first + size - 1 ) do
		slice[#slice + 1] = list[index]
	end
	return slice, page, pages
end

function SP.View( params, notice )
	SP.CaptureVanilla()
	local data = SP.Load()
	local profileId = str( params.profileId )
	if SP.FindProfile( data, profileId ) == nil then profileId = "" end
	local source = str( params.source )
	if source ~= "" and ( SP.vanilla == nil or SP.vanilla[source] == nil ) then source = "" end
	local rolls = source ~= "" and SP.RollCount( source ) or 1
	local roll = int( params.roll, 1 )
	if roll < 1 then roll = 1 end
	if roll > rolls then roll = rolls end

	local profiles = {}
	for _, profile in ipairs( data.profiles ) do
		profiles[#profiles + 1] = {
			id = profile.id,
			name = profile.name,
			active = data.activeId == profile.id,
			count = #profile.ops,
		}
	end

	local profile = SP.FindProfile( data, profileId )
	local rows = {}
	if profile and source ~= "" then
		rows = SP.BuildRows( source, roll, profile.ops )
	end

	local enabled = true
	if ModManager and ModManager.Sv_IsEnabled then
		local ok, result = pcall( ModManager.Sv_IsEnabled, SP.MOD )
		if ok then enabled = result == true end
	end

	local view = {
		profiles = profiles,
		profileId = profileId,
		activeId = data.activeId or "",
		enabled = enabled,
		sources = SP.SourceList(),
		source = source,
		roll = roll,
		rolls = rolls,
		rows = rows,
		notice = notice or "",
		req = int( params.req, 0 ),
	}

	local editItem = str( params.editItem )
	local editAdd = str( params.editAdd )
	local editOccurrence = int( params.editOccurrence, 0 )
	if profile and ( editAdd ~= "" or editItem ~= "" ) then
		local current = SP.CurrentLine( profile, source, editItem, editOccurrence, editAdd )
		local orphan = current == nil
		local minValue, maxValue = 1, 1
		local beforeMin, beforeMax = 1, 1
		local weight, beforeWeight = 0, 0
		local state = "orphelin"
		if current then
			minValue, maxValue = SP.QtyParts( current.quantity )
			weight = current.weight or 0
			if current.kind == "add" then
				state = "ajoute"
			elseif current.kind == "remove" then
				state = "supprime"
				beforeWeight = current.base.weight or 0
				beforeMin, beforeMax = SP.QtyParts( current.base.quantity )
			elseif current.kind == "update" then
				state = "modifie"
				beforeWeight = current.base.weight or 0
				beforeMin, beforeMax = SP.QtyParts( current.base.quantity )
			else
				state = "inchange"
				beforeWeight = weight
				beforeMin, beforeMax = minValue, maxValue
			end
		end
		view.edit = {
			item = editItem,
			occurrence = editOccurrence,
			addId = editAdd,
			label = SP.ItemLabel( editAdd ~= "" and editItem or editItem ),
			state = state,
			orphan = orphan,
			weight = weight,
			beforeWeight = beforeWeight,
			qtyMin = minValue,
			qtyMax = maxValue,
			beforeMin = beforeMin,
			beforeMax = beforeMax,
		}
		if editAdd ~= "" then
			for _, op in ipairs( profile.ops ) do
				if op.kind == "add" and op.id == editAdd then
					view.edit.label = SP.ItemLabel( op.item )
					view.edit.item = op.item
				end
			end
		end
	end

	if params.wantCatalog == true then
		local query = string.lower( str( params.search ) )
		local filtered = {}
		for _, entry in ipairs( SP.Catalog() ) do
			if query == "" or string.find( string.lower( entry.label ), query, 1, true ) then
				filtered[#filtered + 1] = entry
			end
		end
		local slice, page, pages = SP.PageSlice( filtered, int( params.catalogPage, 1 ), SP.CATALOG_PAGE )
		view.catalog = slice
		view.catalogPage = page
		view.catalogPages = pages
		view.catalogCount = #filtered
	end
	return view
end

function SP.Handle( params )
	if type( params ) ~= "table" then params = {} end
	SP.CaptureVanilla()
	local data = SP.Load()
	local cmd = str( params.cmd )
	local notice = ""
	local screen = nil
	local clearEdit = false

	local function profileOrNil()
		return SP.FindProfile( data, str( params.profileId ) )
	end

	if cmd == "create" then
		local id = "p" .. tostring( data.nextId )
		data.nextId = data.nextId + 1
		local name = SP.CleanName( params.name, "Profil " .. id )
		data.profiles[#data.profiles + 1] = { id = id, name = name, ops = {} }
		params.profileId = id
		screen = "editor"
		SP.Save()
		notice = "Profil créé."
	elseif cmd == "duplicate" then
		local sourceProfile = SP.FindProfile( data, str( params.targetId ) )
		if sourceProfile == nil then
			notice = "Profil introuvable."
		else
			local id = "p" .. tostring( data.nextId )
			data.nextId = data.nextId + 1
			data.profiles[#data.profiles + 1] = {
				id = id,
				name = SP.CleanName( sourceProfile.name .. " copie", "Profil " .. id ),
				ops = SP.Copy( sourceProfile.ops ),
			}
			params.profileId = id
			screen = "editor"
			SP.Save()
			notice = "Profil dupliqué."
		end
	elseif cmd == "delete" then
		local id = str( params.targetId )
		for index, profile in ipairs( data.profiles ) do
			if profile.id == id then
				table.remove( data.profiles, index )
				break
			end
		end
		if data.activeId == id then data.activeId = nil end
		if str( params.profileId ) == id then params.profileId = "" end
		screen = "profiles"
		clearEdit = true
		SP.Save()
		notice = "Profil supprimé."
	elseif cmd == "activate" then
		local id = str( params.targetId )
		if SP.FindProfile( data, id ) == nil then
			notice = "Profil introuvable."
		elseif data.activeId == id then
			data.activeId = nil
			SP.Save()
			notice = "Profil désactivé. Le loot redevient vanilla."
		else
			data.activeId = id
			SP.Save()
			notice = "Profil activé."
		end
	elseif cmd == "set" then
		local profile = profileOrNil()
		local current = profile and SP.CurrentLine( profile, str( params.source ), str( params.editItem ), int( params.editOccurrence, 0 ), str( params.editAdd ) )
		if profile == nil then
			notice = "Créez un profil d'abord."
		elseif current == nil or current.kind == "remove" then
			notice = "Cette ligne n'est pas modifiable."
		else
			local weight = nil
			local quantity = nil
			if type( params.weight ) == "number" then
				weight = SP.ClampWeight( params.weight )
			elseif type( params.weightDelta ) == "number" then
				weight = SP.ClampWeight( ( current.weight or 0 ) + params.weightDelta )
			end
			local minValue, maxValue = SP.QtyParts( current.quantity )
			local touchedQty = false
			if type( params.qtyMin ) == "number" then minValue = params.qtyMin touchedQty = true end
			if type( params.qtyMax ) == "number" then maxValue = params.qtyMax touchedQty = true end
			if type( params.qtyMinDelta ) == "number" then minValue = minValue + params.qtyMinDelta touchedQty = true end
			if type( params.qtyMaxDelta ) == "number" then maxValue = maxValue + params.qtyMaxDelta touchedQty = true end
			if touchedQty then quantity = SP.QtyFromParts( minValue, maxValue, current.quantity ) end
			SP.MutateLine( profile, str( params.source ), str( params.editItem ), int( params.editOccurrence, 0 ), str( params.editAdd ), weight, quantity )
			SP.Save()
		end
	elseif cmd == "remove" then
		local profile = profileOrNil()
		local sourceName, item, occurrence, addId = SP.LineTarget( params )
		if profile == nil then
			notice = "Créez un profil d'abord."
		elseif SP.RemoveLine( profile, sourceName, item, occurrence, addId ) then
			screen = "editor"
			clearEdit = true
			SP.Save()
		else
			notice = "Ligne introuvable."
		end
	elseif cmd == "restore" then
		local profile = profileOrNil()
		local sourceName, item, occurrence, addId = SP.LineTarget( params )
		if profile == nil then
			notice = "Créez un profil d'abord."
		else
			SP.RestoreLine( profile, sourceName, item, occurrence, addId )
			screen = "editor"
			clearEdit = true
			SP.Save()
		end
	elseif cmd == "add" then
		local profile = profileOrNil()
		local item = str( params.item )
		local source = str( params.source )
		if profile == nil then
			notice = "Créez un profil d'abord."
		elseif source == "" or SP.vanilla == nil or SP.vanilla[source] == nil then
			notice = "Choisissez une source."
		elseif item == "" then
			notice = "Choisissez un objet."
		else
			local id = "a" .. tostring( data.nextAdd )
			data.nextAdd = data.nextAdd + 1
			local roll = int( params.roll, 1 )
			if roll < 1 then roll = 1 end
			if roll > SP.RollCount( source ) then roll = SP.RollCount( source ) end
			profile.ops[#profile.ops + 1] = {
				kind = "add",
				id = id,
				source = source,
				roll = roll,
				item = item,
				weight = 1,
				quantity = 1,
			}
			screen = "editor"
			clearEdit = true
			SP.Save()
			notice = "Ligne ajoutée."
		end
	end

	local view = SP.View( params, notice )
	if screen ~= nil then view.screen = screen end
	if clearEdit then view.clearEdit = true end
	return view
end
