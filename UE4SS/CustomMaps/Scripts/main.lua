--==================================================
-- Half Sword Custom Maps (UE4SS Lua)
--==================================================

local UEHelpers = require("UEHelpers")
local MapAutoDiscovery = require("map_autodiscovery")

local MAP_SELECTOR_WIDGET_CLASS = "/Game/UI/Tavern/Dialogs/UI_Jester.UI_Jester_C"
local FREEMODE_WIDGET_CLASS = "/Game/UI/Tavern/Dialogs/Jester/UI_Jester_FreeMode.UI_Jester_FreeMode_C"
local MAP_LIST_ENTRY_WIDGET_CLASS = "/Game/UI/Tavern/UI_List_MapSelect.UI_List_MapSelect_C"

local MAP_DISCOVERY = {
    -- Folder scanned recursively for custom map assets.
    rootPath = "/Game/CustomMaps",

    -- Defaults applied to discovered map entries.
    defaultCombatMode = 2,
    defaultTier = 1
}

-- Optional per-folder overrides keyed by discovered map folder.
-- Supported keys:
--   - "SomeMap" for /Game/CustomMaps/SomeMap
--   - "author/somemap" (normalized lowercase) for /Game/CustomMaps/Author/SomeMap
--     (plain "somemap" also works, but full key avoids conflicts)
-- Example:
-- ["gm_construct"] = {
--     name = "GM Construct",
--     levelPath = "/Game/GM_Construct/Construct1",
--     thumbnailPath = "/Game/CustomMaps/gm_construct/Thumbnail.Thumbnail",
--     combatMode = 2,
--     tier = 1,
--     enabled = true,
-- }
local MAP_OVERRIDES = {}

local NATIVE_DISPLAY_NAME_OVERRIDES = {
    ["BP_CombatEvent_Tourney_Baron"] = "Lords Hall",
}

local PASSPORT = {
    Name = "Name_33_80AE82094EAE943B065BE3B5C7F1C41B",
    ID = "ID_41_28B71F884E3E0E8E75C22DBB12DB809E",
    Thumbnail = "Thumbnail_19_195759B240ED112A1BABB0A6408CC99C",
    BetAmount = "BetAmount_20_87517572431AF70989131482829E07E6",
    RewardAmount = "RewardAmount_21_39CBEA0549CBC81CD356EFB5BC1FCC24",
    EquipmentBudget = "EquipmentBudget_26_4FC29A0544CA0B009EAD408C59D5F8A6",
    CombatantsAmount = "CombatantsAmount_22_13BCA4574AA06ED5CE62EBA6B312008C",
    RoundsAmount = "RoundsAmount_23_0DC99BF14EE3D35571D2AAAE6C1503AD",
    LoseCondition = "LoseCondition_24_E094C6EA4737C2FAB5012D9D3698B9EF",
    CombatMode = "CombatMode_25_E0B1EE8946757C4CF058A2AC38196DC7",
    LevelPath = "LevelPath_34_BAD068394946BC2E8C65AA9092DF7B39",
    Tier = "Tier_38_C21E98C34F256B9DCAA0628D037308BC",
}

local RANKS = {
    [0] = "Beggar",
    [1] = "Peasant",
    [2] = "Commoner",
    [3] = "Militia",
    [4] = "Soldier",
    [5] = "Veteran",
    [6] = "Man at Arms",
    [7] = "Knight",
    [8] = "Lord",
}

local COMBAT_MODES = {
    [0] = "Fisting",
    [1] = "Duel",
    [2] = "Champion",
    [3] = "Carnage",
    [4] = "Doubles",
    [5] = "Buhurt",
    [6] = "Riot",
    [7] = "Nemesis",
    [8] = "Tourney",
}

local LOSE_CONDITIONS = {
    [0] = "Submission",
    [1] = "First Blood",
    [2] = "KnockDown",
    [3] = "Circle",
}

local selectorInjectedForSession = false
local selectorInjectionInProgress = false
local selectorInjectionQueued = false
local freeModeInjectedForSession = false
local freeModeInjectionInProgress = false
local freeModeInjectionQueued = false
local injectedCustomMapKeysForSession = {}
local assetRegistryHelpers = nil
local thumbnailAssetCache = {}
local discoveredMapsCache = nil
local DEBUG_TRACE = false
local DEBUG_FREEMODE_NATIVE = false
local debugStep = 0
local gameplayStatics = nil
local kismetMathLibrary = nil
local kismetSystemLibrary = nil
local combatEventClass = nil
local widgetBlueprintLibrary = nil
local mapSelectorWidgetClassObject = nil
local assetRegistryInterface = nil

local find_asset_with_fallback
local freeModeNativeDebugStep = 0

local function freemode_native_log(message)
    if not DEBUG_FREEMODE_NATIVE then
        return
    end

    freeModeNativeDebugStep = freeModeNativeDebugStep + 1
    print(string.format("[CustomMapRotation][FreeModeNativeTemp][%04d] %s", freeModeNativeDebugStep, tostring(message)))
end

local function trace_log(message)
    if not DEBUG_TRACE then
        return
    end

    debugStep = debugStep + 1
    print(string.format("[CustomMapRotation][Trace %04d] %s", debugStep, tostring(message)))
end

