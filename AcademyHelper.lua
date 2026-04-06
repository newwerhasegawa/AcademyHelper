script_name("AcademyHelper")
script_version("0.9.9")
script_authors("Newwer Hasegawa")

local encoding = require 'encoding'
local sampev = require 'lib.samp.events'
local vkeys = require 'lib.vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8
math.randomseed(os.time())

-- ================= [ ССЫЛКИ ] =================
local GAS_URL = "https://script.google.com/macros/s/AKfycbyZWGjcx2ibc3_ltI1D1pwh1qd0pjYcCIiRbEy4tystZeUne10s7n3v1aBNUkrNLXVAlQ/exec"
local ah_dir = getWorkingDirectory() .. "\\config\\AcademyHelper\\"
local localLecturesJson = ah_dir .. "lectures.json"
local localLecturesVer = ah_dir .. "lectures_version.txt"
local LECTURES_JSON_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/lectures.json"
local LECTURES_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/lectures_version.txt"

local SCRIPT_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/refs/heads/main/version.txt"
local SCRIPT_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/refs/heads/main/AcademyHelper.lua"

-- ================= [ ПЕРЕМЕННЫЕ ] =================
local cadetsOnline = {}
local tempCadets = {}
local cadetsDB = {}
local isUpdating = false
local lastSyncTimer = os.clock()
local showHUD = true 
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

local updateTriggered = false 
local isScriptActive = false 
local welcomeShown = false 
local lastClickTick = 0 

-- ================= [ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ] =================
-- Безопасная функция для u8
local function safe_u8(str)
    return u8(tostring(str or ""))
end

local function checkCooldown()
    if os.clock() - lastClickTick < 0.5 then return false end
    lastClickTick = os.clock()
    return true
end

local function trim(s) 
    return s and tostring(s):match("^%s*(.-)%s*$") or "" 
end

