--[[
    Ped Task & AI Control Module
    --------------------------------
    Wraps the GTA V "Task*" natives so scripted peds can be given orders
    without having to remember each native's argument list.

    Covers:
      • Movement  - goTo, goToEntity, follow, wander, flee, face
      • Combat    - combat, melee, shootAt, aimAt, accuracy, firingPattern
      • Vehicles  - enterVehicle, leaveVehicle, openDoor, closeDoor, driveTo, park, chaseVehicle
      • Animation - playAnim, scenario, lookAt, ragdoll, standStill
      • Behaviour - combat/flee attributes, combat range & movement, ped state, config flags
      • Tracking  - status, isRunning, cancel, clear, wait, active

    Design mirrors 'make/ropeControl.lua':
      • Every task is registered against its ped so it can be queried and cancelled.
      • Finite tasks accept an `onComplete` callback and an optional `timeout`.
      • All functions return `false, "reason"` when they cannot run.
      • Inputs accept an entity handle or a vector3/vector4/table of coordinates.

    All natives used here were verified against the FiveM native reference.
    GTA has no close-door task and no "sit still" task, so those use the
    closest available natives instead.

    Usage:
      local ped = makePed({model = `a_m_y_business_03`}, vec4(450.0, -980.0, 30.0, 100.0))
      pedTaskGoTo(ped, vec3(455.0, -975.0, 30.0), {
          run = true,
          onComplete = function(p) print("arrived") end,
      })
]]

