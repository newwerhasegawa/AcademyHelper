script_name("AcademyHelper_Stable_v0.9.7_Merged")
script_version("0.9.7")
script_authors("Newer Hasegawa")

local encoding = require 'encoding'
local sampev = require 'lib.samp.events'
local vkeys = require 'lib.vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8
math.randomseed(os.time())

-- ================= [ НАСТРОЙКИ ] =================
local GAS_URL = "https://script.google.com/macros/s/AKfycbwI9L_unVaA-C1TVM6QmtG7iJu90p4LfRD-N7wCds7VlYoPKjNSJzLFzZ_opduNVrvU/exec"
local ah_dir = getWorkingDirectory() .. "\\config\\AcademyHelper\\"
local localLecturesJson = ah_dir .. "lectures.json"
local localLecturesVer = ah_dir .. "lectures_version.txt"
local LECTURES_JSON_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/lectures.json"
local LECTURES_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/lectures_version.txt"

-- Ссылки для автообновления скрипта
local SCRIPT_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/refs/heads/main/version.txt"
local SCRIPT_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/refs/heads/main/AcademyHelper.lua"

-- ================= [ ПЕРЕМЕННЫЕ ] =================
local cadetsOnline = {}
local tempCadets = {}
local cadetsDB = {}
local isUpdating = false
local lastSyncTimer = 0
local showHUD = true -- Переменная для отображения HUD
local font = nil
local selectedCadet = nil
local lecturesDB = {}
local lectureKeys = {}
local stopLecture = false
local paused = false
local lectureThread = nil
local requestQueue = {}
local isRequesting = false
local requestTimestamp = 0

local updateTriggered = false -- Флаг для защиты от двойного обновления

-- ================= [ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ] =================
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

function hasTwoDaysPassed(dateStr)
    if not dateStr or dateStr == "" or dateStr == "nil" then return false end
    local d, m, y = tostring(dateStr):match("(%d+)%.(%d+)%.(%d+)")
    if not d or not m or not y then return false end
    local status, targetTime = pcall(os.time, {day=tonumber(d), month=tonumber(m), year=tonumber(y), hour=0, min=0, sec=0})
    if not status then return false end
    return (os.time() - targetTime) >= 172800
end

function GetNick()
    local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if myid ~= -1 then
        local nick = sampGetPlayerNickname(myid)
        return nick:gsub("_", " ")
    end
    return "Инструктор"
end

function smartWait(ms)
    local timer = 0
    while timer < ms do
        if not paused then
            timer = timer + 100
        end
        wait(100)
        if stopLecture then return true end
    end
    return false
end

function openAhMenu()
    local toggleText = showHUD and "{FF0000}[ Выключить HUD ]" or "{00FF00}[ Включить HUD ]"
    local s = toggleText .. "\n"
    for i, v in ipairs(cadetsOnline) do s = s .. v.displayName .. " [" .. v.id .. "]\n" end
    sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Выбор", "Закрыть", 2)
end

-- ================= [ ОБРАБОТКА ОЧЕРЕДИ ] =================
function processQueue()
    if isRequesting then
        if os.clock() - requestTimestamp > 12 then isRequesting = false else return end
    end
    if #requestQueue == 0 then return end
    isRequesting = true
    requestTimestamp = os.clock()
    local nextReq = table.remove(requestQueue, 1)
    local prefix = nextReq.url:find("google") and "gas" or (nextReq.url:find("version") and "ver" or "lec")
    
    -- [ВАЖНО] Защита от краша urlmon.dll: проверяем наличие папки ПЕРЕД КАЖДЫМ скачиванием
    if not doesDirectoryExist(ah_dir) then 
        createDirectory(getWorkingDirectory() .. "\\config")
        createDirectory(ah_dir) 
    end

    local tempPath = string.format("%stmp_%s_%d.json", ah_dir, prefix, os.time())
    
    if doesFileExist(tempPath) then os.remove(tempPath) end
    
    downloadUrlToFile(nextReq.url, tempPath, function(id, status)
        if status == 6 then
            local f = io.open(tempPath, "r")
            if f then
                local content = f:read("*all")
                f:close()
                os.remove(tempPath)
                lua_thread.create(function()
                    if nextReq.callback then nextReq.callback(content) end
                end)
            end
            isRequesting = false
        elseif status == 58 then -- Ошибка скачивания
            isRequesting = false
        end
    end)
end

function queueHttpRequest(url, callback)
    table.insert(requestQueue, {url = url, callback = callback})
end

