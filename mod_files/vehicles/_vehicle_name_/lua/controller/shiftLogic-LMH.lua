-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local max = math.max
local min = math.min
local abs = math.abs
local floor = math.floor
local fsign = fsign

local constants = {rpmToAV = 0.104719755, avToRPM = 9.549296596425384}

local newDesiredGearIndex = 0
local gearbox = nil
local engine = nil
local mgu_k = nil

local sharedFunctions = nil
local gearboxAvailableLogic = nil
local gearboxLogic = nil

M.gearboxHandling = nil
M.timer = nil
M.timerConstants = nil
M.inputValues = nil
M.shiftPreventionData = nil
M.shiftBehavior = nil
M.smoothedValues = nil

M.currentGearIndex = 0
M.throttle = 0
M.brake = 0
M.clutchRatio = 0
M.isArcadeSwitched = false
M.isSportModeActive = false

M.smoothedAvgAVInput = 0
M.rpm = 0
M.idleRPM = 0
M.maxRPM = 0

M.engineThrottle = 0
M.engineLoad = 0
M.engineTorque = 0
M.flywheelTorque = 0
M.gearboxTorque = 0

M.ignition = true
M.isEngineRunning = 0

M.oilTemp = 0
M.waterTemp = 0
M.checkEngine = false

M.energyStorages = {}

local clutchHandling = {
  clutchLaunchTargetAV = 0,
  clutchLaunchStartAV = 0,
  clutchLaunchIFactor = 0,
  lastClutchInput = 0
}

local neutralRejectTimer = 0 --used to reject shifts into neutral when using an H shifter
local neutralRejectTime = 0.5

local ignitionCutTime = 0.15

local function getGearName()
  return gearbox.gearIndex
end

local function getGearPosition()
  return 0 --TODO, implement once H-shifter patterns are possible with props
end

local function gearboxBehaviorChanged(behavior)
  gearboxLogic = gearboxAvailableLogic[behavior]
  M.updateGearboxGFXWrapped = gearboxLogic.inGear
  M.shiftUp = gearboxLogic.shiftUp
  M.shiftDown = gearboxLogic.shiftDown
  M.shiftToGearIndex = gearboxLogic.shiftToGearIndex

  if behavior == "realistic" and not M.gearboxHandling.autoClutch and abs(gearbox.gearIndex) == 1 then
    gearbox:setGearIndex(0)
  end
end

local function mgukPostGearChange(dt)
  if M.currentGearIndex > 0 then
    if obj:getGroundSpeed() > 33.3 then
      mgu_k.motorDirection = 1
    else
      mgu_k.motorDirection = 0
    end

    local lift_harvest = v.data.variables["$mgu_k_lift_harvest"].val
    local brake_harvest = v.data.variables["$mgu_k_brake_harvest"].val
    mgu_k.friction = 2 + ((1 - M.inputValues.throttle) * lift_harvest) + (M.inputValues.brake * brake_harvest)
  else
    mgu_k.motorDirection = 0
    mgu_k.friction = 2
  end
end

local function shiftUp()
  local prevGearIndex = gearbox.gearIndex
  local gearIndex = newDesiredGearIndex == 0 and gearbox.gearIndex + 1 or newDesiredGearIndex + 1
  gearIndex = min(max(gearIndex, gearbox.minGearIndex), gearbox.maxGearIndex)

  if M.gearboxHandling.gearboxSafety then
    local gearRatio = gearbox.gearRatios[newDesiredGearIndex]
    if gearbox.outputAV1 * gearRatio > engine.maxAV then
      gearIndex = prevGearIndex
    end
  end

  if gearbox.gearIndex ~= gearIndex then
    newDesiredGearIndex = gearIndex
    M.updateGearboxGFXWrapped = gearboxLogic.whileShifting
  end
end

local function shiftDown()
  local prevGearIndex = gearbox.gearIndex
  local gearIndex = newDesiredGearIndex == 0 and gearbox.gearIndex - 1 or newDesiredGearIndex - 1
  gearIndex = min(max(gearIndex, gearbox.minGearIndex), gearbox.maxGearIndex)

  if M.gearboxHandling.gearboxSafety then
    local gearRatio = gearbox.gearRatios[gearIndex]
    if gearbox.outputAV1 * gearRatio > engine.maxAV then
      gearIndex = prevGearIndex
    end
  end

  if gearbox.gearIndex ~= gearIndex then
    newDesiredGearIndex = gearIndex
    M.updateGearboxGFXWrapped = gearboxLogic.whileShifting
  end
