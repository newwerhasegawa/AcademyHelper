script_name("AcademyHelper_Stable_v0.9.4_Merged")
script_version("0.9.5")
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
local showHUD = true 
local font = nil
local selectedCadet = nil

local updateTriggered = false 

local lecturesDB = {}
local lectureKeys = {}
local stopLecture = false
local paused = false
local lectureThread = nil

local requestQueue = {}
local isRequesting = false
local requestTimestamp = 0

-- ================= [ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ] =================
function trim(s) return s and tostring(s):match("^%s*(.-)%s*$") or "" end

function urlencode(str)
    if str then
        str = string.gsub(tostring(str), "([^%w ])", function(c) return string.format("%%%02X", string.byte(c)) end)
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
    return (myid ~= -1) and sampGetPlayerNickname(myid):gsub("_", " ") or "Инструктор"
end

-- ================= [ ОБРАБОТКА ОБНОВЛЕНИЯ СКРИПТА ] =================
function checkScriptUpdate()
    if updateTriggered then return end
    -- Используем отдельный запрос вне очереди для критического обновления
    downloadUrlToFile(SCRIPT_VER_URL .. "?t=" .. os.time(), ah_dir .. "v.tmp", function(id, status)
        if status == 6 then
            local f = io.open(ah_dir .. "v.tmp", "r")
            if f then
                local remoteVer = f:read("*all")
                f:close()
                os.remove(ah_dir .. "v.tmp")
                
                local currentVer = thisScript().version
                local cleanRemoteVer = trim(remoteVer):match("[%d%.]+") 
                
                if cleanRemoteVer and cleanRemoteVer ~= currentVer then
                    updateTriggered = true
                    sampAddChatMessage(u8:decode("{0633E5}[AH] {FFFFFF}Найдена новая версия {00FF00}v." .. cleanRemoteVer .. "{FFFFFF}. Установка..."), -1)
                    
                    -- Качаем во временный файл, чтобы не было ошибки "Device busy"
                    local updatePath = thisScript().path .. ".tmp"
                    downloadUrlToFile(SCRIPT_URL .. "?t=" .. os.time(), updatePath, function(id2, status2)
                        if status2 == 6 then
                            -- После загрузки пробуем заменить файл
                            os.remove(thisScript().path) -- Удаляем старый
                            if os.rename(updatePath, thisScript().path) then
                                sampAddChatMessage(u8:decode("{0633E5}[AH] {00FF00}Обновление завершено успешно. Перезагрузка..."), -1)
                                thisScript():reload()
                            else
                                -- Если переименовать не вышло (файл всё еще занят), попробуем просто перезагрузиться
                                sampAddChatMessage(u8:decode("{0633E5}[AH] {FF0000}Ошибка замены файла. Попробуйте вручную."), -1)
                            end
                        end
                    end)
                end
            end
        end
    end)
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
    local prefix = nextReq.url:find("google") and "gas" or "req"
    local tempPath = string.format("%stmp_%s.json", ah_dir, prefix)
    
    if doesFileExist(tempPath) then os.remove(tempPath) end
    
    downloadUrlToFile(nextReq.url, tempPath, function(id, status)
        if status == 6 then 
            local f = io.open(tempPath, "r")
            if f then
                local content = f:read("*all")
                f:close()
                os.remove(tempPath)
                lua_thread.create(function() if nextReq.callback then nextReq.callback(content) end end)
            end
        end
        isRequesting = false
    end)
end

function queueHttpRequest(url, callback)
    table.insert(requestQueue, {url = url, callback = callback})
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
    queueHttpRequest(url, function() if shouldSyncAfter then syncAll() end end)
end

function syncAll()
    if isUpdating then return end
    lastSyncTimer = os.clock() 
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
    
    lua_thread.create(function()
        wait(2000)
        checkScriptUpdate() -- Запуск проверки обновления
        wait(3000)
        syncAll()
    end)

    sampRegisterChatCommand("ah", function()
        if #cadetsOnline == 0 then syncAll(); return end
        local s = ""
        for i, v in ipairs(cadetsOnline) do s = s .. v.displayName .. " [" .. v.id .. "]\n" end
        sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Выбор", "Закрыть", 2)
    end)
    
    sampRegisterChatCommand("updc", syncAll)

    while true do
        wait(0)
        processQueue()
        
        -- Авто-синхронизация раз в 90 сек
        if os.clock() - lastSyncTimer >= 90.0 then
            if not sampIsChatInputActive() and not sampIsDialogActive() and not isUpdating then
                syncAll()
            end
        end
        
        -- Отрисовка HUD
        if showHUD and not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then
            local count = #cadetsOnline
            local boxHeight = count > 0 and (40 + (count * 16)) or 56
            renderDrawBox(20, 320, 240, boxHeight, 0x95000000) 
            renderFontDrawText(font, "Кадеты Онлайн", 28, 325, 0xFF4682B4)
            if count > 0 then
                for i, v in ipairs(cadetsOnline) do
                    local db = cadetsDB[trim(v.rawName)]
                    local textBase = string.format("%d. %s [%s] ", i, v.displayName, v.id)
                    renderFontDrawText(font, textBase, 28, 342 + (i * 16), 0xFFFFFFFF)
                end
            end
        end
    end
end

-- ================= [ СОБЫТИЯ ] =================
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
            return false
        end
    end
end