local function safe_trace_call(label, fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        print(string.format("[CustomMapRotation] ERROR at %s: %s", tostring(label), tostring(a)))
        return false, nil
    end
    return true, a, b, c, d
end

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

    -- Remote wrappers can be table or userdata proxies; unwrap a few layers safely.
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

local function normalize_enum_token(v)
    local out = normalize_text(v)
    if out == "" then
        return ""
    end
    out = out:gsub("[_%-%s]+", "")
    return out
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

local function build_enum_lookup(enumTable)
    local byName = {}
    if type(enumTable) ~= "table" then
        return byName
    end

    for index, name in pairs(enumTable) do
        if type(name) == "string" and type(index) == "number" then
            local key = normalize_enum_token(name)
            if key ~= "" then
                byName[key] = index
            end
        end
    end

    return byName
end

local RANKS_BY_NAME = build_enum_lookup(RANKS)
local COMBAT_MODES_BY_NAME = build_enum_lookup(COMBAT_MODES)
local LOSE_CONDITIONS_BY_NAME = build_enum_lookup(LOSE_CONDITIONS)

local function get_map_entry_value(mapEntry, keys)
    if type(mapEntry) ~= "table" or type(keys) ~= "table" then
        return nil
    end

    for i = 1, #keys do
        local key = keys[i]
        local value = mapEntry[key]
        if value ~= nil then
            return value
        end
    end

    return nil
end

local function resolve_integer_value(value)
    value = unwrap_remote_value(value)

    if type(value) == "number" then
        return math.floor(value)
    end

    local text = normalize_text(value)
    if text == "" then
        return nil
    end

    local single = tonumber(text)
    if single ~= nil then
        return math.floor(single)
    end

    local minText, maxText = text:match("^([+-]?%d+)%s*%-%s*([+-]?%d+)$")
    if not minText or not maxText then
        return nil
    end

    local minValue = tonumber(minText)
    local maxValue = tonumber(maxText)
    if minValue == nil or maxValue == nil then
        return nil
    end

    minValue = math.floor(minValue)
    maxValue = math.floor(maxValue)
    if minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    return math.random(minValue, maxValue)
end

local function resolve_enum_value(value, enumByName)
    local numeric = resolve_integer_value(value)
    if numeric ~= nil then
        return numeric
    end

    local key = normalize_enum_token(value)
    if key == "" then
        return nil
    end

    return enumByName[key]
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

local function ensure_level_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    if string.find(path, ".", 1, true) then
        return path
    end

    local baseName = path:match("([^/]+)$")
    if not baseName or baseName == "" then
        return path
    end

    return string.format("%s.%s", path, baseName)
end

local function ensure_asset_path(path)
    if type(path) ~= "string" then
        return nil
    end

    if string.find(path, ".", 1, true) then
        return path
    end

    local baseName = path:match("([^/]+)$")
    if not baseName or baseName == "" then
        return path
    end

    return string.format("%s.%s", path, baseName)
end

local function ensure_class_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    if string.find(path, ".", 1, true) then
        if path:sub(-2) == "_C" then
            return path
        end
        return path .. "_C"
    end

    local baseName = path:match("([^/]+)$")
    if not baseName or baseName == "" then
        return path
    end

    return string.format("%s.%s_C", path, baseName)
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

local function is_widget_in_viewport(widget)
    if not is_uobject_valid(widget) then
        return false
    end

    local isInViewport = safe_member(widget, "IsInViewport")
    if not isInViewport then
        return false
    end

    local ok, inViewport = pcall(isInViewport, widget)
    return ok and inViewport == true
end

---@param widget UUI_Jester_C
local function show_jester_widget(widget)
    if not is_uobject_valid(widget) then
        return false
    end

    local ok = pcall(function()
        if not is_widget_in_viewport(widget) then
            widget:AddToViewport(100)
        end

        widget:SetRenderOpacity(1.0)
        widget:SetIsEnabled(true)
        print("Showing widget:", widget:GetFName():ToString())
    end)
    return ok
end

---@param widget UUI_Jester_C
local function hide_jester_widget(widget)
    if not is_uobject_valid(widget) then
        return false
    end

    local ok = pcall(function()
        widget:SetRenderOpacity(0.0)
        widget:SetIsEnabled(false)

        local removeFromParent = safe_member(widget, "RemoveFromParent")
        if removeFromParent then
            pcall(removeFromParent, widget)
        else
            local removeFromViewport = safe_member(widget, "RemoveFromViewport")
            if removeFromViewport then
                pcall(removeFromViewport, widget)
            end
        end
    end)
    return ok
end

local function ensure_asset_registry_helpers()
    if assetRegistryHelpers and is_uobject_valid(assetRegistryHelpers) then
        return assetRegistryHelpers
    end

    local helper = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if helper and is_uobject_valid(helper) then
        assetRegistryHelpers = helper
        return helper
    end

    return nil
end

local function ensure_asset_registry_interface()
    if assetRegistryInterface and is_uobject_valid(assetRegistryInterface) then
        return assetRegistryInterface
    end

    local helpers = ensure_asset_registry_helpers()
    if not helpers then
        return nil
    end

    local getAssetRegistry = helpers["GetAssetRegistry"]
    if not getAssetRegistry then
        return nil
    end

    local ok, out = pcall(getAssetRegistry, helpers)
    if not ok or not out then
        return nil
    end

    local candidate = unwrap_remote_value(out)
    if candidate and candidate["GetAssetsByPath"] then
        assetRegistryInterface = candidate
        return assetRegistryInterface
    end

    return nil
end

local function ensure_gameplay_statics()
    if gameplayStatics and is_uobject_valid(gameplayStatics) then
        return gameplayStatics
    end

    local obj = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if obj and is_uobject_valid(obj) then
        gameplayStatics = obj
        return gameplayStatics
    end

    return nil
end

local function ensure_kismet_math_library()
    if kismetMathLibrary and is_uobject_valid(kismetMathLibrary) then
        return kismetMathLibrary
    end

    local obj = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    if obj and is_uobject_valid(obj) then
        kismetMathLibrary = obj
        return kismetMathLibrary
    end

    return nil
end

local function ensure_kismet_system_library()
    if kismetSystemLibrary and is_uobject_valid(kismetSystemLibrary) then
        return kismetSystemLibrary
    end

    local obj = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if obj and is_uobject_valid(obj) then
        kismetSystemLibrary = obj
        return kismetSystemLibrary
    end

    return nil
end

local function ensure_widget_blueprint_library()
    if widgetBlueprintLibrary and is_uobject_valid(widgetBlueprintLibrary) then
        return widgetBlueprintLibrary
    end

    local obj = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if obj and is_uobject_valid(obj) then
        widgetBlueprintLibrary = obj
        return widgetBlueprintLibrary
    end

    return nil
end

local function ensure_map_selector_widget_class()
    if mapSelectorWidgetClassObject and is_uobject_valid(mapSelectorWidgetClassObject) then
        return mapSelectorWidgetClassObject
    end

    local obj = StaticFindObject(MAP_SELECTOR_WIDGET_CLASS)
    if not obj and LoadAsset then
        pcall(LoadAsset, MAP_SELECTOR_WIDGET_CLASS)
        obj = StaticFindObject(MAP_SELECTOR_WIDGET_CLASS)
    end

    if obj and is_uobject_valid(obj) then
        mapSelectorWidgetClassObject = obj
        return mapSelectorWidgetClassObject
    end

    return nil
end

local function get_widgets_of_class(worldContextObject, widgetClass, topLevelOnly)
    local wbl = ensure_widget_blueprint_library()
    if not (wbl and widgetClass and worldContextObject) then
        return nil
    end

    local getAllWidgetsOfClass = wbl["GetAllWidgetsOfClass"]
    if not getAllWidgetsOfClass then
        return nil
    end

    local found = {}
    local ok = pcall(getAllWidgetsOfClass, wbl, worldContextObject, found, widgetClass, topLevelOnly == true)
    if ok then
        return found
    end

    return nil
end

local function collect_jester_widgets(worldContextObject)
    local selectorClass = ensure_map_selector_widget_class()
    if worldContextObject and selectorClass then
        local scoped = get_widgets_of_class(worldContextObject, selectorClass, true)
        if scoped and #scoped > 0 then
            return scoped
        end
    end

    return FindAllOf("UI_Jester_C")
end

local function spawn_freemode_selector_preview(ctx)
    local getCtx = ctx and ctx["get"]
    local freeModeWidget = getCtx and getCtx(ctx) or nil --ctx:get()
    if not is_uobject_valid(freeModeWidget) then
        return
    end

    local selectorClass = ensure_map_selector_widget_class()
    local wbl = ensure_widget_blueprint_library()
    if not (selectorClass and wbl) then
        print("[CustomMapRotation] FreeMode selector preview unavailable: missing class/library")
        return
    end

    local existing = get_widgets_of_class(freeModeWidget, selectorClass, true)
    if existing and #existing > 0 then
        return
    end

    local create = wbl["Create"]
    if not create then
        print("[CustomMapRotation] FreeMode selector preview unavailable: WidgetBlueprintLibrary.Create missing")
        return
    end

    local okCreate, selectorWidget = pcall(create, wbl, freeModeWidget, selectorClass, nil)
    if not okCreate or not is_uobject_valid(selectorWidget) then
        print("[CustomMapRotation] Failed to create FreeMode selector preview")
        return
    end

    local widgetsToRemove = {
        "Button",
        "Button_4",
        "Image",
        "Image_0",
        "Image_1",
        "Image_12",
        "Slider_1",
        "TextBlock_1",
        "TextBlock_4"
    }

    for i = 1, #widgetsToRemove do
        local name = widgetsToRemove[i]
        local child = safe_member(selectorWidget, name)
        if is_uobject_valid(child) then
            local removeFromParent = safe_member(child, "RemoveFromParent")
            if removeFromParent then
                pcall(removeFromParent, child)
            end
        end
    end

    pcall(function()
        local battleBtn = safe_member(freeModeWidget, "Button_1")
        if is_uobject_valid(battleBtn) then
            local removeFromParent = safe_member(battleBtn, "RemoveFromParent")
            if removeFromParent then
                pcall(removeFromParent, battleBtn)
            end
        end
    end)

    local leftX = -620.0
    local topY = 100.0

    local okViewport = pcall(function()
        selectorWidget:AddToViewport(140)

        local setAlignmentInViewport = selectorWidget["SetAlignmentInViewport"]
        if setAlignmentInViewport then
            pcall(setAlignmentInViewport, selectorWidget, { X = 0.0, Y = 0.0 })
        end

        local setAnchorsInViewport = selectorWidget["SetAnchorsInViewport"]
        if setAnchorsInViewport then
            pcall(setAnchorsInViewport, selectorWidget, {
                Minimum = { X = 0.0, Y = 0.0 },
                Maximum = { X = 0.0, Y = 0.0 },
            })
        end

        local setPositionInViewport = selectorWidget["SetPositionInViewport"]
        if setPositionInViewport then
            pcall(setPositionInViewport, selectorWidget, { X = leftX, Y = topY }, false)
        end
    end)

    if not okViewport then
        print("[CustomMapRotation] Failed to add FreeMode selector preview to viewport")
        return
    end

    print("[CustomMapRotation] FreeMode selector preview added")
end

local function ensure_combat_event_class()
    if combatEventClass and is_uobject_valid(combatEventClass) then
        return combatEventClass
    end

    local classPath = "/Game/Blueprints/DataAssets/CombatScenarios/BP_CombatEvent_Master.BP_CombatEvent_Master_C"
    local obj = StaticFindObject(classPath)
    if not obj and LoadAsset then
        pcall(LoadAsset, classPath)
        obj = StaticFindObject(classPath)
    end

    if obj and is_uobject_valid(obj) then
        combatEventClass = obj
        return combatEventClass
    end

    return nil
end

local function make_identity_transform()
    local mathLib = ensure_kismet_math_library()
    local makeTransform = mathLib and mathLib["MakeTransform"] or nil
    if not makeTransform then
        return nil
    end

    local ok, transform = pcall(
        makeTransform,
        mathLib,
        { X = 0.0, Y = 0.0, Z = 0.0 },
        { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
        { X = 1.0, Y = 1.0, Z = 1.0 }
    )
    if ok then
        return transform
    end

    return nil
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

local function extract_game_asset_path(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local cleaned = text:gsub('^"(.*)"$', "%1")
    cleaned = cleaned:gsub("\\", "/")
    local gamePath = cleaned:match("(/[Gg][Aa][Mm][Ee][^%s\"']+)")
    if gamePath and gamePath ~= "" then
        return gamePath
    end
    return nil
end

local function combat_event_display_name_from_class_path(classPath)
    if type(classPath) ~= "string" or classPath == "" then
        return nil
    end

    local token = classPath:match("%.([A-Za-z0-9_]+)_C$")
    if not token or token == "" then
        token = classPath:match("([^/]+)$")
    end
    if not token or token == "" then
        return nil
    end

    local overrideName = NATIVE_DISPLAY_NAME_OVERRIDES[token]
    if type(overrideName) == "string" then
        local trimmed = overrideName:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            return trimmed
        end
    end

    token = token:gsub("^BP_CombatEvent_", "")
    token = token:gsub("_", " ")
    token = token:gsub("(%l)(%u)", "%1 %2")
    token = token:gsub("^%s+", "")
    token = token:gsub("%s+$", "")
    if token == "" then
        return nil
    end

    return token
end

local function extract_level_path_from_asset_metadata(assetData)
    local tagsAndValues = value_to_string(get_asset_data_field(assetData, "TagsAndValues"))
    if tagsAndValues == "" then
        return nil
    end

    -- Prefer a level-tag-adjacent path if present.
    local nearLevel = tagsAndValues:match("[Ll]evel[^/]*(/[Gg][Aa][Mm][Ee][^,%]}\"'\r\n%s]+)")
    local extracted = extract_game_asset_path(nearLevel or tagsAndValues)
    if not extracted then
        return nil
    end

    return ensure_level_path(extracted)
end

local function query_assets_under_path(rootPath)
    freemode_native_log("query_assets_under_path: begin")
    local registry = ensure_asset_registry_interface()
    if not registry then
        freemode_native_log("query_assets_under_path: no registry")
        return {}
    end

    local searchAllAssets = registry["SearchAllAssets"]
    if searchAllAssets then
        freemode_native_log("query_assets_under_path: SearchAllAssets begin")
        pcall(searchAllAssets, registry, true)
        freemode_native_log("query_assets_under_path: SearchAllAssets end")
    end

    local waitForCompletion = registry["WaitForCompletion"]
    if waitForCompletion then
        freemode_native_log("query_assets_under_path: WaitForCompletion begin")
        pcall(waitForCompletion, registry)
        freemode_native_log("query_assets_under_path: WaitForCompletion end")
    end

    local scanPaths = registry["ScanPathsSynchronous"]
    if scanPaths then
        freemode_native_log("query_assets_under_path: ScanPathsSynchronous begin")
        pcall(scanPaths, registry, { rootPath }, false, true)
        freemode_native_log("query_assets_under_path: ScanPathsSynchronous end")
    end

    local getAssetsByPath = registry["GetAssetsByPath"]
    if not getAssetsByPath then
        return {}
    end

    local outAssets = {}
    local requestPath = UEHelpers and UEHelpers.FindOrAddFName and UEHelpers.FindOrAddFName(rootPath) or FName(rootPath)
    freemode_native_log("query_assets_under_path: GetAssetsByPath begin")
    local ok, result = pcall(getAssetsByPath, registry, requestPath, outAssets, true, false)
    freemode_native_log(string.format("query_assets_under_path: GetAssetsByPath end ok=%s", tostring(ok)))
    if not ok then
        return {}
    end

    local assets = {}
    local source = type(result) == "table" and result or outAssets
    for_each_tarray(source, function(_, raw)
        local assetData = unwrap_remote_value(raw)
        if assetData then
            assets[#assets + 1] = assetData
        end
        return false
    end)

    freemode_native_log(string.format("query_assets_under_path: discovered %d assets", #assets))

    return assets
end

local function discover_freemode_combat_event_class_paths()
    local rootPath = "/Game/Blueprints/DataAssets/CombatScenarios"
    freemode_native_log("discover_native_maps: begin")
    local assets = query_assets_under_path(rootPath)
    freemode_native_log(string.format("discover_native_maps: query returned %d assets", #assets))
    if #assets == 0 then
        return {}
    end

    local nativeMaps = {}
    local seen = {}
    local masterName = normalize_text("BP_CombatEvent_Master")
    local masterClassPath = normalize_text(rootPath .. "/BP_CombatEvent_Master.BP_CombatEvent_Master_C")
    local masterClassToken = normalize_text("bp_combatevent_master")

    local function is_child_of_master(assetData)
        local parentClass = normalize_text(get_asset_data_field(assetData, "ParentClass"))
        local nativeParentClass = normalize_text(get_asset_data_field(assetData, "NativeParentClass"))
        local tagsAndValues = normalize_text(get_asset_data_field(assetData, "TagsAndValues"))

        if parentClass ~= "" then
            return string.find(parentClass, "bp_combatevent_master", 1, true) ~= nil
                or string.find(parentClass, masterClassPath, 1, true) ~= nil
        end

        if nativeParentClass ~= "" then
            return string.find(nativeParentClass, "bp_combatevent_master", 1, true) ~= nil
                or string.find(nativeParentClass, masterClassPath, 1, true) ~= nil
        end

        if tagsAndValues ~= "" then
            return string.find(tagsAndValues, "bp_combatevent_master", 1, true) ~= nil
                or string.find(tagsAndValues, masterClassPath, 1, true) ~= nil
        end

        -- If parent metadata is unavailable in this build, fall back to folder + blueprint filtering.
        return true
    end

    for i = 1, #assets do
        freemode_native_log(string.format("discover_native_maps: scan asset %d/%d", i, #assets))
        local assetData = assets[i]
        local assetName = normalize_text(get_asset_data_field(assetData, "AssetName"))
        if assetName == "" then
            goto continue_scan
        end

        if assetName == masterName or string.find(assetName, masterClassToken, 1, true) ~= nil then
            freemode_native_log("discover_native_maps: skip master by name")
            goto continue_scan
        end

        local packagePath = normalize_text(get_asset_data_field(assetData, "PackagePath"))
        if not starts_with_ci(packagePath, normalize_text(rootPath)) then
            goto continue_scan
        end

        if not is_child_of_master(assetData) then
            goto continue_scan
        end

        local objectPath = build_object_path_from_asset_data(assetData)
        local classPath = ensure_class_path(objectPath)

        if normalize_text(classPath) == masterClassPath
            or string.find(normalize_text(classPath or ""), masterClassToken, 1, true) ~= nil then
            freemode_native_log("discover_native_maps: skip master by class path")
            goto continue_scan
        end

        if classPath and classPath ~= "" and not seen[classPath] then
            seen[classPath] = true
            local shortName = classPath:match("%.([A-Za-z0-9_]+)_C$") or classPath
            local isTourney = normalize_text(shortName):find("tourney", 1, true) ~= nil
            local levelPathMeta = extract_level_path_from_asset_metadata(assetData)
            nativeMaps[#nativeMaps + 1] = {
                name = shortName,
                sourceClassPath = classPath,
                isTourney = isTourney,
                levelPathMeta = levelPathMeta,
            }
            freemode_native_log(string.format("discover_native_maps: class queued %s", tostring(classPath)))
        end

        ::continue_scan::
    end

    local filteredNativeMaps = {}
    local occupiedLevels = {}

    for i = 1, #nativeMaps do
        local entry = nativeMaps[i]
        if entry.isTourney ~= true then
            filteredNativeMaps[#filteredNativeMaps + 1] = entry
            local key = normalize_text(entry.levelPathMeta)
            if key ~= "" then
                occupiedLevels[key] = true
            end
        end
    end

    for i = 1, #nativeMaps do
        local entry = nativeMaps[i]
        if entry.isTourney == true then
            local levelKey = normalize_text(entry.levelPathMeta)
            if levelKey ~= "" and occupiedLevels[levelKey] then
                freemode_native_log(string.format("discover_native_maps: skip duplicate tourney level class=%s level=%s", tostring(entry.sourceClassPath), tostring(entry.levelPathMeta)))
            else
                filteredNativeMaps[#filteredNativeMaps + 1] = entry
                if levelKey ~= "" then
                    occupiedLevels[levelKey] = true
                end
            end
        end
    end

    nativeMaps = filteredNativeMaps

    table.sort(nativeMaps, function(a, b)
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    print(string.format("[CustomMapRotation][FreeModeNativeTemp] Native maps discovered total: %d", #nativeMaps))
    return nativeMaps
end

local function build_discovered_maps()
    return MapAutoDiscovery.discover_maps(MAP_DISCOVERY, MAP_OVERRIDES)
end

local function get_custom_maps()
    if discoveredMapsCache ~= nil then
        return discoveredMapsCache
    end

    discoveredMapsCache = build_discovered_maps()
    print(string.format("[CustomMapRotation] Discovered %d custom maps under %s", #discoveredMapsCache, tostring(MAP_DISCOVERY.rootPath)))
    return discoveredMapsCache
end

local function build_load_asset_candidates(path)
    local candidates = {}
    local seen = {}

    push_unique(candidates, seen, path)

    local normalized = ensure_asset_path(path)
    push_unique(candidates, seen, normalized)

    local packagePath, objectName = (normalized or path):match("^(.+)%.([A-Za-z0-9_]+)$")
    if packagePath and objectName then
        push_unique(candidates, seen, packagePath)
    end

    return candidates
end

local function try_load_asset(path)
    if type(path) ~= "string" or path == "" or not LoadAsset then
        return false, nil
    end

    local loadedAny = false
    local loadedObject = nil
    local candidates = build_load_asset_candidates(path)
    for i = 1, #candidates do
        local candidate = candidates[i]
        local ok, out = pcall(LoadAsset, candidate)
        if ok and out then
            if is_uobject_valid(out) then
                loadedAny = true
                if not loadedObject then
                    loadedObject = out
                end
            else
                loadedAny = true
            end
        elseif ok then
            loadedAny = true
        end
    end

    return loadedAny, loadedObject
end

local function try_accept_resolved_object(obj, source, path)
    if not obj then
        return nil, source
    end

    if is_uobject_valid(obj) then
        return obj, source
    end

    print(string.format("[CustomMapRotation] Ignoring invalid object from %s for path: %s", tostring(source), tostring(path)))
    return nil, source
end

local function try_asset_registry_get(path)
    local helpers = ensure_asset_registry_helpers()
    if not helpers then
        return nil
    end

    if not (UEHelpers and UEHelpers.FindOrAddFName) then
        return nil
    end

    local normalized = ensure_asset_path(path)
    if type(normalized) ~= "string" or normalized == "" then
        return nil
    end

    local packagePath, objectName = normalized:match("^(.+)%.([A-Za-z0-9_]+)$")
    if not packagePath or not objectName then
        packagePath = normalized
        objectName = normalized:match("([^/]+)$")
    end

    local requests = {}
    requests[#requests + 1] = {
        ObjectPath = UEHelpers.FindOrAddFName(normalized),
    }

    if packagePath and objectName then
        requests[#requests + 1] = {
            PackageName = UEHelpers.FindOrAddFName(packagePath),
            AssetName = UEHelpers.FindOrAddFName(objectName),
        }
    end

    local getAsset = helpers["GetAsset"]
    if not getAsset then
        return nil
    end

    for i = 1, #requests do
        local req = requests[i]
        local ok, out = pcall(getAsset, helpers, req)
        if ok and out and is_uobject_valid(out) then
            return out
        end
    end

    return nil
end

find_asset_with_fallback = function(path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid-path"
    end

    local direct = StaticFindObject(path)
    local acceptedDirect = try_accept_resolved_object(direct, "StaticFindObject:direct", path)
    if acceptedDirect then
        return acceptedDirect, "StaticFindObject:direct"
    end

    local normalized = ensure_asset_path(path)
    if normalized and normalized ~= path then
        local second = StaticFindObject(normalized)
        local acceptedSecond = try_accept_resolved_object(second, "StaticFindObject:normalized", normalized)
        if acceptedSecond then
            return acceptedSecond, "StaticFindObject:normalized"
        end
    end

    local loadedAny, loadedObject = try_load_asset(path)
    local acceptedLoaded = try_accept_resolved_object(loadedObject, "LoadAsset", path)
    if acceptedLoaded then
        return acceptedLoaded, "LoadAsset"
    end

    local afterLoad = StaticFindObject(path)
    local acceptedAfterLoad = try_accept_resolved_object(afterLoad, "StaticFindObject:after-load-direct", path)
    if acceptedAfterLoad then
        return acceptedAfterLoad, "StaticFindObject:after-load-direct"
    end

    if normalized and normalized ~= path then
        local secondAfterLoad = StaticFindObject(normalized)
        local acceptedSecondAfterLoad = try_accept_resolved_object(secondAfterLoad, "StaticFindObject:after-load-normalized", normalized)
        if acceptedSecondAfterLoad then
            return acceptedSecondAfterLoad, "StaticFindObject:after-load-normalized"
        end
    end

    local fromRegistry = try_asset_registry_get(path)
    local acceptedRegistry = try_accept_resolved_object(fromRegistry, "AssetRegistryHelpers:GetAsset", path)
    if acceptedRegistry then
        return acceptedRegistry, "AssetRegistryHelpers:GetAsset"
    end

    if loadedAny then
        print("[CustomMapRotation] LoadAsset succeeded but object not discoverable via StaticFindObject:", path)
    else
        print("[CustomMapRotation] Missing thumbnail asset:", path)
    end

    return nil, "missing"
end

local function resolve_thumbnail_asset(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local cacheKey = ensure_asset_path(path) or path
    if thumbnailAssetCache[cacheKey] and is_uobject_valid(thumbnailAssetCache[cacheKey]) then
        return thumbnailAssetCache[cacheKey], "cache"
    end

    local asset = find_asset_with_fallback(path)
    if asset then
        thumbnailAssetCache[cacheKey] = asset
    end
    return asset
end

local function make_ftext(value)
    local text = value_to_string(value)
    if text == "" then
        return nil
    end

    local lib = UEHelpers.GetKismetTextLibrary()
    local conv = lib and lib["Conv_StringToText"] or nil
    if not conv then
        return nil
    end

    local ok, out = pcall(conv, lib, text)
    if ok and out ~= nil then
        return out
    end

    return nil
end

local function assign_struct_field(passport, fieldName, value)
    if passport == nil then
        trace_log(string.format("assign_struct_field: missing passport for field %s", tostring(fieldName)))
        return false
    end

    trace_log(string.format("assign_struct_field: writing field %s", tostring(fieldName)))
    local ok = pcall(function()
        passport[fieldName] = value
    end)
    trace_log(string.format("assign_struct_field: field %s write result=%s", tostring(fieldName), tostring(ok)))
    return ok
end

local function update_passport_fields(passport, mapEntry, index, minimalOnly)
    trace_log(string.format("update_passport_fields: start mapIndex=%d", tonumber(index) or -1))
    if passport == nil then
        trace_log("update_passport_fields: missing passport")
        return false, "missing-passport"
    end

    local mapName = mapEntry.name or mapEntry.title or string.format("Custom Map %d", index)
    local levelPath = ensure_level_path(get_map_entry_value(mapEntry, { "levelPath", "LevelPath", "level", "Level", "path" }))
    if not levelPath then
        trace_log("update_passport_fields: missing level path")
        return false, "missing-level-path"
    end

    local mapNameText = make_ftext(mapName)
    if mapNameText ~= nil then
        assign_struct_field(passport, PASSPORT.Name, mapNameText)
    end

    assign_struct_field(passport, PASSPORT.LevelPath, FName(levelPath))

    local thumbnailObject = get_map_entry_value(mapEntry, { "thumbnailObject", "ThumbnailObject", "thumbnailAsset", "ThumbnailAsset" })
    if thumbnailObject and is_uobject_valid(thumbnailObject) then
        assign_struct_field(passport, PASSPORT.Thumbnail, thumbnailObject)
    end

    local thumbnailPath = get_map_entry_value(mapEntry, { "thumbnailPath", "ThumbnailPath", "thumbnail", "Thumbnail", "thumbnailAssetPath", "thumbPath", "ThumbPath" })
    if (thumbnailObject == nil or not is_uobject_valid(thumbnailObject)) and type(thumbnailPath) == "string" and thumbnailPath ~= "" then
        trace_log(string.format("update_passport_fields: resolving thumbnail %s", thumbnailPath))
        local thumbnailAsset = resolve_thumbnail_asset(thumbnailPath)
        if thumbnailAsset then
            assign_struct_field(passport, PASSPORT.Thumbnail, thumbnailAsset)
        else
            print(string.format("[CustomMapRotation] Warning: Failed to resolve thumbnail: %s", thumbnailPath))
        end
    end

    if minimalOnly == true then
        trace_log("update_passport_fields: success (minimal mode)")
        return true, nil
    end

    local nextId = resolve_integer_value(get_map_entry_value(mapEntry, { "id", "ID" }))
    if nextId == nil then
        nextId = 500000 + index -- arbitrary, probably doesnt need to be unique even
    end
    assign_struct_field(passport, PASSPORT.ID, nextId)
    trace_log(string.format("update_passport_fields: assigned id=%s", tostring(nextId)))

    local betValue = resolve_integer_value(get_map_entry_value(mapEntry, { "betAmount", "BetAmount", "bet", "Bet" }))
    if betValue ~= nil then
        assign_struct_field(passport, PASSPORT.BetAmount, betValue)
    end

    local rewardValue = resolve_integer_value(get_map_entry_value(mapEntry, { "rewardAmount", "RewardAmount", "reward", "Reward" }))
    if rewardValue ~= nil then
        assign_struct_field(passport, PASSPORT.RewardAmount, rewardValue)
    end

    local equipmentBudget = resolve_integer_value(get_map_entry_value(mapEntry, { "equipmentBudget", "EquipmentBudget", "equipment", "Equipment", "budget", "Budget" }))
    if equipmentBudget ~= nil then
        assign_struct_field(passport, PASSPORT.EquipmentBudget, equipmentBudget)
    end

    local combatantsAmount = resolve_integer_value(get_map_entry_value(mapEntry, { "combatantsAmount", "CombatantsAmount", "combatants", "Combatants", "combatantsCount", "CombatantsCount" }))
    if combatantsAmount ~= nil then
        assign_struct_field(passport, PASSPORT.CombatantsAmount, combatantsAmount)
    end

    local roundsAmount = resolve_integer_value(get_map_entry_value(mapEntry, { "roundsAmount", "RoundsAmount", "rounds", "Rounds", "roundCount", "RoundCount" }))
    if roundsAmount ~= nil then
        assign_struct_field(passport, PASSPORT.RoundsAmount, roundsAmount)
    end

    local loseCondition = resolve_enum_value(get_map_entry_value(mapEntry, { "loseCondition", "LoseCondition", "lose", "Lose" }), LOSE_CONDITIONS_BY_NAME)
    if loseCondition ~= nil then
        assign_struct_field(passport, PASSPORT.LoseCondition, loseCondition)
    end

    local combatMode = resolve_enum_value(get_map_entry_value(mapEntry, { "combatMode", "CombatMode", "mode", "Mode" }), COMBAT_MODES_BY_NAME)
    if combatMode ~= nil then
        assign_struct_field(passport, PASSPORT.CombatMode, combatMode)
    end

    local tierValue = resolve_enum_value(get_map_entry_value(mapEntry, { "tier", "Tier", "rank", "Rank" }), RANKS_BY_NAME)
    if tierValue ~= nil then
        assign_struct_field(passport, PASSPORT.Tier, tierValue)
    end

    trace_log("update_passport_fields: success")
    return true, nil
end

local function map_key(mapEntry)
    if type(mapEntry) ~= "table" then
        return nil
    end

    local name = normalize_text(get_map_entry_value(mapEntry, { "name", "Name", "title", "Title" }))
    local level = normalize_text(ensure_level_path(get_map_entry_value(mapEntry, { "levelPath", "LevelPath", "level", "Level", "path" })))
    if name == "" and level == "" then
        return nil
    end

    return string.format("%s|%s", name, level)
end

local function spawn_combat_event_item(widget, mapEntry, mapIndex, classOverride, minimalOnly)
    trace_log(string.format("spawn_combat_event_item: start mapIndex=%s", tostring(mapIndex)))
    local gs = ensure_gameplay_statics()
    local klass = classOverride or ensure_combat_event_class()
    local spawnTransform = make_identity_transform()

    if not (gs and klass and spawnTransform) then
        trace_log("spawn_combat_event_item: missing dependency")
        return nil, "missing-spawn-dependency"
    end

    local beginSpawn = gs["BeginDeferredActorSpawnFromClass"]
    local finishSpawn = gs["FinishSpawningActor"]
    if not (beginSpawn and finishSpawn) then
        trace_log("spawn_combat_event_item: missing spawn function")
        return nil, "missing-spawn-function"
    end

    trace_log("spawn_combat_event_item: BeginDeferredActorSpawnFromClass begin")
    local okBegin, deferredActor = pcall(beginSpawn, gs, widget, klass, spawnTransform, 1, nil, 1)
    trace_log(string.format("spawn_combat_event_item: BeginDeferredActorSpawnFromClass result ok=%s actor=%s", tostring(okBegin), tostring(deferredActor ~= nil)))
    if not okBegin or deferredActor == nil then
        return nil, "begin-spawn-failed", nil
    end

    trace_log("spawn_combat_event_item: FinishSpawningActor begin")
    local okFinish, itemActor = pcall(finishSpawn, gs, deferredActor, spawnTransform, 1)
    trace_log(string.format("spawn_combat_event_item: FinishSpawningActor ok=%s actor=%s", tostring(okFinish), tostring(itemActor ~= nil)))
    if not okFinish or itemActor == nil then
        return nil, "finish-spawn-failed", nil
    end

    trace_log("spawn_combat_event_item: reading itemActor.Passport")
    local passport = unwrap_remote_value(itemActor["Passport"])
    if passport == nil then
        trace_log("spawn_combat_event_item: fallback to deferredActor.Passport")
        passport = unwrap_remote_value(deferredActor["Passport"])
    end
    trace_log(string.format("spawn_combat_event_item: passport available=%s", tostring(passport ~= nil)))
    if passport == nil then
        return nil, "missing-passport-template", nil
    end

    if mapEntry ~= nil then
        local okUpdate, updateErr = update_passport_fields(passport, mapEntry, mapIndex, minimalOnly == true)
        trace_log(string.format("spawn_combat_event_item: update_passport_fields ok=%s err=%s", tostring(okUpdate), tostring(updateErr)))
        if not okUpdate then
            return nil, updateErr or "passport-update-failed", nil
        end
    end

    -- Keep only in-place field writes on itemActor.Passport. Explicit writeback paths are crash-prone in this build.
    trace_log("spawn_combat_event_item: using in-place itemActor.Passport field writes only")

    trace_log("spawn_combat_event_item: success")
    return itemActor, nil, passport
end

local function inject_maps_into_rotation(widget)
    trace_log("inject_maps_into_rotation: start")
    if not is_uobject_valid(widget) then
        print("[CustomMapRotation] Could not resolve UI_Jester widget")
        trace_log("inject_maps_into_rotation: abort invalid widget")
        return
    end

    local list = widget.ListView_89
    if not is_uobject_valid(list) then
        print("[CustomMapRotation] Could not resolve ListView_89")
        trace_log("inject_maps_into_rotation: abort missing list")
        return
    end

    local customMaps = get_custom_maps()
    if #customMaps == 0 then
        print("[CustomMapRotation] No custom maps discovered")
        trace_log("inject_maps_into_rotation: abort no custom maps")
        return
    end
    trace_log(string.format("inject_maps_into_rotation: customMaps=%d", #customMaps))

    local existing = injectedCustomMapKeysForSession
    local okCurrentCount, currentCount = safe_trace_call("inject_maps_into_rotation.list:GetNumItems(current)", function()
        return list:GetNumItems()
    end)
    if not okCurrentCount or type(currentCount) ~= "number" then
        print("[CustomMapRotation] Failed to read current list count; aborting injection")
        return
    end

    trace_log(string.format("inject_maps_into_rotation: list currently has %d item(s)", currentCount))

    local added = 0

    for i = 1, #customMaps do
        local mapEntry = customMaps[i]
        trace_log(string.format("inject_maps_into_rotation: processing map %d", i))
        if type(mapEntry) == "table" and mapEntry.enabled ~= false then
            local key = map_key(mapEntry)
            if key and not existing[key] then
                local item, err = spawn_combat_event_item(widget, mapEntry, i)
                if item then
                    trace_log(string.format("inject_maps_into_rotation: map %d spawn ok; adding to ListView", i))
                    trace_log(string.format("inject_maps_into_rotation: map %d list:AddItem begin", i))
                    local okAdd = pcall(function()
                        list:AddItem(item)
                    end)
                    trace_log(string.format("inject_maps_into_rotation: map %d list:AddItem ok=%s", i, tostring(okAdd)))
                    if okAdd then
                        existing[key] = true
                        added = added + 1
                    else
                        print(string.format("[CustomMapRotation] Failed to add list item for map %d", i))
                        trace_log(string.format("inject_maps_into_rotation: map %d list:AddItem failed", i))
                    end
                else
                    print(string.format("[CustomMapRotation] Skipped custom map %d (%s)", i, tostring(err)))
                    trace_log(string.format("inject_maps_into_rotation: map %d skipped err=%s", i, tostring(err)))
                end
            end
        end
    end

    if added > 0 then
        print(string.format("[CustomMapRotation] Added %d custom map entries to ListView", added))
    else
        print("[CustomMapRotation] No new custom maps were added")
    end
    trace_log("inject_maps_into_rotation: end")
end

local function add_item_to_list(list, item, label)
    if not (is_uobject_valid(list) and item) then
        return false
    end

    local ok = pcall(function()
        list:AddItem(item)
    end)
    if not ok then
        print(string.format("[CustomMapRotation] Failed to add list item (%s)", tostring(label)))
        return false
    end

    return true
end

local function inject_freemode_maps_into_rotation(widget)
    freemode_native_log("inject_freemode_maps_into_rotation: begin")
    if not is_uobject_valid(widget) then
        freemode_native_log("inject_freemode_maps_into_rotation: widget invalid")
        return
    end

    local list = widget.ListView_89
    if not is_uobject_valid(list) then
        freemode_native_log("inject_freemode_maps_into_rotation: list invalid")
        return
    end

    freemode_native_log("inject_freemode_maps_into_rotation: clear list begin")
    pcall(function()
        list:ClearListItems()
    end)
    freemode_native_log("inject_freemode_maps_into_rotation: clear list end")

    local addedNative = 0
    freemode_native_log("inject_freemode_maps_into_rotation: discover native begin")
    local nativeMaps = discover_freemode_combat_event_class_paths()
    freemode_native_log(string.format("inject_freemode_maps_into_rotation: native discovered=%d", #nativeMaps))
    for i = 1, #nativeMaps do
        local mapEntry = nativeMaps[i]
        freemode_native_log(string.format("inject_freemode_maps_into_rotation: probe native %d begin class=%s", i, tostring(mapEntry.sourceClassPath)))

        local nativeClassObj = nil
        if type(mapEntry.sourceClassPath) == "string" and mapEntry.sourceClassPath ~= "" then
            nativeClassObj = find_asset_with_fallback(mapEntry.sourceClassPath)
        end

        if not is_uobject_valid(nativeClassObj) then
            print(string.format("[CustomMapRotation][FreeModeNativeTemp] Failed to resolve native class object: %s", tostring(mapEntry.sourceClassPath)))
            goto continue_native
        end

        local probeItem, probeErr, probePassport = spawn_combat_event_item(widget, nil, i, nativeClassObj, true)
        freemode_native_log(string.format("inject_freemode_maps_into_rotation: probe native %d end ok=%s", i, tostring(probeItem ~= nil)))
        if not probeItem then
            print(string.format("[CustomMapRotation][FreeModeNativeTemp] Failed to probe native passport: %s (%s)", tostring(mapEntry.sourceClassPath), tostring(probeErr)))
            goto continue_native
        end

        local nativeDisplayName = combat_event_display_name_from_class_path(mapEntry.sourceClassPath)
        if nativeDisplayName and probePassport then
            local displayNameText = make_ftext(nativeDisplayName)
            if displayNameText ~= nil then
                assign_struct_field(probePassport, PASSPORT.Name, displayNameText)
            end
        end

        freemode_native_log(string.format("inject_freemode_maps_into_rotation: add native %d direct begin", i))
        if add_item_to_list(list, probeItem, nativeDisplayName or mapEntry.name or mapEntry.sourceClassPath or tostring(i)) then
            addedNative = addedNative + 1
        else
            print(string.format("[CustomMapRotation][FreeModeNativeTemp] Failed to add native probe item: %s", tostring(mapEntry.sourceClassPath)))
        end
        freemode_native_log(string.format("inject_freemode_maps_into_rotation: add native %d direct end", i))

        ::continue_native::
    end

    local addedCustom = 0
    freemode_native_log("inject_freemode_maps_into_rotation: custom pass begin")
    local customMaps = get_custom_maps()
    for i = 1, #customMaps do
        local mapEntry = customMaps[i]
        if type(mapEntry) == "table" and mapEntry.enabled ~= false then
            local item = spawn_combat_event_item(widget, mapEntry, i, nil, true)
            if item then
                if add_item_to_list(list, item, mapEntry.name or mapEntry.levelPath or tostring(i)) then
                    addedCustom = addedCustom + 1
                end
            end
        end
    end
    freemode_native_log(string.format("inject_freemode_maps_into_rotation: end native=%d custom=%d", addedNative, addedCustom))

    print(string.format("[CustomMapRotation] Free mode list rebuilt: %d native + %d custom", addedNative, addedCustom))
end

local function queue_freemode_injection(widget)
    freemode_native_log("queue_freemode_injection: begin")
    if freeModeInjectionInProgress or freeModeInjectionQueued then
        freemode_native_log("queue_freemode_injection: blocked by state")
        return
    end

    if not is_uobject_valid(widget) then
        freemode_native_log("queue_freemode_injection: widget invalid")
        return
    end

    freeModeInjectionQueued = true

    local function perform_injection()
        freemode_native_log("queue_freemode_injection.perform: begin")
        freeModeInjectionQueued = false
        if freeModeInjectionInProgress then
            freemode_native_log("queue_freemode_injection.perform: already in progress")
            return
        end
        if not is_uobject_valid(widget) then
            freemode_native_log("queue_freemode_injection.perform: widget invalid")
            return
        end

        freeModeInjectionInProgress = true
        freemode_native_log("queue_freemode_injection.perform: inject begin")
        local okInject, injectErr = pcall(inject_freemode_maps_into_rotation, widget)
        freemode_native_log(string.format("queue_freemode_injection.perform: inject end ok=%s", tostring(okInject)))
        freeModeInjectionInProgress = false

        if not okInject then
            freeModeInjectedForSession = false
            print(string.format("[CustomMapRotation] Free mode injection failed: %s", tostring(injectErr)))
            return
        end

        freeModeInjectedForSession = true
    end

    if ExecuteWithDelay then
        ExecuteWithDelay(1, function()
            if ExecuteInGameThread then
                ExecuteInGameThread(perform_injection)
            else
                perform_injection()
            end
        end)
        return
    end

    if ExecuteInGameThread then
        ExecuteInGameThread(perform_injection)
        return
    end

    perform_injection()
end

local function queue_injection(widget)
    if selectorInjectedForSession then
        trace_log("queue_injection: already injected for session")
        return
    end

    if selectorInjectionInProgress then
        trace_log("queue_injection: injection already in progress")
        return
    end

    if selectorInjectionQueued then
        trace_log("queue_injection: injection already queued")
        return
    end

    if not is_uobject_valid(widget) then
        trace_log("queue_injection: widget invalid")
        return
    end

    selectorInjectionQueued = true

    local function perform_injection()
        selectorInjectionQueued = false

        if selectorInjectedForSession or selectorInjectionInProgress then
            trace_log("queue_injection.perform: skipped due to state")
            return
        end

        if not is_uobject_valid(widget) then
            trace_log("queue_injection.perform: widget no longer valid")
            return
        end

        selectorInjectionInProgress = true
        trace_log("queue_injection.perform: calling inject_maps_into_rotation")
        local okInject, injectErr = pcall(inject_maps_into_rotation, widget)
        selectorInjectionInProgress = false

        if not okInject then
            selectorInjectedForSession = false
            print(string.format("[CustomMapRotation] Injection failed: %s", tostring(injectErr)))
            trace_log("queue_injection.perform: injection failed")
            return
        end

        selectorInjectedForSession = true
        trace_log("queue_injection.perform: injection completed and session flag set")
    end

    if ExecuteWithDelay then
        trace_log("queue_injection: scheduling ExecuteWithDelay(1) -> ExecuteInGameThread")
        ExecuteWithDelay(1, function()
            if ExecuteInGameThread then
                ExecuteInGameThread(perform_injection)
            else
                perform_injection()
            end
        end)
        return
    end

    if ExecuteInGameThread then
        trace_log("queue_injection: scheduling ExecuteInGameThread")
        ExecuteInGameThread(perform_injection)
        return
    end

    trace_log("queue_injection: no scheduler available, running immediately")
    perform_injection()
end

local function simplify_freemode_map_list_entry(ctx)
    local getCtx = ctx and ctx["get"]
    ---@type UUI_List_MapSelect_C|nil
    local rowWidget = getCtx and getCtx(ctx) or nil
    if rowWidget == nil then
        return
    end
    if not is_uobject_valid(rowWidget) then
        return
    end

    local gi = safe_member(rowWidget, "As GI Settings")
    if not gi or gi["Free Mode Activated"] ~= true then
        return
    end

    local widgetsToRemove = {
        "TextBlock_1", -- prize
        "TextBlock_2", -- round
        "TextBlock_3", -- rounds
        "TextBlock_4",
        "TextBlock_5",
        "TextBlock_6",
        "Image",
        "Image_0",
        "Image_61",
        "Image_101",
    }

    --[[local widgetsToZIndexIncrease = {
        "Name",
        "Background",
        "Image_100"
    }]]

    for i = 1, #widgetsToRemove do
        local name = widgetsToRemove[i]
        local child = safe_member(rowWidget, name)
        if is_uobject_valid(child) then
            local removeFromParent = safe_member(child, "RemoveFromParent")
            if removeFromParent then
                pcall(removeFromParent, child)
            end
        end
    end

    pcall(function()
        local image = safe_member(rowWidget, "Image_100")
        if is_uobject_valid(image) then
            local texture = find_asset_with_fallback("/Game/Mods/Assets/battle_selector_overlay_minimal.battle_selector_overlay_minimal")
            local setBrushFromTexture = safe_member(image, "SetBrushFromTexture")
            if setBrushFromTexture and texture and texture:IsValid() then
                pcall(setBrushFromTexture, image, texture, true)
            end
        end

        --[[for i = 1, #widgetsToZIndexIncrease do
            local name = widgetsToZIndexIncrease[i]
            local child = safe_member(rowWidget, name)
            if is_uobject_valid(child) then
                local getZOrder = safe_member(child, "GetZOrder")
                local setZOrder = safe_member(child, "SetZOrder")
                if setZOrder then
                    pcall(setZOrder, child, (getZOrder and getZOrder(child) or 0) + 1001)
                    print(string.format("Increased ZOrder for %s", name))
                end
            end
        end]]
    end)

    -- check widget tree for remaining text label for Bet and Prize to remove as well
    --[[local success, result = pcall(function()
        ---@type UWidgetTree
        local widgetTree = rowWidget.WidgetTree
        if widgetTree then
            print("Trying to find TextBlock_1 in widget tree for removal")
            print("WidgetTree:", widgetTree)
            local findWidget = widgetTree["FindWidget"]
            print("Func:", findWidget)
            local test = {}
            findWidget(widgetTree, "TextBlock_1", test)
            print("!!!!!", test)
            if widget and is_uobject_valid(widget) then
                local removeFromParent = safe_member(widget, "RemoveFromParent")
                if removeFromParent then
                    pcall(removeFromParent, widget)
                end
            end
            for i,v in pairs(widgetTree) do
                if i ~= nil then print(i) end
            end
        end
    end)
    print("TextBlock_1 removal attempt result:", success, result)]]
end

local function register_widget_hook()
    local function queue_injection_from_ctx(ctx, sourceLabel)
        local okHook, hookErr = pcall(function()
            local getCtx = ctx and ctx["get"]
            ---@type UUI_Jester_C|nil
            local widget = getCtx and getCtx(ctx) or nil
            if widget == nil then
                return
            end
            if not is_uobject_valid(widget) then
                return
            end

            local gi = widget["As GI Settings"]
            local list = widget.ListView_89
            if not gi or not list then
                return
            end

            if gi["Free Mode Activated"] then
                if freeModeInjectedForSession then
                    return
                end
                queue_freemode_injection(widget)
                return
            end

            if selectorInjectionInProgress or selectorInjectionQueued then
                return
            end

            local expected = #gi["Available Combat Events"]
            if expected <= 0 then
                return
            end

            local okCount, count = safe_trace_call("hook.list:GetNumItems", function()
                return list:GetNumItems()
            end)
            if not okCount or type(count) ~= "number" then
                return
            end

            -- The base list is ready and contains only vanilla entries.
            -- Treat this as a fresh open/reopen cycle and allow reinjection.
            if count == expected then
                if selectorInjectedForSession then
                    selectorInjectedForSession = false
                    injectedCustomMapKeysForSession = {}
                    print(string.format("[CustomMapRotation] Reset injection state for reopened selector (%s)", tostring(sourceLabel)))
                end
                queue_injection(widget)
                return
            end
        end)

        if not okHook then
            print(string.format("[CustomMapRotation] Hook callback failed (%s): %s", tostring(sourceLabel), tostring(hookErr)))
        end
    end

    RegisterHook(MAP_SELECTOR_WIDGET_CLASS .. ":Construct", function(ctx)
        queue_injection_from_ctx(ctx, "Construct")
    end)

    RegisterHook(MAP_SELECTOR_WIDGET_CLASS .. ":BndEvt__UI_Jester_ListView_89_K2Node_ComponentBoundEvent_2_OnListEntryInitializedDynamic__DelegateSignature", function(ctx)
        queue_injection_from_ctx(ctx, "ListEntryInitialized")
    end)

    RegisterHook(FREEMODE_WIDGET_CLASS .. ":Construct", function(ctx)
        local getCtx = ctx and ctx["get"]
        local freeModeWidget = getCtx and getCtx(ctx) or nil
        local widgets = collect_jester_widgets(freeModeWidget)
        local hasReusableJester = false

        if widgets then
            ---@param widget UUI_Jester_C
            for _, widget in ipairs(widgets) do
                if is_uobject_valid(widget) then
                    hasReusableJester = true
                    break
                end
            end
        end

        if not hasReusableJester then
            spawn_freemode_selector_preview(ctx)
            widgets = collect_jester_widgets(freeModeWidget)
        end

        if not widgets then
            return
        end

        ---@param widget UUI_Jester_C
        for _, widget in ipairs(widgets) do
            if is_uobject_valid(widget) then
                ---@cast widget UUI_Jester_C
                show_jester_widget(widget)
            end
        end
    end)

    RegisterHook(FREEMODE_WIDGET_CLASS .. ":BndEvt__UI_Jester_Button_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature", function(ctx)
        local getCtx = ctx and ctx["get"]
        local freeModeWidget = getCtx and getCtx(ctx) or nil
        local widgets = collect_jester_widgets(freeModeWidget)
        if not widgets then
            return
        end

        ---@param widget UUI_Jester_C
        for _, widget in ipairs(widgets) do
            if is_uobject_valid(widget) then
                ---@cast widget UUI_Jester_C
                hide_jester_widget(widget)
            end
        end

        selectorInjectedForSession = false
        selectorInjectionInProgress = false
        selectorInjectionQueued = false
        freeModeInjectedForSession = false
        freeModeInjectionInProgress = false
        freeModeInjectionQueued = false
        injectedCustomMapKeysForSession = {}
    end)

    RegisterHook(MAP_LIST_ENTRY_WIDGET_CLASS .. ":Construct", function(ctx)
        local okHook, hookErr = pcall(simplify_freemode_map_list_entry, ctx)
        if not okHook then
            print(string.format("[CustomMapRotation] Hook callback failed (UI_List_MapSelect:Construct): %s", tostring(hookErr)))
        end
    end)

    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(_)
        selectorInjectedForSession = false
        selectorInjectionInProgress = false
        selectorInjectionQueued = false
        freeModeInjectedForSession = false
        freeModeInjectionInProgress = false
        freeModeInjectionQueued = false
        injectedCustomMapKeysForSession = {}
        discoveredMapsCache = nil
        thumbnailAssetCache = {}

        local widgets = FindAllOf("UI_Jester_C")
        if not widgets then
            return
        end

        ---@param widget UUI_Jester_C
        for _, widget in ipairs(widgets) do
            if is_uobject_valid(widget) then
                widget:RemoveFromViewport()
                --pcall(safe_member(widget, "RemoveFromParent"), widget)
            end
        end
    end)

    print("[CustomMapRotation] Hooks registered")
end

ExecuteInGameThread(function()
    local discovered = get_custom_maps()
    MapAutoDiscovery.debug_print_maps(discovered)

    register_widget_hook()
    print(string.format("[CustomMapRotation] Ready. %d discovered map entries.", #discovered))
end)