end

local function shiftToGearIndex(index)
  local prevGearIndex = gearbox.gearIndex
  local gearIndex = min(max(index, gearbox.minGearIndex), gearbox.maxGearIndex)

  local maxIndex = min(prevGearIndex + 1, gearbox.maxGearIndex)
  local minIndex = max(prevGearIndex - 1, gearbox.minGearIndex)

  --adjust expected gearIndex based on sequential limits, otherwise the safety won't work correctly as it will see a 0 gearratio when going into N from higher gears
  gearIndex = min(max(gearIndex, minIndex), maxIndex)

  if M.gearboxHandling.gearboxSafety then
    local gearRatio = gearbox.gearRatios[gearIndex]
    if gearbox.outputAV1 * gearRatio > engine.maxAV then
      gearIndex = prevGearIndex
    end
  end

  if gearbox.gearIndex ~= gearIndex then
    newDesiredGearIndex = gearIndex
    if newDesiredGearIndex == 0 then
      neutralRejectTimer = neutralRejectTime
    end
    M.updateGearboxGFXWrapped = gearboxLogic.whileShifting
  end
end

local function updateExposedData()
  M.rpm = engine and (engine.outputAV1 * constants.avToRPM) or 0
  M.smoothedAvgAVInput = sharedFunctions.updateAvgAVSingleDevice("gearbox")
  M.waterTemp = (engine and engine.thermals) and (engine.thermals.coolantTemperature and engine.thermals.coolantTemperature or engine.thermals.oilTemperature) or 0
  M.oilTemp = (engine and engine.thermals) and engine.thermals.oilTemperature or 0
  M.checkEngine = engine and engine.isDisabled or false
  M.ignition = engine and (engine.ignitionCoef > 0 and not engine.isDisabled) or false
  M.engineThrottle = (engine and engine.isDisabled) and 0 or M.throttle
  M.engineLoad = engine and (engine.isDisabled and 0 or engine.instantEngineLoad) or 0
  M.running = engine and not engine.isDisabled or false
  M.engineTorque = engine and engine.combustionTorque or 0
  M.flywheelTorque = engine and engine.outputTorque1 or 0
  M.gearboxTorque = gearbox and gearbox.outputTorque1 or 0
  M.isEngineRunning = engine and ((engine.isStalled or engine.ignitionCoef <= 0) and 0 or 1) or 1
end

