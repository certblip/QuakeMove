--!strict
--[[ Aggregates and runs every spec. In Roblox: require this module from the
     command bar or a TestService script:
       require(game.ReplicatedStorage.QuakeTests["init.spec"])
     Returns true when every test passed. ]]

local TestRunner = require(script.Parent:WaitForChild("TestRunner"))

local specs = {
	require(script.Parent:WaitForChild("VectorMath.spec")),
	require(script.Parent:WaitForChild("QuakeMath.spec")),
	require(script.Parent:WaitForChild("RingBuffer.spec")),
	require(script.Parent:WaitForChild("MoveState.spec")),
	require(script.Parent:WaitForChild("AirPhysics.spec")),
	require(script.Parent:WaitForChild("Simulator.spec")),
	require(script.Parent:WaitForChild("WallRun.spec")),
	require(script.Parent:WaitForChild("Replay.spec")),
}

local t = TestRunner.new()
for _, spec in specs do
	spec(t)
end
local ok = t:report()
return ok
