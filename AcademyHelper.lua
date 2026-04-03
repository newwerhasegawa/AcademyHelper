script_name("AcademyHelper_Stable_v0.2")

script_version("0.2")



require 'moonloader'

local vkeys = require 'lib.vkeys'

local sampev = require 'lib.samp.events'

local requests = require 'requests'

local json = require 'json'

local encoding = require 'encoding'

encoding.default = 'CP1251'

local u8 = encoding.UTF8



-- ÒÂÎß ÑÑÛËÊÀ

local GAS_URL = "https://script.google.com/macros/s/AKfycbyPFOentE3gta4L94HL9cKm1KQ__LLZLBKpz2WTKrK1ui74FT4iyKQYhOxSziZRPD0vEw/exec"

local tempFile = getWorkingDirectory() .. "\\config\\cadets_temp.json"



local cadetsOnline = {}

local cadetsDB = {}

local isUpdating = false

local lastSync = 0

local selectedCadet = nil

local font = nil

local needSync = false -- Ôëàã äëÿ áåçîïàñíîãî îáíîâëåíèÿ



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



function updateFromBase()

    lua_thread.create(function()

        print("[AH] Ñèíõðîíèçàöèÿ ñ îáëàêîì...")

        downloadUrlToFile(GAS_URL .. "?action=read", tempFile, function(id, status, p1, p2)

            if status == 6 then 

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

                        print("[AH] Äàííûå îáíîâëåíû.")

                    end

                end

            end

        end)

    end)

end



function updateCadetInBase(name, col)

    local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)

    local myNick = sampGetPlayerNickname(myid)

    sampAddChatMessage("{0633E5}[AH] {FFFFFF}Îáíîâëÿåì " .. name:gsub("_", " ") .. "...", -1)

    

    local fullUrl = GAS_URL .. "?action=update&name=" .. urlencode(name) .. "&col=" .. urlencode(col) .. "&instructor=" .. urlencode(myNick)

    

    -- Óáðàëè yield (wait) èç êîëáýêà

    downloadUrlToFile(fullUrl, tempFile, function(id, status, p1, p2)

        if status == 6 then

            if doesFileExist(tempFile) then os.remove(tempFile) end

            print("[AH] Çàïèñü â òàáëèöó ïîäòâåðæäåíà.")

            needSync = true -- Ñòàâèì ôëàã, main îáíîâèò áàçó ñàì

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

    font = renderCreateFont("Arial", 9, 5)



    sampRegisterChatCommand("ah", function()

        if #cadetsOnline == 0 then return end

        local s = ""

        for i, v in ipairs(cadetsOnline) do s = s .. (v.displayName or "Unknown") .. " [" .. (v.id or "0") .. "]\n" end

        sampShowDialog(9910, "{0633E5}AcademyHelper", s, "Âûáîð", "Çàêðûòü", 2)

    end)

    

    sampRegisterChatCommand("updc", syncAll)

    syncAll()



    while true do

        wait(0)

        

        -- Áåçîïàñíîå îáíîâëåíèå ïîñëå çàïèñè

        if needSync then

            wait(2000) -- Ïàóçà â ãëàâíîì ïîòîêå ðàçðåøåíà

            updateFromBase()

            sampAddChatMessage("{00FF00}[AH] {FFFFFF}Äàííûå ñèíõðîíèçèðîâàíû!", -1)

            needSync = false

        end



        if not isPauseMenuActive() and not isKeyDown(vkeys.VK_F7) and font then

            local count = #cadetsOnline

            if count > 0 then

                renderDrawBox(20, 320, 220, 40 + (count * 16), 0x95000000)

                renderFontDrawText(font, "Êàäåòû Îíëàéí", 30, 325, 0xFF4682B4)

                for i, v in ipairs(cadetsOnline) do

                    local col = 0xFFFF4D4D 

                    local db = cadetsDB[trim(v.rawName)]

                    if db then

                        local l = isMarked(db.lecture)

                        local t = isMarked(db.theory)

                        local p = isMarked(db.practice)

                        if l and t and p then col = 0xFF32CD32 

                        elseif l and t then col = 0xFFFFFF00 

                        elseif l then col = 0xFF1E90FF 

                        end

                    end

                    renderFontDrawText(font, string.format("%d. %s [%s]", i, v.displayName or "Unknown", v.id or "?"), 30, 342 + (i * 16), col)

                end

            end

        end

        if os.clock() - lastSync > 180 then syncAll() end

    end

end



function sampev.onSendDialogResponse(id, btn, lst, inp)
    if id == 9910 and btn == 1 then
        selectedCadet = cadetsOnline[lst + 1]
        if selectedCadet then
            lua_thread.create(function()
                wait(50)
                -- ÄÎÁÀÂÈËÈ ÏÓÍÊÒ "Ñáðîñèòü äàííûå"
                sampShowDialog(9911, "{0633E5}" .. (selectedCadet.displayName or "Cadet"), "Ëåêöèÿ\nÒåîðèÿ\nÏðàêòèêà\n{FF6347}Ñáðîñèòü äàííûå (Reset)", "ÎÊ", "Íàçàä", 2)
            end)
        end
        return false
    end
    if id == 9911 then
        if btn == 1 and selectedCadet then
            -- Òåïåðü çäåñü 4 âàðèàíòà äåéñòâèé
            local actions = {"lecture", "theory", "practice", "reset"}
            local currentAction = actions[lst + 1]
            
            -- Åñëè âûáðàí ñáðîñ, ñðàçó âèçóàëüíî "êðàñèì" â êðàñíûé â ëîêàëüíîé áàçå äëÿ ìãíîâåííîãî ýôôåêòà
            if currentAction == "reset" and cadetsDB[selectedCadet.rawName] then
                cadetsDB[selectedCadet.rawName].lecture = 0
                cadetsDB[selectedCadet.rawName].theory = 0
                cadetsDB[selectedCadet.rawName].practice = 0
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

        local c = txt:gsub("{%x+}", "")

        if c:find("Êàäåò") or c:find("Cadet") then

            local n, id = c:match("[%a%d]+_[%a%d]+"), c:match("ID:%s*(%d+)")

            if n and id then table.insert(cadetsOnline, {rawName = trim(n), displayName = n:gsub("_", " "), id = id}) end

            return false

        end

        if c:find("×ëåíû îðãàíèçàöèè") or c:match("ID:%s*%d+") or c:find("Âñåãî%:") then

            if c:find("Âñåãî%:") then isUpdating = false end

            return false

        end

    end

end

