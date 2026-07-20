--!strict
--[[
	RemotePlayersService.luau
	Purpose: Entity interpolation for OTHER players. The server anchors remote
	characters and streams everyone's authoritative pose on the broadcast
	channel; rendering those raw 30 Hz CFrames directly looks stuttery. This
	service buffers timestamped samples per player and renders each remote body
	INTERP_DELAY behind real time, lerping between the two bracketing samples -
	the standard Source/Quake entity-interpolation scheme. Smooth at any
	broadcast rate, and packet loss just widens the lerp span instead of jumping.
	Architecture notes: Reads only the broadcast buffer (position/yaw/stateId per
	userId); never touches the simulation. The local player is skipped - it is
	client-predicted, not interpolated.
]]

local Players = game:GetService("Players")

export type RemotePlayersService = {
	Name: string,
	Dependencies: { string }?,
	-- Latest interpolated pose per userId, for consumers like animations.
	GetPose: (self: RemotePlayersService, userId: number) -> ({ position: Vector3, yaw: number, stateId: number }?),
	Init: (self: RemotePlayersService, registry: any) -> (),
	Start: (self: RemotePlayersService) -> (),
	Destroy: (self: RemotePlayersService) -> (),
}

type Sample = { t: number, position: Vector3, yaw: number, stateId: number }

type Remote = {
	samples: { Sample }, -- oldest-first ring; pruned past the interp window
	character: Model?,
	root: BasePart?,
	pose: { position: Vector3, yaw: number, stateId: number },
}

type ServiceInternal = RemotePlayersService & {
	_fw: any,
	_transport: any,
	_remotes: { [number]: Remote },
	_conns: { RBXScriptConnection },
	_enabled: boolean,
}

-- 100 ms: comfortably covers the 33 ms broadcast interval plus jitter, so the
-- render time almost always lands between two received samples.
local INTERP_DELAY = 0.1
local BROADCAST_STRIDE = 25
local MAX_SAMPLES = 24 -- ~0.8 s at 30 Hz; ample history, bounded memory
local RENDER_PRIORITY = 90

local RemotePlayersService = {}
RemotePlayersService.__index = RemotePlayersService

local function shortestAngleLerp(a: number, b: number, t: number): number
	local diff = (b - a) % (2 * math.pi)
	if diff > math.pi then
		diff -= 2 * math.pi
	end
	return a + diff * t
end

local function getRemote(self: ServiceInternal, userId: number): Remote
	local r = self._remotes[userId]
	if r == nil then
		r = {
			samples = {},
			character = nil,
			root = nil,
			pose = { position = Vector3.zero, yaw = 0, stateId = 0 },
		}
		self._remotes[userId] = r
	end
	return r
end

local function onBroadcast(self: ServiceInternal, packet: buffer)
	local len = buffer.len(packet)
	if len < 1 then
		return
	end
	local count = buffer.readu8(packet, 0)
	local localId = Players.LocalPlayer.UserId
	local now = os.clock()
	for i = 0, count - 1 do
		local base = 1 + i * BROADCAST_STRIDE
		if base + BROADCAST_STRIDE > len + 1 then
			break -- truncated packet guard
		end
		local userId = buffer.readf64(packet, base)
		if userId ~= localId then
			local pos = Vector3.new(
				buffer.readf32(packet, base + 8),
				buffer.readf32(packet, base + 12),
				buffer.readf32(packet, base + 16)
			)
			local yaw = buffer.readf32(packet, base + 20)
			local stateId = buffer.readu8(packet, base + 24)
			local r = getRemote(self, userId)
			local samples = r.samples
			samples[#samples + 1] = { t = now, position = pos, yaw = yaw, stateId = stateId }
			if #samples > MAX_SAMPLES then
				table.remove(samples, 1)
			end
		end
	end
end

-- Resolves (and caches) the remote player's HumanoidRootPart. The server
-- anchored it, so writing CFrame here overrides raw replication cleanly.
local function resolveRoot(r: Remote, userId: number): BasePart?
	if r.root and r.root.Parent then
		return r.root
	end
	local player = Players:GetPlayerByUserId(userId)
	local character = player and player.Character
	if character == nil then
		r.character = nil
		r.root = nil
		return nil
	end
	if character ~= r.character then
		r.character = character
		r.root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return r.root
end

local function sampleAt(samples: { Sample }, renderTime: number): (Sample?, Sample?, number)
	-- Find the pair bracketing renderTime (oldest-first buffer).
	for i = #samples, 1, -1 do
		local s = samples[i]
		if s.t <= renderTime then
			local next_ = samples[i + 1]
			if next_ == nil then
				return s, nil, 0 -- newest is behind renderTime: hold (no extrapolation)
			end
			local span = next_.t - s.t
			local alpha = if span > 1e-5 then (renderTime - s.t) / span else 0
			return s, next_, math.clamp(alpha, 0, 1)
		end
	end
	-- renderTime older than everything we have: clamp to the oldest.
	local oldest = samples[1]
	return oldest, nil, 0
end

local function render(self: ServiceInternal)
	local renderTime = os.clock() - INTERP_DELAY
	for userId, r in self._remotes do
		local samples = r.samples
		if #samples == 0 then
			continue
		end
		local a, b, alpha = sampleAt(samples, renderTime)
		if a == nil then
			continue
		end
		local pose = r.pose
		if b then
			pose.position = a.position:Lerp(b.position, alpha)
			pose.yaw = shortestAngleLerp(a.yaw, b.yaw, alpha)
			pose.stateId = if alpha < 0.5 then a.stateId else b.stateId
		else
			pose.position = a.position
			pose.yaw = a.yaw
			pose.stateId = a.stateId
		end
		local root = resolveRoot(r, userId)
		if root then
			root.CFrame = CFrame.new(pose.position) * CFrame.Angles(0, pose.yaw, 0)
		end
	end
end

function RemotePlayersService.GetPose(self: ServiceInternal, userId: number)
	local r = self._remotes[userId]
	return if r then r.pose else nil
end

function RemotePlayersService.Init(self: ServiceInternal, registry: any)
	self._transport = registry:Get("MovementController"):GetTransport()
end

function RemotePlayersService.Start(self: ServiceInternal)
	self._transport:OnBroadcast(function(packet: buffer)
		if self._enabled then
			onBroadcast(self, packet)
		end
	end)

	table.insert(self._conns, Players.PlayerRemoving:Connect(function(player: Player)
		self._remotes[player.UserId] = nil
	end))

	self._fw.Scheduler:RegisterRender(RENDER_PRIORITY, function(_dt: number, _alpha: number)
		if self._enabled then
			render(self)
		end
	end)
end

function RemotePlayersService.Destroy(self: ServiceInternal)
	self._enabled = false
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
	table.clear(self._remotes)
end

local function new(fw: any): RemotePlayersService
	return setmetatable({
		Name = "RemotePlayersService",
		Dependencies = { "MovementController" },
		_fw = fw,
		_transport = nil,
		_remotes = {},
		_conns = {},
		_enabled = true,
	}, RemotePlayersService) :: any
end

return { new = new }
