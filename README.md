# QuakeMove-RBX

A deterministic Quake/Source-inspired movement framework for Roblox.

Designed as a reusable locomotion engine rather than a collection of movement scripts, the project focuses on deterministic simulation, client prediction with full server reconciliation, and a modular architecture suitable for competitive FPS games.

![Luau](https://img.shields.io/badge/Language-Luau%20(strict)-blue) ![Roblox](https://img.shields.io/badge/Platform-Roblox-red) ![License](https://img.shields.io/badge/License-MIT-green) ![Status](https://img.shields.io/badge/Status-Beta-yellow) ![Architecture](https://img.shields.io/badge/Architecture-Deterministic-success) ![Prediction](https://img.shields.io/badge/Networking-Reconciliation-blueviolet) ![Tests](https://img.shields.io/badge/Tests-51%20passing-success)

---

## Features

- Fixed timestep simulation (60 Hz), fully decoupled from rendering
- Client-side prediction + rollback + input replay + correction smoothing
- Authoritative server with input queueing and anti-cheat validation
- Lag compensation: server-side rewind (backtracking) for fair hit registration
- Three air-physics modes: **Quake** (Q3 pmove), **Source** (HL2 gamemovement), **CPM** (ProMode air control)
- Surf physics and Source-style ramp boosting
- Bunny hopping, air strafing, slide (exploit-capped), step movement
- Wall running (budget-based, wall jumps, camera lean)
- Source-style ladders (tag-driven)
- Deterministic replay system (records inputs only, re-simulates playback)
- First-person viewmodel (look sway, movement bob, landing dip)
- Quake-style HUD (HP / UPS / keystroke overlay / crosshair) + replay control panel
- In-world debug visualization (traces, normals, clip planes, prediction corrections)
- Modular additive camera pipeline (head bob, tilt, FOV, sway, trauma shake)
- Extensible movement profiles + gameplay modifiers (jump pads, speed zones)

---

## Architecture

```
Input
  ↓
Command (quantized through the wire format BEFORE prediction)
  ↓
Simulator (deterministic kernel)
  ├── LadderMove
  ├── WallRun
  ├── Ground (QuakeMath: friction / accelerate)
  ├── Air (AirPhysics: Quake | Source | CPM)
  ├── SlideMove / StepSlide (collision solver)
  └── GroundTracer (snap / surf / ramp rules)
  ↓
Modifiers (jump pads, speed zones — run on client, rollback AND server)
  ↓
Networking (PredictionBuffer ⇄ authoritative server, 86-byte snapshots)
  ↓
Camera (additive effects) + Viewmodel + HUD
```

The simulator is completely isolated from Roblox-specific APIs — collision
arrives as a pure `trace(origin, delta)` function. That is what makes the
movement logic deterministic, replayable and testable outside Roblox.

---

## Project Structure

```
src/
  shared/MovementFramework/
    Core/         Types, Signal, ServiceRegistry (DI), Scheduler
    Math/         VectorMath, Spring
    Config/       MovementConfig, CameraConfig, InputConfig, NetworkConfig
    Simulation/   Simulator, QuakeMath, AirPhysics, SlideMove, GroundTracer,
                  WallRun, LadderMove, Collision, MoveState, StateMachine
    Networking/   InputCommand, PredictionBuffer, RingBuffer, Replay, Transport,
                  LagCompensation
    Modifiers/    JumpPad, SpeedZone
  client/         MovementController, InputService, CameraService, CameraEffects/,
                  CharacterAdapter, ViewmodelService, HUDService, ReplayService,
                  DebugRenderer, DebugOverlay, ClientBootstrap
  server/         ServerMovementService, ServerBootstrap
  assets/         QuakeHUD.rbxmx, ReplayHUD.rbxmx, Viewmodel.rbxmx
  tests/          TestRunner + 51 specs (engine-free)
lune/             run-tests.luau (CI runner, no Roblox required)
```

---

## Getting Started

```bash
# Build a place file
rojo build default.project.json -o QuakeMove.rbxlx

# ...or live-sync into Studio
rojo serve
```

Open the place, hit Play. Movement, HUD, viewmodel and networking boot
automatically from `ClientBootstrap` / `ServerBootstrap`.

### Controls

| Key | Action |
|-----|--------|
| WASD / Space | Move / jump (hold Space = auto-bhop on default profile) |
| Shift | Sprint |
| Ctrl / C | Slide |
| F3 | Debug overlay + in-world visualization |
| G | Free the mouse cursor (GUI interaction) |
| Replay panel | REC / PLAY — record and re-simulate runs |

### Level authoring

| Tag (CollectionService) | Effect |
|------------------------|--------|
| `MovementLadder` | Climbable Source-style ladder surface |
| `MovementJumpPad` | Launch pad (Quake trigger_push) |
| `MovementSpeedZone` | Speed volume; `SpeedMultiplier` number attribute (default 2) |

Walls need no markup — any near-vertical surface wall-runs when the profile enables it.

---

## Movement Profiles

`Default`, `Quake`, `QuakeLive`, `Source`, `CPM` — each configures ground/air
acceleration, friction, stop speed, gravity, jump, overbounce, surf/ramp
parameters, wall running and ladders. `AirAccelMode` switches the air
strategy per profile.

```lua
local Framework = require(ReplicatedStorage.MovementFramework)
local fw = Framework.create({ MovementProfile = Framework.MovementConfig.CPM })
```

> Use the same profile on client and server — prediction depends on it.

---

## Current Features

| Feature | Status |
|---------|--------|
| Ground / Air / Slide / Step Movement | ✅ |
| Bunny Hop & Air Strafing | ✅ |
| Surf Physics | ✅ |
| Ramp Boosting | ✅ |
| CPM Movement | ✅ |
| Source Air Accelerate | ✅ |
| Wall Running | ✅ |
| Ladders | ✅ |
| Client Prediction | ✅ |
| Server Reconciliation | ✅ |
| Lag Compensation (rewind hitscan) | ✅ |
| Replay System | ✅ |
| Debug Visualization | ✅ |
| Movement Profiles | ✅ |
| Viewmodel & Quake HUD | ✅ |
| Camera Effects | ✅ |
| Engine-free Test Suite | ✅ |

---

## Determinism & Networking

`Simulator:Step(state, command)` is a pure function of state + input.
Commands are quantized through the wire format before prediction, so the
client simulates exactly the bytes the server deserializes. Snapshots carry
every sim-affecting field (timers, wall-run, ladder state); reconciliation
rolls back, replays buffered inputs **and modifiers**, then smooths the
visual correction. Replays store only the start state plus the command
stream — playback re-simulates and lands on the same result bit-for-bit.

Server-side validation: NaN/Inf rejection, tick monotonicity, server-dictated
timestep (no time-dilation exploits), bounded per-tick command drain.

Lag compensation: the server records every player's authoritative pose each
tick (crouch-aware ring buffer) and measures RTT itself via a clock echo in
the input header — a client-reported ping would be a cheat vector. A weapon
system calls `ServerMovementService:RewindRaycast(shooter, origin, dir, dist)`;
the service rewinds every other player to the tick the shooter actually saw
(interp delay + half RTT, capped at `MaxRewindSeconds`) and intersects the ray
with the pose-correct hull, so hits land where targets were rendered on the
shooter's screen.

---

## Testing

51 specs cover the math, wire formats, lag compensation, the simulator (jump edge buffering,
slide cap, all three air-physics modes, wall runs) and replay determinism.

```bash
# CI / no Roblox required (Lune):
lune run lune/run-tests.luau
```

```lua
-- Or in Studio (command bar, Client or Server context):
require(game.ReplicatedStorage.QuakeTests["init.spec"])
```

---

## Performance

- Zero allocations in the simulation hot path (pooled commands, snapshots,
  trace results, slide output)
- Preallocated ring buffers for input history and prediction
- Binary wire formats (23-byte commands, 86-byte snapshots) over unreliable remotes
- Fixed update loop with hitch clamping; rendering interpolates
- Debug rendering uses a pooled adornment set — zero instance churn per frame

---

## Inspiration

- Quake III Arena / Challenge ProMode Arena
- Valve's PMove (GoldSrc / Source SDK)
- Titanfall & Apex Legends movement feel

---

## License

MIT