local function updateInGearArcade(dt)
  M.throttle = M.inputValues.throttle
  M.brake = M.inputValues.brake
  M.isArcadeSwitched = false
  M.isShifting = false

  local gearIndex = gearbox.gearIndex
  local engineAV = engine.outputAV1

  -- driving backwards? - only with automatic shift - for obvious reasons ;)
  if (gearIndex < 0 and M.smoothedValues.avgAV <= 0.15) or (gearIndex <= 0 and M.smoothedValues.avgAV < -1) then
    M.throttle, M.brake = M.brake, M.throttle
    M.isArcadeSwitched = true
  end

  --Arcade mode gets a "rev limiter" in case the engine does not have one
  if engineAV > engine.maxAV and not engine.hasRevLimiter then
    local throttleAdjust = min(max((engineAV - engine.maxAV * 1.02) / (engine.maxAV * 0.03), 0), 1)
    M.throttle = min(max(M.throttle - throttleAdjust, 0), 1)
  end

  if M.timer.gearChangeDelayTimer <= 0 and gearIndex ~= 0 then
    local tmpEngineAV = engineAV
    local relEngineAV = engineAV / gearbox.gearRatio

    sharedFunctions.selectShiftPoints(gearIndex)

    --shift down?
    local rpmTooLow = (tmpEngineAV < M.shiftBehavior.shiftDownAV) or (tmpEngineAV <= engine.idleAV * 1.05)
    if rpmTooLow and abs(gearIndex) > 1 and M.shiftPreventionData.wheelSlipShiftDown and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold then
      gearIndex = gearIndex - fsign(gearIndex)
      tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)
      if tmpEngineAV >= engine.maxAV * 0.85 then
        tmpEngineAV = relEngineAV / (gearbox.gearRatios[gearIndex] or 0)
        gearIndex = gearIndex + fsign(gearIndex)
      end
      sharedFunctions.selectShiftPoints(gearIndex)
    end

    local inGearRange = gearIndex < gearbox.maxGearIndex and gearIndex > gearbox.minGearIndex
    local clutchReady = M.clutchRatio >= 1
    local isRevLimitReached = engine.revLimiterActive and not (engine.isTempRevLimiterActive or false)
    local engineRevTooHigh = (tmpEngineAV >= M.shiftBehavior.shiftUpAV or isRevLimitReached)
    local throttleSpike = abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold
    local notBraking = M.brake <= 0
    --shift up?
    if clutchReady and engineRevTooHigh and M.shiftPreventionData.wheelSlipShiftUp and notBraking and throttleSpike and inGearRange then
      gearIndex = gearIndex + fsign(gearIndex)
      tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)
      if tmpEngineAV < engine.idleAV then
        gearIndex = gearIndex - fsign(gearIndex)
      end
      sharedFunctions.selectShiftPoints(gearIndex)
    end
  end

  -- neutral gear handling
  if abs(gearIndex) <= 1 and M.timer.neutralSelectionDelayTimer <= 0 then
    if gearIndex ~= 0 and abs(M.smoothedValues.avgAV) < M.gearboxHandling.arcadeAutoBrakeAVThreshold and M.throttle <= 0 then
      M.brake = max(M.inputValues.brake, M.gearboxHandling.arcadeAutoBrakeAmount)
    end

    if M.smoothedValues.throttleInput > 0 and M.smoothedValues.brakeInput <= 0 and M.smoothedValues.avgAV > -1 and gearIndex < 1 then
      gearIndex = 1
      M.timer.neutralSelectionDelayTimer = M.timerConstants.neutralSelectionDelay
    end

    if M.smoothedValues.brakeInput > 0 and M.smoothedValues.throttleInput <= 0 and M.smoothedValues.avgAV <= 0.15 and gearIndex > -1 then
      gearIndex = -1
      M.timer.neutralSelectionDelayTimer = M.timerConstants.neutralSelectionDelay
    end

    if engine.ignitionCoef < 1 and gearIndex ~= 0 then
      gearIndex = 0
      M.timer.neutralSelectionDelayTimer = M.timerConstants.neutralSelectionDelay
    end
  end

  if gearbox.gearIndex ~= gearIndex then
    newDesiredGearIndex = gearIndex
    M.updateGearboxGFXWrapped = gearboxLogic.whileShifting
  end

  -- Control clutch to buildup engine RPM
  if abs(gearIndex) == 1 and M.throttle > 0 then
    local ratio = max((engine.outputAV1 - clutchHandling.clutchLaunchStartAV * (1 + M.throttle)) / (clutchHandling.clutchLaunchTargetAV * (1 + clutchHandling.clutchLaunchIFactor)), 0)
    clutchHandling.clutchLaunchIFactor = min(clutchHandling.clutchLaunchIFactor + dt * 0.5, 1)
    M.clutchRatio = min(max(ratio * ratio, 0), 1)
  elseif M.throttle > 0 then
    if M.smoothedValues.avgAV * gearbox.gearRatio * engine.outputAV1 >= 0 then
      M.clutchRatio = 1
    elseif abs(gearbox.gearIndex) > 1 then
      M.brake = M.throttle
      M.throttle = 0
    end
    clutchHandling.clutchLaunchIFactor = 0
  end

  if M.inputValues.clutch > 0 then
    if M.inputValues.clutch < clutchHandling.lastClutchInput then
      M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
    end
    M.clutchRatio = min(1 - M.inputValues.clutch, M.clutchRatio)
  end

  --always prevent stalling
  if engine.outputAV1 < engine.idleAV then
    M.clutchRatio = 0
  end

  if (M.throttle > 0.5 and M.brake > 0.5 and electrics.values.wheelspeed < 2) or gearbox.lockCoef < 1 then
    M.clutchRatio = 0
  end

  if M.clutchRatio < 1 and abs(gearIndex) == 1 then
    M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
  end

  clutchHandling.lastClutchInput = M.inputValues.clutch

  M.currentGearIndex = gearIndex
  updateExposedData()
end

local function updateWhileShiftingArcade(dt)
  M.throttle = M.inputValues.throttle
  M.brake = M.inputValues.brake
  M.isArcadeSwitched = false
  M.isShifting = true

  local gearIndex = gearbox.gearIndex
  if (gearIndex < 0 and M.smoothedValues.avgAV <= 0.15) or (gearIndex <= 0 and M.smoothedValues.avgAV < -1) then
    M.throttle, M.brake = M.brake, M.throttle
    M.isArcadeSwitched = true
  end
  if newDesiredGearIndex > gearIndex and gearIndex > 0 and M.throttle > 0 then
    engine:cutIgnition(ignitionCutTime)
  end

  gearbox:setGearIndex(newDesiredGearIndex)
  newDesiredGearIndex = 0
  M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
  M.updateGearboxGFXWrapped = gearboxLogic.inGear
  updateExposedData()
  --mgukPostGearChange()
