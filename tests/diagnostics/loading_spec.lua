local Assert = require("support.assert")
local original_path = package.path

-- KOReader adds only <plugin>/?.lua, unlike the offline runner's ?/init.lua path.
local plugin_init = BOOK_TEST_ROOT .. "/book.koplugin/?/init.lua"
local paths = {}
for path in package.path:gmatch("[^;]+") do
    if path ~= plugin_init then paths[#paths + 1] = path end
end
package.path = table.concat(paths, ";")

package.preload["l10n"] = function() return { apply = function() end } end
for _, name in ipairs({
    "datastorage", "device", "json", "workers.job", "utils.log", "utils.paths",
    "http.request", "utils.settings", "ui/uimanager", "ui.components.settingrow",
    "ui/widget/infomessage", "ui/widget/inputdialog",
}) do
    package.preload[name] = function() return {} end
end

local ok, ui = pcall(require, "ui.desktop.settings.diagnostics")
package.path = original_path
Assert.is_true(ok, ui)
Assert.eq(type(ui.rows), "function")
Assert.eq(type(require("diagnostics.init").upload), "function")
return true
