-- Survival + / mod.lua
--
-- Editeur de tables de loot pour la Survie. Le fichier commence par le dofile
-- du Mod Manager, exactement comme le template : l'installateur reecrit le
-- prefixe $SURVIVAL_DATA quand il installe le mod.

dofile( "$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )

SurvivalPlus = SurvivalPlus or {}
local SP = SurvivalPlus

SP.MOD = "survivalplus"
SP.CHANNEL = "survivalPlusProfiles"
SP.PAGE = 6
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

local GROUP_ORDER = { Robots = 1, Coffres = 2, Caisses = 3, Minerais = 4, Autres = 5 }

local function log( ... )
	if ModManager and ModManager.Log then
		ModManager.Log( SP.MOD, ... )
	end
end

local function num( value, default )
	if type( value ) ~= "number" then return default end
	return value
end

local function int( value, default )
	if type( value ) ~= "number" then return default end
	return math.floor( value )
end

local function str( value )
	if type( value ) ~= "string" then return "" end
	return value
end

function SP.Copy( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, child in pairs( value ) do
		out[SP.Copy( key, seen )] = SP.Copy( child, seen )
	end
	return out
end

function SP.Clip( text, limit )
	text = tostring( text or "" )
	if string.sub( text, 1, 2 ) == "#{" then return text end
	if #text <= limit then return text end
	for index = 1, #text do
		if string.byte( text, index ) > 127 then return text end
	end
	return string.sub( text, 1, limit - 2 ) .. ".."
end

function SP.CleanName( name, fallback )
	if type( name ) ~= "string" then return fallback end
	name = string.gsub( name, "%s+", " " )
	name = string.gsub( name, "^%s+", "" )
	name = string.gsub( name, "%s+$", "" )
	if name == "" then return fallback end
	if #name > 32 then name = string.sub( name, 1, 32 ) end
	return name
end

function SP.UuidString( uuid )
	if uuid == nil then return "none" end
	if type( uuid ) == "string" then return uuid end
	local ok, text = pcall( tostring, uuid )
	if ok and type( text ) == "string" and text ~= "" then return text end
	return "none"
end

function SP.LineId( line )
	if type( line ) ~= "table" then return "none" end
	if line.uuid ~= nil then return SP.UuidString( line.uuid ) end
	if type( line.table ) == "string" and line.table ~= "" then
		return "table:" .. line.table
	end
	return "none"
end

function SP.NormalizeQty( quantity )
	if quantity == nil then return 1 end
	if type( quantity ) ~= "table" then return quantity end
	if quantity.min ~= nil then
		return { min = quantity.min, avg = quantity.avg, max = quantity.max or quantity.min }
	end
	if #quantity >= 3 then
		return { min = quantity[1], avg = quantity[2], max = quantity[3] }
	end
	if #quantity == 2 then
		return { min = quantity[1], max = quantity[2] }
	end
	if #quantity == 1 then return quantity[1] end
	return 1
end

function SP.ToGameQty( quantity )
	if type( quantity ) ~= "table" then return quantity end
	if quantity.min == nil then return 1 end
	local maxValue = quantity.max or quantity.min
	if quantity.avg ~= nil then
		return { quantity.min, quantity.avg, maxValue }
	end
	if quantity.min == maxValue then return quantity.min end
	return { quantity.min, maxValue }
end

function SP.FormatQty( quantity )
	quantity = SP.NormalizeQty( quantity )
	if type( quantity ) ~= "table" then return tostring( quantity ) end
	local maxValue = quantity.max or quantity.min
	if maxValue == nil or quantity.min == maxValue then return tostring( quantity.min ) end
	return tostring( quantity.min ) .. "-" .. tostring( maxValue )
end

function SP.QtyParts( quantity )
	quantity = SP.NormalizeQty( quantity )
	if type( quantity ) ~= "table" then return quantity, quantity end
	local minValue = quantity.min or 1
	return minValue, quantity.max or minValue
end

function SP.QtyFromParts( minValue, maxValue, previous )
	minValue = math.floor( num( minValue, 1 ) + 0.5 )
	maxValue = math.floor( num( maxValue, minValue ) + 0.5 )
	if minValue < 0 then minValue = 0 end
	if maxValue < minValue then maxValue = minValue end
	if minValue == maxValue then return minValue end
	if type( previous ) == "table" and previous.avg ~= nil then
		local avg = previous.avg
		if avg < minValue then avg = minValue end
		if avg > maxValue then avg = maxValue end
		return { min = minValue, avg = avg, max = maxValue }
	end
	return { min = minValue, max = maxValue }
end

function SP.ClampWeight( weight )
	weight = num( weight, 0 )
	if weight < 0 then weight = 0 end
	return math.floor( weight * 100 + 0.5 ) / 100
end

function SP.SameNumber( left, right )
	return math.abs( num( left, 0 ) - num( right, 0 ) ) < 0.001
end

function SP.StateLabel( state )
	if state == "modifie" then return "modifié" end
	if state == "ajoute" then return "ajouté" end
	if state == "supprime" then return "supprimé" end
	if state == "orphelin" then return "orphelin" end
	return "inchangé"
end

function SP.Span( minValue, maxValue )
	minValue = minValue or 1
	maxValue = maxValue or minValue
	if minValue == maxValue then return tostring( minValue ) end
	return tostring( minValue ) .. "-" .. tostring( maxValue )
end

-- La ligne cliquée depuis la liste envoie item / occurrence / addId.
-- L'écran de détail envoie editItem / editOccurrence / editAdd.
-- editOccurrence vaut 0 quand on n'édite pas : ce n'est pas le rang de la ligne.
function SP.LineTarget( params )
	local addId = str( params.addId )
	if addId == "" then addId = str( params.editAdd ) end
	local item = str( params.item )
	local occurrence = params.occurrence
	if item == "" then
		item = str( params.editItem )
		occurrence = params.editOccurrence
	end
	if type( occurrence ) ~= "number" then
		occurrence = int( params.editOccurrence, 0 )
	else
		occurrence = math.floor( occurrence )
	end
	return str( params.source ), item, occurrence, addId
end

function SP.GroupOf( name )
	local lower = string.lower( name or "" )
	if string.find( lower, "crate", 1, true ) then return "Caisses" end
	if string.find( lower, "chest", 1, true ) or string.find( lower, "locker", 1, true )
		or string.find( lower, "cabinet", 1, true ) or string.find( lower, "bigbox", 1, true )
		or string.find( lower, "amber", 1, true ) then
		return "Coffres"
	end
	if string.find( lower, "mineral", 1, true ) or string.find( lower, "minable", 1, true )
		or string.find( lower, "quartz", 1, true ) or string.find( lower, "voxel", 1, true )
		or string.find( lower, "mud", 1, true ) then
		return "Minerais"
	end
	if string.find( lower, "bot", 1, true ) or string.find( lower, "woc", 1, true )
		or string.find( lower, "glowbug", 1, true ) then
		return "Robots"
	end
	return "Autres"
end

function SP.SourceLabel( name )
	local short = name or ""
	if string.sub( short, 1, 11 ) == "lootsource_" then
		short = string.sub( short, 12 )
	end
	return ( string.gsub( short, "_", " " ) )
end

function SP.ItemLabel( itemId )
	SP.labels = SP.labels or {}
	if SP.labels[itemId] then return SP.labels[itemId] end
	local label = itemId
	if itemId == "none" or itemId == nil or itemId == "" then
		label = "Rien"
	elseif string.sub( itemId, 1, 6 ) == "table:" then
		label = "Table " .. string.sub( itemId, 7 )
	else
		local uuid = nil
		local parsedOk, parsed = pcall( sm.uuid.new, itemId )
		if parsedOk then uuid = parsed end
		if uuid and sm.shape and sm.shape.getShapeTitle then
			local titleOk, title = pcall( sm.shape.getShapeTitle, uuid )
			if titleOk and type( title ) == "string" and title ~= "" then
				label = title
			end
		end
		if label == itemId and type( ITEMS ) == "table" then
			for name, id in pairs( ITEMS ) do
				if SP.UuidString( id ) == itemId then
					label = name
					break
				end
			end
		end
	end
	SP.labels[itemId] = label
	return label
end

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
		row.caption = SP.RowCaption( row )
		row.quantity = nil
		row.beforeQuantity = nil
		row.qtyText = nil
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
		local slice, page, pages = SP.PageSlice( filtered, int( params.catalogPage, 1 ), SP.PAGE )
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
	local buttons = {}
	local seq = 0

	local function widgetName( prefix )
		seq = seq + 1
		return prefix .. tostring( seq )
	end

	local function label( caption, width, align )
		return {
			Type = "TextBox", Skin = "TextBox", Name = widgetName( "t" ),
			Caption = tostring( caption or "" ), FontName = "SM_HeaderTiny",
			TextAlign = align or "Left", NeedKey = false, NeedMouse = false,
			Childs = {}, width = width, height = 22, x = 0, y = 0,
		}
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

	local function pager( page, pages, keyName )
		if pages <= 1 then
			return label( string.format( "Page %d / %d", page, pages ), 200, "Left" )
		end
		local children = {}
		if page > 1 then
			local action = { localCmd = "render" }
			action[keyName] = page - 1
			children[#children + 1] = button( "Prec.", 64, action )
		end
		children[#children + 1] = label( string.format( "%d / %d", page, pages ), 70, "Center" )
		if page < pages then
			local action = { localCmd = "render" }
			action[keyName] = page + 1
			children[#children + 1] = button( "Suiv.", 64, action )
		end
		return row( children, 220, 28 )
	end

	local children = {}
	local ready = type( data.profiles ) == "table"
	children[#children + 1] = label( "Survival +", 700, "Center" )

	if not ready then
		children[#children + 1] = label( "Chargement des profils de ce monde...", 700, "Left" )
	elseif state.screen == "profiles" then
		local activeName = "aucun, le loot reste vanilla"
		for _, profile in ipairs( data.profiles ) do
			if profile.active then activeName = profile.name end
		end
		children[#children + 1] = label( "Profil actif : " .. activeName, 700, "Left" )
		if data.enabled == false then
			children[#children + 1] = label( "Mod désactivé : les drops restent vanilla.", 700, "Left" )
		end
		if data.notice ~= nil and data.notice ~= "" then
			children[#children + 1] = label( data.notice, 700, "Left" )
		end
		children[#children + 1] = row( {
			editBox( "profileName", state.draftName or "", 360 ),
			button( "Créer", 100, { cmd = "create" }, "PrimaryButton" ),
		}, 700, 28 )
		local slice, page, pages = SP.PageSlice( data.profiles, state.profilePage or 1, SP.PAGE )
		state.profilePage = page
		if #data.profiles == 0 then
			children[#children + 1] = label( "Aucun profil. Créez-en un pour commencer.", 700, "Left" )
		end
		for _, profile in ipairs( slice ) do
			local mark = profile.active and "* " or ""
			children[#children + 1] = row( {
				button( SP.Clip( mark .. profile.name .. " (" .. tostring( profile.count ) .. ")", 28 ), 230, {
					cmd = "state", screen = "editor", profileId = profile.id, source = "", roll = 1, rowPage = 1,
				} ),
				button( profile.active and "Désactiver" or "Activer", 100, { cmd = "activate", targetId = profile.id } ),
				button( "Dupliquer", 100, { cmd = "duplicate", targetId = profile.id } ),
				button( "Supprimer", 100, { cmd = "delete", targetId = profile.id } ),
			}, 700, 28 )
		end
		children[#children + 1] = pager( page, pages, "profilePage" )
	elseif state.screen == "add" then
		children[#children + 1] = label( "Ajouter une ligne au tirage " .. tostring( state.roll or 1 ), 700, "Left" )
		children[#children + 1] = row( {
			editBox( "search", state.search or "", 360 ),
			button( "Chercher", 100, { cmd = "state", catalogPage = 1 } ),
		}, 700, 28 )
		local catalog = data.catalog or {}
		if #catalog == 0 then
			children[#children + 1] = label( "Aucun objet pour cette recherche.", 700, "Left" )
		end
		for _, entry in ipairs( catalog ) do
			local line = {}
			local icon = iconOf( entry.item )
			if icon then line[#line + 1] = icon end
			line[#line + 1] = button( SP.Clip( entry.label, 40 ), icon and 420 or 446, {
				cmd = "add", item = entry.item, screen = "editor",
			} )
			children[#children + 1] = row( line, 700, 28 )
		end
		local page = data.catalogPage or 1
		local pages = data.catalogPages or 1
		local nav = {}
		if page > 1 then nav[#nav + 1] = button( "Precedent", 110, { cmd = "state", catalogPage = page - 1 } ) end
		nav[#nav + 1] = label( string.format( "Page %d / %d", page, pages ), 120, "Center" )
		if page < pages then nav[#nav + 1] = button( "Suivant", 110, { cmd = "state", catalogPage = page + 1 } ) end
		children[#children + 1] = row( nav, 700, 28 )
		children[#children + 1] = button( "Retour", 100, {
			localCmd = "render", screen = "editor",
		} )
	elseif state.screen == "edit" then
		local edit = data.edit
		if type( edit ) ~= "table" then
			children[#children + 1] = label( "Chargement de la ligne...", 700, "Left" )
		else
			local rank = ( edit.occurrence or 0 ) > 1 and ( " #" .. tostring( edit.occurrence ) ) or ""
			children[#children + 1] = label( ( edit.label or "?" ) .. rank .. "  " .. SP.StateLabel( edit.state ), 700, "Left" )
			local icon = iconOf( edit.item )
			if icon then children[#children + 1] = icon end
			if edit.orphan or edit.state == "orphelin" then
				children[#children + 1] = label( "Cette ligne n'existe plus dans le loot du jeu.", 700, "Left" )
			elseif edit.state == "supprime" then
				children[#children + 1] = label( string.format( "Supprimée. Avant : poids %.2f, qté %s", edit.beforeWeight or 0, SP.Span( edit.beforeMin, edit.beforeMax ) ), 700, "Left" )
			else
				children[#children + 1] = label( string.format( "Avant : poids %.2f, qté %s", edit.beforeWeight or 0, SP.Span( edit.beforeMin, edit.beforeMax ) ), 700, "Left" )
				children[#children + 1] = label( string.format( "Après : poids %.2f, qté %s", edit.weight or 0, SP.Span( edit.qtyMin, edit.qtyMax ) ), 700, "Left" )
				children[#children + 1] = row( {
					label( "Poids", 70, "Left" ),
					button( "-0.25", 70, { cmd = "set", weightDelta = -0.25 } ),
					button( "-0.05", 70, { cmd = "set", weightDelta = -0.05 } ),
					editBox( "weight", string.format( "%.2f", edit.weight or 0 ), 80 ),
					button( "+0.05", 70, { cmd = "set", weightDelta = 0.05 } ),
					button( "+0.25", 70, { cmd = "set", weightDelta = 0.25 } ),
				}, 700, 28 )
				children[#children + 1] = row( {
					label( "Qté min", 70, "Left" ),
					button( "-1", 50, { cmd = "set", qtyMinDelta = -1 } ),
					editBox( "qtyMin", tostring( edit.qtyMin or 1 ), 60 ),
					button( "+1", 50, { cmd = "set", qtyMinDelta = 1 } ),
					label( "Qté max", 70, "Left" ),
					button( "-1", 50, { cmd = "set", qtyMaxDelta = -1 } ),
					editBox( "qtyMax", tostring( edit.qtyMax or 1 ), 60 ),
					button( "+1", 50, { cmd = "set", qtyMaxDelta = 1 } ),
				}, 700, 28 )
			end
			local actions = {}
			if edit.state ~= "supprime" and edit.state ~= "orphelin" then
				actions[#actions + 1] = button( "Supprimer", 110, { cmd = "remove" } )
			end
			if edit.state ~= "inchange" then
				actions[#actions + 1] = button( "Restaurer", 110, { cmd = "restore" } )
			end
			actions[#actions + 1] = button( "Retour", 100, {
				localCmd = "render", screen = "editor", editItem = "", editOccurrence = 0, editAdd = "",
			} )
			children[#children + 1] = row( actions, 700, 28 )
		end
	else
		local profileName = "Profil"
		local active = false
		for _, profile in ipairs( data.profiles or {} ) do
			if profile.id == state.profileId then
				profileName = profile.name
				active = profile.active
			end
		end
		children[#children + 1] = label( profileName .. ( active and "  (actif)" or "  (inactif)" ), 700, "Left" )
		if data.notice ~= nil and data.notice ~= "" then
			children[#children + 1] = label( data.notice, 700, "Left" )
		end
		children[#children + 1] = row( {
			button( "Profils", 90, { localCmd = "render", screen = "profiles", editItem = "", editOccurrence = 0, editAdd = "" } ),
			button( active and "Désactiver" or "Activer", 110, { cmd = "activate", targetId = state.profileId } ),
		}, 700, 28 )

		local left = {}
		left[#left + 1] = label( "Sources", 240, "Left" )
		local sources = data.sources or {}
		local sourceSlice, sourcePage, sourcePages = SP.PageSlice( sources, state.sourcePage or 1, SP.PAGE )
		state.sourcePage = sourcePage
		for _, source in ipairs( sourceSlice ) do
			local caption = source.label
			if source.name == state.source then caption = "> " .. caption end
			left[#left + 1] = button( SP.Clip( caption, 32 ), 240, {
				cmd = "state", source = source.name, roll = 1, rowPage = 1,
			} )
		end
		left[#left + 1] = pager( sourcePage, sourcePages, "sourcePage" )

		local right = {}
		if state.source == "" then
			right[#right + 1] = label( "Choisissez une source.", 450, "Left" )
		else
			right[#right + 1] = label( string.format( "Tirage %d / %d", data.roll or state.roll or 1, data.rolls or 1 ), 450, "Left" )
			local rollNav = {}
			if ( data.roll or 1 ) > 1 then
				rollNav[#rollNav + 1] = button( "Precedent", 110, { cmd = "state", roll = ( data.roll or 1 ) - 1, rowPage = 1 } )
			end
			if ( data.roll or 1 ) < ( data.rolls or 1 ) then
				rollNav[#rollNav + 1] = button( "Suivant", 110, { cmd = "state", roll = ( data.roll or 1 ) + 1, rowPage = 1 } )
			end
			rollNav[#rollNav + 1] = button( "Ajouter", 90, {
				cmd = "state", screen = "add", catalogPage = 1, search = "",
			}, "PrimaryButton" )
			right[#right + 1] = row( rollNav, 450, 28 )

			local rowSlice, rowPage, rowPages = SP.PageSlice( data.rows or {}, state.rowPage or 1, SP.PAGE )
			state.rowPage = rowPage
			if #( data.rows or {} ) == 0 then
				right[#right + 1] = label( "Aucune ligne dans ce tirage.", 450, "Left" )
			end
			for _, entry in ipairs( rowSlice ) do
				local line = {}
				local icon = iconOf( entry.item )
				if icon then line[#line + 1] = icon end
				line[#line + 1] = button( entry.caption or "?", icon and 250 or 276, {
					cmd = "state", screen = "edit",
					editItem = entry.item, editOccurrence = entry.occurrence or 0, editAdd = entry.addId or "",
				} )
				if entry.state ~= "supprime" and entry.state ~= "orphelin" then
					line[#line + 1] = button( "Suppr", 70, {
						cmd = "remove", item = entry.item, occurrence = entry.occurrence or 0, addId = entry.addId or "",
					} )
				end
				if entry.state == "modifie" or entry.state == "supprime" or entry.state == "orphelin" then
					line[#line + 1] = button( "Restaure", 84, {
						cmd = "restore", item = entry.item, occurrence = entry.occurrence or 0, addId = entry.addId or "",
					} )
				end
				right[#right + 1] = row( line, 450, 28 )
			end
			right[#right + 1] = pager( rowPage, rowPages, "rowPage" )
		end
		children[#children + 1] = row( {
			column( left, 250, 420 ),
			column( right, 460, 420 ),
		}, 720, 430 )
	end

	children[#children + 1] = button( "Fermer", 100, { localCmd = "close" } )
	state.buttons = buttons

	local tree = {
		Anchor = "Center", Type = "Widget", Skin = "BackgroundInteractableWide",
		Name = "SurvivalPlusRoot", LayoutRule = "Vertical",
		NeedMouse = true, NeedKey = true, InheritsPick = true,
		width = 760, height = 620, x = 0, y = 0, Childs = children,
	}
	local ok, err = pcall( function() self.cl.spGui:render( tree ) end )
	if not ok then
		log( "affichage en echec:", err )
	end
end

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
