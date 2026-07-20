--!strict
--[[
	RingBuffer.luau
	Purpose: Fixed-capacity generic ring buffer used by input history and the
	prediction snapshot store.
	Performance: Backing array is allocated once at construction; Push/Get never
	allocate. Indexing is modulo-free via a wrapped cursor.
]]

export type RingBuffer<T> = {
	Push: (self: RingBuffer<T>, value: T) -> T?, -- returns evicted slot for reuse
	Pop: (self: RingBuffer<T>) -> T?, -- removes and returns the oldest entry
	Get: (self: RingBuffer<T>, index: number) -> T?, -- 1 = oldest
	Newest: (self: RingBuffer<T>) -> T?,
	Count: (self: RingBuffer<T>) -> number,
	Capacity: (self: RingBuffer<T>) -> number,
	Clear: (self: RingBuffer<T>) -> (),
	ForEach: (self: RingBuffer<T>, fn: (value: T, index: number) -> ()) -> (),
}

type RingInternal<T> = RingBuffer<T> & {
	_items: { T },
	_capacity: number,
	_head: number, -- next write slot (1-based)
	_count: number,
}

local RingBuffer = {}
RingBuffer.__index = RingBuffer

function RingBuffer.Push<T>(self: RingInternal<T>, value: T): T?
	local evicted: T? = nil
	if self._count == self._capacity then
		evicted = self._items[self._head]
	else
		self._count += 1
	end
	self._items[self._head] = value
	self._head += 1
	if self._head > self._capacity then
		self._head = 1
	end
	return evicted
end

-- FIFO removal; the slot is handed back to the caller for pooling (the queue
-- consumer recycles command tables instead of allocating).
function RingBuffer.Pop<T>(self: RingInternal<T>): T?
	if self._count == 0 then
		return nil
	end
	local oldest = self._head - self._count
	if oldest < 1 then
		oldest += self._capacity
	end
	local value = self._items[oldest]
	self._count -= 1
	return value
end

function RingBuffer.Get<T>(self: RingInternal<T>, index: number): T?
	if index < 1 or index > self._count then
		return nil
	end
	local oldest = self._head - self._count
	local slot = oldest + index - 1
	if slot < 1 then
		slot += self._capacity
	elseif slot > self._capacity then
		slot -= self._capacity
	end
	return self._items[slot]
end

function RingBuffer.Newest<T>(self: RingInternal<T>): T?
	return self:Get(self._count)
end

function RingBuffer.Count<T>(self: RingInternal<T>): number
	return self._count
end

function RingBuffer.Capacity<T>(self: RingInternal<T>): number
	return self._capacity
end

function RingBuffer.Clear<T>(self: RingInternal<T>)
	self._count = 0
	self._head = 1
end

function RingBuffer.ForEach<T>(self: RingInternal<T>, fn: (value: T, index: number) -> ())
	for i = 1, self._count do
		local v = self:Get(i)
		if v ~= nil then
			fn(v, i)
		end
	end
end

local function new<T>(capacity: number): RingBuffer<T>
	assert(capacity > 0, "capacity must be positive")
	return setmetatable({
		_items = table.create(capacity),
		_capacity = capacity,
		_head = 1,
		_count = 0,
	}, RingBuffer) :: any
end

return { new = new }
