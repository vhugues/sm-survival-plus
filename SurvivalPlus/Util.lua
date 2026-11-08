-- Survival + / Util.lua
--
-- Aides partagees. mod.lua charge ce fichier dans le meme environnement.
-- SP est local au chunk : on reprend la globale SurvivalPlus.

local SP = SurvivalPlus

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

SP.log = log
SP.num = num
SP.int = int
SP.str = str
