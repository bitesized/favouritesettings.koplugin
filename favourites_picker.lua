--[[--
The "Add a favourite" browser.

Rather than hanging a gesture off every menu entry -- most of them already use
hold for something -- this mirrors the top menu as an ordinary submenu whose
leaves are checkboxes. The user walks down the structure they already know and
taps to star an entry, which also means unstarring works the same way.

The mirror is built lazily, one level per `sub_item_table_func` call, so
opening it costs no more than opening the menu it shadows.

@module koplugin.favouritesettings.favourites_picker
--]]--

local MenuPath = require("favourites_menupath")
local _ = require("gettext")
local T = require("ffi/util").template

local Picker = {}

-- Tabs are identified by their icon, so they have no label of their own.
local TAB_NAMES = {
    navi = _("Navigation"),
    typeset = _("Typeset"),
    setting = _("Settings"),
    tools = _("Tools"),
    search = _("Search"),
    filemanager = _("File browser"),
    filemanager_settings = _("File browser settings"),
    main = _("Main menu"),
}

local function tabName(tab)
    return TAB_NAMES[tab.id] or tab.id or _("Menu")
end

--- A checkbox toggling the favourite status of the entry at `path`. `text` is
-- what the checkbox itself says, which is not always the entry's own label.
local function checkbox(plugin, path, label, text)
    return {
        text = text or label,
        checked_func = function()
            return plugin.store:isFavourite(path)
        end,
        callback = function()
            plugin.store:togglePath(path, label)
            plugin:refreshTab()
        end,
    }
end

--- Mirrors one level of the menu. `items` is the live level, `path` the way
-- back to it.
function Picker.level(plugin, items, path)
    local mirror = {}
    for index, item in ipairs(items) do
        if type(item) == "table" and not MenuPath.isSeparator(item)
                and not item.favourites_excluded then
            local label = MenuPath.getText(item)
            if label then
                local item_path = MenuPath.child(path, item, index)
                if MenuPath.hasChildren(item) then
                    table.insert(mirror, {
                        text = label,
                        sub_item_table_func = function()
                            local children = MenuPath.getChildren(item) or {}
                            local sub = Picker.level(plugin, children, item_path)
                            -- The submenu itself is worth starring too: it is
                            -- often the thing the user is really after.
                            table.insert(sub, 1, checkbox(plugin, item_path, label,
                                T(_("Add “%1” to favourites"), label)))
                            sub[1].separator = true
                            return sub
                        end,
                    })
                else
                    table.insert(mirror, checkbox(plugin, item_path, label))
                end
            end
        end
    end
    return mirror
end

--- The top level of the browser: one entry per tab, ours excepted.
function Picker.build(plugin)
    local tabs = plugin.tabs
    if not tabs then return {} end
    local mirror = {}
    for index, tab in ipairs(tabs) do
        if tab ~= plugin.tab and #tab > 0 then
            local tab_path = { MenuPath.key(tab, index) }
            table.insert(mirror, {
                text = tabName(tab),
                sub_item_table_func = function()
                    return Picker.level(plugin, tab, tab_path)
                end,
            })
        end
    end
    return mirror
end

return Picker
