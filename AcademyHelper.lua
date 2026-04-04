script_name("AcademyHelper_Stable")
script_version("0.5")

require 'moonloader'
local vkeys = require 'lib.vkeys'
local sampev = require 'lib.samp.events'
local encoding = require 'encoding'
encoding.default = 'CP1251'

-- ================= [ НАСТРОЙКИ ОБНОВЛЕНИЯ ] =================
local current_vers = 0.5
local version_url = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/version.txt"
local script_url = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/AcademyHelper.lua"

-- ================= [ ТВОИ НАСТРОЙКИ ] =================
local GAS_URL = "https://script.google.com/macros/s/AKfycbyPFOentE3gta4L94HL9cKm1KQ__LLZLBKpz2WTKrK1ui74FT4iyKQYhOxSziZRPD0vEw/exec"
local tempFile = getWorkingDirectory() .. "\\config\\cadets_temp.json"

local cadetsOnline = {}
local cadetsDB = {}
local isUpdating = false
local lastSync = 0
local selectedCadet = nil
local font = nil
local needSync = false 

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

function check_update()
    lua_thread.create(function()
        local requests = require 'requests' -- Используем библиотеку запросов вместо системной функции
        
        -- Сначала проверим версию (тут можно оставить downloadUrlToFile, она обычно не глючит на мелких файлах)
        local temp_v = getWorkingDirectory() .. "\\config\\v.txt"
        downloadUrlToFile(version_url, temp_v, function(id, status)
            if status == 6 and doesFileExist(temp_v) then
                local f = io.open(temp_v, "r")
                local online_v = f:read("*all"):gsub("%s+", "")
                f:close()
                os.remove(temp_v)

                if tonumber(online_v) and tonumber(online_v) > current_vers then
                    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Найдено обновление {00FF00}" .. online_v .. "{FFFFFF}. Скачиваю...", -1)
                    
                    -- ВАЖНО: Качаем код прямо в переменную через requests
                    local response = requests.get(script_url)
                    if response.status_code == 200 then
                        local content = response.text
                        
                        -- Теперь записываем этот текст в файл скрипта
                        local currentPath = thisScript().path
                        local file = io.open(currentPath, "wb")
                        if file then
                            file:write(content)
                            file:close()
                            sampAddChatMessage("{00FF00}[AH] {FFFFFF}Обновлено! Перезагружаюсь...", -1)
                            thisScript():reload()
                        else
                            sampAddChatMessage("{FF0000}[AH] {FFFFFF}Ошибка записи. Попробуй запуск от Админа.", -1)
                        end
                    else
                        sampAddChatMessage("{FF0000}[AH] {FFFFFF}Ошибка скачивания с GitHub (Код: " .. response.status_code .. ")", -1)
                    end
                end
            end
        end)
    end)
end

function updateFromBase()
    lua_thread.create(function()
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
                            local n = trim(row.name or row.Nickname or row.Name)
                            if n ~= "" then 
                                temp[n] = {
                                    lecture = row.lecture or row.Lecture,
                                    theory = row.theory or row.Theory,
                                    practice = row.practice or row.Practice
                                }
                            end 
                        end
                        cadetsDB = temp
                    end
                end
            end
        end)
    end)
end

function updateCadetInBase(name, col)
    local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local myNick = sampGetPlayerNickname(myid)
    local fullUrl = GAS_URL .. "?action=update&name=" .. urlencode(name) .. "&col=" .. urlencode(col) .. "&instructor=" .. urlencode(myNick)
    downloadUrlToFile(fullUrl, tempFile, function(id, status)
        if status == 6 then
            if doesFileExist(tempFile) then os.remove(tempFile) end
            needSync = true 
        end
    end)
end

function syncAll()
    updateFromBase()
    lua_thread.create(function()
        wait(1000)
        cadetsOnline = {}
        isUpdating = true
        sampSendChat("/members")
    end)
    lastSync = os.clock()
end

