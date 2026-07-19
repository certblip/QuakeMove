--!strict
--[[
	ServiceRegistry.luau
	Purpose: Explicit dependency-injection container. No runtime scanning, no globals.
	Architecture notes: Services declare dependencies by name; the registry resolves
	them topologically at Start(). Circular dependencies are a hard error at boot,
	never a runtime surprise.
	Performance: Resolution happens exactly once during initialization; lookups after
	Start() are a single table index.
]]

export type Service = {
	Name: string,
	Dependencies: { string }?,
	Init: ((self: Service, registry: ServiceRegistry) -> ())?,
	Start: ((self: Service) -> ())?,
	Destroy: ((self: Service) -> ())?,
	[string]: any,
}

export type ServiceRegistry = {
	Register: (self: ServiceRegistry, service: Service) -> ServiceRegistry,
	Get: (self: ServiceRegistry, name: string) -> Service,
	TryGet: (self: ServiceRegistry, name: string) -> Service?,
	Start: (self: ServiceRegistry) -> (),
	Destroy: (self: ServiceRegistry) -> (),
}

type RegistryInternal = ServiceRegistry & {
	_services: { [string]: Service },
	_order: { Service },
	_started: boolean,
}

local ServiceRegistry = {}
ServiceRegistry.__index = ServiceRegistry

function ServiceRegistry.Register(self: RegistryInternal, service: Service): ServiceRegistry
	assert(not self._started, "Cannot register services after Start()")
	assert(type(service.Name) == "string" and #service.Name > 0, "Service requires a Name")
	assert(self._services[service.Name] == nil, `Duplicate service: {service.Name}`)
	self._services[service.Name] = service
	return self
end

function ServiceRegistry.Get(self: RegistryInternal, name: string): Service
	local service = self._services[name]
	assert(service ~= nil, `Unknown service: {name}`)
	return service
end

function ServiceRegistry.TryGet(self: RegistryInternal, name: string): Service?
	return self._services[name]
end

-- Depth-first topological sort with cycle detection.
local function visit(
	self: RegistryInternal,
	service: Service,
	visiting: { [string]: boolean },
	visited: { [string]: boolean }
)
	if visited[service.Name] then
		return
	end
	assert(not visiting[service.Name], `Circular dependency involving: {service.Name}`)
	visiting[service.Name] = true
	local deps = service.Dependencies
	if deps then
		for _, depName in deps do
			visit(self, self:Get(depName), visiting, visited)
		end
	end
	visiting[service.Name] = nil
	visited[service.Name] = true
	table.insert(self._order, service)
end

function ServiceRegistry.Start(self: RegistryInternal)
	assert(not self._started, "Registry already started")
	local visiting: { [string]: boolean } = {}
	local visited: { [string]: boolean } = {}
	for _, service in self._services do
		visit(self, service, visiting, visited)
	end
	for _, service in self._order do
		if service.Init then
			service.Init(service, self)
		end
	end
	for _, service in self._order do
		if service.Start then
			service.Start(service)
		end
	end
	self._started = true
end

function ServiceRegistry.Destroy(self: RegistryInternal)
	for i = #self._order, 1, -1 do
		local service = self._order[i]
		if service.Destroy then
			service.Destroy(service)
		end
	end
	table.clear(self._services)
	table.clear(self._order)
	self._started = false
end

local function new(): ServiceRegistry
	return setmetatable({
		_services = {},
		_order = {},
		_started = false,
	}, ServiceRegistry) :: any
end

return { new = new }
