-- Solo Randomizer: the tower's chests, shuffled from a seed, with no server.
-- fill.lua turns a seed into a layout that is always beatable; this file applies it in the game:
-- a chest's script still runs, and the grant filter swaps what it gives.

local S, G = cleria.settings, cleria.game
local fill = require("fill")

local next_seed = S.get("Seed", "")           -- the seed of the next new game; empty = a random one
local CHARS = {"yunica", "hugo", "toal"}

local data_cache = {}
local function data_for(char)
    if not data_cache[char] then data_cache[char] = cleria.json.decode(cleria.read("data/" .. char .. ".json")) end
    return data_cache[char]
end

-- The layout of this save: chest key ("S_1001/S_BOX01") -> {old = vanilla item id, new = item id, name =}.
local layout, seed, pending = nil, nil, nil

local function to_layout(data, placed)
    local t = {}
    for i, it in pairs(placed) do
        local l = data.locs[i]
        t[l.chest] = {old = l.id, new = it.id}
    end
    return t
end

-- One try per tick (a try is a few million VM instructions; a dead end is rare).
local function step()
    if not pending then return end
    local p = pending
    p.attempt = p.attempt + 1
    local placed = fill.try(p.data, p.seed, p.attempt)
    if not placed and p.attempt < 200 then return end
    pending = nil
    if not placed then
        cleria.notice("No layout found for this seed: the chests keep their own items.", "Solo Randomizer")
        cleria.log("seed " .. p.seed .. ": no layout in 200 tries")
        return
    end
    layout, seed = to_layout(p.data, placed), p.seed
    if cleria.save.ready() then
        cleria.save.set("seed", seed)
        cleria.save.set("layout", layout)
    end
    local n = 0
    for _ in pairs(layout) do n = n + 1 end
    cleria.notice("Seed " .. seed .. ": " .. n .. " chests shuffled.", "Solo Randomizer")
    cleria.log("seed " .. seed .. ": " .. n .. " chests shuffled for " .. p.data.character .. " (try " .. p.attempt .. ")")
    if p.done then p.done(placed) end
end
cleria.events.on("tick", step)

cleria.events.on("new_game", function()
    layout, seed = nil, nil
    local s = next_seed ~= "" and next_seed or tostring(math.random(100000, 999999))
    pending = {data = data_for(CHARS[G.character()] or "hugo"), seed = s, attempt = 0}
end)
cleria.events.on("load", function()
    pending = nil
    seed, layout = cleria.save.get("seed"), cleria.save.get("layout")
    if type(layout) ~= "table" then layout, seed = nil, nil end
end)

-- ---- in the game: the chest's own script runs, the filter swaps the item ----------------------------------------
cleria.content.add_filter(function(q)
    if not layout or q.script == "" then return nil end
    local c = layout[q.room .. "/" .. q.script:upper()]
    if not c or c.new == c.old or q.index ~= c.old then return nil end
    if q.kind == "store" then
        if q.value <= math.max(q.old, 0) then return nil end
        cleria.content.give(c.new, 1, "solorando")
        cleria.log(string.format("%s/%s: %s instead of %s", q.room, q.script:upper(), G.item_name(c.new), G.item_name(c.old)))
        return "suppress"
    end
    if q.kind == "icon" then return {action = "replace", index = c.new} end
    if q.kind == "window" then
        return {action = "replace", index = c.new, text = cleria.content.treasure_text(q.text, G.item_name(c.new), 1)}
    end
end)

-- ---- the spoiler and the page -----------------------------------------------------------------------------------
local function spoiler()
    if not layout then return nil end
    local data = data_for(CHARS[G.character()] or "hugo")
    local lines = {"Solo Randomizer - seed " .. tostring(seed) .. " - " .. data.character, ""}
    for _, l in ipairs(data.locs) do
        local c = l.chest and layout[l.chest]
        if c then lines[#lines + 1] = string.format("%-44s %s", l.name, G.item_name(c.new)) end
    end
    return table.concat(lines, "\n") .. "\n"
end

cleria.ui.page("Solo Randomizer", function(p)
    p:section("This game")
    if layout then
        local n = 0
        for _ in pairs(layout) do n = n + 1 end
        p:info("Seed", tostring(seed), n .. " chests shuffled. Give this seed to someone to play the same layout.")
        if p:button("Write the spoiler", "Every shuffled chest and what it holds, as a text file in the mod's data folder.") then
            cleria.data.write("spoiler_" .. tostring(seed) .. ".txt", spoiler())
            cleria.notice("Written to modsdata/4rtefakt.solorando/spoiler_" .. tostring(seed) .. ".txt", "Solo Randomizer")
        end
    elseif G.in_game() then
        p:info("Not randomized", "", "This save was started without the randomizer: its chests hold their own items.")
    else
        p:info("No game running", "", "Start a new game to shuffle the chests.")
    end
    p:section("Next new game")
    local v, ch = p:text_field("Seed", next_seed, {desc = "Any text. The same seed and character always give the same layout.", empty = "(random)"})
    if ch then next_seed = v S.set("Seed", v) end
    p:info("What is shuffled", "42 chests", "Keys, medallions, crests, armor, leggings, accessories, Panaceas and Roda Fruits. Skill gems, Cleria Ore, SP chests and what people give you stay where they are.")
end)

cleria.speedrun.modification(function() return "Solo Randomizer" .. (seed and (", seed " .. seed) or "") end)

-- ---- test commands ---------------------------------------------------------------------------------------------
-- "solo gen <character> <seed>": a layout outside any save, printed chest by chest (the tests re-check it).
-- "solo force <chest key> <item id>": make one chest of this game hold that item. "solo": this game's state.
cleria.command("solo", function(a)
    local cmd, x, y = a:match("^(%S*)%s*(%S*)%s*(%S*)")
    if cmd == "gen" then
        local data = data_for(x)
        pending = {data = data, seed = y, attempt = 0, done = function(placed)
            for i, it in pairs(placed) do cleria.log(string.format("place %s %s %d=%s", x, y, i - 1, it.name)) end
            cleria.log("gen done " .. x .. " " .. y)
        end}
    elseif cmd == "force" then
        layout = layout or {}
        local data = data_for(CHARS[G.character()] or "hugo")
        for _, l in ipairs(data.locs) do
            if l.chest == x then layout[x] = {old = l.id, new = tonumber(y)} end
        end
        cleria.log("forced " .. x .. " -> " .. G.item_name(tonumber(y)))
    elseif cmd == "item" then
        cleria.log("item " .. x .. " " .. G.item_name(tonumber(x)) .. " = " .. tostring(G.item(tonumber(x))))
    else
        local n = 0
        for _ in pairs(layout or {}) do n = n + 1 end
        cleria.log("seed " .. tostring(seed) .. " chests " .. n)
    end
end)
cleria.log("Solo Randomizer loaded")
