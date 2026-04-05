script_name("AcademyHelper_Stable_v0.9.4_Merged")
script_version("0.9.6")
script_authors("Newer Hasegawa")

-- ПРАВИЛЬНЫЕ ПУТИ (БЕЗ lib.)
local encoding = require 'encoding'
local sampev = require 'samp.events'
local vkeys = require 'vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- Вспомогательная функция для перевода UTF-8 в CP1251 (чтобы не было кракозябр)
local function u8d(str)
    return u8:decode(str)
end

math.randomseed(os.time())

-- ================= [ НАСТРОЙКИ ] =================
local GAS_URL = "https://script.google.com/macros/s/AKfycbwI9L_unVaA-C1TVM6QmtG7iJu90p4LfRD-N7wCds7VlYoPKjNSJzLFzZ_opduNVrvU/exec"
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
local lastSyncTimer = 0
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
    return u8d("Инструктор")
end

function smartWait(ms)
    local timer = 0
    while timer < ms do
        if not paused then timer = timer + 100 end
        wait(100)
        if stopLecture then return true end
    end
    return false
end

function openAhMenu()
    local toggleText = showHUD and u8d("{FF0000}[ Выключить HUD ]") or u8d("{00FF00}[ Включить HUD ]")
    local s = toggleText .. "\n"
    for i, v in ipairs(cadetsOnline) do s = s .. v.displayName .. " [" .. v.id .. "]\n" end
    sampShowDialog(9910, "{0633E5}AcademyHelper", s, u8d("Выбор"), u8d("Закрыть"), 2)
end

-- ================= [ ОЧЕРЕДЬ ЗАПРОСОВ ] =================
function processQueue()
    if isRequesting then
        if os.clock() - requestTimestamp > 12 then isRequesting = false else return end
    end
    if #requestQueue == 0 then return end
    isRequesting = true
    requestTimestamp = os.clock()
    local nextReq = table.remove(requestQueue, 1)
    local prefix = nextReq.url:find("google") and "gas" or (nextReq.url:find("version") and "ver" or "lec")
    local tempPath = string.format("%stmp_%s_%d.json", ah_dir, prefix, os.time())
    
    downloadUrlToFile(nextReq.url, tempPath, function(id, status)
        if status == 6 then
            local f = io.open(tempPath, "r")
            if f then
                local content = f:read("*all")
                f:close()
                os.remove(tempPath)
                lua_thread.create(function() if nextReq.callback then nextReq.callback(content) end end)
            end
            isRequesting = false
        elseif status == 58 then isRequesting = false end
    end)
end

function queueHttpRequest(url, callback)
    table.insert(requestQueue, {url = url, callback = callback})
end

-- ================= [ АВТООБНОВЛЕНИЕ ] =================
function checkScriptUpdate()
    if updateTriggered then return end
    queueHttpRequest(SCRIPT_VER_URL .. "?t=" .. os.time(), function(remoteVer)
        local currentVer = thisScript().version
        local cleanRemoteVer = trim(remoteVer):match("[%d%.]+")
        
        if cleanRemoteVer and cleanRemoteVer ~= currentVer and not updateTriggered then
            updateTriggered = true
            sampAddChatMessage(u8d("{0633E5}[AH] {FFFFFF}Найдена новая версия {00FF00}v." .. cleanRemoteVer .. "{FFFFFF}, установка..."), -1)
            
            queueHttpRequest(SCRIPT_URL .. "?t=" .. os.time(), function(scriptContent)
                if scriptContent and scriptContent:find("script_name") then
                    local f = io.open(thisScript().path, "wb")
                    if f then
                        f:write(scriptContent)
                        f:close()
                        sampAddChatMessage(u8d("{0633E5}[AH] {00FF00}Обновление завершено. Перезагрузка..."), -1)
                        thisScript():reload()
                    end
                end
            end)
        end
    end)
end