end

local function updateInGear(dt)
  M.throttle = M.inputValues.throttle
  M.brake = M.inputValues.brake
  M.isArcadeSwitched = false
  M.isShifting = false

  -- Control clutch to buildup engine RPM
  if M.gearboxHandling.autoClutch then
    if abs(gearbox.gearIndex) == 1 and M.throttle > 0 then
      local ratio = max((engine.outputAV1 - clutchHandling.clutchLaunchStartAV * (1 + M.throttle)) / (clutchHandling.clutchLaunchTargetAV * (1 + clutchHandling.clutchLaunchIFactor)), 0)
      clutchHandling.clutchLaunchIFactor = min(clutchHandling.clutchLaunchIFactor + dt * 0.5, 1)
      M.clutchRatio = min(max(ratio * ratio, 0), 1)
    elseif M.throttle > 0 then
      if gearbox.outputAV1 * gearbox.gearRatio * engine.outputAV1 >= 0 then
        M.clutchRatio = 1
      elseif abs(gearbox.gearIndex) > 1 then
        local ratio = max((engine.outputAV1 - clutchHandling.clutchLaunchStartAV * (1 + M.throttle)) / (clutchHandling.clutchLaunchTargetAV * (1 + clutchHandling.clutchLaunchIFactor)), 0)
        clutchHandling.clutchLaunchIFactor = min(clutchHandling.clutchLaunchIFactor + dt * 0.5, 1)
        M.clutchRatio = min(max(ratio * ratio, 0), 1)
      end
      clutchHandling.clutchLaunchIFactor = 0
    end

    if M.inputValues.clutch > 0 then
      M.clutchRatio = min(1 - M.inputValues.clutch, M.clutchRatio)
    end

    --always prevent stalling
    if engine.outputAV1 < engine.idleAV then
      M.clutchRatio = 0
    end

    if (M.throttle > 0.5 and M.brake > 0.5 and electrics.values.wheelspeed < 2) or gearbox.lockCoef < 1 then
      M.clutchRatio = 0
    end

    if M.clutchRatio < 1 and abs(gearbox.gearIndex) == 1 then
      M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
    end

    if engine.isDisabled then
      M.clutchRatio = min(1 - M.inputValues.clutch, 1)
    end

    if engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0) then
      M.clutchRatio = 0
    end
  else
    M.clutchRatio = 1 - M.inputValues.clutch
  end
  M.currentGearIndex = gearbox.gearIndex
  updateExposedData()
  --mgukPostGearChange()
end

local function updateWhileShifting(dt)
  -- old -> N -> wait -> new -> in gear update
  M.brake = M.inputValues.brake
  M.throttle = M.inputValues.throttle
  M.isArcadeSwitched = false
  M.isShifting = true

  --if we are shifting into neutral we need to delay this a little bit because the user might use an H pattern shifter which goes through neutral on every shift
  --if we were not to delay this neutral shift, the user can't get out of 1st gear due to gear change limitations of the sequential
  --so only shift to neutral if the new desired gear is still neutral after 0.x seconds (ie the user actually left the H shifter in neutral and did not move to the next gear)
  if newDesiredGearIndex == 0 and neutralRejectTimer > 0 then
    neutralRejectTimer = neutralRejectTimer - dt
  else
    if newDesiredGearIndex > gearbox.gearIndex and gearbox.gearIndex > 0 and M.throttle > 0 then
      engine:cutIgnition(ignitionCutTime)
    end

    gearbox:setGearIndex(newDesiredGearIndex)
    newDesiredGearIndex = 0
    M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
    M.updateGearboxGFXWrapped = gearboxLogic.inGear
  end

  updateExposedData()
end

local function sendTorqueData()
  if engine then
    engine:sendTorqueData()
  end
  if mgu_k then
    mgu_k:sendTorqueData()
  end

end

