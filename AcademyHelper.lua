script_name("AcademyHelper_Stable")
script_version("0.7")

-- Подключаем всё в самом начале (вне функций!)
local requests = require 'requests'
local encoding = require 'encoding'
local sampev = require 'lib.samp.events'
local vkeys = require 'lib.vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ================= [ НАСТРОЙКИ ] =================
local current_vers = 0.7
local version_url = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/version.txt"
local script_url = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/AcademyHelper.lua"
local GAS_URL = "https://script.google.com/macros/s/AKfycbyPFOentE3gta4L94HL9cKm1KQ__LLZLBKpz2WTKrK1ui74FT4iyKQYhOxSziZRPD0vEw/exec"

-- ================= [ ПЕРЕМЕННЫЕ ] =================
local cadetsOnline = {}
local cadetsDB = {}
local isUpdating = false
local lastSync = 0
local font = nil

-- ================= [ ОБНОВЛЕНИЕ (БЕЗОПАСНЫЙ МЕТОД) ] =================
function check_update()
    lua_thread.create(function()
        while not isSampAvailable() do wait(100) end
        wait(5000) -- Даем лаунчеру успокоиться

        -- Проверка версии
        local status_v, res_v = pcall(requests.get, version_url)
        if status_v and res_v and res_v.status_code == 200 then
            local online_v = res_v.text:gsub("%s+", "")
            
            if tonumber(online_v) and tonumber(online_v) > current_vers then
                sampAddChatMessage("{0633E5}[AH] {FFFFFF}Найдено обновление {00FF00}v" .. online_v .. "{FFFFFF}. Качаю...", -1)
                
                -- Качаем код во временную переменную
                local status_s, res_s = pcall(requests.get, script_url)
                if status_s and res_s and res_s.status_code == 200 then
                    -- Исправляем кракозябры (UTF8 -> CP1251)
                    local ok_enc, content = pcall(function() return encoding.UTF8:decode(res_s.text) end)
                    
                    if ok_enc and content then
                        -- Записываем в файл
                        local file = io.open(thisScript().path, "wb")
                        if file then
                            file:write(content)
                            file:close()
                            sampAddChatMessage("{00FF00}[AH] {FFFFFF}Скрипт обновлен! Перезагрузка через 3 сек...", -1)
                            wait(3000)
                            thisScript():reload()
                        end
                    end
                end
            end
        end
    end)
end

-- ================= [ РАБОТА С ДАННЫМИ ] =================
function syncAll()
    lua_thread.create(function()
        -- Загрузка базы из Google
        local status, res = pcall(requests.get, GAS_URL .. "?action=read")
        if status and res and res.status_code == 200 then
            local res_json, data = pcall(decodeJson, res.text)
            if res_json and type(data) == "table" then
                local temp = {}
                for _, row in ipairs(data) do
                    local n = (row.name or row.Nickname or ""):gsub("^%s*(.-)%s*$", "%1")
                    if n ~= "" then temp[n] = row end
                end
                cadetsDB = temp
            end
        end
        -- Обновление списка онлайн
        wait(500)
        cadetsOnline = {}
        isUpdating = true
        sampSendChat("/members")
    end)
    lastSync = os.clock()
end

-- ================= [ ОСНОВНОЙ ЦИКЛ ] =================
function main()
    while not isSampAvailable() do wait(100) end
    
    sampAddChatMessage("{0633E5}[AH] {FF0000}AcademyHelper {FFFFFF}загружен. Версия: {00FF00}" .. current_vers, -1)
    
    font = renderCreateFont("Arial", 9, 5)
    
    -- Запускаем обновление и синхронизацию
    check_update()
    lua_thread.create(function() wait(2000); syncAll() end)

    sampRegisterChatCommand("ah", function()
        if #cadetsOnline == 0 then syncAll() else
            local s = ""
            for i, v in ipairs(cadetsOnline) do s = s .. v.displayName .. " [" .. v.id .. "]\n" end
            sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Выбор", "Закрыть", 2)
        end
    end)

    while true do
        wait(0)
        -- Рендер кадетов на экране
        if not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
            local count = #cadetsOnline
            if count > 0 then
                renderDrawBox(20, 320, 220, 40 + (count * 16), 0x95000000)
                renderFontDrawText(font, "Кадеты Онлайн", 30, 325, 0xFF4682B4)
                for i, v in ipairs(cadetsOnline) do
                    local col = 0xFFFF4D4D
                    local db = cadetsDB[v.rawName:gsub("^%s*(.-)%s*$", "%1")]
                    if db then
                        local l = tostring(db.lecture):lower()
                        local t = tostring(db.theory):lower()
                        local p = tostring(db.practice):lower()
                        if l == "true" or l == "1" then col = 0xFF1E90FF end
                        if (l == "true" or l == "1") and (t == "true" or t == "1") then col = 0xFFFFFF00 end
                        if (l == "true" or l == "1") and (t == "true" or t == "1") and (p == "true" or p == "1") then col = 0xFF32CD32 end
                    end
                    renderFontDrawText(font, string.format("%d. %s [%s]", i, v.displayName, v.id), 30, 342 + (i * 16), col)
                end
            end
        end
        if os.clock() - lastSync > 300 then syncAll() end
    end
end

-- ================= [ ОБРАБОТКА ЧАТА ] =================
function sampev.onServerMessage(clr, txt)
    if isUpdating then
        local cleanTxt = txt:gsub("{%x+}", "")
        if cleanTxt:find("Кадет") or cleanTxt:find("Cadet") then
            local n = cleanTxt:match("([%a%d]+_[%a%d]+)")
            local id = cleanTxt:match("%[(%d+)%]") or cleanTxt:match("ID:%s*(%d+)")
            if n and id then 
                table.insert(cadetsOnline, {rawName = n, displayName = n:gsub("_", " "), id = id}) 
            end
            return false 
        end
        if cleanTxt:find("Всего%:") then isUpdating = false; return false end
        if cleanTxt:find("Члены организации") or cleanTxt:find("▬") or cleanTxt == "" then return false end
    end
end
