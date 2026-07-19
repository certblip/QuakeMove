--!strict
--[[
	TestRunner.luau
	Purpose: Zero-dependency test harness. describe/it/expect with a summary. Runs
	under Roblox (TestService) or a bare Lua VM (the CI target), because the tested
	code - QuakeMath, SlideMove, Simulator, RingBuffer, PredictionBuffer - is pure
	and engine-free by design.
]]

export type Expect = {
	toBe: (self: Expect, expected: any) -> (),
	toBeCloseTo: (self: Expect, expected: number, epsilon: number?) -> (),
	toBeTrue: (self: Expect) -> (),
	toBeFalse: (self: Expect) -> (),
	toBeGreaterThan: (self: Expect, n: number) -> (),
	toBeLessThan: (self: Expect, n: number) -> (),
}

export type TestRunner = {
	describe: (self: TestRunner, name: string, body: () -> ()) -> (),
	it: (self: TestRunner, name: string, body: () -> ()) -> (),
	expect: (self: TestRunner, value: any) -> Expect,
	report: (self: TestRunner) -> boolean,
}

local Runner = {}
Runner.__index = Runner

function Runner.describe(self: any, name: string, body: () -> ())
	self._suite = name
	body()
end

function Runner.it(self: any, name: string, body: () -> ())
	self._total += 1
	-- Cast: pcall's second return only exists on failure; strict mode needs
	-- the callee typed as value-returning to accept the (ok, err) pattern.
	local ok, err = pcall(body :: () -> any)
	if ok then
		self._passed += 1
		print(string.format("  [PASS] %s > %s", self._suite, name))
	else
		self._failed += 1
		print(string.format("  [FAIL] %s > %s\n         %s", self._suite, name, tostring(err)))
	end
end

function Runner.expect(_self: any, value: any): Expect
	local e = {}
	function e.toBe(_s: any, expected: any)
		if value ~= expected then
			error(string.format("expected %s, got %s", tostring(expected), tostring(value)), 2)
		end
	end
	function e.toBeCloseTo(_s: any, expected: number, epsilon: number?)
		local eps = epsilon or 1e-4
		if math.abs(value - expected) > eps then
			error(string.format("expected ~%.5f (+/-%.5f), got %.5f", expected, eps, value), 2)
		end
	end
	function e.toBeTrue(_s: any)
		if value ~= true then
			error(string.format("expected true, got %s", tostring(value)), 2)
		end
	end
	function e.toBeFalse(_s: any)
		if value ~= false then
			error(string.format("expected false, got %s", tostring(value)), 2)
		end
	end
	function e.toBeGreaterThan(_s: any, n: number)
		if not (value > n) then
			error(string.format("expected > %s, got %s", tostring(n), tostring(value)), 2)
		end
	end
	function e.toBeLessThan(_s: any, n: number)
		if not (value < n) then
			error(string.format("expected < %s, got %s", tostring(n), tostring(value)), 2)
		end
	end
	return e :: any
end

function Runner.report(self: any): boolean
	print(string.format("\n%d passed, %d failed, %d total", self._passed, self._failed, self._total))
	return self._failed == 0
end

local function new(): TestRunner
	return setmetatable({
		_suite = "",
		_total = 0,
		_passed = 0,
		_failed = 0,
	}, Runner) :: any
end

return { new = new }