local function init(jbeamData, sharedFunctionTable)
  sharedFunctions = sharedFunctionTable
  engine = powertrain.getDevice("mainEngine")
  mgu_k = powertrain.getDevice("mgukEngine")
  gearbox = powertrain.getDevice("gearbox")
  newDesiredGearIndex = 0

  M.currentGearIndex = 0
  M.throttle = 0
  M.brake = 0
  M.clutchRatio = 0

  ignitionCutTime = jbeamData.ignitionCutTime or 0.15

  gearboxAvailableLogic = {
    arcade = {
      inGear = updateInGearArcade,
      whileShifting = updateWhileShiftingArcade,
      shiftUp = sharedFunctions.warnCannotShiftSequential,
      shiftDown = sharedFunctions.warnCannotShiftSequential,
      shiftToGearIndex = sharedFunctions.switchToRealisticBehavior
    },
    realistic = {
      inGear = updateInGear,
      whileShifting = updateWhileShifting,
      shiftUp = shiftUp,
      shiftDown = shiftDown,
      shiftToGearIndex = shiftToGearIndex
    }
  }

  clutchHandling.clutchLaunchTargetAV = (jbeamData.clutchLaunchTargetRPM or 3000) * constants.rpmToAV * 0.5
  clutchHandling.clutchLaunchStartAV = ((jbeamData.clutchLaunchStartRPM or 2000) * constants.rpmToAV - engine.idleAV) * 0.5
  clutchHandling.clutchLaunchIFactor = 0
  clutchHandling.lastClutchInput = 0

  M.maxRPM = engine.maxRPM
  M.idleRPM = engine.idleRPM
  M.maxGearIndex = gearbox.maxGearIndex
  M.minGearIndex = abs(gearbox.minGearIndex)
  M.energyStorages = sharedFunctions.getEnergyStorages({engine})
end

local function mgukMotorUpdate(dt)
  -- Cycle through strategies
  if electrics.values.ers_strategy == nil then
    electrics.values.ers_strategy = 0
  end

  if electrics.values.ers_strategy > 2 then
    electrics.values.ers_strategy = 0
  end

  -- Only a single battery supported, the first found will be used
  local storage = nil
  if mgu_k.energyStorage then
    for _, s in pairs(mgu_k.registeredEnergyStorages) do
      storage = energyStorage.getStorage(s)
      if storage then
        electrics.values.ers_battery = storage.storedEnergy / storage.energyCapacity
        break
      end
    end
  end
  -- Regenerate battery if friction > 2
  if mgu_k.friction > 2 then
    local engineAV = mgu_k.outputAV1
    local dtT = dt * mgu_k.friction * (-1)
    local grossWork = dtT * (dtT * mgu_k.halfInvEngInertia + engineAV)
    local spentEnergy = grossWork / mgu_k.electricalEfficiencyTable[floor(mgu_k.engineLoad * 100) * 0.01]
    local storageRatio = mgu_k.energyStorageRegenRatios[storage.name]
    storage.storedEnergy = clamp(storage.storedEnergy - (spentEnergy * storageRatio), 0, storage.energyCapacity)
  end
  -- Disable ERS overtake override if brakes are applied
  if M.brake > 0 then
    electrics.values.ers_overtake = 0
  end
  if (electrics.values.ers_overtake or 0) == 1 then
    if obj:getGroundSpeed() > 33.3 then
      electrics.values.mgukThrottle = M.throttle
    end
  else
    if electrics.values.ers_strategy == 0 then -- Conservative strategy (Default)
      if obj:getGroundSpeed() > 69.9 or obj:getGroundSpeed() < 33.3 then
        electrics.values.mgukThrottle = 0
      else
        electrics.values.mgukThrottle = M.throttle * (1.18 - 1.05^(obj:getGroundSpeed()-66.6))
      end
    elseif electrics.values.ers_strategy == 1 then -- Power
      if obj:getGroundSpeed() > 80.7 or obj:getGroundSpeed() < 33.3 then
        electrics.values.mgukThrottle = 0
      else
        electrics.values.mgukThrottle = M.throttle * (1.01 - 1.1^(obj:getGroundSpeed()-80.6))
      end
    elseif electrics.values.ers_strategy == 2 then -- Disabled
      electrics.values.mgukThrottle = 0
    end
  end
end

local function updateGearboxGFXwrapper(dt)
  mgukMotorUpdate(dt)
  M.updateGearboxGFXWrapped(dt)
  mgukPostGearChange(dt)
end

M.init = init

M.gearboxBehaviorChanged = gearboxBehaviorChanged
M.shiftUp = shiftUp
M.shiftDown = shiftDown
M.shiftToGearIndex = shiftToGearIndex
M.updateGearboxGFX = updateGearboxGFXwrapper
M.updateGearboxGFXWrapped = nop
M.getGearName = getGearName
M.getGearPosition = getGearPosition
M.sendTorqueData = sendTorqueData

return M
