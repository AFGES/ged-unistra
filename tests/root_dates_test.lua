-- Run with: resty -I lua tests/root_dates_test.lua
local root_dates = require("root_dates")

local BASE = "https://ged.unistra.fr/nuxeo/site/dav"

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print("FAIL ", name, ": got ", tostring(got), ", want ", tostring(want))
    end
end

local function response(href, lm, cd)
    return '<D:response><D:href>' .. href .. '</D:href><D:propstat><D:prop>'
        .. '<D:getlastmodified>' .. lm .. '</D:getlastmodified>'
        .. '<D:creationdate>' .. cd .. '</D:creationdate>'
        .. '<D:displayname>x</D:displayname><D:resourcetype><D:collection/></D:resourcetype>'
        .. '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
end

-- Root listing as Nuxeo sends it: every entry has the request time
local NOW_LM, NOW_CD = "Mon, 16 Nov 2026 08:00:28 GMT", "2026-11-16T08:00:28.034Z"
local body = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><D:multistatus xmlns:D="DAV:">'
    .. response(BASE .. "/", NOW_LM, NOW_CD)
    .. response(BASE .. "/clesecq", NOW_LM, NOW_CD)
    .. response(BASE .. "/cfvu/", NOW_LM, NOW_CD)
    .. response(BASE .. "/infos-achats", NOW_LM, NOW_CD)
    .. '</D:multistatus>'

-- Top-level folder names: the root itself is not one
local names = root_dates._child_hrefs(body, BASE)
check("folder count", #names, 3)
check("first folder", names[1], "clesecq")
check("trailing slash dropped", names[2], "cfvu")
check("third folder", names[3], "infos-achats")

-- Absolute-path hrefs are recognised too
local abs = root_dates._child_hrefs(response("/nuxeo/site/dav/plans", NOW_LM, NOW_CD), BASE)
check("absolute path href", abs[1], "plans")

-- Deeper paths are not top-level folders
check("deeper path ignored", #root_dates._child_hrefs(response(BASE .. "/cfvu/cfvu", NOW_LM, NOW_CD), BASE), 0)

-- Only folders with known dates change; the root entry keeps its own dates
local out = root_dates._apply_dates(body, {
    clesecq = { lm = "Wed, 01 Sep 2021 14:11:16 GMT", cd = "2021-09-01T14:11:16.625Z" },
    cfvu    = { lm = "Tue, 22 Feb 2022 16:04:31 GMT" },
}, BASE)
local function dates_of(href)
    local block = out:match("<D:href>" .. href:gsub("%p", "%%%0") .. "</D:href>(.-)</D:response>")
    return block:match("<D:getlastmodified>(.-)<"), block:match("<D:creationdate>(.-)<")
end

local lm, cd = dates_of(BASE .. "/clesecq")
check("clesecq getlastmodified", lm, "Wed, 01 Sep 2021 14:11:16 GMT")
check("clesecq creationdate", cd, "2021-09-01T14:11:16.625Z")
lm, cd = dates_of(BASE .. "/cfvu/")
check("cfvu getlastmodified", lm, "Tue, 22 Feb 2022 16:04:31 GMT")
check("cfvu creationdate kept when unknown", cd, NOW_CD)
lm = dates_of(BASE .. "/infos-achats")
check("folder without dates unchanged", lm, NOW_LM)
lm = dates_of(BASE .. "/")
check("root entry unchanged", lm, NOW_LM)
check("other props kept", select(2, out:gsub("<D:displayname>x</D:displayname>", "")), 4)
check("no dates: body unchanged", root_dates._apply_dates(body, {}, BASE), body)

if failures > 0 then
    print(failures, " check(s) failed")
    os.exit(1)
end
print("root_dates: all checks passed")
