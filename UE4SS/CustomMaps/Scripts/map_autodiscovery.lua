local UEHelpers = require("UEHelpers")

local M = {}

local state = {
    assetRegistryHelpers = nil,
    assetRegistryInterface = nil,
    kismetStringTableLibrary = nil,
}

local function safe_member(obj, key)
    local ok, out = pcall(function()
        return obj[key]
    end)
    if ok then
        return out
    end
    return nil
end

local function unwrap_remote_value(value)
    local current = value
    for _ = 1, 4 do
        local kind = type(current)
        if kind ~= "table" and kind ~= "userdata" then
            break
        end

        local getter = safe_member(current, "get")
        if type(getter) ~= "function" then
            break
        end

        local ok, out = pcall(getter, current)
        if not ok or out == nil or out == current then
            break
        end

        current = out
    end

    return current
end

local function value_to_string(value)
    value = unwrap_remote_value(value)
    if value == nil then
        return ""
    end

    if type(value) == "string" then
        return value
    end

    if type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    end

    if type(value) == "table" or type(value) == "userdata" then
        local toString = safe_member(value, "ToString")
        if toString then
            local ok, out = pcall(toString, value)
            if ok and type(out) == "string" then
                return out
            end
        end
    end

    return tostring(value)
end

local function normalize_text(v)
    local text = value_to_string(v)
    if text == "" then
        return ""
    end

    local out = string.lower(text)
    out = out:gsub("^%s+", "")
    out = out:gsub("%s+$", "")
    out = out:gsub('^"(.*)"$', "%1")
    out = out:gsub("^fname%s*", "")
    return out
end

local function for_each_tarray(arr, callback)
    if not arr or type(callback) ~= "function" then
        return
    end

    local forEach = arr["ForEach"]
    if forEach then
        local ok = pcall(function()
            forEach(arr, function(index, element)
                local value = unwrap_remote_value(element)
                local stop = callback(index, value)
                if stop then
                    return true
                end
                return false
            end)
        end)
        if ok then
            return
        end
    end

    local n = #arr
    for i = 1, n do
        local stop = callback(i, unwrap_remote_value(arr[i]))
        if stop then
            return
        end
    end
end

