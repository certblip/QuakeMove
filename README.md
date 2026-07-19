# QuakeMove-RBX

A deterministic Quake/Source-inspired movement framework for Roblox.

Designed as a reusable locomotion engine rather than a collection of movement scripts, the project focuses on deterministic simulation, client prediction, and modular architecture suitable for competitive FPS games.

![Luau](https://img.shields.io/badge/Language-Luau-blue) ![Roblox](https://img.shields.io/badge/Platform-Roblox-red) ![License](https://img.shields.io/badge/License-MIT-green) ![Status](https://img.shields.io/badge/Status-Alpha-orange) ![Architecture](https://img.shields.io/badge/Architecture-Deterministic-success) ![Prediction](https://img.shields.io/badge/Networking-Client%20Prediction-blueviolet)

---

## Features

- Fixed timestep simulation (60 Hz)
- Client-side prediction
- Input buffering
- Slide movement
- Ground movement
- Air acceleration
- Bunny hopping
- Modular camera system
- Prediction buffer
- Networking abstraction
- Deterministic simulation
- Extensible movement profiles

---

## Architecture

```

Input
↓
Prediction
↓
Simulator
↓
Movement Solver
├── Ground
├── Air
├── Slide
└── Step

↓
Networking

↓

Camera

```

The simulator is completely isolated from Roblox-specific APIs, making the movement logic deterministic and easy to test.

---

## Project Structure

```

src/
Simulation/
Simulator.lua
SlideMove.lua
QuakeMath.lua
GroundMove.lua
StepMove.lua

Networking/
Prediction/
Camera/
Input/

```

---

## Design Goals

The framework is heavily inspired by classic FPS movement systems:

- Quake III Arena
- GoldSrc
- Source Engine

while remaining fully adapted to Roblox's physics and networking model.

The focus is:

- deterministic movement
- predictable networking
- modular codebase
- competitive gameplay

---

## Current Features

| Feature | Status |
|---------|--------|
| Ground Movement | ✅ |
| Air Movement | ✅ |
| Bunny Hop | ✅ |
| Slide Move | ✅ |
| Step Move | ✅ |
| Client Prediction | ✅ |
| Fixed Timestep | ✅ |
| Camera Effects | ✅ |
| Networking Layer | ✅ |

---

## Planned Features

- Surf Physics
- Ramp Boosting
- CPM Movement
- Source Air Accelerate
- Wall Running
- Ladders
- Replay System
- Server Reconciliation
- Debug Visualization
- Movement Profiles

---

## Philosophy

This project intentionally avoids Roblox's default Humanoid movement.

Instead, all locomotion is simulated manually to provide:

- deterministic behavior
- better networking
- competitive movement
- engine-like architecture

---

## Performance

Designed for minimal allocations.

- Preallocated buffers
- Fixed update loop
- Low garbage generation
- Modular simulation
- Prediction-friendly architecture

---

## Inspiration

This project takes inspiration from:

- Quake III Arena
- Source SDK
- Titanfall
- Apex Legends
- Valve's PMove implementation

---

## License

MIT