local function urlencode(str)
    if str then
        str = string.gsub(str, "([^%w ])", function(c) return string.format("%%%02X", string.byte(c)) end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

local function isMarked(val)
    if val == nil or val == "" then return false end
    local num = tonumber(val)
    if num then return num >= 1 end
    local str = tostring(val):lower()
    return str == "true" or str == "1" or str == "да"
end

local function GetNick()
    local res, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if res and myid ~= -1 then
        local nick = sampGetPlayerNickname(myid)
        if nick then return nick:gsub("_", " ") end
    end
    return "Инструктор"
end

local function smartWait(ms)
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

local function showWelcomeMessage()
    local scr = thisScript()
    sampAddChatMessage("{0633E5}" .. scr.name .. " {FFFFFF}v.{C8271E}" .. scr.version .. "{FFFFFF} authors {3645E2}" .. table.concat(scr.authors, ", ") .. "{FFFFFF} был успешно загружен!", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Для активации/деактивации скрипта нажмите клавишу '{C8271E}F5{FFFFFF}'.", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Меню взаимодействий - {C8271E}/ah{FFFFFF}, Меню лекций - {C8271E}/lectures{FFFFFF}, поставить на паузу клавиша '{C8271E}I{FFFFFF}'.", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Обновить информацию вручную - {C8271E}/updc{FFFFFF}.", 0x0633E5)
end

-- ================= [ МЕНЮ ] =================
local function openAhMenu()
    local toggleText = showHUD and "{FF0000}Выключить HUD" or "{00FF00}Включить HUD"
    local s = toggleText .. "\n{FFFFFF}Обновить список кадетов\n" 
    
    if #cadetsOnline > 0 then
        for i, v in ipairs(cadetsOnline) do 
            if v and v.displayName and v.id then
                s = s .. v.displayName .. " [" .. v.id .. "]\n" 
            end
        end
    else
        s = s .. "{A9A9A9}Кадетов в сети нет\n"
    end
    
    sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Выбор", "Закрыть", 2)
end

-- ================= [ ОБРАБОТКА ОЧЕРЕДИ ] =================
local function processQueue()
    if isRequesting then
        if os.clock() - requestTimestamp > 20 then isRequesting = false end
        return 
    end
    if #requestQueue == 0 then return end
    
    isRequesting = true
    requestTimestamp = os.clock()
    local nextReq = table.remove(requestQueue, 1)
    
    local tempPath = string.format("%stmp_%d%d.tmp", ah_dir, os.time(), math.random(1000, 9999))
    
    local dl_status, dl_err = pcall(downloadUrlToFile, nextReq.url, tempPath, function(id, status)
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
        elseif status == 58 or status == 7 or status == -1 then 
            if doesFileExist(tempPath) then os.remove(tempPath) end
            isRequesting = false
        end
    end)

    if not dl_status then
        isRequesting = false
    end
end

local function queueHttpRequest(url, callback)
    table.insert(requestQueue, {url = url, callback = callback})
end

-- ================= [ АВТООБНОВЛЕНИЕ СКРИПТА ] =================
local function checkScriptUpdate()
    if updateTriggered then return end
    queueHttpRequest(SCRIPT_VER_URL .. "?t=" .. os.time(), function(remoteVer)
        if not remoteVer then return end
        local currentVer = thisScript().version
        local cleanRemoteVer = trim(remoteVer):match("[%d%.]+")
        
        if cleanRemoteVer and cleanRemoteVer ~= currentVer then
            updateTriggered = true
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Найдена версия {00FF00}v." .. cleanRemoteVer .. "{FFFFFF}. Начинаю загрузку...", -1)
            
            queueHttpRequest(SCRIPT_URL .. "?t=" .. os.time(), function(content)
                if content and content:find("script_name") then
                    local f = io.open(thisScript().path, "wb")
                    if f then
                        f:write(u8:decode(content))
                        f:close()
                        sampAddChatMessage("{0633E5}[AH] {00FF00}Файл обновлен. Перезагрузка через 1 сек...", -1)
                        lua_thread.create(function()
                            wait(1000) 
                            thisScript():reload()
                        end)
                    else
                        sampAddChatMessage("{0633E5}[AH] {FF0000}Ошибка: Файл занят другой программой!", -1)
                        updateTriggered = false
                    end
                else
                    sampAddChatMessage("{0633E5}[AH] {FF0000}Ошибка: Получен пустой файл обновления.", -1)
                    updateTriggered = false
                end
            end)
        end
    end)
end

-- ================= [ ФУНКЦИИ ЛЕКЦИЙ ] =================
local function loadLecturesLocally()
    if not doesFileExist(localLecturesJson) then return false end
    local f = io.open(localLecturesJson, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and #content > 0 then
            local res, data = pcall(decodeJson, content)
            if res and type(data) == "table" then
                lecturesDB = {} 
                lectureKeys = {}
                for k, lines in pairs(data) do
                    local decodedKey = u8:decode(k)
                    lecturesDB[decodedKey] = {}
                    if type(lines) == "table" then
                        for _, line in ipairs(lines) do
                            table.insert(lecturesDB[decodedKey], u8:decode(line))
                        end
                        table.insert(lectureKeys, decodedKey)
                    end
                end
                table.sort(lectureKeys)
                return true
            end
        end
    end
    return false
end

local function updateLecturesFromGitHub()
    local localVer = 0
    if doesFileExist(localLecturesVer) then
        local f = io.open(localLecturesVer, "r")
        if f then 
            local content = f:read("*all")
            if content then localVer = tonumber(content:match("%d+")) or 0 end
            f:close() 
        end
    end
    queueHttpRequest(LECTURES_VER_URL .. "?t=" .. os.time(), function(content)
        if not content then return end
        local gitVer = tonumber(content:match("%d+")) or 0
        if gitVer > localVer then
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Загрузка обновления лекций...", -1)
            queueHttpRequest(LECTURES_JSON_URL .. "?t=" .. os.time(), function(jsonContent)
                if not jsonContent then return end
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

local function startLecturePlay(key)
    paused = false
    lectureThread = lua_thread.create(function()
        if lecturesDB[key] then
            for _, rawLine in ipairs(lecturesDB[key]) do
                if stopLecture then break end
                local text = rawLine:gsub("%s*%[wait:%d+%]$", "")
                local waitTime = rawLine:match("%[wait:(%d+)%]") or 8000
                sampSendChat(text:gsub("{name}", GetNick()))
                if smartWait(tonumber(waitTime)) then break end
            end
        end
        lectureThread = nil
        if not stopLecture then
            sampAddChatMessage("{0633E5}[AH] {FFFFFF}Лекция окончена", -1)
        end
        stopLecture = false
    end)
end

-- ================= [ БАЗА ДАННЫХ И СИНХРОНИЗАЦИЯ ] =================
local function updateFromBase()
    queueHttpRequest(GAS_URL .. "?action=read&t=" .. os.time(), function(content)
        if content and (content:sub(1,1) == "[" or content:sub(1, 1) == "{") then
            local res, data = pcall(decodeJson, content)
            if res and type(data) == "table" then
                local temp = {}
                for _, row in ipairs(data) do
                    if type(row) == "table" then
                        local n = trim(row.name or row.Nickname)
                        if n ~= "" then temp[n:gsub(" ", "_")] = row end
                    end
                end
                cadetsDB = temp
            end
        end
    end)
end

local function updateCadetInBase(name, col, joinDate, shouldSyncAfter, extraVal)
    if not name then return end
    
    -- Применяем безопасную u8 упаковку для всех параметров URL
    local safeName = urlencode(safe_u8(name))
    local safeInst = urlencode(safe_u8(GetNick()))
    
    local url = GAS_URL .. "?action=update&name=" .. safeName .. "&instructor=" .. safeInst
    
    if col then url = url .. "&col=" .. urlencode(safe_u8(col)) end
    if joinDate then url = url .. "&joinDate=" .. urlencode(safe_u8(joinDate)) end
    
    -- Дополнительная проверка на наличие значения
    if extraVal and tostring(extraVal) ~= "" then 
        url = url .. "&val=" .. urlencode(safe_u8(extraVal)) 
    end
    
    queueHttpRequest(url, function()
        if shouldSyncAfter then
            sampAddChatMessage("{0633E5}[AH] {00FF00}Отметка подтверждена базой. Обновляю список...", -1)
            syncAll(false)
        end
    end)
end

function syncAll(silent)
    if isUpdating then return end
    lastSyncTimer = os.clock()
    if not silent then
        sampAddChatMessage("{0633E5}[AH] {FFFFFF}Синхронизация...", -1)
    end
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
                if not silent then
                    sampAddChatMessage("{0633E5}[AH] {FF0000}Таймаут команды /members (Сервер не ответил).", -1)
                end
                break
            end
        end
        if not silent and #cadetsOnline == 0 then
            sampAddChatMessage("{0633E5}[AH] {FF0000}Кадетов в сети нет.", -1)
        end
    end)
end

-- ================= [ MAIN ] =================
function main()
    if not doesDirectoryExist(ah_dir) then createDirectory(getWorkingDirectory() .. "\\config"); createDirectory(ah_dir) end
    while not isSampAvailable() do wait(100) end
    font = renderCreateFont("Arial", 8, 5)
    loadLecturesLocally()
    
    lua_thread.create(function()
        checkScriptUpdate() 
        wait(4000)
        updateLecturesFromGitHub()
    end)

    sampRegisterChatCommand("lectures", function()
        if not isScriptActive then return end
        if not checkCooldown() then return end
        if #lectureKeys == 0 then loadLecturesLocally() end
        if #lectureKeys == 0 then
            sampAddChatMessage("{0633E5}[AH] {FF0000}Список лекций пуст!", -1)
            return
        end
        local s = ""
        for _, k in ipairs(lectureKeys) do s = s .. k .. "\n" end
        sampShowDialog(9913, "{0633E5}Меню лекций", s, "Выбрать", "Отмена", 2)
    end)

    sampRegisterChatCommand("ah", function()
        if not isScriptActive then return end
        if not checkCooldown() then return end
        openAhMenu()
    end)
    
    sampRegisterChatCommand("updc", function()
        if not isScriptActive then return end
        if not checkCooldown() then return end
        syncAll(false)
    end)

    while true do
        wait(0)
        processQueue()
        
        if not welcomeShown and sampIsLocalPlayerSpawned() then
            welcomeShown = true
            lua_thread.create(function()
                wait(1000) 
                showWelcomeMessage()
            end)
        end
        
        if wasKeyPressed(vkeys.VK_F5) and not sampIsChatInputActive() and not sampIsDialogActive() then
            if checkCooldown() then
                isScriptActive = not isScriptActive
                if isScriptActive then
                    sampAddChatMessage("{0633E5}[AH] {00FF00}Скрипт активирован!", -1)
                    syncAll(true)
                else
                    sampAddChatMessage("{0633E5}[AH] {FF0000}Скрипт выключен!", -1)
                end
            end
        end
        
        if isScriptActive then
            if os.clock() - lastSyncTimer >= 90.0 and not isPauseMenuActive() then
                if not sampIsChatInputActive() and not sampIsDialogActive() and not isUpdating then
                    syncAll(true)
                end
            end

            if isKeyDown(vkeys.VK_CONTROL) and wasKeyPressed(vkeys.VK_R) and not isPauseMenuActive() then
                if not sampIsChatInputActive() and not sampIsDialogActive() then
                    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Принудительная остановка и перезагрузка...", -1)
                    if lectureThread then
                        stopLecture = true
                        pcall(function() lectureThread:terminate() end) 
                        lectureThread = nil
                    end
                    isUpdating = false
                    isRequesting = false
                    requestQueue = {}
                    lua_thread.create(function()
                        wait(100)
                        thisScript():reload()
                    end)
                end
            end

            if wasKeyPressed(vkeys.VK_I) and not sampIsChatInputActive() and not sampIsDialogActive() then
                if lectureThread then
                    paused = not paused
                    sampAddChatMessage(paused and "{0633E5}[AH] {FF0000}Лекция на паузе" or "{0633E5}[AH] {00FF00}Лекция продолжена", -1)
                end
            end

            if showHUD and not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
                local count = #cadetsOnline
                local boxWidth = renderGetFontDrawTextLength(font, "Кадеты Онлайн") + 20
                if count > 0 then
                    for i, v in ipairs(cadetsOnline) do
                        if v and v.displayName and v.id then
                            local fullText = string.format("%d. %s [%s] [Л][Т][П][Д]", i, v.displayName, v.id)
                            local w = renderGetFontDrawTextLength(font, fullText) + 15
                            if w > boxWidth then boxWidth = w end
                        end
                    end
                end

                local boxHeight = count > 0 and (35 + (count * 14)) or 50
                renderDrawBox(20, 320, boxWidth, boxHeight, 0x95000000)
                renderFontDrawText(font, "Кадеты Онлайн", 28, 325, 0xFF4682B4)
                
                if count > 0 then
                    local renderIndex = 1
                    for i, v in ipairs(cadetsOnline) do
                        if v and v.rawName then
                            local l, t, p, dPassed, raising = false, false, false, false, false
                            local safeName = trim(v.rawName)
                            local db = cadetsDB and cadetsDB[safeName] or nil
                            if db then
                                l = isMarked(db.lecture)
                                t = isMarked(db.theory)
                                p = isMarked(db.practice)
                                dPassed = isMarked(db.isTwoDays) 
                                raising = isMarked(db.raising) 
                            end
                            local baseX, baseY = 28, 338 + (renderIndex * 14)

                            local isReady = (raising or dPassed) 

                            if isReady then
                                renderFontDrawText(font, string.format("%d. %s [%s]", renderIndex, v.displayName or "Unknown", v.id or "0"), baseX, baseY, 0xFF00FF00)
                            else
                                local textBase = string.format("%d. %s [%s] ", renderIndex, v.displayName or "Unknown", v.id or "0")
                                renderFontDrawText(font, textBase, baseX, baseY, 0xFFFFFFFF)
                                
                                local offset = renderGetFontDrawTextLength(font, textBase)
                                renderFontDrawText(font, "[Л]", baseX + offset, baseY, l and 0xFF00FF00 or 0xFFFF4D4D)
                                offset = offset + renderGetFontDrawTextLength(font, "[Л]")
                                renderFontDrawText(font, "[Т]", baseX + offset, baseY, t and 0xFF00FF00 or 0xFFFF4D4D)
                                offset = offset + renderGetFontDrawTextLength(font, "[Т]")
                                renderFontDrawText(font, "[П]", baseX + offset, baseY, p and 0xFF00FF00 or 0xFFFF4D4D)
                                offset = offset + renderGetFontDrawTextLength(font, "[П]")
                                renderFontDrawText(font, "[Д]", baseX + offset, baseY, dPassed and 0xFF00FF00 or 0xFFFF4D4D)
                            end
                            
                            renderIndex = renderIndex + 1
                        end
                    end
                else
                    renderFontDrawText(font, "—", 28, 345, 0xFFFFFFFF)
                end
            end
        end
    end
end

-- ================= [ ОБРАБОТКА ДИАЛОГОВ ] =================
function sampev.onSendDialogResponse(id, btn, lst, inp)
    if not checkCooldown() then return false end 
    if id == 9910 then
        if btn == 1 then
            if lst == 0 then 
                showHUD = not showHUD
                sampAddChatMessage(showHUD and "{0633E5}[AH] {00FF00}HUD включен" or "{0633E5}[AH] {FF0000}HUD выключен", -1)
                lua_thread.create(function() wait(50); openAhMenu() end)
            elseif lst == 1 then 
                syncAll(false)
            else 
                if #cadetsOnline > 0 then
                    selectedCadet = cadetsOnline[lst - 1]
                    if selectedCadet and selectedCadet.displayName then
                        lua_thread.create(function()
                            wait(50)
                            sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                        end)
                    end
                end
            end
        end
        return false
    elseif id == 9911 then
        if btn == 1 then
            if not selectedCadet or not selectedCadet.rawName then return false end
            local safeName = trim(selectedCadet.rawName)
            
            if lst == 5 then
                local db = cadetsDB and cadetsDB[safeName] or nil
                local l = (db and isMarked(db.lecture)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local t = (db and isMarked(db.theory)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local p = (db and isMarked(db.practice)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local d = (db and isMarked(db.isTwoDays)) and "{00FF00}прошло" or "{FF0000}не прошло"
                local rep = (db and db.report and db.report ~= "") and "{00FF00}залит" or "{FF0000}не залит"
                local com = (db and db.comment and db.comment ~= "") and "{00FF00}добавлен" or "{FF0000}не добавлен"
                local info_text = string.format("Лекция: %s\n{FFFFFF}Теория: %s\n{FFFFFF}Практика: %s\n{FFFFFF}Два дня: %s\n{FFFFFF}Отчет: %s\n{FFFFFF}Комментарий: %s", l, t, p, d, rep, com)
                lua_thread.create(function() wait(50); sampShowDialog(9912, "{0633E5}Инфо: " .. (selectedCadet.displayName or ""), info_text, "Назад", "", 0) end)
            elseif lst == 6 then
                sampAddChatMessage("{0633E5}[AH] {FFFFFF}Запрос на сброс отправлен...", -1)
                if cadetsDB and cadetsDB[safeName] then cadetsDB[safeName] = nil end
                updateCadetInBase(selectedCadet.rawName, "reset", nil, true)
                lua_thread.create(function()
                    wait(100)
                    if selectedCadet and selectedCadet.displayName then
                        sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                    end
                end)
            elseif lst == 3 then
                lua_thread.create(function() wait(50); sampShowDialog(9914, "{0633E5}Отчет", "{FFFFFF}Введите ссылку на отчет:", "Отправить", "Отмена", 1) end)
            elseif lst == 4 then
                lua_thread.create(function() wait(50); sampShowDialog(9915, "{0633E5}Комментарий", "{FFFFFF}Введите комментарий:", "Отправить", "Отмена", 1) end)
            else
                local columns = {"lecture", "theory", "practice"}
                local colName = columns[lst + 1]
                if colName then
                    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Запрос на обновление...", -1)
                    if not cadetsDB then cadetsDB = {} end
                    if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
                    cadetsDB[safeName][colName] = "1"
                    updateCadetInBase(selectedCadet.rawName, colName, nil, true)
                    lua_thread.create(function()
                        wait(100)
                        if selectedCadet and selectedCadet.displayName then
                            sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                        end
                    end)
                end
            end
        else
            lua_thread.create(function() wait(50); openAhMenu() end)
        end
        return false
    elseif id == 9912 then
        lua_thread.create(function() 
            wait(50)
            if selectedCadet and selectedCadet.displayName then
                sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) 
            end
        end)
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
    elseif id == 9914 then
        if btn == 1 and inp and inp:match("%S") then
            if not selectedCadet or not selectedCadet.rawName then return false end
            local safeName = trim(selectedCadet.rawName)
            if not cadetsDB then cadetsDB = {} end
            if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
            cadetsDB[safeName].report = inp
            updateCadetInBase(selectedCadet.rawName, "report", nil, true, inp)
        else
            lua_thread.create(function() 
                wait(50)
                if selectedCadet and selectedCadet.displayName then
                    sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) 
                end
            end)
        end
        return false
    elseif id == 9915 then
        if btn == 1 and inp and inp:match("%S") then
            if not selectedCadet or not selectedCadet.rawName then return false end
            local safeName = trim(selectedCadet.rawName)
            if not cadetsDB then cadetsDB = {} end
            if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
            cadetsDB[safeName].comment = inp
            updateCadetInBase(selectedCadet.rawName, "comment", nil, true, inp)
        else
            lua_thread.create(function() 
                wait(50)
                if selectedCadet and selectedCadet.displayName then
                    sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) 
                end
            end)
        end
        return false
    end
end

function sampev.onServerMessage(clr, txt)
    if not txt then return end 
    local cleanTxt = txt:gsub("{%x+}", "") 
    
    if isUpdating then
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
            
            local batchData = {}
            for _, c in ipairs(cadetsOnline) do 
                if c and c.rawName then
                    table.insert(batchData, {n = c.rawName, d = c.joinDate})
                end
            end
            
            if #batchData > 0 then
                local jsonStr = encodeJson(batchData)
                local safeJson = urlencode(jsonStr)
                local batchUrl = GAS_URL .. "?action=batch_sync&data=" .. safeJson
                queueHttpRequest(batchUrl, function() end)
            end
            
            return false
        end
        
        return false 
    end
end