local function tarray_to_list(arr)
    local out = {}
    for_each_tarray(arr, function(_, value)
        out[#out + 1] = value
        return false
    end)
    return out
end

local function push_unique(list, seen, value)
    if type(value) ~= "string" or value == "" then
        return
    end
    if seen[value] then
        return
    end
    seen[value] = true
    list[#list + 1] = value
end

local function is_uobject_valid(obj)
    if not obj then
        return false
    end

    local isValidFn = obj["IsValid"]
    if not isValidFn then
        return true
    end

    local ok, isValid = pcall(isValidFn, obj)
    if not ok then
        return true
    end

    return isValid == true
end

local function ensure_asset_registry_helpers()
    if state.assetRegistryHelpers and is_uobject_valid(state.assetRegistryHelpers) then
        return state.assetRegistryHelpers
    end

    local helper = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if helper and is_uobject_valid(helper) then
        state.assetRegistryHelpers = helper
        return helper
    end

    return nil
end

local function ensure_asset_registry_interface()
    if state.assetRegistryInterface and is_uobject_valid(state.assetRegistryInterface) then
        return state.assetRegistryInterface
    end

    local helpers = ensure_asset_registry_helpers()
    if helpers then
        local getAssetRegistry = helpers["GetAssetRegistry"]
        if getAssetRegistry then
            local ok, out = pcall(getAssetRegistry, helpers)
            if ok and out then
                local candidate = unwrap_remote_value(out)
                if candidate and candidate["GetAssetsByPath"] then
                    state.assetRegistryInterface = candidate
                    return candidate
                end
            end
        end
    end

    local fallback = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryImpl")
    if fallback and is_uobject_valid(fallback) then
        state.assetRegistryInterface = fallback
        return fallback
    end

    return nil
end

local function starts_with_ci(text, prefix)
    if type(text) ~= "string" or type(prefix) ~= "string" then
        return false
    end
    if #text < #prefix then
        return false
    end
    return string.lower(string.sub(text, 1, #prefix)) == string.lower(prefix)
end

local function get_asset_data_field(assetData, fieldName)
    if assetData == nil then
        return ""
    end

    local ok, out = pcall(function()
        return assetData[fieldName]
    end)
    if not ok then
        return ""
    end

    out = unwrap_remote_value(out)
    local text = value_to_string(out)
    text = text:gsub('^"(.*)"$', "%1")
    text = text:gsub("^FName%s*", "")
    return text
end

local function canonicalize_asset_path_text(text)
    if type(text) ~= "string" then
        return ""
    end

    local out = text
    out = out:gsub("\\", "/")
    out = out:gsub('^"(.*)"$', "%1")
    out = out:gsub("^FName%s*", "")
    out = out:gsub("^Name%s*", "")
    out = out:gsub("^%s+", "")
    out = out:gsub("%s+$", "")

    local gamePath = out:match("(/[Gg][Aa][Mm][Ee][^%s]*)")
    if gamePath then
        out = gamePath
    end

    return out
end

local function extract_folder_name_from_root_path(candidatePath, rootPath)
    local candidate = canonicalize_asset_path_text(candidatePath)
    local root = canonicalize_asset_path_text(rootPath)
    if candidate == "" or root == "" then
        return nil
    end

    candidate = candidate:gsub("%.[^/%.]+$", "")

    local rootPrefix = root .. "/"
    if starts_with_ci(candidate, rootPrefix) then
        local relative = string.sub(candidate, #rootPrefix + 1)
        return relative:match("^([^/]+)")
    end

    if starts_with_ci(candidate, root) then
        local remainder = string.sub(candidate, #root + 1)
        remainder = remainder:gsub("^/+", "")
        if remainder ~= "" then
            return remainder:match("^([^/]+)")
        end
    end

    return nil
end

local function split_path_segments(path)
    local segments = {}
    if type(path) ~= "string" or path == "" then
        return segments
    end

    for segment in string.gmatch(path, "[^/]+") do
        if segment ~= "" then
            segments[#segments + 1] = segment
        end
    end

    return segments
end

local function relative_package_path_under_root(packagePath, rootPath)
    local pkg = canonicalize_asset_path_text(packagePath)
    local root = canonicalize_asset_path_text(rootPath)
    if pkg == "" or root == "" then
        return nil
    end

    local rootPrefix = root .. "/"
    if starts_with_ci(pkg, rootPrefix) then
        return string.sub(pkg, #rootPrefix + 1)
    end

    if starts_with_ci(pkg, root) then
        local remainder = string.sub(pkg, #root + 1)
        remainder = remainder:gsub("^/+", "")
        if remainder ~= "" then
            return remainder
        end
    end

    return nil
end

local function resolve_map_folder_from_asset(packagePath, rootPath)
    local relative = relative_package_path_under_root(packagePath, rootPath)
    if not relative or relative == "" then
        return nil
    end

    local segments = split_path_segments(relative)
    if #segments == 1 then
        return {
            key = normalize_text(segments[1]),
            relativePath = segments[1],
            author = nil,
            folderName = segments[1],
        }
    end

    if #segments == 2 then
        return {
            key = normalize_text(segments[1] .. "/" .. segments[2]),
            relativePath = segments[1] .. "/" .. segments[2],
            author = segments[1],
            folderName = segments[2],
        }
    end

    return nil
end

local function collect_map_roots_with_levels(assets, rootPath)
    local roots = {}

    for i = 1, #assets do
        local assetData = unwrap_remote_value(assets[i])
        local assetName = normalize_text(get_asset_data_field(assetData, "AssetName"))
        if assetName == "level" then
            local packagePath = get_asset_data_field(assetData, "PackagePath")
            local relative = relative_package_path_under_root(packagePath, rootPath)
            if relative and relative ~= "" then
                local segments = split_path_segments(relative)
                if #segments == 1 then
                    roots[normalize_text(segments[1])] = true
                elseif #segments >= 2 then
                    roots[normalize_text(segments[1] .. "/" .. segments[2])] = true
                end
            end
        end
    end

    return roots
end

local function is_under_known_map_root(packagePath, rootPath, knownRoots)
    local relative = relative_package_path_under_root(packagePath, rootPath)
    if not relative or relative == "" then
        return false
    end

    local normalizedRelative = normalize_text(relative)
    for rootKey, _ in pairs(knownRoots) do
        if normalizedRelative ~= rootKey and starts_with_ci(normalizedRelative, rootKey .. "/") then
            return true
        end
    end

    return false
end

local function resolve_override_entry(overrides, relativePath, folderName)
    if type(overrides) ~= "table" then
        return nil
    end

    local keys = {}
    local seen = {}
    push_unique(keys, seen, normalize_text(relativePath))
    push_unique(keys, seen, normalize_text(folderName))

    for i = 1, #keys do
        local key = keys[i]
        local candidate = overrides[key]
        if type(candidate) == "table" then
            return candidate
        end
    end

    return nil
end

local function build_object_path_from_asset_data(assetData)
    local packageName = get_asset_data_field(assetData, "PackageName")
    local assetName = get_asset_data_field(assetData, "AssetName")
    if packageName == "" then
        return nil
    end

    if assetName == "" then
        local inferred = packageName:match("([^/]+)$")
        assetName = inferred or ""
    end
    if assetName == "" then
        return nil
    end

    return string.format("%s.%s", packageName, assetName)
end

local function get_asset_class_signature(assetData)
    local className = get_asset_data_field(assetData, "AssetClass")
    local classPath = get_asset_data_field(assetData, "AssetClassPath")
    local joined = (className or "") .. " " .. (classPath or "")
    return normalize_text(joined)
end

local function is_level_asset_data(assetData)
    local assetName = normalize_text(get_asset_data_field(assetData, "AssetName"))
    if assetName == "level" then
        return true
    end

    local signature = get_asset_class_signature(assetData)
    if signature == "" then
        return false
    end

    if string.find(signature, " world", 1, true)
        or string.find(signature, "world'", 1, true)
        or string.find(signature, "/script/engine.world", 1, true)
        or string.find(signature, "umap", 1, true) then
        return true
    end

    return false
end

local function is_thumbnail_asset_data(assetData)
    local signature = get_asset_class_signature(assetData)
    local assetName = normalize_text(get_asset_data_field(assetData, "AssetName"))
    local packageName = normalize_text(get_asset_data_field(assetData, "PackageName"))

    if signature ~= "" then
        if string.find(signature, "texture2d", 1, true) ~= nil
            or string.find(signature, "texture ", 1, true) ~= nil
            or string.find(signature, "texture'", 1, true) ~= nil then
            return true
        end
    end

    -- Fallback for games/builds where AssetClass fields are not exposed reliably.
    if assetName == "thumbnail" then
        return true
    end

    if packageName ~= "" and packageName:match("%.thumbnail$") then
        return true
    end

    return false
end

local function is_string_table_asset_data(assetData)
    local signature = get_asset_class_signature(assetData)
    if signature ~= "" and string.find(signature, "stringtable", 1, true) ~= nil then
        return true
    end

    -- Fallback for games/builds where class metadata is missing.
    local assetName = normalize_text(get_asset_data_field(assetData, "AssetName"))
    if assetName == "stringtable" then
        return true
    end

    if string.find(assetName, "string", 1, true) ~= nil
        and string.find(assetName, "table", 1, true) ~= nil then
        return true
    end

    return false
end

local function query_assets_under_path(rootPath)
    local registry = ensure_asset_registry_interface()
    if not registry then
        print("[CustomMapRotation] query_assets_under_path: no AssetRegistry interface")
        return {}
    end

    print(string.format("[CustomMapRotation] query_assets_under_path: begin for %s", tostring(rootPath)))

    local searchAllAssets = registry["SearchAllAssets"]
    if searchAllAssets then
        pcall(searchAllAssets, registry, true)
    end

    local waitForCompletion = registry["WaitForCompletion"]
    if waitForCompletion then
        pcall(waitForCompletion, registry)
    end

    local scanPaths = registry["ScanPathsSynchronous"]
    if scanPaths then
        pcall(scanPaths, registry, { rootPath }, false, true)
    end

    local collectFromPath = function(path)
        local getAssetsByPath = registry["GetAssetsByPath"]
        if not getAssetsByPath then
            return {}
        end

        local outAssets = {}
        local requestPath = FName(path)
        requestPath = UEHelpers.FindOrAddFName(path)

        local ok, result = pcall(getAssetsByPath, registry, requestPath, outAssets, true, false)
        if not ok then
            return {}
        end

        if type(result) == "table" then
            local resultList = tarray_to_list(result)
            if #resultList > 0 then
                return resultList
            end
        end

        local outList = tarray_to_list(outAssets)
        if #outList > 0 then
            return outList
        end

        return {}
    end

    local directAssets = collectFromPath(rootPath)
    if #directAssets > 0 then
        return directAssets
    end

    local getSubPaths = registry["GetSubPaths"]
    if getSubPaths then
        local subPaths = {}
        local ok = pcall(getSubPaths, registry, rootPath, subPaths, true)
        if ok then
            local subPathList = tarray_to_list(subPaths)

            local merged = {}
            local seen = {}

            local rootAssets = collectFromPath(rootPath)
            for i = 1, #rootAssets do
                local objPath = build_object_path_from_asset_data(rootAssets[i])
                if objPath and not seen[objPath] then
                    seen[objPath] = true
                    merged[#merged + 1] = rootAssets[i]
                end
            end

            for i = 1, #subPathList do
                local subPath = value_to_string(subPathList[i])
                local assetsInPath = collectFromPath(subPath)
                for j = 1, #assetsInPath do
                    local objPath = build_object_path_from_asset_data(assetsInPath[j])
                    if objPath and not seen[objPath] then
                        seen[objPath] = true
                        merged[#merged + 1] = assetsInPath[j]
                    end
                end
            end

            if #merged > 0 then
                return merged
            end
        end
    end

    local getAllAssets = registry["GetAllAssets"]
    if getAllAssets then
        local allAssets = {}
        local ok, result = pcall(getAllAssets, registry, allAssets, false)
        if ok then
            local source = allAssets
            if type(result) == "table" and #tarray_to_list(result) > 0 then
                source = result
            end

            local filtered = {}
            for_each_tarray(source, function(_, raw)
                local assetData = unwrap_remote_value(raw)
                local packagePath = get_asset_data_field(assetData, "PackagePath")
                if starts_with_ci(packagePath, rootPath) then
                    filtered[#filtered + 1] = assetData
                end
                return false
            end)

            if #filtered > 0 then
                return filtered
            end
        end
    end

    return {}
end

local function ensure_kismet_string_table_library()
    if state.kismetStringTableLibrary and is_uobject_valid(state.kismetStringTableLibrary) then
        return state.kismetStringTableLibrary
    end

    local lib = StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary")
    if lib and is_uobject_valid(lib) then
        state.kismetStringTableLibrary = lib
        return lib
    end

    return nil
end

local function try_string_table_entry(lib, tableId, key)
    local getSourceString = lib and lib["GetTableEntrySourceString"] or nil
    if not getSourceString then
        return nil
    end

    -- Engine signature expects FName table IDs.
    local safeTableId = tableId
    if UEHelpers and UEHelpers.FindOrAddFName and type(tableId) == "string" then
        local okName, outName = pcall(UEHelpers.FindOrAddFName, tableId)
        if okName and outName ~= nil then
            safeTableId = outName
        end
    end

    local ok, value = pcall(getSourceString, lib, safeTableId, key)
    if not ok then
        return nil
    end

    local text = value_to_string(value)
    if normalize_text(text) == "" then
        return nil
    end

    return text
end

local function try_string_table_entries(lib, tableId, keys)
    if type(keys) ~= "table" then
        return nil
    end

    for i = 1, #keys do
        local key = keys[i]
        if type(key) == "string" and key ~= "" then
            local value = try_string_table_entry(lib, tableId, key)
            if value ~= nil then
                return value, key
            end
        end
    end

    return nil
end

local function parse_boolish(value)
    if type(value) == "boolean" then
        return value
    end

    local text = normalize_text(value)
    if text == "" then
        return nil
    end

    if text == "1" or text == "true" or text == "yes" or text == "on" then
        return true
    end
    if text == "0" or text == "false" or text == "no" or text == "off" then
        return false
    end

    return nil
end

local function read_metadata_from_string_table_asset(stringTableAssetData)
    local lib = ensure_kismet_string_table_library()
    if not lib then
        return nil
    end

    local objectPath = build_object_path_from_asset_data(stringTableAssetData)
    local packageName = get_asset_data_field(stringTableAssetData, "PackageName")
    local assetName = get_asset_data_field(stringTableAssetData, "AssetName")

    local tableIdCandidates = {}
    local seen = {}
    push_unique(tableIdCandidates, seen, assetName)

    local packageLeaf = type(packageName) == "string" and packageName:match("([^/]+)$") or nil
    push_unique(tableIdCandidates, seen, packageLeaf)

    local objectLeaf = type(objectPath) == "string" and objectPath:match("%.([^%.]+)$") or nil
    push_unique(tableIdCandidates, seen, objectLeaf)

    -- Keep path-like IDs as a final fallback only.
    push_unique(tableIdCandidates, seen, packageName)
    push_unique(tableIdCandidates, seen, objectPath)

    -- Try to force-load the string table asset before lookup.
    if LoadAsset then
        if type(objectPath) == "string" and objectPath ~= "" then
            pcall(LoadAsset, objectPath)
        end
        if type(packageName) == "string" and packageName ~= "" then
            pcall(LoadAsset, packageName)
        end
    end

    for i = 1, #tableIdCandidates do
        local tableId = tableIdCandidates[i]
        if tableId and tableId ~= "" then
            local metadata = {
                name = try_string_table_entries(lib, tableId, { "Name", "MapName", "Title" }),
                id = try_string_table_entries(lib, tableId, { "ID", "Id" }),
                tier = try_string_table_entries(lib, tableId, { "Tier", "Rank" }),
                combatMode = try_string_table_entries(lib, tableId, { "CombatMode", "Mode" }),
                loseCondition = try_string_table_entries(lib, tableId, { "LoseCondition", "Lose" }),
                betAmount = try_string_table_entries(lib, tableId, { "Bet", "BetAmount" }),
                rewardAmount = try_string_table_entries(lib, tableId, { "Reward", "RewardAmount" }),
                equipmentBudget = try_string_table_entries(lib, tableId, { "EquipmentBudget", "Budget", "Equipment" }),
                combatantsAmount = try_string_table_entries(lib, tableId, { "Combatants", "CombatantsAmount", "CombatantsCount" }),
                roundsAmount = try_string_table_entries(lib, tableId, { "Rounds", "RoundsAmount", "RoundCount" }),
                thumbnailPath = try_string_table_entries(lib, tableId, { "ThumbnailPath", "Thumbnail", "ThumbPath" }),
                levelPath = try_string_table_entries(lib, tableId, { "LevelPath", "Level", "MapPath" }),
                enabled = parse_boolish(try_string_table_entries(lib, tableId, { "Enabled" })),
                tableId = tableId,
            }

            if metadata.name
                or metadata.id
                or metadata.tier
                or metadata.combatMode
                or metadata.loseCondition
                or metadata.betAmount
                or metadata.rewardAmount
                or metadata.equipmentBudget
                or metadata.combatantsAmount
                or metadata.roundsAmount
                or metadata.thumbnailPath
                or metadata.levelPath
                or metadata.enabled ~= nil then
                return metadata
            end
        end
    end

    return nil
end

local function default_config()
    return {
        rootPath = "/Game/CustomMaps",
        defaultCombatMode = 2,
        defaultTier = 1,
    }
end

function M.discover_maps(config, overrides)
    local cfg = config or default_config()
    local rootPath = cfg.rootPath
    if type(rootPath) ~= "string" or rootPath == "" then
        return {}
    end

    local assets = query_assets_under_path(rootPath)
    if #assets == 0 then
        print(string.format("[CustomMapRotation] No assets found under %s", rootPath))
        return {}
    end

    local groupsByFolder = {}
    local knownMapRoots = collect_map_roots_with_levels(assets, rootPath)

    for i = 1, #assets do
        local assetData = unwrap_remote_value(assets[i])
        local packagePath = get_asset_data_field(assetData, "PackagePath")
        local assetName = get_asset_data_field(assetData, "AssetName")

        if is_under_known_map_root(packagePath, rootPath, knownMapRoots) then
            goto continue_asset_loop
        end

        local mapFolder = resolve_map_folder_from_asset(packagePath, rootPath)
        if mapFolder and mapFolder.key ~= "" then
            local bucket = groupsByFolder[mapFolder.key]
            if not bucket then
                bucket = {
                    folderName = mapFolder.folderName,
                    relativePath = mapFolder.relativePath,
                    author = mapFolder.author,
                    levelAsset = nil,
                    thumbnailAsset = nil,
                    dataAsset = nil,
                }
                groupsByFolder[mapFolder.key] = bucket
            end

            local assetKey = normalize_text(assetName)
            if assetKey == "level" or (not bucket.levelAsset and is_level_asset_data(assetData)) then
                if not bucket.levelAsset then
                    bucket.levelAsset = assetData
                end
            elseif assetKey == "thumbnail" or (not bucket.thumbnailAsset and is_thumbnail_asset_data(assetData)) then
                if not bucket.thumbnailAsset then
                    bucket.thumbnailAsset = assetData
                end
            elseif assetKey == "data" or (not bucket.dataAsset and is_string_table_asset_data(assetData)) then
                if not bucket.dataAsset then
                    bucket.dataAsset = assetData
                end
            end
        else
            print(string.format(
                "[CustomMapRotation] Ignoring asset outside supported map folder depth. PackagePath='%s' AssetName='%s'",
                tostring(packagePath),
                tostring(assetName)
            ))
        end

        ::continue_asset_loop::
    end

    local groupKeys = {}
    for key, _ in pairs(groupsByFolder) do
        groupKeys[#groupKeys + 1] = key
    end
    table.sort(groupKeys)
    print(string.format("[CustomMapRotation] build_discovered_maps: grouped into %d map folders", #groupKeys))

    local discovered = {}
    for _, key in ipairs(groupKeys) do
        local bucket = groupsByFolder[key]
        local folderName = bucket.folderName
        local levelAsset = bucket.levelAsset
        local thumbnailAsset = bucket.thumbnailAsset
        local dataAsset = bucket.dataAsset

        local levelPath = levelAsset and build_object_path_from_asset_data(levelAsset) or nil
        local thumbnailPath = thumbnailAsset and build_object_path_from_asset_data(thumbnailAsset) or nil

        local metadata = dataAsset and read_metadata_from_string_table_asset(dataAsset) or nil
        if metadata and type(metadata.levelPath) == "string" and metadata.levelPath ~= "" and not levelPath then
            levelPath = metadata.levelPath
        end
        if metadata and type(metadata.thumbnailPath) == "string" and metadata.thumbnailPath ~= "" and not thumbnailPath then
            thumbnailPath = metadata.thumbnailPath
        end

        if levelPath then

            local mapEntry = {
                folder = bucket.relativePath,
                mapFolder = folderName,
                author = bucket.author,
                name = folderName,
                levelPath = levelPath,
                thumbnailPath = thumbnailPath,
                combatMode = cfg.defaultCombatMode,
                tier = cfg.defaultTier,
                enabled = true,
            }

            if metadata then
                if type(metadata.name) == "string" and metadata.name ~= "" then
                    mapEntry.name = metadata.name
                end
                if metadata.id ~= nil then
                    mapEntry.id = metadata.id
                end
                if metadata.tier ~= nil then
                    mapEntry.tier = metadata.tier
                end
                if metadata.combatMode ~= nil then
                    mapEntry.combatMode = metadata.combatMode
                end
                if metadata.loseCondition ~= nil then
                    mapEntry.loseCondition = metadata.loseCondition
                end
                if metadata.betAmount ~= nil then
                    mapEntry.betAmount = metadata.betAmount
                end
                if metadata.rewardAmount ~= nil then
                    mapEntry.rewardAmount = metadata.rewardAmount
                end
                if metadata.equipmentBudget ~= nil then
                    mapEntry.equipmentBudget = metadata.equipmentBudget
                end
                if metadata.combatantsAmount ~= nil then
                    mapEntry.combatantsAmount = metadata.combatantsAmount
                end
                if metadata.roundsAmount ~= nil then
                    mapEntry.roundsAmount = metadata.roundsAmount
                end
                if metadata.levelPath ~= nil and metadata.levelPath ~= "" then
                    mapEntry.levelPath = metadata.levelPath
                end
                if metadata.thumbnailPath ~= nil and metadata.thumbnailPath ~= "" then
                    mapEntry.thumbnailPath = metadata.thumbnailPath
                end
                if metadata.enabled ~= nil then
                    mapEntry.enabled = metadata.enabled
                end
                print(string.format("[CustomMapRotation] Metadata loaded for '%s' from string table id '%s'", folderName, tostring(metadata.tableId)))
            end

            local override = resolve_override_entry(overrides, bucket.relativePath, folderName)
            if type(override) == "table" then
                for field, value in pairs(override) do
                    mapEntry[field] = value
                end
            end

            if mapEntry.enabled ~= false then
                discovered[#discovered + 1] = mapEntry
            end
        else
            print(string.format("[CustomMapRotation] Skipping folder '%s' (missing required 'Level' asset)", bucket.relativePath or folderName))
        end
    end

    return discovered
end

function M.debug_print_maps(maps)
    if type(maps) ~= "table" then
        return
    end

    print(string.format("[CustomMapRotation] debug_print_maps: %d map(s)", #maps))

    for i = 1, #maps do
        local m = maps[i]
        print(string.format(
            "[CustomMapRotation] map[%d] folder=%s name=%s level=%s thumb=%s id=%s tier=%s",
            i,
            tostring(m.folder),
            tostring(m.name),
            tostring(m.levelPath),
            tostring(m.thumbnailPath),
            tostring(m.id),
            tostring(m.tier)
        ))
    end
end

return M
