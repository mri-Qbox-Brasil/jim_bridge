-- Client Item Registry
-- ---------------------------------------------------------------------------
-- Dynamically derived list of items a client is allowed to request through the
-- ":server:toggleItem" net event.
--
-- There is no hardcoded item list. The registry is built once, on first use,
-- from the host resource's own tables:
--
--   * Crafting        - recipe results and ingredients
--   * Stores          - shop item definitions ({ name = "item" })
--   * MaterialRecieve - material returns
--   * createUseableItem() registrations
--   * allowClientItem() calls
--
-- Because it reads the script's existing definitions, adding a new recipe or
-- shop item automatically makes it grantable. Servers do not need to maintain
-- a second list.
--
-- Items that are not found in any of the above are refused.
-- ---------------------------------------------------------------------------

ClientItemAllowlist = ClientItemAllowlist or {}
ClientItemUseable = ClientItemUseable or {}

local built = false

--- Default maximum a client may request of a dynamically discovered item.
ClientItemDefaultMax = ClientItemDefaultMax or 10

local function add(item, max)
    if type(item) ~= "string" or item == "" then return end
    if ClientItemAllowlist[item] == nil then
        ClientItemAllowlist[item] = tonumber(max) or ClientItemDefaultMax
    end
end

-- Walks a table and treats every string key and string value as a candidate
-- item name. Non-item strings are harmless because the caller still runs
-- doesItemExist() before granting anything.
local function scan(tbl, seen, depth)
    if type(tbl) ~= "table" or seen[tbl] then return end
    if depth and depth > 12 then return end
    seen[tbl] = true

    for k, v in pairs(tbl) do
        if type(k) == "string" then add(k) end
        if type(v) == "table" then
            scan(v, seen, (depth or 0) + 1)
        elseif type(v) == "string" then
            add(v)
        end
    end
end

--- Builds the registry from whatever item tables the host resource exposes.
local function build()
    if built then return end
    built = true

    local seen = {}
    if type(Crafting) == "table" then scan(Crafting, seen, 0) end
    if type(Stores) == "table" then scan(Stores, seen, 0) end
    if type(MaterialRecieve) == "table" then scan(MaterialRecieve, seen, 0) end
    -- Scripts keep item names in Config too (shops, sell tables, processing).
    -- This is what makes the registry follow each server's own configuration.
    if type(Config) == "table" then scan(Config, seen, 0) end

    for item in pairs(ClientItemUseable) do add(item) end

    local count = 0
    for _ in pairs(ClientItemAllowlist) do count = count + 1 end
    debugPrint("^6Bridge^7: ^2Client item registry built for ^3"..tostring(getScript()).."^7 - ^6"..count.."^7 entries")

    if count == 0 then
        print("^6Bridge^7: ^3"..tostring(getScript()).." ^1has no item definitions to build a client registry from^7.")
        print("^6Bridge^7: ^1Client-side addItem/removeItem grants are disabled for this resource^7.")
        print("^6Bridge^7: ^2Call ^3allowClientItem(\"item_name\", maxAmount)^2 if this resource needs them^7.")
    end
end

--- Registers an item as client-grantable. Use this for items that are not
--- covered by the host resource's Crafting/Stores/MaterialRecieve tables.
--- @param item string
--- @param maxAmount number|nil
function allowClientItem(item, maxAmount)
    if type(item) ~= "string" or item == "" then return end
    ClientItemAllowlist[item] = tonumber(maxAmount) or ClientItemDefaultMax
end

--- Records an item registered through createUseableItem().
--- @param item string
function registerClientUseableItem(item)
    if type(item) == "string" and item ~= "" then
        ClientItemUseable[item] = true
    end
end

--- Returns the maximum amount a client may request, or nil if not allowed.
--- Triggers the one-time build on first call.
--- @param item string
--- @return number|nil
function isClientItemAllowed(item)
    if not built then build() end
    return ClientItemAllowlist[item]
end
