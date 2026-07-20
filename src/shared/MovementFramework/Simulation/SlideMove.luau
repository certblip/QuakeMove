--!strict
--[[
	SlideMove.luau
	Purpose: PM_SlideMove / PM_StepSlideMove - moves the collider through the world,
	clipping velocity against every plane it touches (walls, ramps, ceilings),
	handling creases (two-plane corners) via the cross-product slide direction,
	and attempting stair steps when horizontally blocked.
	Architecture notes: Operates purely through a TraceFn; returns results through a
	pre-allocated output struct to keep the hot path allocation-free.
	Non-obvious: the crease case. When clipping against plane B re-violates plane A,
	the only legal direction is along the seam cross(A, B); velocity is projected
	onto that line, preserving speed along the crease (this is what makes surf ramp
	transitions feel continuous rather than sticky).
]]

local Types = require(script.Parent.Parent.Core.Types)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)

export type SlideOutput = {
	position: Vector3,
	velocity: Vector3,
	collisionCount: number,
	hitCeiling: boolean,
	hitWall: boolean,
	-- Clip planes touched during the last solve, exposed for debug
	-- visualization. Pre-allocated; only indices 1..planeCount are valid.
	planes: { Vector3 },
	planeCount: number,
}

local SlideMove = {}

-- Pre-allocated plane storage (max planes is small and fixed).
local planes: { Vector3 } = table.create(8, Vector3.zero)

local function slide(
	trace: Types.TraceFn,
	position: Vector3,
	velocity: Vector3,
	dt: number,
	maxBumps: number,
	maxPlanes: number,
	overbounce: number,
	out: SlideOutput
)
	local timeLeft = dt
	local numPlanes = 0
	out.collisionCount = 0
	out.hitCeiling = false
	out.hitWall = false
	out.planeCount = 0

	for _ = 1, maxBumps do
		if timeLeft <= 0 then
			break
		end
		local delta = velocity * timeLeft
		local tr = trace(position, delta)
		position = tr.position

		if not tr.hit then
			break
		end

		out.collisionCount += 1
		timeLeft -= timeLeft * tr.fraction

		if tr.normal.Y < -0.1 then
			out.hitCeiling = true
		elseif math.abs(tr.normal.Y) < 0.7 then
			out.hitWall = true
		end

		if numPlanes >= maxPlanes then
			velocity = Vector3.zero
			break
		end
		numPlanes += 1
		planes[numPlanes] = tr.normal
		-- Mirror into the output for debug visualization (values, no aliasing).
		out.planes[numPlanes] = tr.normal
		out.planeCount = numPlanes

		-- Clip against the new plane, then verify we do not violate earlier ones.
		local clipped = VectorMath.clipVelocity(velocity, tr.normal, overbounce)
		for i = 1, numPlanes - 1 do
			if clipped:Dot(planes[i]) < 0 then
				-- Crease: slide along the seam of the two planes.
				local seam = planes[i]:Cross(tr.normal)
				local seamDir = VectorMath.safeUnit(seam)
				clipped = seamDir * seamDir:Dot(velocity)
				break
			end
		end
		velocity = clipped
	end

	out.position = position
	out.velocity = velocity
end

-- Step-slide: run the slide; if a wall stopped horizontal progress, retry the
-- whole slide from stepHeight above and settle back down, keeping whichever
-- attempt travelled further horizontally. This is PM_StepSlideMove.
function SlideMove.stepSlide(
	trace: Types.TraceFn,
	position: Vector3,
	velocity: Vector3,
	dt: number,
	grounded: boolean,
	stepHeight: number,
	maxBumps: number,
	maxPlanes: number,
	overbounce: number,
	out: SlideOutput
)
	local startPos = position
	local startVel = velocity

	slide(trace, position, velocity, dt, maxBumps, maxPlanes, overbounce, out)

	if not grounded or not out.hitWall then
		return
	end

	local firstPos = out.position
	local firstVel = out.velocity
	local firstCollisions = out.collisionCount

	-- Raise
	local up = trace(startPos, Vector3.new(0, stepHeight, 0))
	local raisedPos = up.position

	-- Slide again from the raised origin
	slide(trace, raisedPos, startVel, dt, maxBumps, maxPlanes, overbounce, out)

	-- Settle back down
	local down = trace(out.position, Vector3.new(0, -stepHeight, 0))
	out.position = down.position
	if down.hit and down.normal.Y > 0.7 then
		out.velocity = VectorMath.clipVelocity(out.velocity, down.normal, overbounce)
	end

	local firstGain = (firstPos - startPos)
	local stepGain = (out.position - startPos)
	local firstH = firstGain.X * firstGain.X + firstGain.Z * firstGain.Z
	local stepH = stepGain.X * stepGain.X + stepGain.Z * stepGain.Z

	if firstH >= stepH then
		out.position = firstPos
		out.velocity = firstVel
		out.collisionCount = firstCollisions
	end
end

function SlideMove.newOutput(): SlideOutput
	return {
		position = Vector3.zero,
		velocity = Vector3.zero,
		collisionCount = 0,
		hitCeiling = false,
		hitWall = false,
		planes = table.create(8, Vector3.zero),
		planeCount = 0,
	}
end

return table.freeze(SlideMove)
