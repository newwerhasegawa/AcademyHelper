script_name("AcademyHelper_Stable")
script_version("0.6")

local requests = require 'requests'
local encoding = require 'encoding'
local sampev = require 'lib.samp.events'
local vkeys = require 'lib.vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ================= [ НАСТРОЙКИ ] =================
local current_vers = 0.6 -- ТВОЯ ТЕКУЩАЯ ВЕРСИЯ
local version_url = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/version.txt"
local script_url = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/AcademyHelper.lua"
local GAS_URL = "https://script.google.com/macros/s/AKfycbyPFOentE3gta4L94HL9cKm1KQ__LLZLBKpz2WTKrK1ui74FT4iyKQYhOxSziZRPD0vEw/exec"

-- ================= [ ПЕРЕМЕННЫЕ ] =================
local cadetsOnline = {}
local cadetsDB = {}
local isUpdating = false
local lastSync = 0
local font = nil
local tempFile = getWorkingDirectory() .. "\\config\\cadets_temp.json"

-- ================= [ СЛУЖЕБНЫЕ ФУНКЦИИ ] =================
function trim(s) return s and s:match("^%s*(.-)%s*$") or "" end

function urlencode(str)
    if str then
        str = string.gsub(str, "([^%w ])", function(c) return string.format("%%%02X", string.byte(c)) end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

function isMarked(val)
    if val == nil or val == "" then return false end
    local num = tonumber(val)
    if num then return num >= 1 end
    local str = tostring(val):lower()
    return str == "true" or str == "1"
end

-- ================= [ ЛОГИКА ОБНОВЛЕНИЯ ] =================
function check_update()
    lua_thread.create(function()
        while not isSampAvailable() do wait(100) end
        wait(3000) -- Даем игре прогрузиться
        
        local temp_v = getWorkingDirectory() .. "\\config\\v_check.tmp"
        downloadUrlToFile(version_url, temp_v, function(id, status)
            if status == 6 and doesFileExist(temp_v) then
                local f = io.open(temp_v, "r")
                if f then
                    local online_v = f:read("*all"):gsub("%s+", "")
                    f:close()
                    os.remove(temp_v)

                    if tonumber(online_v) and tonumber(online_v) > current_vers then
                        sampAddChatMessage("{0633E5}[AH] {FFFFFF}Найдено обновление {00FF00}v" .. online_v .. "{FFFFFF}. Загрузка...", -1)
                        
                        lua_thread.create(function()
                            local status_req, response = pcall(requests.get, script_url)
                            if status_req and response and response.status_code == 200 then
                                -- Фикс кракозябр: UTF8 -> CP1251
                                local content = encoding.UTF8:decode(response.text)
                                local file = io.open(thisScript().path, "wb")
                                if file then
                                    file:write(content)
                                    file:close()
                                    sampAddChatMessage("{00FF00}[AH] {FFFFFF}Обновлено! Перезагрузка через 2 сек...", -1)
                                    wait(2000)
                                    thisScript():reload()
                                end
                            end
                        end)
                    end
                end
            end
        end)
    end)
end

-- ================= [ РАБОТА С БАЗОЙ ] =================
function syncAll()
    lua_thread.create(function()
        -- Сначала тянем данные из Google Таблицы
        downloadUrlToFile(GAS_URL .. "?action=read", tempFile, function(id, status)
            if status == 6 and doesFileExist(tempFile) then
                local f = io.open(tempFile, "r")
                if f then
                    local content = f:read("*all")
                    f:close()
                    os.remove(tempFile)
                    local res, data = pcall(decodeJson, content)
                    if res and type(data) == "table" then
                        local temp = {}
                        for _, row in ipairs(data) do
                            local n = trim(row.name or row.Nickname)
                            if n ~= "" then temp[n] = row end
                        end
                        cadetsDB = temp
                    end
                end
            end
        end)
        
        -- Потом запускаем скрытый /members
        wait(500)
        cadetsOnline = {}
        isUpdating = true
        sampSendChat("/members")
    end)
    lastSync = os.clock()
end

-- ================= [ ОСНОВНОЙ ЦИКЛ ] =================
function main()
    if not doesDirectoryExist(getWorkingDirectory() .. "\\config") then
        createDirectory(getWorkingDirectory() .. "\\config")
    end
    while not isSampAvailable() do wait(100) end
    
    -- ПРИВЕТСТВИЕ
    sampAddChatMessage("{0633E5}[AH] {FF0000}AcademyHelper v." .. current_vers .. " {FFFFFF}загружен. Автор {0633E5}Newwer Hasegawa.", -1)
    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Для работы напишите в чат {FF0000}/ah", -1)

    font = renderCreateFont("Arial", 9, 5)
    check_update()

    -- Авто-синхронизация при входе
    lua_thread.create(function() wait(2000); syncAll() end)

    sampRegisterChatCommand("ah", function()
        if #cadetsOnline == 0 then syncAll(); return end
        local s = ""
        for i, v in ipairs(cadetsOnline) do s = s .. v.displayName .. " [" .. v.id .. "]\n" end
        sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Выбор", "Закрыть", 2)
    end)

    sampRegisterChatCommand("updc", syncAll)

    while true do
        wait(0)
        -- Рендер списка кадетов на экране
        if not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
            local count = #cadetsOnline
            if count > 0 then
                renderDrawBox(20, 320, 220, 40 + (count * 16), 0x95000000)
                renderFontDrawText(font, "Кадеты Онлайн", 30, 325, 0xFF4682B4)
                for i, v in ipairs(cadetsOnline) do
                    local col = 0xFFFF4D4D
                    local db = cadetsDB[trim(v.rawName)]
                    if db and isMarked(db.lecture) then col = 0xFF1E90FF end
                    if db and isMarked(db.lecture) and isMarked(db.theory) then col = 0xFFFFFF00 end
                    if db and isMarked(db.lecture) and isMarked(db.theory) and isMarked(db.practice) then col = 0xFF32CD32 end
                    renderFontDrawText(font, string.format("%d. %s [%s]", i, v.displayName, v.id), 30, 342 + (i * 16), col)
                end
            end
        end
        -- Авто-обновление списка каждые 5 минут
        if os.clock() - lastSync > 300 then syncAll() end
    end
end

-- ================= [ ОБРАБОТКА ЧАТА ] =================
function sampev.onServerMessage(clr, txt)
    if isUpdating then
        local cleanTxt = txt:gsub("{%x+}", ""):gsub("^%s*(.-)%s*$", "%1")
        
        if cleanTxt:find("Кадет") or cleanTxt:find("Cadet") then
            local n = cleanTxt:match("([%a%d]+_[%a%d]+)")
            local id = cleanTxt:match("ID:%s*(%d+)") or cleanTxt:match("%[(%d+)%]")
            if n and id then 
                table.insert(cadetsOnline, {rawName = n, displayName = n:gsub("_", " "), id = id}) 
            end
            return false 
        end

        if cleanTxt:find("Члены организации") or cleanTxt:find("Всего%:") or cleanTxt:find("▬") or cleanTxt == "" then
            if cleanTxt:find("Всего%:") then isUpdating = false end
            return false 
        end
        return false 
    end
end
