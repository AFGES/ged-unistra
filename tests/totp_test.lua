-- Run with: resty -I lua tests/totp_test.lua
local totp = require("totp")

-- RFC 6238 appendix B, SHA1 secret "12345678901234567890", last 6 digits.
local SECRET  = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
local VECTORS = {
    { 59,         "287082" },
    { 1111111109, "081804" },
    { 1111111111, "050471" },
    { 1234567890, "005924" },
    { 2000000000, "279037" },
}

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print("FAIL ", name, ": got ", tostring(got), ", want ", tostring(want))
    end
end

for _, v in ipairs(VECTORS) do
    check("code at " .. v[1], totp.code(SECRET, v[1]), v[2])
end

check("secret, lower case and spaces", totp.is_secret("gezd gnbv gy3t qojq"), true)
check("secret, too short", totp.is_secret("GEZDGNBV"), false)
check("secret, invalid char", totp.is_secret("GEZDGNBVGY3TQOJ1"), false)
check("code, 6 digits", totp.is_code("012345"), true)
check("code, 5 digits", totp.is_code("12345"), false)
check("code, letters", totp.is_code("12a456"), false)
check("invalid secret", totp.code("not base32!", 59), nil)

if failures > 0 then
    print(failures, " check(s) failed")
    os.exit(1)
end
print("all TOTP checks passed")
