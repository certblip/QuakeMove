--!nonstrict
--[[
	lune/run-tests.luau
	Purpose: Executes the engine-free test suite (src/tests) outside Roblox.
	Builds a mock DataModel from the filesystem (ReplicatedStorage/
	MovementFramework + QuakeTests), injects a pure-Lua Vector3 and a require
	shim, then runs init.spec through Lune's Luau VM.
	Usage:  lune run lune/run-tests.luau
	Notes: Numbers here are f64 (Roblox Vector3 is f32), so results can differ
	from Studio in the last bits - the specs' tolerances absorb that. This
	runner exists for CI; Studio remains the authoritative environment.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

--------------------------------------------------------------------------------
-- Vector3 shim (f64). Only what the simulation layer actually uses.
--------------------------------------------------------------------------------

local Vector3 = {}
local vecMeta = {}

local function vnew(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, vecMeta)
end

vecMeta.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		return vnew(v.X / m, v.Y / m, v.Z / m)
	elseif key == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y + a.Z * b.Z
		end
	elseif key == "Cross" then
		return function(a, b)
			return vnew(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
		end
	elseif key == "Lerp" then
		return function(a, b, t)
			return vnew(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
		end
	end
	return nil
end

vecMeta.__add = function(a, b)
	return vnew(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
vecMeta.__sub = function(a, b)
	return vnew(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
vecMeta.__unm = function(a)
	return vnew(-a.X, -a.Y, -a.Z)
end
vecMeta.__mul = function(a, b)
	if type(a) == "number" then
		return vnew(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return vnew(a.X * b, a.Y * b, a.Z * b)
	end
	return vnew(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
vecMeta.__div = function(a, b)
	if type(b) == "number" then
		return vnew(a.X / b, a.Y / b, a.Z / b)
	end
	return vnew(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
vecMeta.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
vecMeta.__tostring = function(v)
	return string.format("%g, %g, %g", v.X, v.Y, v.Z)
end

Vector3.new = vnew
Vector3.zero = vnew(0, 0, 0)
Vector3.one = vnew(1, 1, 1)
Vector3.xAxis = vnew(1, 0, 0)
Vector3.yAxis = vnew(0, 1, 0)
Vector3.zAxis = vnew(0, 0, 1)

--------------------------------------------------------------------------------
-- Mock instance tree over the filesystem
--------------------------------------------------------------------------------

local nodeMeta
local requireNode -- forward decl

local function newNode(name: string, filePath: string?)
	return setmetatable({
		Name = name,
		Parent = nil,
		_children = {},
		_filePath = filePath,
	}, nodeMeta)
end

nodeMeta = {
	__index = function(node, key)
		if key == "WaitForChild" or key == "FindFirstChild" then
			return function(self, childName)
				local child = self._children[childName]
				if child == nil and key == "WaitForChild" then
					error(`{self.Name}: missing child '{childName}'`)
				end
				return child
			end
		end
		local child = rawget(node, "_children")[key]
		if child ~= nil then
			return child
		end
		error(`{rawget(node, "Name")}: unknown member '{tostring(key)}'`)
	end,
	__tostring = function(node)
		return rawget(node, "Name")
	end,
}

-- Builds nodes from a directory. A folder with init.luau becomes a module
-- node that ALSO has children (Rojo semantics).
local function buildTree(dirPath: string, name: string)
	local initPath = dirPath .. "/init.luau"
	local node = newNode(name, if fs.isFile(initPath) then initPath else nil)
	for _, entry in fs.readDir(dirPath) do
		local full = dirPath .. "/" .. entry
		if fs.isDir(full) then
			local child = buildTree(full, entry)
			child.Parent = node
			node._children[entry] = child
		elseif entry:match("%.luau$") and entry ~= "init.luau" then
			local childName = entry:gsub("%.luau$", "")
			local child = newNode(childName, full)
			child.Parent = node
			node._children[childName] = child
		end
	end
	return node
end

--------------------------------------------------------------------------------
-- Environment + require shim
--------------------------------------------------------------------------------

local replicatedStorage = newNode("ReplicatedStorage")

local game = {
	GetService = function(_self, serviceName: string)
		if serviceName == "ReplicatedStorage" then
			return replicatedStorage
		end
		error(`mock game: service '{serviceName}' is not available in the test runner`)
	end,
}

local moduleCache = {}
local CYCLE = {} -- sentinel

function requireNode(node)
	local path = rawget(node, "_filePath")
	assert(path ~= nil, `require: '{rawget(node, "Name")}' is not a ModuleScript`)
	local cached = moduleCache[path]
	if cached == CYCLE then
		error(`require cycle detected at {path}`)
	elseif cached ~= nil then
		return cached
	end
	moduleCache[path] = CYCLE

	local source = fs.readFile(path)
	local bytecode = luau.compile(source, { optimizationLevel = 1, debugLevel = 1 })
	local fn = luau.load(bytecode, {
		debugName = path,
		environment = {
			script = node,
			game = game,
			require = requireNode,
			Vector3 = Vector3,
			warn = print,
		},
		injectGlobals = true, -- keep Lune's math/table/string/buffer/bit32/os/pcall...
	})
	local result = fn()
	moduleCache[path] = result
	return result
end

--------------------------------------------------------------------------------
-- Mount src/shared/MovementFramework + src/tests and run
--------------------------------------------------------------------------------

local fw = buildTree("src/shared/MovementFramework", "MovementFramework")
fw.Parent = replicatedStorage
replicatedStorage._children.MovementFramework = fw

local tests = buildTree("src/tests", "QuakeTests")
tests.Parent = replicatedStorage
replicatedStorage._children.QuakeTests = tests

local ok, result = pcall(requireNode, tests._children["init.spec"])
if not ok then
	print("[run-tests] harness error:")
	print(result)
	process.exit(2)
end
process.exit(if result == true then 0 else 1)
