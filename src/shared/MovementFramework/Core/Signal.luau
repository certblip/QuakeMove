--!strict
--[[
	Signal.luau
	Purpose: Minimal typed signal used for cross-service events (state changes, etc.).
	Performance: Intrusive singly linked list; Fire performs zero allocations.
	Notes: Handlers run synchronously. Do not yield inside handlers.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type ConnectionInternal = {
	Connected: boolean,
	Disconnect: (self: ConnectionInternal) -> (),
	_fn: (...any) -> (),
	_next: ConnectionInternal?,
	_signal: SignalInternal,
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

type SignalInternal = {
	_head: ConnectionInternal?,
	Connect: (self: SignalInternal, fn: (...any) -> ()) -> Connection,
	Fire: (self: SignalInternal, ...any) -> (),
	DisconnectAll: (self: SignalInternal) -> (),
}

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: ConnectionInternal)
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local node = signal._head
		while node do
			if node._next == self then
				node._next = self._next
				break
			end
			node = node._next
		end
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.Connect(self: SignalInternal, fn: (...any) -> ()): Connection
	local connection: ConnectionInternal = setmetatable({
		Connected = true,
		_fn = fn,
		_next = self._head,
		_signal = self,
	}, Connection) :: any
	self._head = connection
	return connection
end

function Signal.Fire(self: SignalInternal, ...: any)
	local node = self._head
	while node do
		if node.Connected then
			node._fn(...)
		end
		node = node._next
	end
end

function Signal.DisconnectAll(self: SignalInternal)
	local node = self._head
	while node do
		node.Connected = false
		node = node._next
	end
	self._head = nil
end

local function new<T...>(): Signal<T...>
	return setmetatable({ _head = nil }, Signal) :: any
end

return { new = new }
