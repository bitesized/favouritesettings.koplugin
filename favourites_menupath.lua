--[[--
Stable references to entries in KOReader's top menu.

A favourite is stored as a path: one key per menu level, from the tab down to
the entry itself. Each key records everything that could identify the entry
again later, because none of it is reliable on its own:

* `id` is set by the menu sorter, but only for entries that live in the order
  tables; entries declared inline inside a `sub_item_table` have none.
* `text` is stable across restarts, but changes with the UI language, and is
  absent from entries that build their label with a `text_func`.
* `index` survives a rename, but shifts as soon as a plugin is toggled.

Resolution tries them in that order, so a path keeps working when a menu is
reordered, an entry is renamed, or the UI language changes -- just not all
three at once.

@module koplugin.favouritesettings.favourites_menupath
--]]--

local MenuPath = {}

local SEPARATOR_TEXT = "KOMenu:separator"

--- Returns an entry's displayed label, evaluating `text_func` if it has one.
function MenuPath.getText(item)
    if item.text_func then
        local ok, text = pcall(item.text_func)
        if ok and type(text) == "string" then
            return text
        end
    end
    return item.text
end

function MenuPath.isSeparator(item)
    return item.text == SEPARATOR_TEXT
end

function MenuPath.hasChildren(item)
    return item.sub_item_table ~= nil or item.sub_item_table_func ~= nil
end

--- Returns an entry's child entries, or nil for a leaf.
-- `sub_item_table_func` is called here, so only ask for children you are about
-- to show: some of them are not cheap to build.
function MenuPath.getChildren(item)
    if item.sub_item_table_func then
        local ok, sub = pcall(item.sub_item_table_func)
        return ok and sub or nil
    end
    return item.sub_item_table
end

--- Builds the path key identifying `item` at position `index` of its level.
function MenuPath.key(item, index)
    return {
        id = item.id,
        text = item.text,
        label = MenuPath.getText(item),
        index = index,
    }
end

function MenuPath.child(path, item, index)
    local child = {}
    for i, key in ipairs(path) do
        child[i] = key
    end
    child[#child + 1] = MenuPath.key(item, index)
    return child
end

function MenuPath.sameKey(a, b)
    return a.id == b.id and a.text == b.text and a.label == b.label
end

function MenuPath.same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if not MenuPath.sameKey(a[i], b[i]) then return false end
    end
    return true
end

-- Each pass is a weaker way of recognising the same entry; we only fall back to
-- the next one when the whole level failed to match on the current one.
local passes = {
    function(item, key) return key.id ~= nil and item.id == key.id end,
    function(item, key) return key.text ~= nil and item.text == key.text end,
    function(item, key) return key.label ~= nil and MenuPath.getText(item) == key.label end,
}

function MenuPath.findChild(items, key)
    for _pass, matches in ipairs(passes) do
        for _i, item in ipairs(items) do
            if type(item) == "table" and matches(item, key) then
                return item
            end
        end
    end
    -- Falling back to position is only safe when there was nothing else to go
    -- on. An entry we could have recognised and did not is gone -- a disabled
    -- plugin, say -- and whatever moved into its place is a different setting,
    -- not this one.
    if key.id or key.text or key.label then return nil end
    local item = key.index and items[key.index]
    if type(item) == "table" and not MenuPath.isSeparator(item) then
        return item
    end
end

--- Walks `path` down from `tabs`, the top-level tab list. Returns nil when any
-- level is missing, which is normal: many reader entries have no file browser
-- counterpart and vice versa.
function MenuPath.resolve(tabs, path)
    if #path < 2 then return nil end -- a whole tab is not a favourite
    -- The first level is special: a tab *is* its own list of entries, it does
    -- not hold one in a sub_item_table.
    local items = MenuPath.findChild(tabs, path[1])
    local item
    for i = 2, #path do
        if not items then return nil end
        item = MenuPath.findChild(items, path[i])
        if not item then return nil end
        items = MenuPath.getChildren(item)
    end
    return item
end

return MenuPath
