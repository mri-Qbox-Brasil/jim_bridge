### pedTasks.lua

This module wraps the GTA V `Task*` natives so scripted peds can be given orders without having to remember each native's argument list.

Every task is registered against its ped, so it can be queried and cancelled later. Finite tasks accept an `onComplete` callback and an optional `timeout`, and every function returns `false, "reason"` when it cannot run.

Coordinates can be passed as a `vector3`, a `vector4`, a plain `{x=,y=,z=}` table, or an entity handle, and are normalised automatically.

> ⚠️ **The ped must not be frozen.** GTA ignores movement and animation tasks on a frozen
> ped, so create peds with `makePed(..., freeze = false, ...)` or call
> `FreezeEntityPosition(ped, false)` before giving them tasks.

> ⚠️ **Peds need a weapon and `canShoot`** before `pedTaskShootAt` will make them fire.
> Use `GiveWeaponToPed(ped, `WEAPON_PISTOL`, 50, false, true)` and
> `pedCombatAttributes(ped, { canShoot = true, canAim = true })`.
> GTA also refuses to let a ped fire unless it is already aiming, so pass `aim = true`
> or call `pedTaskAimAt` first.

#### Movement

- **pedTaskGoTo(ped, coords, opts)**

  - Sends a ped to walk or run to a set of coordinates. The task completes once the ped is within `opts.radius` of the destination.
  - **Options:** `run`, `speed`, `radius`, `heading`, `slide`, `nativeTimeout`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskGoTo(ped, vec3(455.0, -975.0, 30.0), {
        run = true,
        onComplete = function(p) print("arrived") end,
    })
    ```

- **pedTaskGoToEntity(ped, target, opts)**

  - Sends a ped towards an entity for a set time or until it is within range.
  - **Options:** `duration`, `distance`, `speed`, `run`
  - **Example:**
    ```lua
    pedTaskGoToEntity(ped, vehicle, { run = true })
    ```

- **pedTaskFollow(ped, target, opts)**

  - Makes a ped follow another entity at a set offset. Completes when the ped catches up.
  - **Options:** `offset`, `run`, `speed`, `radius`, `nativeTimeout`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskFollow(ped, targetPed, { offset = vec3(2.0, 0.0, 0.0), run = true })
    ```

- **pedTaskWander(ped, coords, opts)**

  - Sends a ped wandering randomly inside a radius. Continuous task, no completion callback.
  - **Options:** `radius`, `length`, `betweenWalks`
  - **Example:**
    ```lua
    pedTaskWander(ped, vec3(455.0, -975.0, 30.0), { radius = 10.0 })
    ```

- **pedTaskFlee(ped, threat, opts)**

  - Makes a ped run away from a threat, which can be an entity or a set of coordinates.
  - **Options:** `distance`, `time`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskFlee(ped, threatPed, { distance = 60.0 })
    ```

- **pedTaskFace(ped, target, opts)**

  - Makes a ped turn to face an entity, or to reach a heading in degrees.
  - **Options:** `duration`
  - **Example:**
    ```lua
    pedTaskFace(ped, targetPed)
    ```

#### Vehicles

- **pedTaskEnterVehicle(ped, vehicle, opts)**

  - Tells a ped to get into a vehicle. Completes once the ped is seated.
  - **Options:** `seat` ("any", "driver", "passenger", "rearLeft", "rearRight"), `speed`, `flag` ("normal", "teleportToVehicle", "carjackFromSeat", "teleportDirectly"), `nativeTimeout`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskEnterVehicle(ped, vehicle, { seat = "driver" })
    ```

- **pedTaskLeaveVehicle(ped, opts)**

  - Tells a ped to get out of a vehicle. Completes once the ped is out.
  - **Options:** `vehicle`, `flag` ("normal", "normalSlow", "keepDoorOpen", "teleportOutside", "throwOutOfVehicle", "moveToPassengerFirst"), `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskLeaveVehicle(ped)
    ```

- **pedTaskOpenDoor(ped, vehicle, door, opts)**

  - Tells a ped to open a vehicle door. GTA opens the door nearest to the given seat, so use seat names rather than door names. Asking for "driver" may still open the passenger door if that one is closer.
  - **Options:** `speed`, `nativeTimeout`, `timeout`, `onComplete`
  - **Example:**
    ```lua
    pedTaskOpenDoor(ped, vehicle, "passenger")
    ```

