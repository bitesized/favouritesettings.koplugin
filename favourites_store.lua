--[[--
Persistence for the favourites list.

Favourites are kept as a single ordered list so the user can arrange menu
entries and quick actions together. Two kinds:

* `menu`: a reference to an entry of the top menu, see @{favourites_menupath}.
* `action`: a Dispatcher action, the same ones the Gestures and Profiles
  plugins offer. Their values live in `self.actions`, which is the table
  Dispatcher's own picker reads and writes.

@module koplugin.favouritesettings.favourites_store
--]]--

local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local MenuPath = require("favourites_menupath")

local Store = {}
Store.__index = Store

function Store:new(file)
    -- Dispatcher fills in the details of its cre/kopt-derived actions here;
    -- without it, reading back a stored action's value throws.
    Dispatcher:init()
    local store = setmetatable({}, self)
    store.settings = LuaSettings:open(file)
    store.list = store.settings:readSetting("favourites", {})
    store.actions = store.settings:readSetting("actions", {})
    store:syncActions()
    return store
end

function Store:flush()
    self.settings:flush()
end

function Store:isShownIn(context)
    return self.settings:nilOrTrue("show_in_" .. context)
end

function Store:toggleShownIn(context)
    self.settings:flipNilOrTrue("show_in_" .. context)
    self.settings:flush()
end

--- Reconciles the list with the actions table, which Dispatcher's picker edits
-- behind our back: actions it added are appended, actions it dropped are
-- removed. Returns true when anything changed.
function Store:syncActions()
    local changed = false
    local listed = {}
    for i = #self.list, 1, -1 do
        local fav = self.list[i]
        if fav.kind == "action" then
            if self.actions[fav.key] == nil then
                table.remove(self.list, i)
                changed = true
            else
                listed[fav.key] = true
            end
        end
    end
    for _, item in ipairs(Dispatcher.getDisplayList(self.actions)) do
        if not listed[item.key] then
            table.insert(self.list, { kind = "action", key = item.key })
            changed = true
        end
    end
    return changed
end

function Store:indexOfPath(path)
    for i, fav in ipairs(self.list) do
        if fav.kind == "menu" and MenuPath.same(fav.path, path) then
            return i
        end
    end
end

function Store:isFavourite(path)
    return self:indexOfPath(path) ~= nil
end

--- Adds the menu entry at `path` if absent, removes it if present.
function Store:togglePath(path, label)
    local index = self:indexOfPath(path)
    if index then
        table.remove(self.list, index)
    else
        table.insert(self.list, { kind = "menu", path = path, label = label })
    end
    self:flush()
end

--- Returns the current position of a favourite, which shifts as the list is
-- edited, so never hold on to one.
function Store:indexOf(favourite)
    for i, fav in ipairs(self.list) do
        if fav == favourite then return i end
    end
end

function Store:insert(favourite, index)
    table.insert(self.list, math.min(index or #self.list + 1, #self.list + 1), favourite)
    if favourite.kind == "action" and favourite.value ~= nil then
        self.actions[favourite.key] = favourite.value
    end
    self:flush()
end

function Store:remove(favourite)
    local index = self:indexOf(favourite)
    if not index then return end
    local fav = table.remove(self.list, index)
    if fav.kind == "action" then
        favourite.value = self.actions[fav.key] -- kept so it can be put back
        self.actions[fav.key] = nil
        -- Dispatcher keeps its own execution order alongside the values.
        local order = self.actions.settings and self.actions.settings.order
        if order then
            for i, key in ipairs(order) do
                if key == fav.key then
                    table.remove(order, i)
                    break
                end
            end
        end
    end
    self:flush()
    return index
end

function Store:reorder(keys)
    local by_key = {}
    for _, fav in ipairs(self.list) do
        by_key[self:keyOf(fav)] = fav
    end
    local sorted = {}
    for _, key in ipairs(keys) do
        if by_key[key] then
            table.insert(sorted, by_key[key])
            by_key[key] = nil
        end
    end
    for _, fav in ipairs(self.list) do -- anything the sort widget did not see
        if by_key[self:keyOf(fav)] then
            table.insert(sorted, fav)
        end
    end
    self.list = sorted
    self.settings:saveSetting("favourites", self.list)
    self:flush()
end

--- A string identifying one favourite, for matching across a reorder.
function Store:keyOf(fav)
    if fav.kind == "action" then
        return "action:" .. fav.key
    end
    local parts = {}
    for _, key in ipairs(fav.path) do
        table.insert(parts, tostring(key.id or key.text or key.label or key.index))
    end
    return "menu:" .. table.concat(parts, "/")
end

--- The label to show for a favourite that is not currently reachable.
function Store:labelOf(fav)
    if fav.kind == "action" then
        return Dispatcher:getNameFromItem(fav.key, self.actions)
    end
    return fav.label or "?"
end

return Store
