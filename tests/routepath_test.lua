-- op77_map3d getRoutePath: N.routePath in client/native/app.lua, the stretch of the route around the player.
-- app.lua needs the whole client to load, so the function is cut out of it and run with the file locals it
-- reads (route, waypoint, nav, clamp) supplied here. Run from the repo root: pwsh -File tests/run-lua.ps1 -Test routepath_test.lua
local function readAll(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
-- every table and value an export result is made of: the platform refuses a copy above 4,096 of them
local function nodes(v)
    if type(v) ~= "table" then return 1 end
    local n = 1
    for _, x in pairs(v) do n = n + nodes(x) end
    return n
end

local app = readAll("client/native/app.lua")
local src = app:match("\n(local ROUTE_WINDOW_POINTS[^\n]*\nfunction N%.routePath%(ahead, behind%).-\nend)\n")
assert(src, "client/native/app.lua no longer defines N.routePath(ahead, behind) after ROUTE_WINDOW_POINTS")
local CAP = assert(tonumber(src:match("ROUTE_WINDOW_POINTS[^=\n]*=%s*(%d+)")), "the point cap is not a plain number")
assert(CAP == 600, "the window cap is 600 points")
for _, name in ipairs({ "route", "nav", "waypoint", "clamp" }) do   -- the file locals the function reads
    local at = app:find("\nlocal " .. name .. "[ =,]") or app:find("\nlocal function " .. name .. "%(")
    assert(at and at < app:find("function N.routePath", 1, true), name .. " is a file local declared before N.routePath")
end

local env = { N = {}, tonumber = tonumber, ipairs = ipairs, math = math, type = type,
    clamp = function(v, a, b) return v < a and a or (v > b and b or v) end }
assert(load(src, "routePath", "t", env))()
local routePath = env.N.routePath

-- a straight route along y, a point every `step` metres, with the maneuvers given
local function line(length, step, maneuvers, id)
    local P, C = {}, {}
    for i = 0, math.floor(length / step) do
        local d = i * step
        P[#P + 1], P[#P + 2], P[#P + 3] = i, d, 5
        C[#C + 1] = d
    end
    return { id = id or 1, points = P, cumulative = C, length = C[#C], maneuvers = maneuvers or {} }
end
local function drive(r, along) env.route, env.waypoint, env.nav = r, { x = 0, y = r and r.length or 0 }, { along = along } end

-- no route, no waypoint, an empty route: nothing
env.route, env.waypoint, env.nav = nil, nil, { along = 0 }
assert(routePath(100, 10) == nil, "no route: nil")
env.route = line(1000, 1)
assert(routePath(100, 10) == nil, "a route without a waypoint (just cleared): nil")
drive({ id = 2, points = {}, cumulative = {}, length = 0, maneuvers = {} }, 0)
assert(routePath(100, 10) == nil, "a route without points: nil")

-- the window: 10 m back to 115 m on, a point per metre
local M = { { kind = "left", at = 4100 }, { kind = "right", at = 9000 } }
local route = line(10000, 1, M, 4)
drive(route, 4000.5)
local r = routePath(115, 10)
assert(r.id == 4 and r.along == 4000.5 and r.length == 10000, "id, along, length")
assert(r.cumulative[1] == 3990 and r.cumulative[#r.cumulative] == 4116, "from the last point at or before 3990.5 to the first at or past 4115.5")
assert(#r.cumulative == 127 and #r.points == 127 * 3, "points are x, y, z flat, one triple per distance")
assert(r.points[1] == 3990 and r.points[2] == 3990 and r.points[3] == 5, "the first triple is the point at the first distance")
assert(r.points[#r.points - 1] == 4116, "and the last one the point at the last distance")
assert(#r.maneuvers == 1 and r.maneuvers[1].kind == "left" and r.maneuvers[1].at == 4100, "only the maneuvers inside the window")
assert(nodes(route) > 4096, "the whole route is over the export limit")
assert(nodes(r) < 4096, "the window is under it")

-- boundaries land on a point exactly: no extra point either side
drive(route, 1000)
r = routePath(0, 10)
assert(#r.cumulative == 11 and r.cumulative[1] == 990 and r.cumulative[11] == 1000, "ahead 0 and a point at along: 10 m back up to along")
r = routePath(0, 0)
assert(#r.cumulative == 1 and r.cumulative[1] == 1000, "ahead 0, behind 0: the point at along only")
drive(route, 1000.5)
r = routePath(0, 0)
assert(#r.cumulative == 2 and r.cumulative[1] == 1000 and r.cumulative[2] == 1001, "between two points: both of them")

-- defaults and clamps
drive(route, 5000)
r = routePath()
assert(r.cumulative[1] == 4990 and r.cumulative[#r.cumulative] == 5150, "defaults: 10 m back, 150 m ahead")
r = routePath(nil, nil)
assert(#r.cumulative == 161, "nil sizes are the defaults")
r = routePath("50", "abc")
assert(r.cumulative[1] == 4990 and r.cumulative[#r.cumulative] == 5050, "a numeric string counts, other text is the default")
for _, bad in ipairs({ 0 / 0, {}, true, function() end }) do
    r = routePath(bad, bad)
    assert(#r.cumulative == 161, "not a number (" .. type(bad) .. "): the defaults")
end
r = routePath(1e9, 1e9)
assert(r.cumulative[1] == 4900 and r.cumulative[#r.cumulative] == 5400, "ahead is at most 400 m, behind at most 100 m")
r = routePath(math.huge, math.huge)
assert(r.cumulative[1] == 4900 and r.cumulative[#r.cumulative] == 5400, "infinity is the maximum too")
r = routePath(-50, -50)
assert(#r.cumulative == 1 and r.cumulative[1] == 5000, "negative sizes are 0")

-- the route's start and end
drive(route, 0)
r = routePath(150, 10)
assert(r.cumulative[1] == 0 and r.cumulative[#r.cumulative] == 150 and r.points[1] == 0, "at the start there is nothing behind")
drive(route, 9990)
r = routePath(150, 10)
assert(r.cumulative[1] == 9980 and r.cumulative[#r.cumulative] == 10000 and #r.points == #r.cumulative * 3, "at the end the window stops with the route")
drive(route, 10050)
r = routePath(150, 10)
assert(#r.cumulative == 1 and r.cumulative[1] == 10000, "past the end (progress overshoots): the last point")
drive(route, -3)
r = routePath(5, 0)
assert(r.cumulative[1] == 0 and r.cumulative[#r.cumulative] == 2, "before the start: from the first point, to along + ahead")
env.nav = {}
r = routePath(5, 5)
assert(r.along == 0 and r.cumulative[1] == 0, "no progress yet: along 0")

-- uneven spacing, against a plain scan: any progress, any sizes
do
    local P, C, d = {}, {}, 0
    local seed = 12345
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    for i = 1, 3000 do
        d = d + 0.2 + rnd() * 20
        P[#P + 1], P[#P + 2], P[#P + 3] = i * 2, d, i % 7
        C[#C + 1] = d
    end
    local rough = { id = 9, points = P, cumulative = C, length = d, maneuvers = {} }
    for _ = 1, 400 do
        local along, ahead, behind = rnd() * d * 1.02 - 10, rnd() * 450, rnd() * 110
        drive(rough, along)
        r = routePath(ahead, behind)
        local from, to = along - math.min(behind, 100), along + math.min(ahead, 400)
        local first = 1
        for k = 1, #C do if C[k] <= from then first = k end end
        local last = #C
        for k = first, #C do if C[k] >= to then last = k; break end end
        last = math.min(last, first + CAP - 1)
        assert(#r.cumulative == last - first + 1 and r.cumulative[1] == C[first] and r.cumulative[#r.cumulative] == C[last],
            ("window %d..%d expected, got %d points from %s"):format(first, last, #r.cumulative, tostring(r.cumulative[1])))
        assert(r.points[1] == P[first * 3 - 2] and r.points[#r.points] == P[last * 3], "the points follow the distances")
    end
end

-- the cap: a route with a point every 10 cm, 100,000 of them, asked for the widest window
do
    local dense = line(10000, 0.1, {}, 5)
    assert(#dense.cumulative > 100000)
    drive(dense, 5000)
    r = routePath(400, 100)
    assert(#r.cumulative == CAP and #r.points == CAP * 3, "capped at 600 points (" .. #r.cumulative .. ")")
    assert(r.cumulative[1] <= 4900 and r.cumulative[1] > 4899.8, "the cap cuts the far end: the window still starts 100 m back")
    assert(r.cumulative[CAP] < 5400, "and ends short of 400 m ahead")
    assert(nodes(dense) > 4096 * 50 and nodes(r) < 4096, "the whole route is far over the limit, the window under")
    drive(dense, 10000)
    r = routePath(400, 100)
    assert(#r.cumulative == CAP and r.cumulative[1] <= 9900 and r.cumulative[CAP] < 10000, "at the end the cap still holds: 100 m back is already 1,000 points")
    r = routePath(400, 5)
    assert(#r.cumulative == 51 and r.cumulative[51] == 10000, "and a window under the cap runs to the last point")
end

-- maneuvers: the window's own, at most 8, in order, copies
do
    local many = {}
    for i = 1, 20 do many[i] = { kind = i % 2 == 0 and "left" or "right", at = 4000 + i * 10 } end
    many[#many + 1] = { kind = "start", at = 0 }
    many[#many + 1] = { kind = "arrive", at = 9999 }
    local mr = line(10000, 1, many, 6)
    drive(mr, 4000)
    r = routePath(400, 100)
    assert(#r.maneuvers == 8 and r.maneuvers[1].at == 4010 and r.maneuvers[8].at == 4080, "the first 8 of the window, in order")
    r = routePath(30, 0)
    assert(#r.maneuvers == 3 and r.maneuvers[3].at == 4030, "a maneuver exactly at the window's end is in")
    drive(mr, 4040)
    r = routePath(10, 10)
    assert(#r.maneuvers == 3 and r.maneuvers[1].at == 4030 and r.maneuvers[3].at == 4050, "and one exactly at its start")
    r = routePath(0, 0)
    assert(#r.maneuvers == 1 and r.maneuvers[1].at == 4040 and r.maneuvers[1].kind == "left", "ahead 0, behind 0: the one at along")
    drive(mr, 5000)
    r = routePath(100, 100)
    assert(#r.maneuvers == 0, "none in the window: an empty list, not nil")
    drive(mr, 4000)
    r = routePath(65, 0)
    assert(#r.maneuvers == 6 and r.maneuvers[6].at == 4060, "none past the window")
    drive(mr, 0)
    r = routePath(10, 0)
    assert(#r.maneuvers == 1 and r.maneuvers[1].kind == "start", "the start maneuver when the window holds it")
    mr.maneuvers = { { kind = "left" }, { kind = "right", at = 5 } }
    r = routePath(10, 0)
    assert(#r.maneuvers == 1 and r.maneuvers[1].kind == "right", "a maneuver without a position is skipped")
    mr.maneuvers = nil
    r = routePath(10, 0)
    assert(#r.maneuvers == 0, "a route without a maneuver list")
end

-- a fresh table: nothing the caller does reaches the route or the next answer
do
    local fresh = line(1000, 1, { { kind = "left", at = 520 } }, 7)
    drive(fresh, 500)
    local a = routePath(100, 10)
    local was = a.points[2]
    assert(a.points ~= fresh.points and a.cumulative ~= fresh.cumulative and a.maneuvers[1] ~= fresh.maneuvers[1], "no table is shared with the route")
    a.points[2], a.cumulative[1], a.maneuvers[1].kind, a.maneuvers[1].at, a.id, a.along = -1, -1, "u-turn", -1, -1, -1
    local b = routePath(100, 10)
    assert(b.points[2] == was and b.cumulative[1] == 490 and b.maneuvers[1].kind == "left" and b.maneuvers[1].at == 520 and b.id == 7 and b.along == 500,
        "an edited answer changes neither the route nor the next answer")
    assert(fresh.points[491 * 3 - 1] == 490 and fresh.cumulative[491] == 490 and fresh.maneuvers[1].kind == "left", "the route is as it was")
    assert(a ~= b and a.points ~= b.points, "every call builds a new table")
end

-- a route recomputed while driving: the answer is the new route's, with its own id and progress
do
    local old, new = line(8000, 1, {}, 10), line(900, 1, { { kind = "right", at = 300 } }, 11)
    drive(old, 7000)
    local before = routePath(100, 10)
    assert(before.id == 10 and before.cumulative[1] == 6990)
    env.route, env.nav = new, { along = 0 }   -- N.onRoute: the new route, progress back to 0
    local after = routePath(100, 10)
    assert(after.id == 11 and after.along == 0 and after.length == 900 and after.cumulative[1] == 0 and after.cumulative[#after.cumulative] == 100,
        "the new route's id and window from its start")
    assert(#after.maneuvers == 0, "with its own maneuvers")
    env.route, env.waypoint = nil, nil   -- the waypoint was cleared
    assert(routePath(100, 10) == nil, "cleared: nil again")
end

-- the worst case under the export limit: the widest window, the cap met, the most maneuvers
do
    local many = {}
    for i = 1, 40 do many[i] = { kind = "right", at = 5000 - 100 + i * 10 } end
    local worst = line(10000, 0.1, many, 12)
    drive(worst, 5000)
    r = routePath(400, 100)
    local n = nodes(r)
    assert(#r.cumulative == CAP and #r.maneuvers == 8)
    assert(n < 4096 and n < 2600, "worst case " .. n .. " nodes, limit 4096")
    print(("worst case window: %d nodes (limit 4096), %d points"):format(n, #r.cumulative))
end

print("PASS: getRoutePath window, bounds, cap, defaults and clamps, maneuvers, fresh tables, recompute, node count")
