script_name("AcademyHelper_Stable")
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
local settingsFile = ah_dir .. "settings.json"
local localLecturesJson = ah_dir .. "lectures.json"
local localLecturesVer = ah_dir .. "lectures_version.txt"

local SCRIPT_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/refs/heads/main/version.txt"
local SCRIPT_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/refs/heads/main/AcademyHelper.lua"
local LECTURES_JSON_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/lectures.json"
local LECTURES_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/AcademyHelper/main/lectures_version.txt"

-- ================= [ ПЕРЕМЕННЫЕ ] =================
local cadetsOnline = {}
local tempCadets = {}
local cadetsDB = {}
local isUpdating = false
local isShuttingDown = false
local updateTriggered = false -- Защита от спама обновлений
local lastSyncTimer = os.clock()

local config = { showHUD = true }
local font = nil
local selectedCadet = nil
local lecturesDB = {}
local lectureKeys = {}
local requestQueue = {}
local isRequesting = false
local requestTimestamp = 0

-- ================= [ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ] =================
function trim(s) 
    local str = tostring(s or "")
    return str:match("^%s*(.-)%s*$") or "" 
end

function urlencode(str)
    if str then
        str = string.gsub(tostring(str), "([^%w ])", function(c) return string.format("%%%02X", string.byte(c)) end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

function isMarked(val)
    if val == nil or val == "" then return false end
    local s = tostring(val):lower()
    return s == "true" or s == "1"
end

function hasTwoDaysPassed(dateStr)
    if not dateStr or dateStr == "" then return false end
    local d, m, y = tostring(dateStr):match("(%d+)%.(%d+)%.(%d+)")
    if not d or not m or not y then return false end 
    local status, t = pcall(os.time, {day=tonumber(d), month=tonumber(m), year=tonumber(y), hour=0, min=0, sec=0})
    return status and (os.time() - t >= 172800) or false
end

function GetNick()
    local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if myid ~= -1 then return sampGetPlayerNickname(myid):gsub("_", " ") end
    return u8:decode("Инструктор")
end

-- ================= [ СЕТЬ ] =================
function processQueue()
    if isRequesting then
        if os.clock() - requestTimestamp > 10 then isRequesting = false else return end
    end
    if #requestQueue == 0 or isShuttingDown then return end
    
    isRequesting = true
    requestTimestamp = os.clock()
    local nextReq = table.remove(requestQueue, 1)
    local tempPath = string.format("%stmp_req_%d.json", ah_dir, os.time())
    
    downloadUrlToFile(nextReq.url, tempPath, function(id, status)
        if status == 6 then 
            local f = io.open(tempPath, "r")
            if f then
                local content = f:read("*all")
                f:close()
                os.remove(tempPath) -- Удаляем сразу
                if not isShuttingDown and nextReq.callback then
                    lua_thread.create(function() nextReq.callback(content) end)
                end
            end
            isRequesting = false
        elseif status == 58 or status == -1 then 
            os.remove(tempPath)
            isRequesting = false 
        end
    end)
end

function queueHttpRequest(url, callback)
    if not isShuttingDown then table.insert(requestQueue, {url = url, callback = callback}) end
end

-- ================= [ ОБНОВЛЕНИЯ ] =================
function checkScriptUpdate()
    if updateTriggered then return end
    queueHttpRequest(SCRIPT_VER_URL .. "?t=" .. os.time(), function(remoteVer)
        local currentVer = thisScript().version
        remoteVer = trim(remoteVer):match("[%d%.]+") 
        if remoteVer and remoteVer ~= currentVer and not updateTriggered then
            updateTriggered = true
            sampAddChatMessage(u8:decode("{0633E5}[AH] {FFFFFF}Найдена версия {00FF00}v" .. remoteVer .. "{FFFFFF}. Обновляюсь..."), -1)
            isShuttingDown = true
            
            -- Скачиваем сразу в файл скрипта
            downloadUrlToFile(SCRIPT_URL .. "?t=" .. os.time(), thisScript().path, function(id, status)
                if status == 6 then
                    sampAddChatMessage(u8:decode("{0633E5}[AH] {00FF00}Обновление завершено. Перезагрузка..."), -1)
                    thisScript():reload()
                end
            end)
        end
    end)
end

function updateLectures()
    local localVer = 0
    if doesFileExist(localLecturesVer) then
        local f = io.open(localLecturesVer, "r")
        if f then localVer = tonumber(f:read("*all"):match("%d+")) or 0; f:close() end
    end
    queueHttpRequest(LECTURES_VER_URL .. "?t=" .. os.time(), function(content)
        local gitVer = tonumber(content:match("%d+")) or 0
        if gitVer > localVer then
            queueHttpRequest(LECTURES_JSON_URL .. "?t=" .. os.time(), function(jsonContent)
                local f = io.open(localLecturesJson, "w"); if f then f:write(jsonContent); f:close() end
                local fv = io.open(localLecturesVer, "w"); if fv then fv:write(tostring(gitVer)); fv:close() end
                loadLectures()
                sampAddChatMessage(u8:decode("{0633E5}[AH] {00FF00}Лекции обновлены!"), -1)
            end)
        else loadLectures() end
    end)
end

function loadLectures()
    if not doesFileExist(localLecturesJson) then return end
    local f = io.open(localLecturesJson, "r")
    if f then
        local content = f:read("*all"); f:close()
        local res, data = pcall(decodeJson, content)
        if res and type(data) == "table" then
            lecturesDB = data
            lectureKeys = {}
            for k, _ in pairs(lecturesDB) do table.insert(lectureKeys, k) end
            table.sort(lectureKeys)
        end
    end
end

-- ================= [ БАЗА ] =================
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
    queueHttpRequest(url, function() if shouldSyncAfter then syncAll() end end)
end

function syncAll()
    if isUpdating or isShuttingDown then return end
    lastSyncTimer = os.clock() 
    sampAddChatMessage(u8:decode("{0633E5}[AH] {FFFFFF}Синхронизация..."), -1)
    updateFromBase()
    lua_thread.create(function()
        wait(200)
        tempCadets = {}
        isUpdating = true
        sampSendChat("/members")
        local t = os.clock()
        while isUpdating and os.clock() - t < 5.0 do wait(100) end
        isUpdating = false
    end)
end

-- ================= [ MAIN ] =================
function main()
    if not doesDirectoryExist(ah_dir) then 
        createDirectory(getWorkingDirectory() .. "\\config")
        createDirectory(ah_dir) 
    end
    
    if doesFileExist(settingsFile) then
        local f = io.open(settingsFile, "r")
        if f then 
            local res, data = pcall(decodeJson, f:read("*all"))
            if res then config = data end
            f:close() 
        end
    end

    while not isSampAvailable() do wait(100) end
    font = renderCreateFont("Arial", 9, 5)
    loadLectures()
    
    lua_thread.create(function()
        wait(3000)
        checkScriptUpdate() 
        if not isShuttingDown then
            updateLectures()
            wait(1000)
            syncAll()
        end
    end)

    sampRegisterChatCommand("ah", function()
        if isShuttingDown then return end
        local s = config.showHUD and u8:decode("{FF0000}[ Выключить HUD ]\n") or u8:decode("{00FF00}[ Включить HUD ]\n")
        for i, v in ipairs(cadetsOnline) do s = s .. v.displayName .. " [" .. v.id .. "]\n" end
        sampShowDialog(9910, "{0633E5}AcademyHelper", s, u8:decode("Выбор"), u8:decode("Закрыть"), 2)
    end)

    sampRegisterChatCommand("updc", syncAll)

    while true do
        wait(0)
        if not isShuttingDown then
            processQueue()
            if os.clock() - lastSyncTimer >= 180.0 then syncAll() end

            if isKeyDown(vkeys.VK_CONTROL) and wasKeyPressed(vkeys.VK_R) then
                if not sampIsChatInputActive() and not sampIsDialogActive() then syncAll() end
            end
            
            if config.showHUD and not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
                local count = #cadetsOnline
                local bh = count > 0 and (40 + (count * 16)) or 56
                renderDrawBox(20, 320, 240, bh, 0x95000000) 
                renderFontDrawText(font, u8:decode("Кадеты Онлайн"), 28, 325, 0xFF4682B4)
                if count > 0 then
                    for i, v in ipairs(cadetsOnline) do
                        local l, t, p, d2 = false, false, false, false
                        local db = cadetsDB[trim(v.rawName)]
                        if db then
                            l, t, p = isMarked(db.lecture), isMarked(db.theory), isMarked(db.practice)
                            d2 = hasTwoDaysPassed(db.date) or isMarked(db.isTwoDays)
                        end
                        local bx, by = 28, 342 + (i * 16)
                        local textBase = string.format("%d. %s [%s] ", i, v.displayName, v.id)
                        renderFontDrawText(font, textBase, bx, by, 0xFFFFFFFF)
                        local off = renderGetFontDrawTextLength(font, textBase)
                        local tags = { {n="[Л]", v=l}, {n="[Т]", v=t}, {n="[П]", v=p}, {n="[Д]", v=d2} }
                        for _, tag in ipairs(tags) do
                            renderFontDrawText(font, tag.n, bx + off, by, tag.v and 0xFF00FF00 or 0xFFFF4D4D)
                            off = off + renderGetFontDrawTextLength(font, tag.n)
                        end
                    end
                else renderFontDrawText(font, "—", 28, 345, 0xFFFFFFFF) end
            end
        end
    end
end

function sampev.onSendDialogResponse(id, btn, lst, inp)
    if isShuttingDown then return end
    if id == 9910 and btn == 1 then
        if lst == 0 then 
            config.showHUD = not config.showHUD
            local f = io.open(settingsFile, "w"); if f then f:write(encodeJson(config)); f:close() end
            sampProcessChatInput("/ah")
        else
            selectedCadet = cadetsOnline[lst]
            if selectedCadet then
                lua_thread.create(function()
                    wait(10)
                    sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, u8:decode("Лекция\nТеория\nПрактика\n{A020F0}Информация\n{FF0000}Сброс прогресса"), "ОК", u8:decode("Назад"), 2)
                end)
            end
        end
        return false
    elseif id == 9911 and btn == 1 then
        if lst == 3 then 
            local db = cadetsDB[trim(selectedCadet.rawName)]
            local l = (db and isMarked(db.lecture)) and "{00FF00}"..u8:decode("прошел") or "{FF0000}"..u8:decode("не прошел")
            local t = (db and isMarked(db.theory)) and "{00FF00}"..u8:decode("прошел") or "{FF0000}"..u8:decode("не прошел")
            local p = (db and isMarked(db.practice)) and "{00FF00}"..u8:decode("прошел") or "{FF0000}"..u8:decode("не прошел")
            local d = (db and (hasTwoDaysPassed(db.date) or isMarked(db.isTwoDays))) and "{00FF00}"..u8:decode("прошло") or "{FF0000}"..u8:decode("не прошло")
            local info = string.format(u8:decode("Лекция: %s\n{FFFFFF}Теория: %s\n{FFFFFF}Практика: %s\n{FFFFFF}Два дня: %s"), l, t, p, d)
            lua_thread.create(function() wait(10); sampShowDialog(9912, u8:decode("Инфо: ") .. selectedCadet.displayName, info, u8:decode("Назад"), "", 0) end)
        elseif lst == 4 then updateCadetInBase(selectedCadet.rawName, "reset", nil, true)
        else updateCadetInBase(selectedCadet.rawName, ({"lecture", "theory", "practice"})[lst + 1], nil, true) end
        return false
    elseif id == 9912 then
        sampProcessChatInput("/ah")
        return false
    end
end

function sampev.onServerMessage(clr, txt)
    if isUpdating then
        local clean = txt:gsub("{%x+}", "")
        if clean:find("ID:") and (clean:find("Кадет") or clean:find("Cadet")) then
            local id, dm, nick = clean:match("ID:%s*(%d+)%s*|%s*%d+:%d+%s*([%d%.]+)%s*|%s*([%a%d_]+)")
            if nick and id then table.insert(tempCadets, {rawName = nick, displayName = nick:gsub("_", " "), id = id, joinDate = dm}) end
        end
        if clean:find("Всего%:") or clean:find("Всего в сети") or clean:find("Онлайн организации") then
            isUpdating = false
            cadetsOnline = tempCadets
            lua_thread.create(function()
                for _, c in ipairs(cadetsOnline) do updateCadetInBase(c.rawName, nil, c.joinDate, false); wait(50) end
                sampAddChatMessage(u8:decode("{0633E5}[AH] {00FF00}Список обновлен."), -1)
            end)
        end
        return false 
    end
end
