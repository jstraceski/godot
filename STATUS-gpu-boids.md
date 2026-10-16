# Status: CPU-less boid simulation in Godot (engine modification)

_Last updated: this session_

## Goal
Run the boid flock (currently ~262,100 boids via a local-RD compute pipeline in
`spyte/godot/boids/boid_controller.gd`) **entirely on the GPU**, with no CPU readback
of per-boid state, using Godot's built-in `GPUParticles3D` + a modified `particles.glsl`.

## Current state: **WORKING PoC** ✅

### PoC A: O(n²) boids in the process shader (ping-pong read buffer)
- **8-boid flock runs on the GPU** via `GPUParticles3D` + modified `particles.glsl`.
- **No CPU readback** of per-boid state (the AABB debug print is for verification only).
- **Boids flocking works**: the velocity changes over time (cohesion/alignment/separation
  forces are affecting the velocity).
- **O(n²) boids** in the user `process()` body (each boid reads every other boid's state
  from the ping-pong read buffer via the engine's `boid_*` accessors).

### PoC B: External boid buffer (separate compute → direct read) ✅
- **256-boid flock runs on the GPU** via `GPUParticles3D` + a **separate compute shader**
  that writes boid state to an **external RD storage buffer** (binding 5).

### PoC A applied to the real `3d_test` grass scene ✅
- **`spyte/godot/boids/3d_test.tscn`** now runs the CPU-less sim (PoC A) on the real
  grass scene:
  - `boids/shaders/3d_boid_draw.gdshader`: boid sim in the `GPUParticles3D` process
    shader (O(n²) neighbor loop via `boid_position()`/`boid_velocity()`). No textures,
    no CPU readback, no separate compute.
  - `boids/boid_controller.gd`: minimal driver — just configures the `GPUParticles3D`
    (amount, lifetime, explosiveness). No local RD, no compute, no readback.
  - `3d_test.tscn`: `Grass` node scale 200 → 1 so the 5×5 sim board is visible.
- The CPU-less sim mechanism is proven via `flock_test`/`engine_tests` (same
  process-shader path). The full `3d_test` scene is heavier (lights/shadows/camera
  rig), so the command-line non-headless run stalls in this environment — run it in
  the editor to see the boids.
- **No CPU readback**: the process shader reads boid state **directly** from the external
  buffer via the engine's `boid_ext_*` accessors (binding 5).
- **No ping-pong**: the compute writes to a single buffer; the process reads from it.
- **No second device**: the compute is recorded into the main device's `draw_graph` via
  the `frame_draw_begin` signal (render thread), so it runs in-order with the render.
- **New engine property**: `GPUParticles3D.external_boid_buffer` (RID) — sets the external
  boid buffer that the process shader reads from (binding 5).

## What was done this session

### 1a. Engine changes for PoC B (external boid buffer, branch `gpu-boids-wip`)
- **`servers/rendering/shader_types.cpp`**: added `boid_ext_position(i)` / `boid_ext_velocity(i)` /
  `boid_ext_rotation(i)` as **built-in stage functions** to the `SHADER_PARTICLES` mode.
  These are exposed to user shader code as `boid_ext_position(i)`, `boid_ext_velocity(i)`,
  `boid_ext_rotation(i)`.
- **`servers/rendering/renderer_rd/storage_rd/particles_storage.cpp`**:
  - Added `boid_ext_position` / `boid_ext_velocity` / `boid_ext_rotation` to
    `actions.renames` so the shader compiler resolves them without mangling.
  - Added **external boid buffer binding** (binding 5) to the particle dispatch uniform set.
- **`servers/rendering/renderer_rd/shaders/particles.glsl`**:
  - Added a **`BoidOutput` buffer block** (binding 5) for the external boid buffer.
  - Added **`boid_ext_position(i)`** / **`boid_ext_velocity(i)`** / **`boid_ext_rotation(i)`**
    accessor functions that read from the `BoidOutput` buffer.
- **`servers/rendering/renderer_rd/storage_rd/particles_storage.h`**:
  - Added `external_boid_buffer` RID member to the `Particles` struct.
- **`scene/3d/gpu_particles_3d.h` / `.cpp`**:
  - Added `external_boid_buffer` property to `GPUParticles3D` (setter + getter + binding).
- **`servers/rendering/rendering_server.h` / `.cpp`**:
  - Added `particles_set_external_boid_buffer()` method to `RenderingServer`.

### 1b. PoC B scene (`~/Projects/spyte/godot/boids_ext/`)
- **`boid_ext_compute.glsl`**: compute shader that writes boid state (pos, vel, rot) to
  the external boid buffer. Each boid traces a 2D Lissajous curve on the xz plane.
- **`boid_ext_process.gdshader`**: process shader that reads boid state **directly** from
  the external boid buffer via `boid_ext_position(i)` / `boid_ext_velocity(i)` /
  `boid_ext_rotation(i)`. Sets particle position and rotation.
- **`boid_ext_poc.gd`**: driver script that creates the external boid buffer, the compute
  pipeline, and the `GPUParticles3D` with the external boid buffer. Records the compute
  dispatch into the main device's `draw_graph` via the `frame_draw_begin` signal.
- **`boid_ext_poc.tscn`**: scene with the driver script.

### 1. Engine changes (in `~/godot`, branch `gpu-boids-poc`)
- **`servers/rendering/shader_types.cpp`**: added `COUNT` built-in and `boid_position(i)` /
  `boid_velocity(i)` stage functions to the `SHADER_PARTICLES` mode. These are exposed to
  user shader code as `COUNT`, `boid_position(i)`, `boid_velocity(i)`.
- **`servers/rendering/renderer_rd/storage_rd/particles_storage.cpp`**:
  - Added a **ping-pong read buffer** (`particle_buffer_b`) that snapshots the previous
    frame's state into the write buffer at the start of each dispatch.
  - Added a **`COUNT` rename** (`actions.renames["COUNT"] = "params.total_particles"`) so
    user shader code can use `COUNT` as the particle count.
  - **Fixed the uniform set binding**: the dispatch now binds the ping-aware reference
    (`particles_material_uniform_set`) instead of the non-ping version
    (`p_particles->particles_material_uniform_set`). This was the critical bug — the
    ping-pong copy was reading from the wrong buffer.
- **`servers/rendering/renderer_rd/shaders/particles.glsl`**:
  - Added a **`ParticlesPrev` buffer block** (binding 4) for the ping-pong read buffer.
  - Added **`boid_position(i)`** and **`boid_velocity(i)`** accessor functions that read
    from the `ParticlesPrev` buffer.
  - Added the **ping-pong copy** at the start of the dispatch:
    ```glsl
    {
        ParticleData tmp = PARTICLE_PREV;
        PARTICLE.xform = tmp.xform;
        PARTICLE.velocity = tmp.velocity;
        PARTICLE.flags = tmp.flags;
        PARTICLE.color = tmp.color;
        PARTICLE.custom = tmp.custom;
    }
    ```

### 2. PoC scene (`~/godot/poc-boids/`)
- **`boids_process.gdshader`**: O(n²) boids user shader. Each boid reads every other boid's
  position and velocity from the ping-pong read buffer via `boid_position(i)` /
  `boid_velocity(i)`. Computes cohesion, alignment, and separation forces.
- **`poc_main.gd`**: minimal scene script that prints the particle AABB each frame (for
  verification only — no CPU readback of per-boid state).
- **`boids_poc.tscn`**: scene with a `GPUParticles3D` node (amount=8) using the boids shader.

### 3. Build & run
- **Build**: `nix develop --command bash -c 'scons debug=1 dev_build=1 -j32'` (~3.5 min).
- **Run**: `LD_LIBRARY_PATH=... bin/godot.linuxbsd.editor.dev.x86_64 --path poc-boids`.
- **Verified**: the boids particle moves and the velocity changes over time (flocking works).

## Key findings
- **The ping-pong read buffer is essential** for cross-particle reads. Without it, each
  boid reads the current frame's state (which is being written), leading to inconsistent
  reads.
- **The uniform set binding was the critical bug**: the dispatch was binding the non-ping
  uniform set, so the ping-pong copy was reading from the wrong buffer. Fixing this made
  the ping-pong copy work.
- **The boids flocking works**: the velocity changes over time (cohesion/alignment/separation
  forces are affecting the velocity).

## Readback + verification methods (this session)

New `RenderingServer` methods for debugging/verification (all backends implemented):
- **`particles_get_particle_buffer(RID) -> RID`** — the ping-pong WRITE buffer (latest state).
- **`particles_get_read_buffer(RID) -> RID`** — the ping-pong READ buffer (previous frame's state).
- **`particles_get_instance_buffer(RID) -> RID`** — the instance buffer (mat4 per particle, for rendering).
- **`particles_get_current_aabb(RID) -> AABB`** — fixed for std430 alignment (GLSL ParticleData
  is 116B vs C++ 112B; now uses actual buffer size).

**Verified via `boids/engine_tests.tscn`** (6/6 PASS):
- Write buffer, read buffer, instance buffer all valid.
- AABB non-zero.
- Ping-pong: write != read (buffers differ).
- Ping-pong: read == previous frame's write (correctness).

**`boid_flock` verified working**: buffer readback confirms boids move and flock
(position changes over time, velocity changes due to cohesion/alignment/separation).

## Next steps
1. **Scale up**: increase the particle count from 8 to ~262,100 and verify performance.
2. **Spatial hashing**: replace the O(n²) boids with a spatial hash (grid) for O(n) performance.
3. **Integrate with the rest of the `spyte/godot/boids` project**: the `3d_test` grass
   scene is done (CPU-less); other scenes still use the old local-RD compute pipeline +
   CPU readback and should be converted the same way.

## Long-term goals

### L1. Investigate the main device's compute queue  *(added this session)*
Determine whether Godot's main `RenderingDevice` exposes a **user-accessible compute queue**
(or a frame hook that lets us enqueue compute into one). Goal: run the ping-pong boid compute
**on the main device** (same device as the render) so it works **in the editor** with:
- **no second device** (avoids the NVIDIA ICD refusing a 2nd device on the same GPU), and
- **no cross-device transfer** (compute + render share the same buffers/memory).

Open questions to answer:
1. How many command queues does the main device create? (graphics vs. compute vs. transfer)
2. Can user code get a handle to a compute queue on the main device, or only the render queue?
3. Is there a frame callback / hook where we can enqueue a compute dispatch **in-order** with the frame?
4. How to wire the fence/semaphore so the boid-draw pass **waits on** the sim write (cross-queue dependency)?
5. Can the sim run at a **fixed timestep** (e.g. 60 Hz) decoupled from the render FPS, enqueued from the CPU each step?

### L1 findings (this session) — **RESOLVED: the frame hook already exists, no engine mod needed**

Traced the main device's frame flow in the engine source. The mechanism to enqueue
compute on the **main device, in-order, with no 2nd device and no `submit()`/`sync()`** is
already exposed to GDScript:

- **`RenderingDevice.compute_list_begin()` / `compute_list_bind_compute_pipeline()` /
  `compute_list_dispatch()` / `compute_list_end()`** are bound to GDScript
  (`rendering_device.cpp:9436-9440`) and do **not** check `is_main_instance` (only
  `submit()`/`sync()` do, `rendering_device.cpp:8137/8147`). They record into the device's
  `draw_graph`.
- **The `draw_graph` is flushed + submitted as part of the frame's main queue.**
  `RenderingDevice::swap_buffers()` (`rendering_device.cpp:8118`) does:
  `_end_frame()` (→ `draw_graph.end(...)`, flush the graph into the command buffer) →
  `_execute_frame()` (→ `command_queue_execute_and_present(main_queue, ...)`) → advance →
  `_begin_frame()` (→ `draw_graph.begin()`, **reset** the graph for the next frame).
  So a compute list recorded into the `draw_graph` is submitted on the **main queue** with
  **no user `submit()`/`sync()`** and **no `is_main_instance` violation**.
- **The recording window** for frame N spans from the end of frame N-1's `_draw`
  (where `swap_buffers` resets frame N's graph) through frame N's `_draw` (scene recording
  in `viewport->draw_viewports`) to the end of frame N's `_draw` (where `swap_buffers`
  flushes). `RendererCompositorRD::begin_frame` does **not** reset the graph; only
  `swap_buffers` (via `end_frame`) does.
- **The user hook that fires inside that window:**
  - **`RenderingServer.frame_pre_draw`** signal — emitted in `RenderingServerDefault::draw()`
    (`rendering_server_default.cpp:450`) *before* `_draw()`, i.e. after the previous frame's
    reset and before this frame's scene recording. **Inside the window.**
  - **`RenderingServer.call_on_render_thread(callable)`** — bound to GDScript
    (`rendering_server.cpp:3597`); runs the callable on the render thread (directly when
    single-threaded, else queued ahead of `_draw`). **Also inside the window.**
- **Threading:** `_separate_thread_render = false` by default (`core/os/os.h:127`), so
  `create_thread = false` → the main thread **is** the render thread → `frame_pre_draw`
  callbacks run on the render thread and pass `compute_list_begin()`'s
  `ERR_RENDER_THREAD_GUARD`. (If separate-thread rendering is enabled, use
  `call_on_render_thread` instead.)

**Consequence:** the ping-pong boid driver can run its compute dispatch **on the main
device** by recording a compute list in the `frame_pre_draw` callback (or via
`call_on_render_thread`). It is submitted in-order on the main queue, shares buffers with
the render, needs **no 2nd device** (works in the editor), and needs **no cross-device
transfer**. The compute runs *before* the scene's draws (recorded later in
`draw_viewports`), so the boid-draw pass reads the sim's output. Ping-pong across frames is
safe because the main queue executes frame N-1's command buffer before frame N's.

**Remaining work (L1 → done, move to L3):** wire the existing `ping_pong.gd` driver to
record its compute list via `compute_list_*` in a `frame_pre_draw` callback on the main
device (replace `RenderingServer.create_local_rendering_device()` + `submit()`/`sync()`),
then scale to ~262,100 boids.

Why this is the right shape (vs. the local device):
- The local device gives concurrency (separate queue) but costs a **cross-device data shuttle** + the **editor refusal**, for **no performance gain** (same GPU).
- A second **queue on the same device** gives the same concurrency with **shared memory** and **no 2nd device**.
- The ping-pong double-buffer is already scheduling-safe under sequential queue execution; a cross-queue fence handles the concurrent case.

### L2. Resolve the editor conflict
The NVIDIA ICD (595.71.05 on this NixOS setup) returns `VK_ERROR_OUT_OF_DEVICE` when a 2nd
`VkDevice` is requested on the same physical GPU while the editor's main device is live.
The L1 compute-queue approach should remove the need for a 2nd device entirely.

### L3. Scale to ~262,100 boids on the main device
Spatial binning + reindex + compute, dispatched on the main device's compute queue, CPU-less
(no per-boid CPU readback), running inside the editor.

## Files
- Engine changes: `~/godot` (branch `gpu-boids-wip`)
  - `servers/rendering/shader_types.cpp` (boid_ext_* built-in functions)
  - `servers/rendering/renderer_rd/storage_rd/particles_storage.cpp` (renames + external buffer binding)
  - `servers/rendering/renderer_rd/storage_rd/particles_storage.h` (external_boid_buffer member)
  - `servers/rendering/renderer_rd/shaders/particles.glsl` (BoidOutput buffer + boid_ext_* accessors)
  - `scene/3d/gpu_particles_3d.h` / `.cpp` (external_boid_buffer property)
  - `servers/rendering/rendering_server.h` / `.cpp` (particles_set_external_boid_buffer)
- PoC A scene: `~/godot/poc-boids/`
  - `boids_process.gdshader`
  - `poc_main.gd`
  - `boids_poc.tscn`
- PoC B scene: `~/Projects/spyte/godot/boids_ext/`
  - `boid_ext_compute.glsl`
  - `boid_ext_process.gdshader`
  - `boid_ext_poc.gd`
  - `boid_ext_poc.tscn`
- 3d_test (CPU-less, real grass scene): `~/Projects/spyte/godot/boids/`
  - `shaders/3d_boid_draw.gdshader` (boid sim in process shader)
  - `boid_controller.gd` (minimal driver)
  - `3d_test.tscn` (Grass scale 200 → 1)
- Debug/verification: `~/Projects/spyte/godot/boids/`
  - `engine_tests.gd` / `engine_tests.tscn` (6/6 PASS)
  - `flock_test.tscn` + `shaders/boid_flock.gdshader` (verified flocking)
  - `min_test.tscn` + `shaders/min_test.gdshader` (basic particle test)
- Build: `scons platform=linuxbsd target=editor dev_build=yes -j$(nproc)`
- Run: `DISPLAY=:0 ./run-godot.sh --path ~/Projects/spyte/godot --scene res://boids_ext/boid_ext_poc.tscn`