function main()
    if not doesDirectoryExist(getWorkingDirectory() .. "\\config") then
        createDirectory(getWorkingDirectory() .. "\\config")
    end
    while not isSampAvailable() do wait(100) end
    
    -- ПРИВЕТСТВЕННОЕ СООБЩЕНИЕ
    sampAddChatMessage("{0633E5}[AH] {FF0000}AcademyHelper v.0.5 {FFFFFF}загружен. Автор {0633E5}Newwer Hasegawa.", -1)
    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Для работы напишите в чат {FF0000}/ah", -1)

    check_update()
    font = renderCreateFont("Arial", 9, 5)

    -- АВТОМАТИЧЕСКИЙ ВЫЗОВ /updc ПРИ ВХОДЕ
    lua_thread.create(function()
        wait(2000) -- Ждем 2 секунды после входа, чтобы всё прогрузилось
        syncAll()
    end)

    sampRegisterChatCommand("ah", function()
        if #cadetsOnline == 0 then 
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Список пуст. Синхронизирую...", -1)
            syncAll()
            return 
        end
        local s = ""
        for i, v in ipairs(cadetsOnline) do s = s .. (v.displayName or "Unknown") .. " [" .. (v.id or "0") .. "]\n" end
        sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Выбор", "Закрыть", 2)
    end)
    
    sampRegisterChatCommand("updc", syncAll)

    while true do
        wait(0)
        if needSync then
            wait(2000)
            updateFromBase()
            needSync = false
        end

        if not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
            local count = #cadetsOnline
            if count > 0 then
                renderDrawBox(20, 320, 220, 40 + (count * 16), 0x95000000)
                renderFontDrawText(font, "Кадеты Онлайн", 30, 325, 0xFF4682B4)
                for i, v in ipairs(cadetsOnline) do
                    local col = 0xFFFF4D4D 
                    local db = cadetsDB[trim(v.rawName)]
                    if db then
                        local l, t, p = isMarked(db.lecture), isMarked(db.theory), isMarked(db.practice)
                        if l and t and p then col = 0xFF32CD32 
                        elseif l and t then col = 0xFFFFFF00 
                        elseif l then col = 0xFF1E90FF 
                        end
                    end
                    renderFontDrawText(font, string.format("%d. %s [%s]", i, v.displayName or "Unknown", v.id or "?"), 30, 342 + (i * 16), col)
                end
            end
        end
        if os.clock() - lastSync > 300 then syncAll() end
    end
end

function sampev.onSendDialogResponse(id, btn, lst, inp)
    if id == 9910 and btn == 1 then
        selectedCadet = cadetsOnline[lst + 1]
        if selectedCadet then
            lua_thread.create(function()
                wait(50)
                sampShowDialog(9911, "{0633E5}" .. (selectedCadet.displayName or "Cadet"), "Лекция\nТеория\nПрактика\n{FF6347}Сбросить данные (Reset)", "ОК", "Назад", 2)
            end)
        end
        return false
    end
    if id == 9911 then
        if btn == 1 and selectedCadet then
            local actions = {"lecture", "theory", "practice", "reset"}
            local currentAction = actions[lst + 1]
            if currentAction == "reset" and cadetsDB[selectedCadet.rawName] then
                cadetsDB[selectedCadet.rawName].lecture, cadetsDB[selectedCadet.rawName].theory, cadetsDB[selectedCadet.rawName].practice = 0, 0, 0
            end
            updateCadetInBase(selectedCadet.rawName, currentAction)
        elseif btn == 0 then
            lua_thread.create(function() wait(50); sampSendChat("/ah") end)
        end
        return false
    end
end

function sampev.onServerMessage(clr, txt)
    if isUpdating then
        -- Агрессивное скрытие всего, что связано с /members
        local cleanTxt = txt:gsub("{%x+}", ""):gsub("^%s*(.-)%s*$", "%1")
        
        if cleanTxt:find("Кадет") or cleanTxt:find("Cadet") then
            local n = cleanTxt:match("([%a%d]+_[%a%d]+)")
            local id = cleanTxt:match("ID:%s*(%d+)") or cleanTxt:match("%[(%d+)%]")
            if n and id then 
                table.insert(cadetsOnline, {rawName = trim(n), displayName = n:gsub("_", " "), id = id}) 
            end
            return false 
        end

        if cleanTxt:find("Члены организации") or cleanTxt:find("Всего%:") or cleanTxt:find("▬") or cleanTxt == "" then
            if cleanTxt:find("Всего%:") then isUpdating = false end
            return false 
        end
        
        -- Если мы в режиме обновления, блокируем все сообщения, чтобы не было просадок
        return false 
    end
end