-- ================= [ АВТООБНОВЛЕНИЕ СКРИПТА ] =================
function checkScriptUpdate()
    if updateTriggered then return end
    queueHttpRequest(SCRIPT_VER_URL .. "?t=" .. os.time(), function(remoteVer)
        local currentVer = thisScript().version
        local cleanRemoteVer = trim(remoteVer):match("[%d%.]+")
        
        if cleanRemoteVer and cleanRemoteVer ~= currentVer and not updateTriggered then
            updateTriggered = true
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Найдена новая версия {00FF00}v." .. cleanRemoteVer .. "{FFFFFF}, установка...", -1)
            
            -- Качаем скрипт напрямую, минуя JSON очередь.
            local tempUpdatePath = getWorkingDirectory() .. "\\AH_update_temp.lua"
            downloadUrlToFile(SCRIPT_URL .. "?t=" .. os.time(), tempUpdatePath, function(id, status)
                if status == 6 then
                    -- Проверяем, что скачался именно Lua код, а не ошибка провайдера/GitHub
                    local f = io.open(tempUpdatePath, "r")
                    if f then
                        local checkContent = f:read("*all")
                        f:close()
                        
                        if checkContent:find("script_name") then
                            -- Записываем проверенный код в оригинальный файл
                            local mainF = io.open(thisScript().path, "wb")
                            if mainF then
                                mainF:write(checkContent)
                                mainF:close()
                                os.remove(tempUpdatePath)
                                sampAddChatMessage("{0633E5}[AH] {00FF00}Обновление завершено. Перезагрузка...", -1)
                                thisScript():reload()
                            end
                        else
                            os.remove(tempUpdatePath)
                            sampAddChatMessage("{0633E5}[AH] {FF0000}Ошибка: скачан поврежденный код.", -1)
                            updateTriggered = false
                        end
                    end
                elseif status == 58 then
                    sampAddChatMessage("{0633E5}[AH] {FF0000}Не удалось скачать обновление.", -1)
                    updateTriggered = false
                end
            end)
        end
    end)
end