-- ================= [ ЛЕКЦИИ ] =================
function loadLecturesLocally()
    if not doesFileExist(localLecturesJson) then return false end
    local f = io.open(localLecturesJson, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local res, data = pcall(decodeJson, content)
        if res and type(data) == "table" then
            lecturesDB = data
            lectureKeys = {}
            for k, _ in pairs(lecturesDB) do table.insert(lectureKeys, k) end
            table.sort(lectureKeys)
            return true
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
            sampAddChatMessage(u8d("{0633E5}[AH] {FFFFFF}Загрузка обновления лекций..."), -1)
            queueHttpRequest(LECTURES_JSON_URL .. "?t=" .. os.time(), function(jsonContent)
                local fJson = io.open(localLecturesJson, "w")
                if fJson then fJson:write(jsonContent); fJson:close() end
                local fVer = io.open(localLecturesVer, "w")
                if fVer then fVer:write(tostring(gitVer)); fVer:close() end
                loadLecturesLocally()
                sampAddChatMessage(u8d("{0633E5}[AH] {00FF00}Лекции успешно обновлены!"), -1)
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
            sampSendChat(u8d(text):gsub("{name}", GetNick()))
            if smartWait(tonumber(waitTime)) then break end
        end
        lectureThread = nil
        if not stopLecture then sampAddChatMessage(u8d("{0633E5}[AH] {FFFFFF}Лекция окончена"), -1) end
        stopLecture = false
    end)
end

-- ================= [ БАЗА ДАННЫХ ] =================
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
            sampAddChatMessage(u8d("{0633E5}[AH] {00FF00}Отметка подтверждена базой. Обновляю список..."), -1)
            syncAll()
        end
    end)
end

function syncAll()
    if isUpdating then return end
    lastSyncTimer = os.clock()
    sampAddChatMessage(u8d("{0633E5}[AH] {FFFFFF}Синхронизация..."), -1)
    updateFromBase()
    lua_thread.create(function()
        wait(500)
        tempCadets = {}
        isUpdating = true
        sampSendChat("/members")
        local timer = os.clock()
        while isUpdating do
            wait(100)
            if os.clock() - timer > 3.0 then isUpdating = false; break end
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
        checkScriptUpdate()
        wait(4000)
        updateLecturesFromGitHub()
        wait(2000)
        syncAll()
    end)

    sampRegisterChatCommand("lectures", function()
        if #lectureKeys == 0 then loadLecturesLocally() end
        local s = ""
        for _, k in ipairs(lectureKeys) do s = s .. u8d(k) .. "\n" end
        sampShowDialog(9913, u8d("{0633E5}Меню лекций"), s, u8d("Выбрать"), u8d("Отмена"), 2)
    end)

    sampRegisterChatCommand("ah", function() openAhMenu() end)
    sampRegisterChatCommand("updc", syncAll)

    while true do
        wait(0)
        processQueue()
        
        if os.clock() - lastSyncTimer >= 90.0 and not sampIsChatInputActive() and not isUpdating then syncAll() end

        if wasKeyPressed(vkeys.VK_I) and not sampIsChatInputActive() and lectureThread then
            paused = not paused
            sampAddChatMessage(paused and u8d("{0633E5}[AH] {FF0000}Лекция на паузе") or u8d("{0633E5}[AH] {00FF00}Лекция продолжена"), -1)
        end

        if showHUD and not isPauseMenuActive() and font then
            local count = #cadetsOnline
            renderDrawBox(20, 320, 240, count > 0 and (40 + (count * 16)) or 56, 0x95000000)
            renderFontDrawText(font, u8d("Кадеты Онлайн"), 28, 325, 0xFF4682B4)
            if count > 0 then
                for i, v in ipairs(cadetsOnline) do
                    local db = cadetsDB[trim(v.rawName)]
                    local l = db and isMarked(db.lecture)
                    local t = db and isMarked(db.theory)
                    local p = db and isMarked(db.practice)
                    local d2 = db and (hasTwoDaysPassed(db.date) or isMarked(db.isTwoDays))
                    
                    local text = string.format("%d. %s [%s] ", i, v.displayName, v.id)
                    renderFontDrawText(font, text, 28, 342 + (i * 16), 0xFFFFFFFF)
                    local off = renderGetFontDrawTextLength(font, text)
                    renderFontDrawText(font, "[Л]", 28 + off, 342 + (i * 16), l and 0xFF00FF00 or 0xFFFF4D4D)
                    off = off + renderGetFontDrawTextLength(font, "[Л]")
                    renderFontDrawText(font, "[Т]", 28 + off, 342 + (i * 16), t and 0xFF00FF00 or 0xFFFF4D4D)
                    off = off + renderGetFontDrawTextLength(font, "[Т]")
                    renderFontDrawText(font, "[П]", 28 + off, 342 + (i * 16), p and 0xFF00FF00 or 0xFFFF4D4D)
                    off = off + renderGetFontDrawTextLength(font, "[П]")
                    renderFontDrawText(font, "[Д]", 28 + off, 342 + (i * 16), d2 and 0xFF00FF00 or 0xFFFF4D4D)
                end
            end
        end
    end
