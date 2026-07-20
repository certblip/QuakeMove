--!strict
--[[
	Transport.luau
	Purpose: The only file in the framework aware of RemoteEvents. Provides:
	  RemoteTransport - unreliable remote pair for input up / snapshots down
	  NullTransport   - inert implementation for offline play and tests
	Architecture notes: Consumers hold Types.ITransport; swapping live/offline/test
	transports requires zero changes elsewhere. Packets are raw `buffer`s -
	serialization lives with the data types, not the pipe.
]]

local Types = require(script.Parent.Parent.Core.Types)

local Transport = {}

local REMOTE_FOLDER = "MovementFrameworkRemotes"
local INPUT_REMOTE = "MovementInput"
local SNAPSHOT_REMOTE = "MovementSnapshot"

type RemoteInternal = Types.ITransport & {
	_input: UnreliableRemoteEvent,
	_snapshot: UnreliableRemoteEvent,
	_conn: RBXScriptConnection?,
	_isServer: boolean,
	_player: Player?,
}

local RemoteTransport = {}
RemoteTransport.__index = RemoteTransport

function RemoteTransport.SendInput(self: RemoteInternal, packet: buffer)
	if self._isServer then
		return -- server never sends input
	end
	self._input:FireServer(packet)
end

function RemoteTransport.OnSnapshot(self: RemoteInternal, handler: (packet: buffer) -> ())
	if self._isServer then
		return
	end
	-- Rebinding replaces the previous handler; without the disconnect the old
	-- connection would leak and double-process every snapshot.
	if self._conn then
		self._conn:Disconnect()
	end
	self._conn = self._snapshot.OnClientEvent:Connect(function(packet: buffer)
		handler(packet)
	end)
end

function RemoteTransport.Destroy(self: RemoteInternal)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

-- Server-side helpers (not part of ITransport; the server replicator uses these).
export type ServerTransport = {
	OnInput: (self: ServerTransport, handler: (player: Player, packet: buffer) -> ()) -> (),
	SendSnapshot: (self: ServerTransport, player: Player, packet: buffer) -> (),
	Destroy: (self: ServerTransport) -> (),
}

type ServerInternal = ServerTransport & {
	_input: UnreliableRemoteEvent,
	_snapshot: UnreliableRemoteEvent,
	_conn: RBXScriptConnection?,
}

local ServerTransportImpl = {}
ServerTransportImpl.__index = ServerTransportImpl

function ServerTransportImpl.OnInput(self: ServerInternal, handler: (player: Player, packet: buffer) -> ())
	self._conn = self._input.OnServerEvent:Connect(function(player: Player, packet: unknown)
		if typeof(packet) == "buffer" then
			handler(player, packet)
		end
	end)
end

function ServerTransportImpl.SendSnapshot(self: ServerInternal, player: Player, packet: buffer)
	self._snapshot:FireClient(player, packet)
end

function ServerTransportImpl.Destroy(self: ServerInternal)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

local function getRemotes(create: boolean): (UnreliableRemoteEvent, UnreliableRemoteEvent)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder: Instance
	if create then
		-- Server: create on demand (idempotent). Children are parented before
		-- the folder so clients never observe a partially built folder.
		local existing = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
		if existing == nil then
			local f = Instance.new("Folder")
			f.Name = REMOTE_FOLDER
			local input = Instance.new("UnreliableRemoteEvent")
			input.Name = INPUT_REMOTE
			input.Parent = f
			local snapshot = Instance.new("UnreliableRemoteEvent")
			snapshot.Name = SNAPSHOT_REMOTE
			snapshot.Parent = f
			f.Parent = ReplicatedStorage
			folder = f
		else
			folder = existing
		end
	else
		-- Client: the server bootstrap may still be running when an early
		-- joiner gets here; never assert, wait for replication instead.
		folder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER)
	end
	return folder:WaitForChild(INPUT_REMOTE) :: UnreliableRemoteEvent,
		folder:WaitForChild(SNAPSHOT_REMOTE) :: UnreliableRemoteEvent
end

function Transport.newClient(): Types.ITransport
	local input, snapshot = getRemotes(false)
	return setmetatable({
		_input = input,
		_snapshot = snapshot,
		_isServer = false,
	}, RemoteTransport) :: any
end

function Transport.newServer(): ServerTransport
	local input, snapshot = getRemotes(true)
	return setmetatable({
		_input = input,
		_snapshot = snapshot,
	}, ServerTransportImpl) :: any
end

-- Inert transport: offline play, Studio testing, unit tests.
local NullTransport = {}
NullTransport.__index = NullTransport
function NullTransport.SendInput(_self: Types.ITransport, _packet: buffer) end
function NullTransport.OnSnapshot(_self: Types.ITransport, _handler: (packet: buffer) -> ()) end
function NullTransport.Destroy(_self: Types.ITransport) end

function Transport.newNull(): Types.ITransport
	return setmetatable({}, NullTransport) :: any
end

return table.freeze(Transport)