-- ================= [ ФУНКЦИИ ЛЕКЦИЙ ] =================
function loadLecturesLocally()
    if not doesFileExist(localLecturesJson) then return false end
    local f = io.open(localLecturesJson, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if #content > 0 then
            local res, data = pcall(decodeJson, content)
            if res and type(data) == "table" then
                lecturesDB = data
                lectureKeys = {}
                for k, _ in pairs(lecturesDB) do table.insert(lectureKeys, k) end
                table.sort(lectureKeys)
                print("[AH] Лекции загружены. Всего: " .. #lectureKeys)
                return true
            end
        end
    end
    return false
end

function updateLecturesFromGitHub()
    local localVer = 0
    if doesFileExist(localLecturesVer) then
        local f = io.open(localLecturesVer, "r")
        if f then localVer = tonumber(f:read("*all"):match("%d+")) or 0; f:close() end
    end
    queueHttpRequest(LECTURES_VER_URL .. "?t=" .. os.time(), function(content)
        local gitVer = tonumber(content:match("%d+")) or 0
        if gitVer > localVer then
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Загрузка обновления лекций...", -1)
            queueHttpRequest(LECTURES_JSON_URL .. "?t=" .. os.time(), function(jsonContent)
                local fJson = io.open(localLecturesJson, "w")
                if fJson then fJson:write(jsonContent); fJson:close() end
                local fVer = io.open(localLecturesVer, "w")
                if fVer then fVer:write(tostring(gitVer)); fVer:close() end
                loadLecturesLocally()
                sampAddChatMessage("{0633E5}[AH] {00FF00}Лекции успешно обновлены!", -1)
            end)
        else
            loadLecturesLocally()
        end
    end)
end

function startLecturePlay(key)
    paused = false
    lectureThread = lua_thread.create(function()
        for _, rawLine in ipairs(lecturesDB[key]) do
            if stopLecture then break end
            local text = rawLine:gsub("%s*%[wait:%d+%]$", "")
            local waitTime = rawLine:match("%[wait:(%d+)%]") or 8000
            sampSendChat(u8:decode(text):gsub("{name}", GetNick()))
            if smartWait(tonumber(waitTime)) then break end
        end
        lectureThread = nil
        if not stopLecture then
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Лекция окончена", -1)
        end
        stopLecture = false
    end)
end

-- ================= [ БАЗА ДАННЫХ И СИНХРОНИЗАЦИЯ ] =================
function updateFromBase()
    queueHttpRequest(GAS_URL .. "?action=read&t=" .. os.time(), function(content)
        if content and (content:sub(1,1) == "[" or content:sub(1, 1) == "{") then
            local res, data = pcall(decodeJson, content)
            if res then
                local temp = {}
                for _, row in ipairs(data) do
                    local n = trim(row.name or row.Nickname)
                    if n ~= "" then temp[n:gsub(" ", "_")] = row end
                end
                cadetsDB = temp
            end
        end
    end)
end

function updateCadetInBase(name, col, joinDate, shouldSyncAfter)
    local url = GAS_URL .. "?action=update&name=" .. urlencode(name) .. "&instructor=" .. urlencode(GetNick())
    if col then url = url .. "&col=" .. urlencode(col) end
    if joinDate then url = url .. "&joinDate=" .. urlencode(joinDate) end
    queueHttpRequest(url, function()
        if shouldSyncAfter then
            sampAddChatMessage("{0633E5}[AH] {00FF00}Отметка подтверждена базой. Обновляю список...", -1)
            syncAll()
        end
    end)
end

function syncAll()
    if isUpdating then return end
    lastSyncTimer = os.clock()
    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Синхронизация...", -1)
    updateFromBase()
    lua_thread.create(function()
        wait(500)
        tempCadets = {}
        isUpdating = true
        sampSendChat("/members")
        local timer = os.clock()
        while isUpdating do
            wait(100)
            if os.clock() - timer > 3.0 then
                isUpdating = false
                sampAddChatMessage("{0633E5}[AH] {FF0000}Таймаут команды /members (Сервер не ответил).", -1)
                break
            end
        end
    end)
end

-- ================= [ MAIN ] =================
function main()
    if not doesDirectoryExist(ah_dir) then createDirectory(getWorkingDirectory() .. "\\config"); createDirectory(ah_dir) end
    while not isSampAvailable() do wait(100) end
    font = renderCreateFont("Arial", 9, 5)
    loadLecturesLocally()
    
    lua_thread.create(function()
        checkScriptUpdate() -- Запускаем проверку при входе
        wait(4000)
        updateLecturesFromGitHub()
        wait(2000)
        syncAll()
    end)

    sampRegisterChatCommand("lectures", function()
        if #lectureKeys == 0 then loadLecturesLocally() end
        if #lectureKeys == 0 then
            sampAddChatMessage("{0633E5}[AH] {FF0000}Список лекций пуст. Проверьте JSON!", -1)
            return
        end
        local s = ""
        for _, k in ipairs(lectureKeys) do
            local d = u8:decode(k)
            if d then s = s .. d .. "\n" end
        end
        sampShowDialog(9913, "{0633E5}Меню лекций", s, "Выбрать", "Отмена", 2)
    end)

    sampRegisterChatCommand("ah", function()
        if #cadetsOnline == 0 then syncAll(); return end
        openAhMenu()
    end)
    
    sampRegisterChatCommand("updc", syncAll)

    while true do
        wait(0)
        processQueue()
        
        -- АВТОМАТИЧЕСКОЕ ОБНОВЛЕНИЕ РАЗ В 90 СЕКУНД
        if os.clock() - lastSyncTimer >= 90.0 then
            if not sampIsChatInputActive() and not sampIsDialogActive() and not isUpdating then
                syncAll()
            end
        end

        -- ХОТКЕЙ: CTRL + R ДЛЯ ОБНОВЛЕНИЯ
        if isKeyDown(vkeys.VK_CONTROL) and wasKeyPressed(vkeys.VK_R) then
            if not sampIsChatInputActive() and not sampIsDialogActive() then
                syncAll()
            end
        end

        -- ХОТКЕЙ: I ДЛЯ ПАУЗЫ
        if wasKeyPressed(vkeys.VK_I) and not sampIsChatInputActive() and not sampIsDialogActive() then
            if lectureThread then
                paused = not paused
                if paused then
                    sampAddChatMessage("{0633E5}[AH] {FF0000}Лекция поставлена на паузу", -1)
                else
                    sampAddChatMessage("{0633E5}[AH] {00FF00}Лекция продолжена", -1)
                end
            end
        end

        -- ОТРИСОВКА HUD
        if showHUD and not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
            local count = #cadetsOnline
            local boxHeight = count > 0 and (40 + (count * 16)) or 56
            renderDrawBox(20, 320, 240, boxHeight, 0x95000000)
            renderFontDrawText(font, "Кадеты Онлайн", 28, 325, 0xFF4682B4)
            if count > 0 then
                for i, v in ipairs(cadetsOnline) do
                    local l, t, p, twoDaysPassed = false, false, false, false
                    local db = cadetsDB[trim(v.rawName)]
                    if db then
                        l = isMarked(db.lecture)
                        t = isMarked(db.theory)
                        p = isMarked(db.practice)
                        twoDaysPassed = hasTwoDaysPassed(db.date) or isMarked(db.isTwoDays)
                    end
                    local baseX = 28
                    local baseY = 342 + (i * 16)
                    local textBase = string.format("%d. %s [%s] ", i, v.displayName, v.id)
                    renderFontDrawText(font, textBase, baseX, baseY, 0xFFFFFFFF)
                    local offset = renderGetFontDrawTextLength(font, textBase)
                    local colL = l and 0xFF00FF00 or 0xFFFF4D4D
                    renderFontDrawText(font, "[Л]", baseX + offset, baseY, colL)
                    offset = offset + renderGetFontDrawTextLength(font, "[Л]")
                    local colT = t and 0xFF00FF00 or 0xFFFF4D4D
                    renderFontDrawText(font, "[Т]", baseX + offset, baseY, colT)
                    offset = offset + renderGetFontDrawTextLength(font, "[Т]")
                    local colP = p and 0xFF00FF00 or 0xFFFF4D4D
                    renderFontDrawText(font, "[П]", baseX + offset, baseY, colP)
                    offset = offset + renderGetFontDrawTextLength(font, "[П]")
                    local colD = twoDaysPassed and 0xFF00FF00 or 0xFFFF4D4D
                    renderFontDrawText(font, "[Д]", baseX + offset, baseY, colD)
                end
            else
                renderFontDrawText(font, "—", 28, 345, 0xFFFFFFFF)
            end
        end
    end
end

-- ================= [ СОБЫТИЯ ] =================
function sampev.onSendDialogResponse(id, btn, lst, inp)
    if id == 9910 then
        if btn == 1 then
            if lst == 0 then
                showHUD = not showHUD
                sampAddChatMessage(showHUD and "{0633E5}[AH] {00FF00}Отображение HUD включено" or "{0633E5}[AH] {FF0000}Отображение HUD выключено", -1)
                lua_thread.create(function() wait(10); openAhMenu() end)
            else
                selectedCadet = cadetsOnline[lst]
                if selectedCadet then
                    lua_thread.create(function()
                        wait(10)
                        sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                    end)
                end
            end
        end
        return false
    elseif id == 9911 then
        if btn == 1 then
            if lst == 3 then
                local db = cadetsDB[trim(selectedCadet.rawName)]
                local l = (db and isMarked(db.lecture)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local t = (db and isMarked(db.theory)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local p = (db and isMarked(db.practice)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local d = (db and (hasTwoDaysPassed(db.date) or isMarked(db.isTwoDays))) and "{00FF00}прошло" or "{FF0000}не прошло"
                local info_text = string.format("Лекция: %s\n{FFFFFF}Теория: %s\n{FFFFFF}Практика: %s\n{FFFFFF}Два дня: %s", l, t, p, d)
                lua_thread.create(function() wait(10); sampShowDialog(9912, "{0633E5}Инфо: " .. selectedCadet.displayName, info_text, "Назад", "", 0) end)
            elseif lst == 4 then
                sampAddChatMessage("{0633E5}[AH] {FFFFFF}Запрос на сброс отправлен...", -1)
                if cadetsDB[trim(selectedCadet.rawName)] then cadetsDB[trim(selectedCadet.rawName)] = nil end
                updateCadetInBase(selectedCadet.rawName, "reset", nil, true)
            else
                sampAddChatMessage("{0633E5}[AH] {FFFFFF}Запрос на обновление отправлен...", -1)
                local columns = {"lecture", "theory", "practice"}
                local colName = columns[lst + 1]
                local safeName = trim(selectedCadet.rawName)
                if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
                cadetsDB[safeName][colName] = "1"
                updateCadetInBase(selectedCadet.rawName, colName, nil, true)
            end
        else
            lua_thread.create(function() wait(10); openAhMenu() end)
        end
        return false
    elseif id == 9912 then
        lua_thread.create(function() wait(10); sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) end)
        return false
    elseif id == 9913 then
        if btn == 1 then
            local key = lectureKeys[lst + 1]
            if key and lecturesDB[key] then
                if lectureThread then
                    stopLecture = true
                    lua_thread.create(function()
                        while lectureThread ~= nil do wait(10) end
                        stopLecture = false
                        startLecturePlay(key)
                    end)
                else
                    startLecturePlay(key)
                end
            end
        end
        return false
    end
end

function sampev.onServerMessage(clr, txt)
    if isUpdating then
        local cleanTxt = txt:gsub("{%x+}", "")
        if cleanTxt:find("ID:") and (cleanTxt:find("Кадет") or cleanTxt:find("Cadet")) then
            local id, date_mem, nick = cleanTxt:match("ID:%s*(%d+)%s*|%s*%d+:%d+%s*([%d%.]+)%s*|%s*([%a%d_]+)")
            if nick and id then
                table.insert(tempCadets, {rawName = nick, displayName = nick:gsub("_", " "), id = id, joinDate = date_mem})
            end
            return false
        end
        if cleanTxt:find("Всего%:") or cleanTxt:find("Всего в сети") or cleanTxt:find("Онлайн организации") then
            isUpdating = false
            cadetsOnline = tempCadets
            for _, c in ipairs(cadetsOnline) do updateCadetInBase(c.rawName, nil, c.joinDate, false) end
            return false
        end
        return false
    end
end
