-- PD2 Music System for PAYDAY 3 - v1.0.1 (Lua part). Picks the song (lobby button) and the phase (heist state);
-- the native part in dlls/main.dll plays it (JB_Play / JB_Volume).
-- Menus are left alone: nothing plays outside heists, and nothing plays if no song is picked.
local MOD_DIR = debug.getinfo(1, "S").source:match("@?(.*)[/\\]Scripts[/\\]main%.lua$") or "."
local LOG = MOD_DIR .. "\\jukebox_log.txt"
local nLog = 0
local function log(fmt, ...)   -- capped so a long session can't grow the file without limit
    if nLog > 300 then return end
    nLog = nLog + 1
    local ok, s = pcall(string.format, fmt, ...)
    if nLog > 300 then ok, s = true, "log limit reached - nothing more is written this session" end
    local f = io.open(LOG, "a"); if f then f:write(os.date("%H:%M:%S "), ok and s or tostring(fmt), "\n"); f:close() end
end
do local f = io.open(LOG, "w"); if f then f:close() end end
log("PD2 Music System 1.0.1 starting")
if not JB_Play then log("ERROR: native part missing (dlls/main.dll not loaded)"); return end

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

------------------------------------------------------------------ config (config.txt, key=value)
local CFG = { button_x = -40, button_y = 175, list_x = -420, list_y = 175, list_width = 360, list_height = 430, button_size = 20, list_text_size = 17, transition_ms = 2000, volume_curve = 2, volume_db = 0 }
do
    local f = io.open(MOD_DIR .. "\\config.txt", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(-?[%d%.]+)")
            if k and CFG[k] ~= nil then CFG[k] = tonumber(v) end
        end
        f:close()
        local f2 = io.open(MOD_DIR .. "\\config.txt", "r"); local txt = f2 and f2:read("*a") or ""; if f2 then f2:close() end
        local NOTE = {
            transition_ms = "how long the old phase rings out under the new one (PAYDAY 2 uses 2000). 0 = hard cut.",
            volume_curve = "how the volume sliders map to loudness: 1 = straight (loud), 2 = like most games (default), 3 = quieter at low settings",
            volume_db = "overall music volume trim in dB on top of your sliders (e.g. -6 = half as loud, 3 = louder)",
        }
        local fa = nil
        for _, k in ipairs({ "transition_ms", "volume_curve", "volume_db" }) do
            if not txt:find(k, 1, true) then
                fa = fa or io.open(MOD_DIR .. "\\config.txt", "a")
                if fa then fa:write("\n# ", NOTE[k], "\n", k, "=", CFG[k], "\n") end
            end
        end
        if fa then fa:close() end
    else
        f = io.open(MOD_DIR .. "\\config.txt", "w")
        if f then
            f:write("# Jukebox layout (pixels at 1080p, measured from the top-right corner of the screen). Restart the game after editing.\n")
            for _, k in ipairs({ "button_x", "button_y", "list_x", "list_y", "list_width", "list_height", "button_size", "list_text_size", "transition_ms", "volume_curve", "volume_db" }) do f:write(k, "=", CFG[k], "\n") end
            f:write("# transition_ms: how long the old phase rings out under the new one (PAYDAY 2 uses 2000). 0 = hard cut.\n")
            f:write("# volume_curve: how the volume sliders map to loudness: 1 = straight (loud), 2 = like most games, 3 = quieter at low settings\n")
            f:write("# volume_db: overall music volume trim in dB on top of your sliders (e.g. -6 = half as loud, 3 = louder)\n")
            f:close()
        end
    end
end

------------------------------------------------------------------ songs
local MUSIC = MOD_DIR .. "\\music\\"
local songs, byId = {}, {}
do
    local f = io.open(MUSIC .. "jukebox_index.txt", "r")
    if not f then log("ERROR: music\\jukebox_index.txt missing - no music installed (see README)") else
        for line in f:lines() do
            local id, name, phase, file, ls, le = line:match("^([^\t]+)\t([^\t]*)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)")
            if id then
                local s = byId[id]
                if not s then s = { id = id, name = name, phases = {} }; byId[id] = s; songs[#songs + 1] = s end
                s.phases[phase] = s.phases[phase] or {}
                table.insert(s.phases[phase], { file = MUSIC .. file, ls = ls, le = le, fname = file })
            end
        end
        f:close()
    end
end
table.sort(songs, function(a, b) return a.name:lower() < b.name:lower() end)
log("%d songs loaded", #songs)
-- per-song loudness trim (music\loudness.txt: id <TAB> dB). Evens out tracks that were mastered louder than the rest.
local trim = {}
do
    local f = io.open(MUSIC .. "loudness.txt", "r")
    if f then
        local n = 0
        for line in f:lines() do
            local id, db = line:match("^([^\t#]+)\t(-?[%d%.]+)")
            if id and tonumber(db) then trim[id] = tonumber(db); n = n + 1 end
        end
        f:close()
        log("loudness trims: %d songs", n)
    end
end
if JB_Transition then pcall(JB_Transition, CFG.transition_ms) else log("note: old native part (no transitions/preload) - update dlls\\main.dll") end

local SEL = MOD_DIR .. "\\selected.txt"
local selected = nil
do local f = io.open(SEL, "r"); if f then local id = f:read("*l"); f:close(); selected = byId[id or ""] end end
-- read the chosen song's files into memory in the background, so phase changes never touch the disk
local function preload(s)
    if not JB_Preload then return end
    local list = {}
    if s then for _, files in pairs(s.phases) do for _, e in ipairs(files) do list[#list + 1] = e.file end end end
    pcall(JB_Preload, table.concat(list, "\n"))
end
local volT = 99
local function select_song(s)
    selected = s
    volT = 99
    preload(s)
    local f = io.open(SEL, "w"); if f then f:write(s and s.id or "off"); f:close() end
    log("selected: %s", s and (s.id .. " " .. s.name) or "off")
end
preload(selected)   -- the saved song is ready before the first heist

------------------------------------------------------------------ phase rules
-- EPD3HeistState: 0 Stealth 1 Search 2 Alarm 3 FirstResponse 4 Negotiation 5 Anticipation 6 Assault 7 Control 8 PointOfNoReturn
local PHASE = { [0] = "setup", [1] = "setup", [2] = "control", [3] = "control", [4] = "control",
    [5] = "anticipation", [6] = "assault", [7] = "control", [8] = "final" }

local function files_for(song, phase)
    if phase == "final" then
        local a = song.phases.assault or {}
        if song.id == "track_50" then   -- Break the Rules: v2 only on the final assault
            for _, e in ipairs(a) do if e.fname:find("assault_v2") then return { e } end end
        end
        return a
    end
    local list = song.phases[phase] or song.phases.control or {}
    if song.id == "track_50" and phase == "assault" then   -- regular assaults: v1 only
        for _, e in ipairs(list) do if e.fname:find("assault_v1") then return { e } end end
    end
    return list
end

------------------------------------------------------------------ game state
local gs, settings = nil, nil
-- the game's live settings object (the one the options menu changes). FindFirstOf can return the class default
-- copy instead, which never sees your slider changes, so ask the engine for the real one.
local settingsLogged = false
local function find_settings()
    if valid(settings) then return settings end
    local s = nil
    local cdo = StaticFindObject("/Script/Engine.Default__GameUserSettings")
    if valid(cdo) then
        local ok, r = pcall(function() return cdo:GetGameUserSettings() end)
        if ok and valid(r) then s = r end
    end
    if not s then
        local ok, list = pcall(FindAllOf, "SBZGameUserSettings")
        if ok and list then
            for _, o in ipairs(list) do
                local okn, n = pcall(function() return o:GetFName():ToString() end)
                if okn and n and not n:find("^Default__") then s = o break end
            end
        end
    end
    settings = s
    if s and not settingsLogged then
        settingsLogged = true
        local okf, fn = pcall(function() return s:GetFullName() end)
        log("volume settings object: %s", okf and tostring(fn) or "?")
    end
    return s
end
local realMusic = nil   -- the player's real Music volume while we hold the game's at 0
NotifyOnNewObject("/Script/Starbreeze.PD3HeistGameState", function(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    if ok and n and n:find("^Default__") then return end
    gs = o
end)
local function heist_state()
    if not valid(gs) then gs = nil; return nil end
    local ok, st = pcall(function() return gs.CurrentHeistState end)
    return ok and tonumber(st) or nil
end
local BACKUP = MOD_DIR .. "\\music_volume_backup.txt"
local muted = false
local lastGain = nil
local function volume()
    if not find_settings() then return 0.1 end
    local ok1, m = pcall(function() return settings.MasterVolume end)
    local ok2, mu = pcall(function() return settings.MusicVolume end)
    if muted and ok2 and type(mu) == "number" and mu > 0.5 then
        -- the player moved the Music slider during the heist: that's their new level. Keep it, and keep PD3's own music silent.
        realMusic = mu
        local f = io.open(BACKUP, "w"); if f then f:write(tostring(realMusic)); f:close() end
        pcall(function() settings:SetMusicVolume(0) end)
        log("Music slider changed in heist: now %.1f", mu)
    end
    if realMusic then ok2, mu = true, realMusic end
    if not ok1 or not ok2 or type(m) ~= "number" or type(mu) ~= "number" then return 0.1 end
    local base = math.max(0, math.min(1, (m / 100) * (mu / 100)))
    local db = CFG.volume_db + ((selected and trim[selected.id]) or 0)
    local g = (base ^ math.max(0.5, CFG.volume_curve)) * 10 ^ (db / 20)
    if not lastGain or math.abs(g - lastGain) > 0.01 then
        lastGain = g
        log("volume: master %.0f, music %.0f, song trim %.1f dB -> player gain %.3f", m, mu, db, g)
    end
    return g
end

------------------------------------------------------------------ PD3 music mute (heists only)
-- PD3 has no separate music control we can reach, so during a heist the game's own Music setting is set to 0
-- and put back afterwards. The real value is kept in music_volume_backup.txt so it survives a crash.
local function settings_obj()
    return find_settings()
end
do  -- crash recovery: a backup left behind means the game closed mid-heist
    local f = io.open(BACKUP, "r")
    if f then local v = tonumber(f:read("*l") or ""); f:close(); if v then realMusic = v; log("found music volume backup %.1f (restoring)", v) end end
end
local function restore_music()
    local s = settings_obj()
    if s and realMusic then
        pcall(function() s:SetMusicVolume(realMusic) end)
        log("PD3 music restored to %.1f", realMusic)
        realMusic = nil; os.remove(BACKUP)
    end
end
local function mute_pd3_music(on)
    local s = settings_obj(); if not s then return end
    if on and not muted then
        if realMusic == nil then
            local ok, v = pcall(function() return s.MusicVolume end)
            realMusic = (ok and type(v) == "number") and v or 50
            local f = io.open(BACKUP, "w"); if f then f:write(tostring(realMusic)); f:close() end
        end
        pcall(function() s:SetMusicVolume(0) end)
        muted = true; log("PD3 music muted (real volume %.1f kept)", realMusic)
    elseif not on and muted then
        muted = false; restore_music()
    elseif not on and not muted and realMusic then
        restore_music()   -- leftover from a crash
    end
end

------------------------------------------------------------------ playback driver
local curKey = nil
local lastState = "none"
local STATE_NAME = { [0] = "Stealth", [1] = "Search", [2] = "Alarm", [3] = "FirstResponse", [4] = "Negotiation",
    [5] = "Anticipation", [6] = "Assault", [7] = "Control", [8] = "PointOfNoReturn" }
local function update(dt)
    volT = volT + dt
    if volT >= 1 then volT = 0; pcall(JB_Volume, volume()) end   -- slider changes picked up within a second
    local st = heist_state()
    if tostring(st) ~= lastState then
        log("heist state %s -> %s (%s)", lastState, tostring(st), st and (STATE_NAME[st] or "unknown") or "no heist")
        lastState = tostring(st)
    end
    local key, files = "off", nil
    if st ~= nil and selected then
        local phase = PHASE[st] or "control"
        files = files_for(selected, phase)
        key = selected.id .. "/" .. phase
    end
    if key ~= curKey then
        curKey = key
        if files and #files > 0 then
            local spec = {}
            for _, e in ipairs(files) do spec[#spec + 1] = string.format("%s|%s|%s", e.file, e.ls, e.le) end
            local err = JB_Play(table.concat(spec, "\n"))
            log("play %s (state %s, %d file(s)) %s", key, tostring(st), #files, err ~= "" and ("ERROR " .. err) or "ok")
        else
            JB_Play("")
            log("stop (%s)", key)
        end
    end
    mute_pd3_music(st ~= nil and selected ~= nil and key ~= "off")
end

------------------------------------------------------------------ lobby UI
-- 0.6: the button is built INSIDE the lobby screen's own widget tree, so it is created, hidden and destroyed together
-- with the lobby. (0.5 kept its own viewport widget across map loads and touched it after the game had torn it down,
-- which crashed the game when coming back to the lobby after a heist.) Nothing here is touched unless its owner
-- (the lobby widget) is still valid.
local UI = { gen = 0, open = false, wasPressed = {}, buttons = {}, seen = 0 }
local FONT = nil
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function new(cls, outer, name)
    UI.gen = UI.gen + 1
    local c = StaticFindObject("/Script/UMG." .. cls)
    return StaticConstructObject(c, outer, FName(string.format("PD2JB_%s_%d", name, UI.gen)))
end
local function label(outer, str, size)
    local t = new("TextBlock", outer, "T")
    FONT = (FONT and valid(FONT)) and FONT or StaticFindObject("/Game/UI/Assets/Fonts/Din_Pro/DINPro-CondMedium_Font.DINPro-CondMedium_Font")
    pcall(function() if valid(FONT) then t.Font.FontObject = FONT end; t.Font.Size = size or 18 end)
    pcall(function() t:SetText(FText(str)) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = { R = 0.95, G = 0.93, B = 0.88, A = 1 }, ColorUseRule = 0 }) end)
    return t
end
local function button(outer, str, size, onclick)
    local b = new("Button", outer, "B")
    pcall(function()
        local st = b.WidgetStyle
        st.Normal.TintColor.SpecifiedColor = { R = 0.05, G = 0.05, B = 0.06, A = 0.85 }
        st.Hovered.TintColor.SpecifiedColor = { R = 0.35, G = 0.25, B = 0.05, A = 0.95 }
        st.Pressed.TintColor.SpecifiedColor = { R = 0.55, G = 0.40, B = 0.08, A = 1 }
    end)
    local t = label(b, str, size)
    pcall(function() b:SetContent(t) end)
    UI.buttons[#UI.buttons + 1] = { w = b, fn = onclick, t = t }
    return b, t
end
local function button_text()
    if #songs == 0 then return "\226\153\170 JUKEBOX: no music installed" end
    return "\226\153\170 JUKEBOX: " .. (selected and selected.name or "OFF")
end

function UI.refresh()
    if not UI.built or not valid(UI.owner) then return end
    if valid(UI.mainText) then pcall(function() UI.mainText:SetText(FText(button_text())) end) end
    if valid(UI.frame) then pcall(function() UI.frame:SetVisibility(UI.open and 0 or 1) end) end
end

-- forget our widgets; remove them first only if they (and their owner) are still alive
local function ui_drop(remove)
    if remove and valid(UI.owner) and valid(UI.root) then pcall(function() UI.root:RemoveFromParent() end) end
    UI.buttons, UI.wasPressed = {}, {}
    UI.root, UI.owner, UI.ownerAddr, UI.frame, UI.mainText, UI.mode = nil, nil, nil, nil, nil, nil
    UI.built, UI.open, UI.shown = false, false, false
end

local function build_ui(owner)
    local okT, tree = pcall(function() return owner.WidgetTree end)
    if not okT or not valid(tree) then return false, "no widget tree" end
    local okR, root = pcall(function() return tree.RootWidget end)
    local isCanvas = false
    if okR and valid(root) then
        local okC, cn = pcall(function() return root:GetClass():GetFName():ToString() end)
        isCanvas = okC and cn == "CanvasPanel"
    end
    UI.buttons, UI.wasPressed = {}, {}
    local canvas
    if isCanvas then
        -- our own full-screen canvas, added as a child of the lobby screen's root canvas
        canvas = new("CanvasPanel", tree, "Canvas")
        local slot = root:AddChildToCanvas(canvas)
        if not valid(slot) then return false, "AddChildToCanvas failed" end
        pcall(function()
            slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
            slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            slot:SetZOrder(1000)
        end)
        UI.mode, UI.root = "embedded", canvas
    else
        -- fallback: a small viewport layer owned by the lobby widget, removed whenever the lobby is not showing
        local hud = new("UserWidget", owner, "Layer")
        local t2 = new("WidgetTree", hud, "Tree")
        hud.WidgetTree = t2
        canvas = new("CanvasPanel", t2, "Canvas")
        t2.RootWidget = canvas
        hud:AddToViewport(450)
        pcall(function() hud:SetVisibility(4) end)
        UI.mode, UI.root = "viewport", hud
    end
    pcall(function() canvas:SetVisibility(4) end)   -- SelfHitTestInvisible: only the buttons take clicks
    -- main button
    local mb, mt = button(canvas, button_text(), CFG.button_size, function() UI.open = not UI.open; UI.refresh() end)
    UI.mainText = mt
    local s = canvas:AddChildToCanvas(mb)
    pcall(function()
        s:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        s:SetAlignment({ X = 1, Y = 0 }); s:SetAutoSize(true); s:SetPosition({ X = CFG.button_x, Y = CFG.button_y })
    end)
    -- song list
    local frame = new("Border", canvas, "Frame")
    pcall(function() frame:SetBrushColor({ R = 0.02, G = 0.02, B = 0.03, A = 0.92 }) end)
    local scroll = new("ScrollBox", frame, "Scroll")
    pcall(function() frame:SetContent(scroll) end)
    local function add(str, fn) local b = button(scroll, str, CFG.list_text_size, fn); pcall(function() scroll:AddChild(b) end) end
    add("OFF (normal PAYDAY 3 music)", function() select_song(nil); UI.open = false; UI.refresh() end)
    for _, sg in ipairs(songs) do
        add(sg.name, function() select_song(sg); UI.open = false; UI.refresh() end)
    end
    local fs = canvas:AddChildToCanvas(frame)
    pcall(function()
        fs:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        fs:SetAlignment({ X = 1, Y = 0 }); fs:SetPosition({ X = CFG.list_x, Y = CFG.list_y }); fs:SetSize({ X = CFG.list_width, Y = CFG.list_height })
    end)
    UI.frame = frame
    UI.owner, UI.ownerAddr = owner, addr(owner)
    UI.built = true
    UI.refresh()
    return true, UI.mode
end

-- called once a second with the visible lobby widget (or nil when the lobby isn't showing / in a heist)
local function ui_tick(lw)
    if UI.built and not valid(UI.owner) then ui_drop(false) end   -- lobby destroyed: our widgets went with it
    if not lw then
        UI.seen = 0
        if UI.built then
            if UI.mode == "viewport" then ui_drop(true)
            elseif UI.shown then UI.open = false; UI.refresh(); UI.shown = false end
        end
        return
    end
    if UI.built and UI.ownerAddr ~= addr(lw) then ui_drop(UI.mode == "viewport") end   -- a new lobby screen
    if not UI.built then
        UI.seen = UI.seen + 1
        if UI.seen < 2 then return end   -- let the lobby finish loading before adding to it
        local ok, res, info = pcall(build_ui, lw)
        if not ok or not res then
            log("UI build failed: %s", tostring(ok and info or res))
            ui_drop(true); UI.seen = -10   -- retry in ~10 s
            return
        end
        log("UI built (%d buttons, %s)", #UI.buttons, tostring(info))
    end
    UI.shown = true
end

local function ui_poll()
    if not UI.built or not UI.shown or not valid(UI.owner) then return end
    local n = UI.open and #UI.buttons or 1   -- button 1 is the main button
    for i = 1, n do
        local b = UI.buttons[i]
        if not valid(b.w) then return end
        local ok, p = pcall(function() return b.w:IsPressed() end)
        p = ok and p == true
        if UI.wasPressed[i] and not p then pcall(b.fn) end   -- fire on release
        UI.wasPressed[i] = p
    end
end

-- lobby detection: the pre-heist planning screen (native class, so no costly scans)
local lobbyWidgets = {}
NotifyOnNewObject("/Script/Starbreeze.SBZMainMenuPrePlanningWidget", function(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    if ok and n and not n:find("Default__") then lobbyWidgets[#lobbyWidgets + 1] = o; log("lobby widget created: %s", n) end
end)
local forceShow = false
local function lobby_widget()
    for i = #lobbyWidgets, 1, -1 do
        local w = lobbyWidgets[i]
        if not valid(w) then table.remove(lobbyWidgets, i)
        else
            local ok, v = pcall(function() return w:IsVisible() end)
            if (ok and v == true) or forceShow then return w end
        end
    end
    return nil
end
pcall(RegisterKeyBind, Key.F8, function() forceShow = not forceShow; log("F8: force show button = %s", tostring(forceShow)) end)

------------------------------------------------------------------ loops
local t, lobbyCheck, lobby = 0, 0, false
LoopInGameThreadWithDelay(500, function()
    t = t + 0.5
    local ok, e = pcall(update, 0.5)
    if not ok then log("update error: %s", tostring(e)) end
    if t - lobbyCheck >= 1 then
        lobbyCheck = t
        local okL, l = pcall(lobby_widget); lobby = okL and l or nil
        local inHeist = heist_state() ~= nil
        local okU, eu = pcall(ui_tick, (not inHeist) and lobby or nil)
        if not okU then log("ui error: %s", tostring(eu)) end
    end
end)
LoopInGameThreadWithDelay(80, function() if UI.shown then pcall(ui_poll) end end)
log("ready; selected = %s", selected and selected.name or "off")