if not isServer() then
    -------------------------------------------------------------
    -- State
    -------------------------------------------------------------

    -- Tracks the tasks currently assigned to each ped.
    -- PedTasks[ped] = { current = "goTo", tasks = { ["goTo"] = true } }
    local PedTasks = {}
    -- Generation counter per ped/task, used to invalidate stale completion watchers.
    local TaskGen = {}

    -------------------------------------------------------------
    -- Native constants
    -------------------------------------------------------------

    -- SET_PED_COMBAT_ATTRIBUTES takes a single attribute index, not a bitmask.
    -- Indexes taken from the game's eCombatAttribute enum.
    local combatAttributes = {
        useCover                           = 0,
        useVehicle                         = 1,
        doDrivebys                         = 2,
        leaveVehicles                      = 3,
        canUseDynamicStrafeDecisions       = 4,
        alwaysFight                        = 5,
        fleeWhilstInVehicle                = 6,
        justFollowVehicle                  = 7,
        playReactionAnims                  = 8,
        willScanForDeadPeds                = 9,
        isAGuard                           = 10,
        justSeekCover                      = 11,
        blindFireInCover                   = 12,
        aggressive                         = 13,
        canInvestigate                     = 14,
        canUseRadio                        = 15,
        canCaptureEnemyPeds                = 16,
        alwaysFlee                         = 17,
        canTauntInVehicle                  = 20,
        canChaseTargetOnFoot               = 21,
        willDragInjuredPedsToSafety        = 22,
        requiresLosToShoot                 = 23,
        useProximityFiringRate             = 24,
        disableSecondaryTarget             = 25,
        disableEntryReactions              = 26,
        perfectAccuracy                    = 27,
        canUseFrustratedAdvance            = 28,
        moveToLocationBeforeCoverSearch    = 29,
        canShootWithoutLos                 = 30,
        maintainMinDistanceToTarget        = 31,
        canUsePeekingVariations            = 34,
        disablePinnedDown                  = 35,
        disablePinDownOthers               = 36,
        openCombatWhenDefensiveAreaReached = 37,
        disableBulletReactions             = 38,
        canBust                            = 39,
        ignoredByOtherPedsWhenWanted       = 40,
        canCommandeerVehicles              = 41,
        canFlank                           = 42,
        switchToAdvanceIfCantFindCover     = 43,
        switchToDefensiveIfInCover         = 44,
        clearPrimaryDefensiveAreaReached   = 45,
        canFightArmedPedsWhenNotArmed      = 46,
        enableTacticalPointsWhenDefensive  = 47,
        disableCoverArcAdjustments         = 48,
        useEnemyAccuracyScaling            = 49,
        canCharge                          = 50,
        removeAreaSetWillAdvanceWhenReached = 51,
        useVehicleAttack                   = 52,
        useVehicleAttackIfHasMountedGuns    = 53,
        alwaysEquipBestWeapon              = 54,
        canSeeUnderwaterPeds               = 55,
        disableAimAtAiTargetsInHelis       = 56,
        disableSeekDueToLineOfSight        = 57,
        disableFleeFromCombat              = 58,
        disableTargetChangesDuringPursuit  = 59,
        canThrowSmokeGrenade               = 60,
        clearAreaSetDefensiveIfUnreachable = 62,
        disableBlockFromPursueDuringChase  = 64,
        disableSpinOutDuringVehicleChase   = 65,
        disableCruiseInFrontDuringChase    = 66,
        canIgnoreBlockedLosWeighting       = 67,
        disableReactToBuddyShot            = 68,
        preferNavmeshDuringVehicleChase    = 69,
        allowedToAvoidOffroadDuringChase  = 70,
        permitChargeBeyondDefensiveArea    = 71,
        useRocketsAgainstVehiclesOnly      = 72,
        disableTacticalPointsWithoutLos    = 73,
        disablePullAlongsideDuringChase    = 74,
        disableAllRandomsFlee              = 78,
        generateDeadPedSeenScriptEvents    = 79,
        useMaxSenseRangeOnEvents           = 80,
        restrictInVehicleAimingToSide      = 81,
        useDefaultBlockedLosPosition       = 82,
        requiresLosToAim                   = 83,
        canCruiseAndBlockInVehicle         = 84,
        preferAirCombatWhenInAircraft      = 85,
        allowDogFighting                   = 86,
        preferNonAircraftTargets           = 87,
        preferKnownTargetsWhenClosest      = 88,
        forceCheckAttackAngleForMountedGun = 89,
        blockFireForPassengerMountedGuns   = 90,
    }

    -- SET_PED_COMBAT_RANGE values
    local combatRanges = { melee = 0, preferred = 1, far = 2 }
    -- SET_PED_COMBAT_MOVEMENT values
    local combatMovements = { hold = 0, strafe = 1, advance = 2 }

    -- Vehicle seat indexes, these also match the door indexes used by the door natives
    local vehicleSeats = {
        any       = -1,
        driver    = 0,
        passenger = 1,
        rearLeft  = 2,
        rearRight = 3,
    }

    -- TASK_PLAY_ANIM flags
    local animFlags = {
        looping                    = 1,
        holdLastFrame              = 2,
        repositionWhenFinished     = 4,
        notInterruptable           = 8,
        upperBody                  = 16,
    }

    -- TASK_ENTER_VEHICLE flags
    local enterVehicleFlags = {
        normal            = 1,
        teleportToVehicle = 3,
        carjackFromSeat   = 8,
        teleportDirectly  = 16,
    }

    -- TASK_LEAVE_VEHICLE flags
    local leaveVehicleFlags = {
        normal                = 0,
        normalSlow            = 64,
        keepDoorOpen          = 256,
        teleportOutside       = 16,
        throwOutOfVehicle     = 4160,
        moveToPassengerFirst  = 262144,
    }

    -- TASK_VEHICLE_PARK modes
    local parkModes = { ignoreHeading = 0, forward = 1, reverse = 2 }

    -- The task index used by GetIsTaskActive to report a wandering ped
    local TASK_INDEX_WANDER = 222

    -------------------------------------------------------------
    -- Internal helpers
    -------------------------------------------------------------

    --- Checks the ped handle is a living, existing entity.
    --- @param ped number The ped handle to test.
    --- @return boolean True if the ped can be given a task.
    local function isValidPed(ped)
        return type(ped) == "number" and ped ~= 0 and DoesEntityExist(ped) and not IsEntityDead(ped)
    end

    --- Normalises a coordinate input into a vector3.
    --- @param target number|vector3|vector4|table An entity handle or a set of coordinates.
    --- @return vector3|nil The resolved coordinates, or nil if they could not be resolved.
    local function resolveCoords(target)
        if type(target) == "number" then
            if not DoesEntityExist(target) then return nil end
            return GetEntityCoords(target, false)
        end
        if type(target) == "vector3" then return target end
        if type(target) == "vector4" then return target.xyz end
        if type(target) == "table" and target.x and target.y and target.z then
            return vec3(target.x, target.y, target.z)
        end
        return nil
    end

    --- Resolves a seat or door index from a name or number.
    --- @param seat string|number The seat name ("driver") or index.
    --- @return number The seat index, defaulting to -1 (any seat).
    local function resolveSeat(seat)
        if type(seat) == "string" then return vehicleSeats[seat] or -1 end
        if type(seat) == "number" then return seat end
        return -1
    end

    --- Runs a native inside pcall so a bad argument list cannot break the calling script.
    --- @param label string The name used in the debug output if the call fails.
    --- @param fn function The native to call.
    --- @return boolean True if the call succeeded.
    local function safeCall(label, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            debugPrint("^6Bridge^7: ^1ERROR^7 in ^3"..label.."^7: "..tostring(err))
        end
        return ok
    end

    --- Registers a task against a ped and returns its generation token.
    --- @param ped number The ped the task belongs to.
    --- @param name string The name of the task.
    --- @return number The generation token for this assignment.
    local function registerTask(ped, name)
        if not PedTasks[ped] then PedTasks[ped] = { current = nil, tasks = {} } end
        PedTasks[ped].current = name
        PedTasks[ped].tasks[name] = true

        TaskGen[ped] = TaskGen[ped] or {}
        TaskGen[ped][name] = (TaskGen[ped][name] or 0) + 1

        debugPrint("^6Bridge^7: ^3pedTask^7: '^6"..name.."' ^2assigned to ped^7 '^6"..ped.."'")
        return TaskGen[ped][name]
    end

    --- Removes a task from a ped's registry.
    --- @param ped number The ped the task belongs to.
    --- @param name string The name of the task.
    local function unregisterTask(ped, name)
        if not PedTasks[ped] then return end
        if PedTasks[ped].current == name then PedTasks[ped].current = nil end
        PedTasks[ped].tasks[name] = nil
    end

    --- Watches a task until its condition is met, the timeout expires, or the ped is gone.
    --- @param ped number The ped running the task.
    --- @param name string The name of the task being watched.
    --- @param gen number The generation token from registerTask.
    --- @param check function A function returning true when the task is complete.
    --- @param opts table Optional callbacks and the timeout in milliseconds.
    local function watchTask(ped, name, gen, check, opts)
        local timeout = opts.timeout or 15000
        local start = GetGameTimer()

        CreateThread(function()
            while DoesEntityExist(ped) and (GetGameTimer() - start) < timeout do
                local ok, result = pcall(check, ped)
                if ok and result then
                    if TaskGen[ped] and TaskGen[ped][name] == gen then
                        unregisterTask(ped, name)
                    end
                    if opts.onComplete then opts.onComplete(ped) end
                    return
                end
                Wait(100)
            end

            if TaskGen[ped] and TaskGen[ped][name] == gen then
                unregisterTask(ped, name)
            end
            if opts.onTimeout then opts.onTimeout(ped) end
        end)
    end

    -------------------------------------------------------------
    -- Movement
    -------------------------------------------------------------

    --- Sends a ped to walk or run to a set of coordinates.
    ---
    --- The task completes once the ped is within `opts.radius` of the destination.
    ---
    ---@param ped number The ped to move.
    ---@param coords vector3|vector4|table|number The destination, or an entity to walk to.
    ---@param opts table|nil Optional settings.
    --- - **run** `boolean`: Run instead of walk. Default `false`.
    --- - **speed** `number`: Raw move speed, `1.0` walks and `3.0` runs. Default depends on `run`.
    --- - **radius** `number`: Arrival distance in game units. Default `2.0`.
    --- - **heading** `number`: Target heading in degrees, `-1` keeps current. Default `-1`.
    --- - **slide** `number`: Distance the ped may slide to a stop. Default `0.0`.
    --- - **nativeTimeout** `number`: Milliseconds the native itself allows. Default `-1`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `15000`.
    --- - **onComplete** `function`: Called with the ped once it arrives.
    --- - **onTimeout** `function`: Called with the ped if it never arrives.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskGoTo(ped, vec3(455.0, -975.0, 30.0), { run = true })
    --- ```
    function pedTaskGoTo(ped, coords, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local target = resolveCoords(coords)
        if not target then return false, "invalid coords" end

        local speed = opts.speed or (opts.run and 3.0 or 1.0)

        safeCall("pedTaskGoTo", TaskGoStraightToCoord, ped,
            target.x, target.y, target.z,
            speed, opts.nativeTimeout or -1,
            opts.heading or -1, opts.slide or 0.0)

        local name = "goTo"
        local gen = registerTask(ped, name)
        local radius = opts.radius or 2.0

        watchTask(ped, name, gen, function(p)
            return #(GetEntityCoords(p, false) - target) <= radius
        end, opts)

        return true
    end

    --- Sends a ped towards an entity for a set time or until it is within range.
    ---
    ---@param ped number The ped to move.
    ---@param target number The entity to walk to.
    ---@param opts table|nil Optional settings.
    --- - **duration** `number`: Milliseconds the ped keeps moving. Default `5000`.
    --- - **distance** `number`: Distance considered "arrived". Default `4.0`.
    --- - **speed** `number`: Move speed. Default `1.0`.
    --- - **run** `boolean`: Run instead of walk. Default `false`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskGoToEntity(ped, vehicle, { run = true })
    --- ```
    function pedTaskGoToEntity(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(target) ~= "number" or not DoesEntityExist(target) then return false, "invalid target" end
        opts = opts or {}

        safeCall("pedTaskGoToEntity", TaskGoToEntity, ped, target,
            opts.duration or 5000, opts.distance or 4.0,
            opts.speed or (opts.run and 3.0 or 1.0),
            1073741824, 0)

        registerTask(ped, "goToEntity")
        return true
    end

    --- Makes a ped follow another entity at a set offset.
    ---
    --- The task completes once the ped is within `opts.radius` of its target.
    ---
    ---@param ped number The ped that follows.
    ---@param target number The entity to follow.
    ---@param opts table|nil Optional settings.
    --- - **offset** `vector3`: Distance to keep from the target. Default `vec3(1.5, 0.0, 0.0)`.
    --- - **run** `boolean`: Run instead of walk. Default `false`.
    --- - **speed** `number`: Raw move speed. Default depends on `run`.
    --- - **radius** `number`: Distance considered "arrived". Default `3.0`.
    --- - **nativeTimeout** `number`: Milliseconds the native itself allows. Default `-1`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `15000`.
    --- - **onComplete** `function`: Called with the ped once it catches up.
    --- - **onTimeout** `function`: Called with the ped if it never catches up.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskFollow(ped, targetPed, { offset = vec3(2.0, 0.0, 0.0), run = true })
    --- ```
    function pedTaskFollow(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(target) ~= "number" or not DoesEntityExist(target) then return false, "invalid target" end
        opts = opts or {}

        local offset = opts.offset or vec3(1.5, 0.0, 0.0)
        local speed = opts.speed or (opts.run and 3.0 or 1.0)

        safeCall("pedTaskFollow", TaskFollowToOffsetOfEntity, ped, target,
            offset.x, offset.y, offset.z,
            speed, opts.nativeTimeout or -1,
            opts.radius or 10.0, opts.persist ~= false)

        local name = "follow"
        local gen = registerTask(ped, name)
        local radius = opts.radius or 3.0

        watchTask(ped, name, gen, function(p)
            return #(GetEntityCoords(p, false) - GetEntityCoords(target, false)) <= radius
        end, opts)

        return true
    end

    --- Sends a ped wandering randomly inside a radius.
    ---
    --- This is a continuous task, it has no completion callback.
    ---
    ---@param ped number The ped to move.
    ---@param coords vector3|vector4|table|number The centre of the wandering area.
    ---@param opts table|nil Optional settings.
    --- - **radius** `number`: Size of the area to wander in. Default `20.0`.
    --- - **length** `number`: Minimum length of each walk. Default `10`.
    --- - **betweenWalks** `number`: Seconds to wait between walks. Default `5.0`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskWander(ped, vec3(455.0, -975.0, 30.0), { radius = 10.0 })
    --- ```
    function pedTaskWander(ped, coords, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local target = resolveCoords(coords)
        if not target then return false, "invalid coords" end

        safeCall("pedTaskWander", TaskWanderInArea, ped,
            target.x, target.y, target.z,
            opts.radius or 20.0, opts.length or 10, opts.betweenWalks or 5.0)

        registerTask(ped, "wander")
        return true
    end

    --- Makes a ped run away from a threat.
    ---
    ---@param ped number The ped that flees.
    ---@param threat vector3|vector4|table|number The thing to run from, an entity or coordinates.
    ---@param opts table|nil Optional settings.
    --- - **distance** `number`: How far to run. Default `40.0`.
    --- - **time** `number`: Milliseconds to keep fleeing, `-1` forever. Default `-1`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `10000`.
    --- - **onComplete** `function`: Called with the ped once it is clear.
    --- - **onTimeout** `function`: Called with the ped if it never escapes.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskFlee(ped, threatPed, { distance = 60.0 })
    --- ```
    function pedTaskFlee(ped, threat, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local distance = opts.distance or 40.0
        local time = opts.time or -1

        if type(threat) == "number" and DoesEntityExist(threat) then
            safeCall("pedTaskFlee", TaskSmartFleePed, ped, threat, distance, time, false, false)
        else
            local from = resolveCoords(threat)
            if not from then return false, "invalid threat" end
            safeCall("pedTaskFlee", TaskSmartFleeCoord, ped, from.x, from.y, from.z, distance, time, false, false)
        end

        local name = "flee"
        local gen = registerTask(ped, name)

        watchTask(ped, name, gen, function(p)
            local away = GetEntityCoords(p, false)
            local from = resolveCoords(threat)
            if not from then return false end
            return #(away - from) >= distance
        end, opts)

        return true
    end

    --- Makes a ped turn to face an entity or a heading.
    ---
    ---@param ped number The ped to turn.
    ---@param target number|number The entity to face, or a heading in degrees.
    ---@param opts table|nil Optional settings.
    --- - **duration** `number`: Milliseconds the turn is allowed to take. Default `1000`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskFace(ped, targetPed)
    --- ```
    function pedTaskFace(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        if type(target) == "number" and DoesEntityExist(target) then
            safeCall("pedTaskFace", TaskTurnPedToFaceEntity, ped, target, opts.duration or 1000)
        elseif type(target) == "number" then
            safeCall("pedTaskFace", TaskAchieveHeading, ped, target, opts.duration or 1000)
        else
            return false, "invalid target"
        end

        registerTask(ped, "face")
        return true
    end

    -------------------------------------------------------------
    -- Vehicles
    -------------------------------------------------------------

    --- Tells a ped to get into a vehicle.
    ---
    --- The task completes once the ped is seated.
    ---
    ---@param ped number The ped that enters.
    ---@param vehicle number The vehicle to enter.
    ---@param opts table|nil Optional settings.
    --- - **seat** `string|number`: "any", "driver", "passenger", "rearLeft", "rearRight" or an index. Default `"any"`.
    --- - **speed** `number`: Approach speed, `1.0` walks and `2.0` runs. Default `1.0`.
    --- - **flag** `string|number`: "normal", "teleportToVehicle", "carjackFromSeat", "teleportDirectly". Default `"normal"`.
    --- - **nativeTimeout** `number`: Milliseconds the native itself allows. Default `-1`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `10000`.
    --- - **onComplete** `function`: Called with the ped once seated.
    --- - **onTimeout** `function`: Called with the ped if it never gets in.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskEnterVehicle(ped, vehicle, { seat = "driver" })
    --- ```
    function pedTaskEnterVehicle(ped, vehicle, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(vehicle) ~= "number" or not DoesEntityExist(vehicle) then return false, "invalid vehicle" end
        opts = opts or {}

        local seat = resolveSeat(opts.seat or "any")
        local flag = type(opts.flag) == "string" and enterVehicleFlags[opts.flag] or (opts.flag or enterVehicleFlags.normal)

        safeCall("pedTaskEnterVehicle", TaskEnterVehicle, ped, vehicle,
            opts.nativeTimeout or -1, seat, opts.speed or 1.0, flag, 0)

        local name = "enterVehicle"
        local gen = registerTask(ped, name)

        watchTask(ped, name, gen, function(p)
            return IsPedInAnyVehicle(p, false)
        end, opts)

        return true
    end

    --- Tells a ped to get out of a vehicle.
    ---
    ---@param ped number The ped that leaves.
    ---@param opts table|nil Optional settings.
    --- - **vehicle** `number`: The vehicle to leave, defaults to the one the ped is in.
    --- - **flag** `string|number`: "normal", "normalSlow", "keepDoorOpen", "teleportOutside", "throwOutOfVehicle", "moveToPassengerFirst". Default `"normal"`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `10000`.
    --- - **onComplete** `function`: Called with the ped once it is out.
    --- - **onTimeout** `function`: Called with the ped if it never gets out.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskLeaveVehicle(ped)
    --- ```
    function pedTaskLeaveVehicle(ped, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local vehicle = opts.vehicle or GetVehiclePedIsIn(ped, false)
        if not vehicle or vehicle == 0 then return false, "ped is not in a vehicle" end

        local flag = type(opts.flag) == "string" and leaveVehicleFlags[opts.flag] or (opts.flag or leaveVehicleFlags.normal)

        safeCall("pedTaskLeaveVehicle", TaskLeaveVehicle, ped, vehicle, flag)

        local name = "leaveVehicle"
        local gen = registerTask(ped, name)

        watchTask(ped, name, gen, function(p)
            return not IsPedInAnyVehicle(p, false)
        end, opts)

        return true
    end

    --- Tells a ped to open a vehicle door.
    ---
    --- GTA opens the door nearest to the given seat, so use seat names rather than
    --- door names here. "driver" opens the front left door, "passenger" the front right.
    ---
    ---@param ped number The ped that opens the door.
    ---@param vehicle number The vehicle to open.
    ---@param door string|number The seat to open, e.g. "driver" or an index.
    ---@param opts table|nil Optional settings.
    --- - **speed** `number`: Opening speed. Default `1.0`.
    --- - **nativeTimeout** `number`: Milliseconds the native itself allows. Default `-1`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `10000`.
    --- - **onComplete** `function`: Called with the ped once the door is open.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskOpenDoor(ped, vehicle, "passenger")
    --- ```
    function pedTaskOpenDoor(ped, vehicle, door, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(vehicle) ~= "number" or not DoesEntityExist(vehicle) then return false, "invalid vehicle" end
        opts = opts or {}

        local index = resolveSeat(door)
        if index < 0 then return false, "invalid door" end

        -- remember which doors were shut, GTA may open a different one to the seat asked for
        local beforeRatios = {}
        for i = 0, 5 do beforeRatios[i] = GetVehicleDoorAngleRatio(vehicle, i) end

        safeCall("pedTaskOpenDoor", TaskOpenVehicleDoor, ped, vehicle,
            opts.nativeTimeout or -1, index, opts.speed or 1.0)

        local name = "openDoor"
        local gen = registerTask(ped, name)

        watchTask(ped, name, gen, function()
            for i = 0, 5 do
                if beforeRatios[i] <= 0.0 and GetVehicleDoorAngleRatio(vehicle, i) > 0.0 then
                    return true
                end
            end
            return false
        end, opts)

        return true
    end

    --- Closes a vehicle door.
    ---
    --- GTA has no "close door" task, so this uses the door native directly.
    ---
    --- If the ped that opened the door still has that task running it will fight the
    --- close, so pass their handle as `opts.ped` to cancel their tasks first.
    ---
    ---@param vehicle number The vehicle to close.
    ---@param door string|number The door to close, e.g. "driver" or an index.
    ---@param opts table|nil Optional settings.
    --- - **instant** `boolean`: Snap the door shut. Default `false`.
    --- - **ped** `number`: A ped whose tasks should be cancelled before closing.
    ---
    ---@return boolean True if the door was closed.
    ---@usage
    --- ```lua
    --- pedCloseDoor(vehicle, "passenger", { ped = ped })
    --- ```
    function pedCloseDoor(vehicle, door, opts)
        if type(vehicle) ~= "number" or not DoesEntityExist(vehicle) then return false, "invalid vehicle" end
        opts = opts or {}

        if opts.ped and DoesEntityExist(opts.ped) then
            ClearPedTasksImmediately(opts.ped)
        end

        local index = resolveSeat(door)
        if index < 0 then return false, "invalid door" end

        safeCall("pedCloseDoor", SetVehicleDoorShut, vehicle, index, opts.instant == true)
        return true
    end

    --- Makes a ped drive a vehicle to a set of coordinates.
    ---
    ---@param ped number The ped driving.
    ---@param vehicle number The vehicle to drive.
    ---@param coords vector3|vector4|table The destination.
    ---@param opts table|nil Optional settings.
    --- - **speed** `number`: Driving speed. Default `30.0`.
    --- - **drivingMode** `number`: Driving mode bitmask. Default `16777216`.
    --- - **model** `number`: Vehicle model hash, defaults to the vehicle's own model.
    --- - **stopRange** `number`: How close to get before stopping. Default `1.0`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `30000`.
    --- - **onComplete** `function`: Called with the ped once it arrives.
    --- - **onTimeout** `function`: Called with the ped if it never arrives.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskDriveTo(ped, vehicle, vec3(100.0, 200.0, 30.0))
    --- ```
    function pedTaskDriveTo(ped, vehicle, coords, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(vehicle) ~= "number" or not DoesEntityExist(vehicle) then return false, "invalid vehicle" end
        opts = opts or {}

        local target = resolveCoords(coords)
        if not target then return false, "invalid coords" end

        safeCall("pedTaskDriveTo", TaskVehicleDriveToCoord, ped, vehicle,
            target.x, target.y, target.z,
            opts.speed or 30.0, 1.0,
            opts.model or GetEntityModel(vehicle),
            opts.drivingMode or 16777216,
            opts.stopRange or 1.0, true)

        local name = "driveTo"
        local gen = registerTask(ped, name)
        local radius = opts.radius or 5.0

        watchTask(ped, name, gen, function(p)
            local veh = GetVehiclePedIsIn(p, false)
            if not veh or veh == 0 then return false end
            return #(GetEntityCoords(veh, false) - target) <= radius
        end, opts)

        return true
    end

    --- Makes a ped park a vehicle at a set of coordinates.
    ---
    ---@param ped number The ped parking.
    ---@param vehicle number The vehicle to park.
    ---@param coords vector3|vector4|table Where to park.
    ---@param opts table|nil Optional settings.
    --- - **heading** `number`: Final heading in degrees. Default `0`.
    --- - **mode** `string|number`: "ignoreHeading", "forward", "reverse". Default `"ignoreHeading"`.
    --- - **radius** `number`: How close the vehicle must end up. Default `20.0`.
    --- - **keepEngineOn** `boolean`: Leave the engine running. Default `false`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `30000`.
    --- - **onComplete** `function`: Called with the ped once parked.
    --- - **onTimeout** `function`: Called with the ped if it never parks.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskPark(ped, vehicle, vec3(100.0, 200.0, 30.0), { heading = 90.0 })
    --- ```
    function pedTaskPark(ped, vehicle, coords, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(vehicle) ~= "number" or not DoesEntityExist(vehicle) then return false, "invalid vehicle" end
        opts = opts or {}

        local target = resolveCoords(coords)
        if not target then return false, "invalid coords" end

        local mode = type(opts.mode) == "string" and parkModes[opts.mode] or (opts.mode or parkModes.ignoreHeading)

        safeCall("pedTaskPark", TaskVehiclePark, ped, vehicle,
            target.x, target.y, target.z,
            opts.heading or 0, mode, opts.radius or 20.0, opts.keepEngineOn == true)

        local name = "park"
        local gen = registerTask(ped, name)
        local radius = opts.radius or 20.0

        watchTask(ped, name, gen, function(p)
            local veh = GetVehiclePedIsIn(p, false)
            if not veh or veh == 0 then return false end
            return #(GetEntityCoords(veh, false) - target) <= radius
        end, opts)

        return true
    end

    --- Makes a ped in a vehicle chase another entity.
    ---
    --- This is a continuous task, it has no completion callback.
    ---
    ---@param ped number The ped driving.
    ---@param target number The entity to chase.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskChase(ped, targetVehicle)
    --- ```
    function pedTaskChase(ped, target)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(target) ~= "number" or not DoesEntityExist(target) then return false, "invalid target" end

        safeCall("pedTaskChase", TaskVehicleChase, ped, target)

        registerTask(ped, "chase")
        return true
    end

    -------------------------------------------------------------
    -- Combat
    -------------------------------------------------------------

    --- Sends a ped to attack a target.
    ---
    --- This is a continuous task, it has no completion callback.
    ---
    ---@param ped number The ped that attacks.
    ---@param target number The entity to attack.
    ---@param opts table|nil Optional settings.
    --- - **style** `string`: "melee" (default) or "ranged".
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskCombat(ped, targetPed, { style = "melee" })
    --- ```
    function pedTaskCombat(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(target) ~= "number" or not DoesEntityExist(target) then return false, "invalid target" end
        opts = opts or {}

        if (opts.style or "melee") == "ranged" then
            safeCall("pedTaskCombat", TaskCombatPed, ped, target, 0, 16)
        else
            safeCall("pedTaskCombat", TaskPutPedDirectlyIntoMelee, ped, target, 0.0, -1.0, 0.0, false)
        end

        registerTask(ped, "combat")
        return true
    end

    --- Makes a ped shoot at an entity or a set of coordinates.
    ---
    --- This is a continuous task, it has no completion callback.
    ---
    --- GTA will not let a ped fire until it is already aiming at the target, so pass
    --- `opts.aim = true` to have this issue an aim task first, or aim the ped yourself
    --- with `pedTaskAimAt` before calling this.
    ---
    ---@param ped number The ped that shoots.
    ---@param target vector3|vector4|table|number The entity or coordinates to shoot at.
    ---@param opts table|nil Optional settings.
    --- - **duration** `number`: Milliseconds to keep shooting, `-1` indefinitely. Default `-1`.
    --- - **pattern** `string|number`: Firing pattern, e.g. "FIRING_PATTERN_FULL_AUTO". Default full auto.
    --- - **aim** `boolean`: Aim at the target first so the ped can actually fire. Default `false`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskShootAt(ped, targetPed, { pattern = "FIRING_PATTERN_BURST_FIRE", aim = true })
    --- ```
    function pedTaskShootAt(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local duration = opts.duration or -1
        local pattern = type(opts.pattern) == "string" and joaat(opts.pattern) or (opts.pattern or joaat("FIRING_PATTERN_FULL_AUTO"))

        if opts.aim then
            pedTaskAimAt(ped, target, { duration = opts.aimDuration or duration })
            Wait(100)
        end

        if type(target) == "number" and DoesEntityExist(target) then
            safeCall("pedTaskShootAt", TaskShootAtEntity, ped, target, duration, pattern)
        else
            local coords = resolveCoords(target)
            if not coords then return false, "invalid target" end
            safeCall("pedTaskShootAt", TaskShootAtCoord, ped, coords.x, coords.y, coords.z, duration, pattern)
        end

        registerTask(ped, "shootAt")
        return true
    end

    --- Makes a ped aim a weapon at an entity or a set of coordinates.
    ---
    --- This is a continuous task, it has no completion callback.
    ---
    ---@param ped number The ped that aims.
    ---@param target vector3|vector4|table|number The entity or coordinates to aim at.
    ---@param opts table|nil Optional settings.
    --- - **duration** `number`: Milliseconds to hold the aim, `-1` indefinitely. Default `-1`.
    --- - **instant** `boolean`: Snap straight into the aim. Default `false`.
    --- - **intro** `boolean`: Play the aim intro animation. Default `false`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskAimAt(ped, vec3(100.0, 200.0, 30.0))
    --- ```
    function pedTaskAimAt(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local duration = opts.duration or -1

        if type(target) == "number" and DoesEntityExist(target) then
            safeCall("pedTaskAimAt", TaskAimGunAtEntity, ped, target, duration, opts.instant == true)
        else
            local coords = resolveCoords(target)
            if not coords then return false, "invalid target" end
            safeCall("pedTaskAimAt", TaskAimGunAtCoord, ped, coords.x, coords.y, coords.z,
                duration, opts.instant == true, opts.intro == true)
        end

        registerTask(ped, "aimAt")
        return true
    end

    --- Sets how accurate a ped is when shooting.
    ---
    ---@param ped number The ped to configure.
    ---@param level number The accuracy level, `0` is poor and `100` is perfect.
    ---
    ---@return boolean True if the accuracy was applied.
    ---@usage
    --- ```lua
    --- pedTaskAccuracy(ped, 80)
    --- ```
    function pedTaskAccuracy(ped, level)
        if not isValidPed(ped) then return false, "invalid ped" end

        SetPedAccuracy(ped, level or 0)
        return true
    end

    --- Sets the firing pattern a ped uses.
    ---
    ---@param ped number The ped to configure.
    ---@param pattern string|number The pattern name or hash, e.g. "FIRING_PATTERN_FULL_AUTO".
    ---
    ---@return boolean True if the pattern was applied.
    ---@usage
    --- ```lua
    --- pedTaskFiringPattern(ped, "FIRING_PATTERN_BURST_FIRE")
    --- ```
    function pedTaskFiringPattern(ped, pattern)
        if not isValidPed(ped) then return false, "invalid ped" end
        if not pattern then return false, "invalid pattern" end

        local hash = type(pattern) == "string" and joaat(pattern) or pattern
        SetPedFiringPattern(ped, hash)
        return true
    end

    -------------------------------------------------------------
    -- Animation
    -------------------------------------------------------------

    --- Plays an animation on a ped.
    ---
    --- The task completes once the animation has finished, unless `opts.loop` is set.
    ---
    ---@param ped number The ped to animate.
    ---@param dict string The animation dictionary.
    ---@param anim string The animation name.
    ---@param opts table|nil Optional settings.
    --- - **blendIn** `number`: Blend in speed. Default `8.0`.
    --- - **blendOut** `number`: Blend out speed. Default `-8.0`.
    --- - **duration** `number`: Milliseconds, `-1` to loop. Default `-1`.
    --- - **flag** `string|number`: "looping", "holdLastFrame", "repositionWhenFinished", "notInterruptable", "upperBody". Default `"looping"`.
    --- - **playbackRate** `number`: Playback speed. Default `1.0`.
    --- - **lock** `boolean`: Lock the ped in place. Default `false`.
    --- - **loop** `boolean`: Treat the animation as never ending. Default `false`.
    --- - **timeout** `number`: Milliseconds before giving up. Default `15000`.
    --- - **onComplete** `function`: Called with the ped once the animation ends.
    --- - **onTimeout** `function`: Called with the ped if it never ends.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskPlayAnim(ped, "amb@world_human_clipboard@male@idle_a", "idle_c")
    --- ```
    function pedTaskPlayAnim(ped, dict, anim, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if not dict or not anim then return false, "invalid animation" end
        opts = opts or {}

        loadAnimDict(dict)

        local flag = type(opts.flag) == "string" and animFlags[opts.flag] or (opts.flag or animFlags.looping)
        local lock = opts.lock and true or false

        safeCall("pedTaskPlayAnim", TaskPlayAnim, ped, dict, anim,
            opts.blendIn or 8.0, opts.blendOut or -8.0,
            opts.duration or -1, flag, opts.playbackRate or 1.0,
            lock, lock, lock)

        local name = "playAnim"
        local gen = registerTask(ped, name)

        if not opts.loop then
            watchTask(ped, name, gen, function(p)
                return not IsEntityPlayingAnim(p, dict, anim, 3)
            end, opts)
        end

        return true
    end

    --- Starts a scenario on a ped, such as a sitting or leaning animation.
    ---
    --- This is a continuous task, it has no completion callback.
    ---
    ---@param ped number The ped to animate.
    ---@param scenario string The scenario name.
    ---@param opts table|nil Optional settings.
    --- - **duration** `number`: Time before the ped leaves the scenario, `0` keeps it. Default `0`.
    --- - **intro** `boolean`: Play the scenario intro clip. Default `true`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskScenario(ped, "WORLD_HUMAN_STAND_IMPATIENT")
    --- ```
    function pedTaskScenario(ped, scenario, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if not scenario then return false, "invalid scenario" end
        opts = opts or {}

        safeCall("pedTaskScenario", TaskStartScenarioInPlace, ped, scenario,
            opts.duration or 0, opts.intro ~= false)

        registerTask(ped, "scenario")
        return true
    end

    --- Makes a ped look at an entity or a set of coordinates.
    ---
    ---@param ped number The ped that looks.
    ---@param target vector3|vector4|table|number The entity or coordinates to look at.
    ---@param opts table|nil Optional settings.
    --- - **duration** `number`: Milliseconds to look. Default `5000`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskLookAt(ped, targetPed, { duration = 3000 })
    --- ```
    function pedTaskLookAt(ped, target, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local duration = opts.duration or 5000

        if type(target) == "number" and DoesEntityExist(target) then
            safeCall("pedTaskLookAt", TaskLookAtEntity, ped, target, duration, 1, 0)
        else
            local coords = resolveCoords(target)
            if not coords then return false, "invalid target" end
            safeCall("pedTaskLookAt", TaskLookAtCoord, ped, coords.x, coords.y, coords.z, duration, 1, 0)
        end

        registerTask(ped, "lookAt")
        return true
    end

    --- Makes a ped ragdoll for a set duration.
    ---
    ---@param ped number The ped to ragdoll.
    ---@param duration number Milliseconds to stay ragdolled. Default `5000`.
    ---@param opts table|nil Optional settings.
    --- - **type** `number`: Ragdoll type, `0` relaxes and anything else balances. Default `0`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskRagdoll(ped, 3000)
    --- ```
    function pedTaskRagdoll(ped, duration, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        local time = duration or 5000
        safeCall("pedTaskRagdoll", SetPedToRagdoll, ped, time, time, opts.type or 0, false, false, false)

        registerTask(ped, "ragdoll")
        return true
    end

    --- Makes a ped stand still for a set duration.
    ---
    ---@param ped number The ped to hold still.
    ---@param duration number Milliseconds to hold. Default `5000`.
    ---
    ---@return boolean True if the task was issued.
    ---@usage
    --- ```lua
    --- pedTaskStandStill(ped, 3000)
    --- ```
    function pedTaskStandStill(ped, duration)
        if not isValidPed(ped) then return false, "invalid ped" end

        safeCall("pedTaskStandStill", TaskStandStill, ped, duration or 5000)

        registerTask(ped, "standStill")
        return true
    end

    -------------------------------------------------------------
    -- Behaviour
    -------------------------------------------------------------

    --- Sets what a ped is allowed to do in combat.
    ---
    --- The native takes one attribute at a time, so every option you provide is applied
    --- individually. Options left out are not changed.
    ---
    ---@param ped number The ped to configure.
    ---@param opts table A table of named combat attributes set to `true` or `false`.
    --- See `combatAttributes` for the full list, for example `alwaysFight`, `canShoot`,
    --- `canUseCover`, `aggressive`, `perfectAccuracy` and `disableFleeFromCombat`.
    ---
    ---@return boolean True if the attributes were applied.
    ---@usage
    --- ```lua
    --- pedCombatAttributes(ped, { alwaysFight = true, canShoot = true, canUseCover = true })
    --- ```
    function pedCombatAttributes(ped, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        for name, enabled in pairs(opts) do
            local index = combatAttributes[name]
            if index then
                SetPedCombatAttributes(ped, index, enabled and true or false)
            else
                debugPrint("^6Bridge^7: ^3pedCombatAttributes^7: ^1unknown attribute^7 '^6"..tostring(name).."^7'")
            end
        end

        return true
    end

    --- Sets what a ped is allowed to do when it is fleeing.
    ---
    --- The native takes a bitmask, so each attribute is applied as `1 << bit`.
    --- FiveM only documents bit `15` as "force cower", the rest follow the game's
    --- flee attribute ordering, so use `pedSetFleeAttribute` if you need a specific bit.
    ---
    ---@param ped number The ped to configure.
    ---@param opts table A table keyed by flee attribute bit position, e.g. `{ [15] = true }`.
    ---
    ---@return boolean True if the attributes were applied.
    ---@usage
    --- ```lua
    --- pedFleeAttributes(ped, { [15] = true })
    --- ```
    function pedFleeAttributes(ped, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        for bit, enabled in pairs(opts) do
            if type(bit) == "number" then
                SetPedFleeAttributes(ped, 1 << bit, enabled and true or false)
            end
        end

        return true
    end

    --- Sets a single flee attribute on a ped by its bit position.
    ---
    ---@param ped number The ped to configure.
    ---@param bit number The flee attribute bit position, `15` is force cower.
    ---@param enabled boolean True to enable the attribute.
    ---
    ---@return boolean True if the attribute was applied.
    ---@usage
    --- ```lua
    --- pedSetFleeAttribute(ped, 15, true)
    --- ```
    function pedSetFleeAttribute(ped, bit, enabled)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(bit) ~= "number" then return false, "invalid bit" end

        SetPedFleeAttributes(ped, 1 << bit, enabled ~= false)
        return true
    end

    --- Sets how far a ped will engage in combat.
    ---
    ---@param ped number The ped to configure.
    ---@param range string|number "melee", "preferred", "far" or a raw value 0-2.
    ---
    ---@return boolean True if the range was applied.
    ---@usage
    --- ```lua
    --- pedCombatRange(ped, "melee")
    --- ```
    function pedCombatRange(ped, range)
        if not isValidPed(ped) then return false, "invalid ped" end

        local value = type(range) == "string" and combatRanges[range] or range
        if value == nil then return false, "invalid range" end

        SetPedCombatRange(ped, value)
        return true
    end

    --- Sets how well a ped fights, from `0` (poor) to `4` (very good).
    ---
    ---@param ped number The ped to configure.
    ---@param level number The combat ability level, 0-4.
    ---
    ---@return boolean True if the ability was applied.
    ---@usage
    --- ```lua
    --- pedCombatAbility(ped, 3)
    --- ```
    function pedCombatAbility(ped, level)
        if not isValidPed(ped) then return false, "invalid ped" end

        SetPedCombatAbility(ped, level or 0)
        return true
    end

    --- Sets how a ped moves while fighting.
    ---
    ---@param ped number The ped to configure.
    ---@param mode string|number "hold", "strafe", "advance" or a raw value 0-2.
    ---
    ---@return boolean True if the movement was applied.
    ---@usage
    --- ```lua
    --- pedCombatMovement(ped, "strafe")
    --- ```
    function pedCombatMovement(ped, mode)
        if not isValidPed(ped) then return false, "invalid ped" end

        local value = type(mode) == "string" and combatMovements[mode] or mode
        if value == nil then return false, "invalid movement" end

        SetPedCombatMovement(ped, value)
        return true
    end

    --- Sets a raw ped config flag, for anything the helpers above do not cover.
    ---
    ---@param ped number The ped to configure.
    ---@param flag number The config flag index.
    ---@param value boolean True to enable the flag.
    ---
    ---@return boolean True if the flag was applied.
    ---@usage
    --- ```lua
    --- pedSetConfigFlag(ped, 17, true) -- block non temporary events
    --- ```
    function pedSetConfigFlag(ped, flag, value)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(flag) ~= "number" then return false, "invalid flag" end

        SetPedConfigFlag(ped, flag, value ~= false)
        return true
    end

    --- Reads a raw ped config flag.
    ---
    ---@param ped number The ped to check.
    ---@param flag number The config flag index.
    ---
    ---@return boolean The value of the flag.
    ---@usage
    --- ```lua
    --- local blocksEvents = pedGetConfigFlag(ped, 17)
    --- ```
    function pedGetConfigFlag(ped, flag)
        if not isValidPed(ped) then return false end
        if type(flag) ~= "number" then return false end

        -- the native can hand back 1/0 instead of true/false, so normalise it
        return not not GetPedConfigFlag(ped, flag, false)
    end

    --- Sets a group of general states on a ped.
    ---
    --- Only the options provided are applied, everything else is left alone.
    ---
    ---@param ped number The ped to configure.
    ---@param opts table The states to apply.
    --- - **invincible** `boolean`: Cannot be hurt or killed.
    --- - **canRagdoll** `boolean`: Can be knocked over.
    --- - **dropsWeapons** `boolean`: Drops weapons on death.
    --- - **criticalHits** `boolean`: Suffers critical damage.
    --- - **canSwitchWeapon** `boolean`: Can change weapon.
    --- - **drunk** `boolean`: Staggered and unable to aim.
    --- - **armour** `number`: Armour value, 0-100.
    --- - **health** `number`: Health value.
    --- - **canBeDamaged** `boolean`: Can take damage.
    --- - **blocksEvents** `boolean`: Ignores scripted events.
    --- - **moveRate** `number`: Movement rate override, `1.0` is normal.
    --- - **density** `number`: Crowd density multiplier for this frame.
    ---
    ---@return boolean True if the states were applied.
    ---@usage
    --- ```lua
    --- pedState(ped, { invincible = true, canRagdoll = false, armour = 100 })
    --- ```
    function pedState(ped, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        opts = opts or {}

        if opts.invincible ~= nil then SetEntityInvincible(ped, opts.invincible) end
        if opts.canRagdoll ~= nil then SetPedCanRagdoll(ped, opts.canRagdoll) end
        if opts.dropsWeapons ~= nil then SetPedDropsWeaponsWhenDead(ped, opts.dropsWeapons) end
        if opts.criticalHits ~= nil then SetPedSuffersCriticalHits(ped, opts.criticalHits) end
        if opts.canSwitchWeapon ~= nil then SetPedCanSwitchWeapon(ped, opts.canSwitchWeapon) end
        if opts.drunk ~= nil then SetPedIsDrunk(ped, opts.drunk) end
        if opts.armour ~= nil then SetPedArmour(ped, opts.armour) end
        if opts.health ~= nil then SetEntityHealth(ped, opts.health) end
        if opts.canBeDamaged ~= nil then SetEntityCanBeDamaged(ped, opts.canBeDamaged) end
        if opts.blocksEvents ~= nil then SetBlockingOfNonTemporaryEvents(ped, opts.blocksEvents) end
        if opts.moveRate ~= nil then SetPedMoveRateOverride(ped, opts.moveRate) end
        if opts.density ~= nil then SetPedDensityMultiplierThisFrame(opts.density) end

        return true
    end

    -------------------------------------------------------------
    -- Tracking
    -------------------------------------------------------------

    --- Returns the name of the task currently assigned to a ped.
    ---
    ---@param ped number The ped to check.
    ---@return string|nil The task name, or nil if the ped has no tracked task.
    ---@usage
    --- ```lua
    --- if pedTaskStatus(ped) == "goTo" then print("on the move") end
    --- ```
    function pedTaskStatus(ped)
        if not PedTasks[ped] then return nil end
        return PedTasks[ped].current
    end

    --- Checks if a named task is currently assigned to a ped.
    ---
    ---@param ped number The ped to check.
    ---@param name string The task name to look for.
    ---@return boolean True if the task is running.
    ---@usage
    --- ```lua
    --- if pedTaskIsRunning(ped, "combat") then print("fighting") end
    --- ```
    function pedTaskIsRunning(ped, name)
        if not PedTasks[ped] then return false end
        return PedTasks[ped].tasks[name] == true
    end

    --- Checks if a native task is active on a ped by its task index.
    ---
    --- Use `pedTaskWanderIndex()` to get the index for the wander task.
    ---
    ---@param ped number The ped to check.
    ---@param index number The native task index.
    ---@return boolean True if the task is active.
    ---@usage
    --- ```lua
    --- if pedTaskActive(ped, pedTaskWanderIndex()) then print("wandering") end
    --- ```
    function pedTaskActive(ped, index)
        if not isValidPed(ped) then return false end
        if type(index) ~= "number" then return false end

        return GetIsTaskActive(ped, index)
    end

    --- Returns the native task index used by the wander task.
    ---
    ---@return number The task index.
    function pedTaskWanderIndex()
        return TASK_INDEX_WANDER
    end

    --- Cancels a task on a ped.
    ---
    --- GTA has no per task cancellation, so the ped's whole task queue is cleared.
    --- The `name` is used to confirm the task is still the one running before clearing.
    ---
    ---@param ped number The ped to cancel the task on.
    ---@param name string The task name to cancel.
    ---@return boolean True if the task was cancelled.
    ---@usage
    --- ```lua
    --- pedTaskCancel(ped, "goTo")
    --- ```
    function pedTaskCancel(ped, name)
        if not PedTasks[ped] then return false, "no task running" end
        if name and PedTasks[ped].current ~= name then return false, "task is not running" end

        ClearPedTasksImmediately(ped)

        TaskGen[ped] = TaskGen[ped] or {}
        if name then
            TaskGen[ped][name] = (TaskGen[ped][name] or 0) + 1
            unregisterTask(ped, name)
        else
            PedTasks[ped].current = nil
            PedTasks[ped].tasks = {}
        end

        debugPrint("^6Bridge^7: ^3pedTask^7: '^6"..(name or "all").."' ^1cancelled^7 for ped '^6"..ped.."'")
        return true
    end

    --- Clears every task on a ped and resets its tracking.
    ---
    ---@param ped number The ped to clear.
    ---@return boolean True if the ped was cleared.
    ---@usage
    --- ```lua
    --- pedTaskClear(ped)
    --- ```
    function pedTaskClear(ped)
        if not DoesEntityExist(ped) then return false, "invalid ped" end

        ClearPedTasksImmediately(ped)

        PedTasks[ped] = { current = nil, tasks = {} }
        TaskGen[ped] = {}

        return true
    end

    --- Waits for a condition to become true for a ped.
    ---
    --- Useful for chaining tasks together without needing a separate script thread.
    ---
    ---@param ped number The ped to watch.
    ---@param condition function A function taking the ped and returning true when done.
    ---@param opts table|nil Optional settings.
    --- - **timeout** `number`: Milliseconds before giving up. Default `15000`.
    --- - **interval** `number`: How often to check. Default `100`.
    --- - **onComplete** `function`: Called with the ped once the condition is met.
    --- - **onTimeout** `function`: Called with the ped if the condition is never met.
    ---
    ---@return boolean True if the wait was started.
    ---@usage
    --- ```lua
    --- pedTaskWait(ped, function(p) return #(GetEntityCoords(p) - target) < 3.0 end, {
    ---     onComplete = function(p) pedTaskPlayAnim(p, "dict", "anim") end,
    --- })
    --- ```
    function pedTaskWait(ped, condition, opts)
        if not isValidPed(ped) then return false, "invalid ped" end
        if type(condition) ~= "function" then return false, "invalid condition" end
        opts = opts or {}

        local name = "wait"
        local gen = registerTask(ped, name)
        local interval = opts.interval or 100

        CreateThread(function()
            local timeout = opts.timeout or 15000
            local start = GetGameTimer()

            while DoesEntityExist(ped) and (GetGameTimer() - start) < timeout do
                local ok, result = pcall(condition, ped)
                if ok and result then
                    if TaskGen[ped] and TaskGen[ped][name] == gen then
                        unregisterTask(ped, name)
                    end
                    if opts.onComplete then opts.onComplete(ped) end
                    return
                end
                Wait(interval)
            end

            if TaskGen[ped] and TaskGen[ped][name] == gen then
                unregisterTask(ped, name)
            end
            if opts.onTimeout then opts.onTimeout(ped) end
        end)

        return true
    end

    -------------------------------------------------------------
    -- Cleanup
    -------------------------------------------------------------

    --- Clears any outstanding tasks when the resource stops.
    onResourceStop(function()
        for ped in pairs(PedTasks) do
            if DoesEntityExist(ped) then
                ClearPedTasksImmediately(ped)
            end
        end
        PedTasks = {}
        TaskGen = {}
    end, true)
end
