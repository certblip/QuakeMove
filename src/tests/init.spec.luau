--!strict
--[[ Aggregates and runs every spec. Requireable from a Roblox test place or a
     bare Lua VM via the shim in tests/run.lua. ]]

local TestRunner = require(script.Parent.TestRunner)

local specs = {
	require(script.Parent["VectorMath.spec"]),
	require(script.Parent["QuakeMath.spec"]),
	require(script.Parent["RingBuffer.spec"]),
	require(script.Parent["Simulator.spec"]),
}

local t = TestRunner.new()
for _, spec in specs do
	spec(t)
end
local ok = t:report()
return ok