- **pedCloseDoor(vehicle, door, opts)**

  - Closes a vehicle door. GTA has no "close door" task, so this uses the door native directly.
  - **Options:** `instant` (snap it shut), `ped` (a ped whose tasks should be cancelled first, so they stop fighting the close)
  - **Example:**
    ```lua
    pedCloseDoor(vehicle, "passenger", { ped = ped })
    ```

- **pedTaskDriveTo(ped, vehicle, coords, opts)**

  - Makes a ped drive a vehicle to a set of coordinates.
  - **Options:** `speed`, `drivingMode`, `model`, `stopRange`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskDriveTo(ped, vehicle, vec3(100.0, 200.0, 30.0))
    ```

- **pedTaskPark(ped, vehicle, coords, opts)**

  - Makes a ped park a vehicle at a set of coordinates.
  - **Options:** `heading`, `mode` ("ignoreHeading", "forward", "reverse"), `radius`, `keepEngineOn`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskPark(ped, vehicle, vec3(100.0, 200.0, 30.0), { heading = 90.0 })
    ```

- **pedTaskChase(ped, target)**

  - Makes a ped in a vehicle chase another entity. Continuous task.
  - **Example:**
    ```lua
    pedTaskChase(ped, targetVehicle)
    ```

#### Combat

- **pedTaskCombat(ped, target, opts)**

  - Sends a ped to attack a target. Continuous task.
  - **Options:** `style` ("melee" or "ranged")
  - **Example:**
    ```lua
    pedTaskCombat(ped, targetPed, { style = "melee" })
    ```

- **pedTaskShootAt(ped, target, opts)**

  - Makes a ped shoot at an entity or a set of coordinates. Continuous task.
  - **Options:** `duration`, `pattern` (e.g. "FIRING_PATTERN_FULL_AUTO"), `aim` (aim at the target first, required for the ped to actually fire)
  - **Example:**
    ```lua
    pedTaskShootAt(ped, targetPed, { pattern = "FIRING_PATTERN_BURST_FIRE", aim = true })
    ```

- **pedTaskAimAt(ped, target, opts)**

  - Makes a ped aim a weapon at an entity or a set of coordinates. Continuous task.
  - **Options:** `duration`, `instant`, `intro`
  - **Example:**
    ```lua
    pedTaskAimAt(ped, vec3(100.0, 200.0, 30.0))
    ```

- **pedTaskAccuracy(ped, level)**

  - Sets how accurate a ped is when shooting, `0` is poor and `100` is perfect.
  - **Example:**
    ```lua
    pedTaskAccuracy(ped, 80)
    ```

- **pedTaskFiringPattern(ped, pattern)**

  - Sets the firing pattern a ped uses, by name or hash.
  - **Example:**
    ```lua
    pedTaskFiringPattern(ped, "FIRING_PATTERN_BURST_FIRE")
    ```

#### Animation

