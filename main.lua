--[[--
Favourite settings: a star tab in the top menu holding the settings you reach
for often, so they are one tap away instead of three levels down.

The tab is added by mutating the menu order tables, which are require-cached
and therefore process-wide -- the same approach `ui/plugin/insert_menu` uses to
add entries to "More tools", applied to the top-level tab list instead.

Its contents are filled after the menu has been sorted, because a favourite is
a reference to a live menu entry and those only exist once `MenuSorter` has run.

@module koplugin.favouritesettings
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local MenuPath = require("favourites_menupath")
local MenuSorter = require("ui/menusorter")
local Picker = require("favourites_picker")
local Store = require("favourites_store")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local MENU_ORDERS = {
    reader = "ui/elements/reader_menu_order",
    filemanager = "ui/elements/filemanager_menu_order",
}

--- Adds or removes our tab in one context's menu order.
-- The order tables are singletons, so this outlives the plugin instance that
-- called it and takes effect the next time that menu is built.
local function setTabInOrder(context, wanted)
    local order = require(MENU_ORDERS[context])
    local buttons = order["KOMenu:menu_buttons"]
    local position
    for i, id in ipairs(buttons) do
        if id == "favourites" then
            position = i
            break
        end
    end
    if wanted and not position then
        -- An empty order list is required: without it the sorter treats the
        -- tab as a leaf item and drops it from the tab bar.
        order.favourites = {}
        table.insert(buttons, #buttons, "favourites") -- just before "main"
    elseif not wanted and position then
        table.remove(buttons, position)
        order.favourites = nil
    end
end

-- The instance whose menu is currently being built. `addToMainMenu` runs from
-- `setUpdateItemTable`, immediately before it calls the sorter, so this is
-- always set and consumed within one build.
local building

if not MenuSorter.favouritesettings_hooked then
    MenuSorter.favouritesettings_hooked = true
    local mergeAndSort = MenuSorter.mergeAndSort
    MenuSorter.mergeAndSort = function(sorter, config_prefix, item_table, order)
        local tabs = mergeAndSort(sorter, config_prefix, item_table, order)
        local plugin = building
        building = nil
        if plugin then
            plugin:onMenuBuilt(tabs)
        end
        return tabs
    end
end

local FavouriteSettings = WidgetContainer:extend{
    name = "favouritesettings",
    is_doc_only = false,
}

function FavouriteSettings:init()
    self.store = Store:new(DataStorage:getSettingsDir() .. "/favourite_settings.lua")
    self.context = self.ui.document and "reader" or "filemanager"
    setTabInOrder(self.context, self.store:isShownIn(self.context))
    -- Dispatcher's action picker reports changes by setting `updated` on the
    -- caller it was given; catch that to persist and refresh.
    self.dispatcher_caller = setmetatable({}, {
        __newindex = function(caller, key, value)
            rawset(caller, key, value)
            if key == "updated" and value then
                self:onActionsEdited()
            end
        end,
    })
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function FavouriteSettings:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_favourites", {
        category = "none",
        event = "ShowFavourites",
        title = _("Show favourite settings"),
        general = true,
    })
end

function FavouriteSettings:onFlushSettings()
    self.store:flush()
end

function FavouriteSettings:addToMainMenu(menu_items)
    building = self
    self.tab, self.tab_index = nil, nil
    -- Also reachable from Tools, so the tab can be turned off without losing
    -- the way to turn it back on.
    menu_items.favourite_settings = {
        text = _("Favourite settings"),
        sorting_hint = "more_tools",
        favourites_excluded = true, -- starring our own entries makes no sense
        sub_item_table_func = function()
            return self:settingsMenu()
        end,
    }
    if not self.store:isShownIn(self.context) then return end
    -- Contents are filled in by onMenuBuilt, once there is a sorted menu to
    -- resolve favourites against.
    self.tab = {
        icon = "star.full",
        -- Favourites are the same entries as elsewhere in the menu; listing
        -- them again would just duplicate every hit.
        ignored_by_menu_search = true,
    }
    menu_items.favourites = self.tab
end

--- Called with the freshly sorted tab list, straight after `addToMainMenu`.
function FavouriteSettings:onMenuBuilt(tabs)
    self.tabs = tabs
    for i, tab in ipairs(tabs) do
        if tab == self.tab then
            self.tab_index = i
            break
        end
    end
    self:fillTab()
end

--- Opens the top menu on our tab.
function FavouriteSettings:onShowFavourites()
    if not self.tab_index then
        -- The menu has never been built, so we do not know where our tab sits
        -- yet; building it now fills in tab_index as a side effect.
        self.ui.menu:setUpdateItemTable()
    end
    self.ui.menu:onShowMenu(self.tab_index)
    return true
end

--- Rebuilds the tab's contents in place, so an edit shows up immediately
-- without waiting for the whole menu to be rebuilt.
function FavouriteSettings:fillTab()
    local tab = self.tab
    if not tab then return end
    for i = #tab, 1, -1 do
        tab[i] = nil
    end

    for _index, favourite in ipairs(self.store.list) do
        local item = self:buildItem(favourite)
        if item then
            table.insert(tab, item)
        end
    end
    if #tab == 0 then
        table.insert(tab, {
            text = _("No favourites yet"),
            enabled = false,
        })
    end
    tab[#tab].separator = true

    for _index, item in ipairs(self:settingsMenu()) do
        table.insert(tab, item)
    end
end

--- The plugin's own entries: adding favourites, and everything about them.
-- They sit at the foot of the tab, and under Tools as well.
function FavouriteSettings:settingsMenu()
    return {
        {
            text = _("Add a favourite"),
            favourites_excluded = true,
            help_text = _("Walk the menu and tick the settings you want in the tab."),
            sub_item_table_func = function()
                return Picker.build(self)
            end,
        },
        {
            text = _("Manage favourites"),
            favourites_excluded = true,
            sub_item_table_func = function()
                return self:manageMenu()
            end,
        },
    }
end

FavouriteSettings.refreshTab = FavouriteSettings.fillTab

--- Turns a stored favourite into a menu entry, or nil when it is not reachable
-- from here (many reader settings have no file browser counterpart).
function FavouriteSettings:buildItem(favourite)
    if favourite.kind == "action" then
        local key = favourite.key
        return {
            text_func = function()
                return Dispatcher:getNameFromItem(key, self.store.actions)
            end,
            keep_menu_open = true,
            callback = function()
                Dispatcher:execute({ [key] = self.store.actions[key] })
            end,
        }
    end

    local item = self.tabs and MenuPath.resolve(self.tabs, favourite.path)
    if not item then return nil end
    -- A shallow copy: the entry keeps working -- its callbacks and nested
    -- tables are shared with the original -- but we can set our own separator
    -- without moving one in the menu it came from.
    local copy = {}
    for key, value in pairs(item) do
        copy[key] = value
    end
    copy.separator = nil
    return copy
end

function FavouriteSettings:onActionsEdited()
    self.store.settings:saveSetting("actions", self.store.actions)
    self.store:syncActions()
    self.store:flush()
    self:refreshTab()
end

function FavouriteSettings:manageMenu()
    local list = self.store.list
    return {
        {
            text = _("Arrange favourites"),
            enabled_func = function()
                return #list > 1
            end,
            keep_menu_open = true,
            callback = function()
                self:showSortWidget()
            end,
        },
        {
            text = _("Remove favourites"),
            enabled_func = function()
                return #list > 0
            end,
            sub_item_table_func = function()
                return self:removeMenu()
            end,
        },
        {
            text = _("Quick actions"),
            help_text = _("Actions from the same list gestures and profiles use, for settings that are not menu entries."),
            separator = true,
            sub_item_table_func = function()
                local actions = {}
                Dispatcher:addSubMenu(self.dispatcher_caller, actions, self.store, "actions")
                return actions
            end,
        },
        {
            text = _("Show tab in reader"),
            checked_func = function()
                return self.store:isShownIn("reader")
            end,
            callback = function()
                self:toggleShownIn("reader")
            end,
        },
        {
            text = _("Show tab in file browser"),
            checked_func = function()
                return self.store:isShownIn("filemanager")
            end,
            callback = function()
                self:toggleShownIn("filemanager")
            end,
        },
    }
end

function FavouriteSettings:toggleShownIn(context)
    self.store:toggleShownIn(context)
    setTabInOrder(context, self.store:isShownIn(context))
    if context == self.context then
        -- Drop the built menu so the tab bar is rebuilt without (or with) us.
        self.ui.menu.tab_item_table = nil
        self.tab, self.tabs, self.tab_index = nil, nil, nil
    end
end

function FavouriteSettings:removeMenu()
    local items = {}
    for _index, favourite in ipairs(self.store.list) do
        local item = self:buildItem(favourite)
        local label = item and MenuPath.getText(item) or self.store:labelOf(favourite)
        if not item then
            label = T(_("%1 (not available here)"), label)
        end
        -- Ticked means kept. Untick to remove, tick again to change your mind:
        -- removed entries stay listed until the submenu is left.
        local position
        table.insert(items, {
            text = label,
            checked_func = function()
                return self.store:indexOf(favourite) ~= nil
            end,
            callback = function()
                if self.store:indexOf(favourite) then
                    position = self.store:remove(favourite)
                else
                    self.store:insert(favourite, position)
                end
                self:refreshTab()
            end,
        })
    end
    return items
end

function FavouriteSettings:showSortWidget()
    local SortWidget = require("ui/widget/sortwidget")
    local display = {}
    for _index, favourite in ipairs(self.store.list) do
        local item = self:buildItem(favourite)
        table.insert(display, {
            text = item and MenuPath.getText(item) or self.store:labelOf(favourite),
            key = self.store:keyOf(favourite),
        })
    end
    UIManager:show(SortWidget:new{
        title = _("Arrange favourites"),
        item_table = display,
        callback = function()
            local keys = {}
            for i, entry in ipairs(display) do
                keys[i] = entry.key
            end
            self.store:reorder(keys)
            self:refreshTab()
        end,
    })
end

return FavouriteSettings