end

-- ================= [ EVENTS ] =================
function sampev.onSendDialogResponse(id, btn, lst, inp)
    if id == 9910 and btn == 1 then
        if lst == 0 then
            showHUD = not showHUD
            lua_thread.create(function() wait(10); openAhMenu() end)
        else
            selectedCadet = cadetsOnline[lst]
            if selectedCadet then
                lua_thread.create(function()
                    wait(10)
                    sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, u8d("Лекция\nТеория\nПрактика\n{A020F0}Информация\n{FF0000}Сброс прогресса"), u8d("ОК"), u8d("Назад"), 2)
                end)
            end
        end
        return false
    elseif id == 9911 then
        if btn == 1 then
            if lst == 3 then
                local db = cadetsDB[trim(selectedCadet.rawName)]
                local l = (db and isMarked(db.lecture)) and u8d("{00FF00}прошел") or u8d("{FF0000}не прошел")
                local t = (db and isMarked(db.theory)) and u8d("{00FF00}прошел") or u8d("{FF0000}не прошел")
                local p = (db and isMarked(db.practice)) and u8d("{00FF00}прошел") or u8d("{FF0000}не прошел")
                local d = (db and (hasTwoDaysPassed(db.date) or isMarked(db.isTwoDays))) and u8d("{00FF00}прошло") or u8d("{FF0000}не прошло")
                local info = string.format(u8d("Лекция: %s\n{FFFFFF}Теория: %s\n{FFFFFF}Практика: %s\n{FFFFFF}Два дня: %s"), l, t, p, d)
                lua_thread.create(function() wait(10); sampShowDialog(9912, u8d("{0633E5}Инфо: ") .. selectedCadet.displayName, info, u8d("Назад"), "", 0) end)
            elseif lst == 4 then
                updateCadetInBase(selectedCadet.rawName, "reset", nil, true)
            else
                local cols = {"lecture", "theory", "practice"}
                updateCadetInBase(selectedCadet.rawName, cols[lst+1], nil, true)
            end
        else lua_thread.create(function() wait(10); openAhMenu() end) end
        return false
    elseif id == 9912 then
        lua_thread.create(function() wait(10); sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, u8d("Лекция\nТеория\nПрактика\n{A020F0}Информация\n{FF0000}Сброс прогресса"), u8d("ОК"), u8d("Назад"), 2) end)
        return false
    elseif id == 9913 and btn == 1 then
        local key = lectureKeys[lst+1]
        if key then
            if lectureThread then stopLecture = true; lua_thread.create(function() while lectureThread do wait(10) end; startLecturePlay(key) end)
            else startLecturePlay(key) end
        end
        return false
    end
end

function sampev.onServerMessage(clr, txt)
    if isUpdating then
        local clean = txt:gsub("{%x+}", "")
        if clean:find("ID:") and (clean:find(u8d("Кадет")) or clean:find("Cadet")) then
            local id, d_mem, nick = clean:match("ID:%s*(%d+)%s*|%s*%d+:%d+%s*([%d%.]+)%s*|%s*([%a%d_]+)")
            if nick then table.insert(tempCadets, {rawName = nick, displayName = nick:gsub("_", " "), id = id, joinDate = d_mem}) end
            return false
        end
        if clean:find(u8d("Всего")) or clean:find(u8d("Онлайн")) then
            isUpdating = false
            cadetsOnline = tempCadets
            for _, c in ipairs(cadetsOnline) do updateCadetInBase(c.rawName, nil, c.joinDate, false) end
            return false
        end
    end
end