- **pedTaskPlayAnim(ped, dict, anim, opts)**

  - Plays an animation on a ped. Completes once the animation has finished, unless `opts.loop` is set.
  - **Options:** `blendIn`, `blendOut`, `duration`, `flag` ("looping", "holdLastFrame", "repositionWhenFinished", "notInterruptable", "upperBody"), `playbackRate`, `lock`, `loop`, `timeout`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskPlayAnim(ped, "amb@world_human_clipboard@male@idle_a", "idle_c")
    ```

- **pedTaskScenario(ped, scenario, opts)**

  - Starts a scenario on a ped, such as a sitting or leaning animation. Continuous task.
  - **Options:** `duration`, `intro`
  - **Example:**
    ```lua
    pedTaskScenario(ped, "WORLD_HUMAN_STAND_IMPATIENT")
    ```

- **pedTaskLookAt(ped, target, opts)**

  - Makes a ped look at an entity or a set of coordinates.
  - **Options:** `duration`
  - **Example:**
    ```lua
    pedTaskLookAt(ped, targetPed, { duration = 3000 })
    ```

- **pedTaskRagdoll(ped, duration, opts)**

  - Makes a ped ragdoll for a set duration.
  - **Options:** `type`
  - **Example:**
    ```lua
    pedTaskRagdoll(ped, 3000)
    ```

- **pedTaskStandStill(ped, duration)**

  - Makes a ped stand still for a set duration.
  - **Example:**
    ```lua
    pedTaskStandStill(ped, 3000)
    ```

#### Behaviour

- **pedCombatAttributes(ped, opts)**

  - Sets what a ped is allowed to do in combat. The native takes one attribute at a time, so every option provided is applied individually and anything left out is not changed.
  - **Options:** any of `alwaysFight`, `canShoot`, `canAim`, `canUseCover`, `aggressive`, `perfectAccuracy`, `disableFleeFromCombat`, `canFlank`, `canCharge` and the rest of the game's combat attributes.
  - **Example:**
    ```lua
    pedCombatAttributes(ped, { alwaysFight = true, canShoot = true, canUseCover = true })
    ```

- **pedFleeAttributes(ped, opts)**

  - Sets what a ped is allowed to do when it is fleeing. The native takes a bitmask, so each attribute is applied as `1 << bit`.
  - FiveM only documents bit `15` as "force cower", the rest follow the game's flee attribute ordering. Use `pedSetFleeAttribute` if you need a specific bit.
  - **Example:**
    ```lua
    pedFleeAttributes(ped, { [15] = true })
    ```

- **pedSetFleeAttribute(ped, bit, enabled)**

  - Sets a single flee attribute on a ped by its bit position.
  - **Example:**
    ```lua
    pedSetFleeAttribute(ped, 15, true)
    ```

- **pedCombatRange(ped, range)**

  - Sets how far a ped will engage in combat. Accepts "melee", "preferred", "far" or a raw value 0-2.
  - **Example:**
    ```lua
    pedCombatRange(ped, "melee")
    ```

- **pedCombatAbility(ped, level)**

  - Sets how well a ped fights, from `0` (poor) to `4` (very good).
  - **Example:**
    ```lua
    pedCombatAbility(ped, 3)
    ```

- **pedCombatMovement(ped, mode)**

  - Sets how a ped moves while fighting. Accepts "hold", "strafe", "advance" or a raw value 0-2.
  - **Example:**
    ```lua
    pedCombatMovement(ped, "strafe")
    ```

- **pedSetConfigFlag(ped, flag, value)** / **pedGetConfigFlag(ped, flag)**

  - Reads and writes raw ped config flags, for anything the helpers above do not cover.
  - **Example:**
    ```lua
    pedSetConfigFlag(ped, 17, true) -- block non temporary events
    ```

- **pedState(ped, opts)**

  - Sets a group of general states on a ped. Only the options provided are applied.
  - **Options:** `invincible`, `canRagdoll`, `dropsWeapons`, `criticalHits`, `canSwitchWeapon`, `drunk`, `armour`, `health`, `canBeDamaged`, `blocksEvents`, `moveRate`, `density`
  - **Example:**
    ```lua
    pedState(ped, { invincible = true, canRagdoll = false, armour = 100 })
    ```

#### Tracking

- **pedTaskStatus(ped)**

  - Returns the name of the task currently assigned to a ped, or nil.
  - **Example:**
    ```lua
    if pedTaskStatus(ped) == "goTo" then print("on the move") end
    ```

- **pedTaskIsRunning(ped, name)**

  - Checks if a named task is currently assigned to a ped.
  - **Example:**
    ```lua
    if pedTaskIsRunning(ped, "combat") then print("fighting") end
    ```

- **pedTaskActive(ped, index)**

  - Checks if a native task is active on a ped by its task index.
  - **Example:**
    ```lua
    if pedTaskActive(ped, pedTaskWanderIndex()) then print("wandering") end
    ```

- **pedTaskWanderIndex()**

  - Returns the native task index used by the wander task, for use with `pedTaskActive`.

- **pedTaskCancel(ped, name)**

  - Cancels a task on a ped. GTA has no per task cancellation, so the ped's whole task queue is cleared. The name confirms the task is still the one running first.
  - **Example:**
    ```lua
    pedTaskCancel(ped, "goTo")
    ```

- **pedTaskClear(ped)**

  - Clears every task on a ped and resets its tracking.
  - **Example:**
    ```lua
    pedTaskClear(ped)
    ```

- **pedTaskWait(ped, condition, opts)**

  - Waits for a condition to become true for a ped. Useful for chaining tasks together without a separate script thread.
  - **Options:** `timeout`, `interval`, `onComplete`, `onTimeout`
  - **Example:**
    ```lua
    pedTaskWait(ped, function(p) return #(GetEntityCoords(p) - target) < 3.0 end, {
        onComplete = function(p) pedTaskPlayAnim(p, "dict", "anim") end,
    })
    ```

#### Chaining tasks together

```lua
pedTaskGoTo(ped, coords, {
    run = true,
    onComplete = function(p)
        pedTaskPlayAnim(p, "amb@world_human_clipboard@male@idle_a", "idle_c", {
            onComplete = function(p2)
                pedTaskGoTo(p2, coords2)
            end,
        })
    end,
})
```
