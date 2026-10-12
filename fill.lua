-- The seed -> layout part of the Solo Randomizer: no game calls here, only tables.
--
-- data (data/<character>.json, built from the Ys Origin apworld's logic):
--   regions   : names; index 0 is the start
--   entrances : {from, to, rule}                      (0-based region indices)
--   locs      : {name, region, rule, item, id, chest, shuffle}
--   start     : item names owned from the start; goal: the region that must be reachable
-- A rule is true, {"has", item name, count}, {"reach", region}, {"all", ...} or {"any", ...}.

local M = {}

-- A small generator of our own, so a seed gives the same layout whatever Lua's math.random does.
local function rng_of(seed)
    local h = 2166136261
    for i = 1, #seed do h = ((h ~ seed:byte(i)) * 16777619) & 0xFFFFFFFF end
    local s = h == 0 and 1 or h
    return function(n)                      -- an integer in 1..n
        s = s ~ ((s << 13) & 0xFFFFFFFF)
        s = s ~ (s >> 17)
        s = s ~ ((s << 5) & 0xFFFFFFFF)
        return s % n + 1
    end
end

local function shuffle(t, rnd)
    for i = #t, 2, -1 do
        local j = rnd(i)
        t[i], t[j] = t[j], t[i]
    end
end

-- Everything reachable from the start: `placed[i]` is the item name at location i (or nil), `have` the items
-- owned before taking anything. Returns the set of reachable regions and of reachable locations.
function M.sweep(data, placed, have)
    local count, reach, got = {}, {[0] = true}, {}
    for name, n in pairs(have) do count[name] = n end
    local function ok(r)
        if r == true or r == false then return r end
        local op = r[1]
        if op == "has" then return (count[r[2]] or 0) >= r[3] end
        if op == "reach" then return reach[r[2]] == true end
        if op == "all" then
            for i = 2, #r do if not ok(r[i]) then return false end end
            return true
        end
        for i = 2, #r do if ok(r[i]) then return true end end
        return false
    end
    local grew = true
    while grew do
        grew = false
        for _, e in ipairs(data.entrances) do
            if reach[e[1]] and not reach[e[2]] and ok(e[3]) then reach[e[2]] = true grew = true end
        end
        for i, loc in ipairs(data.locs) do
            if not got[i] and reach[loc.region] and ok(loc.rule) then
                got[i] = true
                grew = true
                local it = placed[i]
                if it then count[it] = (count[it] or 0) + 1 end
            end
        end
    end
    return reach, got
end

local function rule_items(r, out)
    if type(r) ~= "table" then return end
    if r[1] == "has" then out[r[2]] = true return end
    for i = 2, #r do rule_items(r[i], out) end
end

-- One try at a layout. Returns placed (location index -> {name =, id =}) or nil when the try dead-ends.
-- The items a rule asks for are placed first, each in a chest that is reachable while every item still to
-- place is assumed owned ("assumed fill"); the rest goes wherever is left.
function M.try(data, seed, attempt)
    local rnd = rng_of(seed .. "#" .. attempt)
    local needed = {}
    for _, e in ipairs(data.entrances) do rule_items(e[3], needed) end
    for _, l in ipairs(data.locs) do rule_items(l.rule, needed) end

    local names, key, junk, empty = {}, {}, {}, {}        -- names[i]: the item name at location i, for the sweep
    local out = {}
    for i, l in ipairs(data.locs) do
        if l.shuffle then
            empty[#empty + 1] = i
            local it = {name = l.item, id = l.id}
            if needed[l.item] then key[#key + 1] = it else junk[#junk + 1] = it end
        elseif l.item then
            names[i] = l.item                                -- stays where the game put it
        end
    end
    shuffle(key, rnd)
    shuffle(junk, rnd)
    local start = {}
    for _, n in ipairs(data.start) do start[n] = (start[n] or 0) + 1 end

    for k, it in ipairs(key) do
        local have = {}
        for n, c in pairs(start) do have[n] = c end
        for j = k + 1, #key do have[key[j].name] = (have[key[j].name] or 0) + 1 end
        local _, got = M.sweep(data, names, have)
        local open = {}
        for e, i in ipairs(empty) do if got[i] then open[#open + 1] = e end end
        if #open == 0 then return nil end
        local e = open[rnd(#open)]
        local i = table.remove(empty, e)
        names[i], out[i] = it.name, it
    end
    shuffle(empty, rnd)
    for e, i in ipairs(empty) do names[i], out[i] = junk[e].name, junk[e] end

    local reach, got = M.sweep(data, names, start)           -- the real check: from nothing, take everything
    if not reach[data.goal] then return nil end
    for i in ipairs(data.locs) do if not got[i] then return nil end end
    return out
end

return M
