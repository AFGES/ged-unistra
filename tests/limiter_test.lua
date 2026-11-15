-- Run with: resty --shdict 'cas_auth_state 1m' -I lua tests/limiter_test.lua
local config  = require("config")
local limiter = require("limiter")

-- Small limits so the checks stay short; same code path as the defaults
config.init()
local cfg = config.get()
cfg.auth_max_failures_user = 3
cfg.auth_max_failures_ip   = 5
cfg.auth_failure_window    = 60

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print("FAIL ", name, ": got ", tostring(got), ", want ", tostring(want))
    end
end

-- Per username: blocked at the limit, whatever the address
for i = 1, 2 do limiter.record_failure("alice", "203.0.113." .. i) end
check("user under limit", limiter.blocked("alice", "203.0.113.9"), nil)
limiter.record_failure("alice", "203.0.113.3")
local wait = limiter.blocked("alice", "203.0.113.9")
check("user at limit is blocked", wait ~= nil, true)
check("retry after within window", wait ~= nil and wait >= 1 and wait <= 60, true)
check("other user, same address, not blocked", limiter.blocked("bob", "203.0.113.1"), nil)

-- A successful login clears the username's failures
limiter.reset_user("alice")
check("user after reset", limiter.blocked("alice", "203.0.113.9"), nil)

-- Per address: blocked at the limit, whatever the username
for i = 1, 4 do limiter.record_failure("user" .. i, "198.51.100.7") end
check("address under limit", limiter.blocked("someone", "198.51.100.7"), nil)
limiter.record_failure("user5", "198.51.100.7")
check("address at limit is blocked", limiter.blocked("someone", "198.51.100.7") ~= nil, true)
check("other address not blocked", limiter.blocked("someone", "198.51.100.8"), nil)

-- reset_user does not clear the address
limiter.reset_user("user5")
check("address stays blocked after a user reset", limiter.blocked("someone", "198.51.100.7") ~= nil, true)

if failures > 0 then
    print(failures, " check(s) failed")
    os.exit(1)
end
print("all limiter checks passed")
