# GPU Boid Sim — Architecture & Status

_Last updated: this session_

## TL;DR
- The boid sim (ping‑pong, double‑buffered) runs **on the GPU, CPU‑less** (no per‑boid CPU round‑trip).
- It currently runs on a **local `RenderingDevice`** (a 2nd Vulkan device). That works from the **CLI / game**, but **not in the editor** — the NVIDIA ICD refuses a 2nd device on the same GPU while the editor holds the first (`VK_ERROR_OUT_OF_DEVICE`).
- Fix direction: run the sim compute on the **main device** (same device as the render) via a **compute queue / frame hook** → no 2nd device, no cross‑device transfer, works in the editor.

---

## The core ideas (what we established)

### 1. Ping‑pong = data double‑buffering, *not* a device thing
- Two sets of state buffers (**A** and **B**): position / velocity / rotation / bin.
- Each step: **READ → one set, WRITE → the other**, dispatch, swap.
- Invariant: the set being read is **never** the set being written in the same dispatch → cross‑particle reads always see the *previous* step's state. No race, no CPU round‑trip.
- Works identically regardless of which device runs the shaders.

### 2. Main device vs local device
- **Main device** = managed by Godot. You **cannot** `submit()`/`sync()` on it (`Only local devices can submit and sync`). Godot drives its command queue inside the frame loop.
- **Local device** = you create it (`create_local_rendering_device()`), you own it, you **can** `submit()`/`sync()`.
- The ping‑pong needs a device it can submit/sync on → that's why it uses a local device today.

### 3. Why the editor breaks the local device
- The editor creates its own main device (for the editor UI).
- The script then requests a **2nd device on the same physical GPU**.
- The NVIDIA ICD (595.71.05 on this NixOS setup) returns `VK_ERROR_OUT_OF_DEVICE` → null device → cascade of null errors.
- From the **CLI (game mode)** the 2nd device *is* accepted → works (~120+ FPS).

### 4. GPU scheduling: CPU defines structure, GPU drives execution
- **CPU** defines: which queues, order within a queue, cross‑queue dependencies (fences/semaphores), and the **cadence** (fixed timestep, e.g. 60 Hz).
- **GPU** drives: overlap of independent queues, parallelization of the N boid invocations across cores, timing.
- The GPU sequences by **dependency** (barrier/semaphore), **not by time**. It has **no timer/delay primitive** — it cannot "wait 16 ms." The cadence is CPU‑driven.
  - "Run A, wait for A's queue to finish, then B" → **YES** (GPU‑driven; barrier/semaphore in one submission).
  - "Wait for a certain time to elapse" → **NO** (that's the CPU's clock).

### 5. CPU sync: coordinate always, block rarely
- **Semaphore (GPU→GPU):** orders sim→draw. The **GPU** enforces it; the CPU records it and moves on. **No CPU block.**
- **Fence (GPU→CPU):** **blocks the CPU.** Only needed for a **readback** (state → CPU). The CPU‑less design avoids this.
- The CPU is always the coordinator (submits + paces), but it does **not** block on the boid state — that's the whole point.

### 6. The main benefit (why CPU‑less)
- State lives in GPU buffers; the draw reads the compute's output buffer **directly**. No copy to CPU, no copy back.
- At 262k boids a CPU round‑trip is ~**10–25 MB/frame** plus a CPU‑side neighbor compute that's far too slow. Keeping it on the GPU eliminates both.
- The sim→draw "sync" is just *"the draw reads the buffer the compute wrote"* — automatic (same device/memory), ordered by a semaphore, **no data movement**.

### 7. Why not just keep the local device (the tradeoff)
- Local device = concurrency (separate queue) **but**:
  - **Cross‑device data shuttle** (compute on local device, render on main device → must move state between devices).
  - **Editor refusal** (2nd device on same GPU).
  - **No performance gain** (same GPU).
- A **2nd queue on the same (main) device** = same concurrency, **shared memory** (no shuttle), **no 2nd device** (no editor refusal). Strictly better for the CPU‑less goal.

---

## What's working now
- ✅ Ping‑pong boid sim on the GPU, CPU‑less, via a **local device** — works from the **CLI / game** (`ping_pong_test.tscn`), ~120+ FPS.
- ✅ Engine patch: `boid_*` accessors + ping‑pong read buffer in `particles.glsl` (main‑device particle path).
- ✅ Built‑in `GPUParticles3D` + process shader path (`flock_test.tscn`) runs on the **main device, in the editor**, no 2nd device (simpler; no binning scale).
- ✅ Dev shell (`~/godot/flake.nix`) provides all runtime libs (X11, fontconfig, EGL, audio, Vulkan ICD) → engine runs **Vulkan Forward+** on the RTX 5080.

## What's NOT working / left to do

### Not working right now
- ❌ **In the editor:** the local‑device ping‑pong fails (`VK_ERROR_OUT_OF_DEVICE` → null device → null errors). The 2nd device is refused while the editor holds the first.
- ❌ **Scale (262k) in the editor:** not there yet — needs the main‑device compute queue + spatial binning.
- ❌ **Fully CPU‑less render in `ping_pong_test`:** the current `ping_pong_test.gd` does a **CPU readback** to build the mesh / AABB (not fully CPU‑less). The PoC in `~/godot/poc-boids` is closer (draw reads the buffer via a shader).

### Left to do (the plan)
1. **L1 — Investigate the main device's compute queue** *(the key task)*:
   - How many command queues does the main device create (graphics vs compute vs transfer)?
   - Can user code get a handle to a **compute queue** on the main device, or only the render queue?
   - Is there a frame callback/hook to enqueue a compute dispatch **in‑order** with the frame?
   - How to wire the fence/semaphore so the boid‑draw **waits on** the sim write (cross‑queue dependency)?
   - Can the sim run at a **fixed timestep** (60 Hz) decoupled from the render FPS?
2. **L2 — Resolve the editor conflict:** the compute‑queue approach should remove the need for a 2nd device entirely.
3. **L3 — Scale to ~262,100 boids on the main device:** spatial binning + reindex + compute, dispatched on the main device's compute queue, CPU‑less, in the editor.
4. **Make the ping‑pong render fully CPU‑less:** draw reads the state buffer via a shader (no CPU mesh rebuild / AABB readback), matching the PoC.
5. **Decide the dispatch shape:** same‑queue (in‑order, simplest) vs separate‑queue (concurrent, needs one fence). Prototype both, measure.

---

## Files
- **Engine:** `~/godot` (branch `gpu-boids-poc`) — `servers/rendering/shader_types.cpp`, `servers/rendering/renderer_rd/storage_rd/particles_storage.cpp`, `servers/rendering/renderer_rd/shaders/particles.glsl`
- **PoC (CPU‑less, main device):** `~/godot/poc-boids/`
- **Spyte ping‑pong driver (local device):** `~/Projects/spyte/godot/boids/ping_pong.gd`, `ping_pong_test.gd`, `ping_pong_test.tscn`
- **Spyte built‑in path:** `~/Projects/spyte/godot/boids/flock_test.tscn`
- **Dev shell:** `~/godot/flake.nix`, `~/godot/run-godot.sh`
- **Status:** `~/godot/STATUS-gpu-boids.md`
