import Foundation

// MARK: - Precision Trapezoidal Numerical Integrator
public struct PrecisionIntegratorState {
    public var dischargeAh: Double = 0.0
    public var dischargeWh: Double = 0.0
    public var rechargeAh: Double = 0.0
    public var rechargeWh: Double = 0.0
    
    public init() {}
    
    public mutating func reset() {
        dischargeAh = 0.0
        dischargeWh = 0.0
        rechargeAh = 0.0
        rechargeWh = 0.0
    }
}

public final class PrecisionIntegrationEngine {
    private(set) public var state = PrecisionIntegratorState()
    
    private var lastUptime: TimeInterval?
    private var lastCurrent: Double = 0.0
    private var lastPower: Double = 0.0
    
    private let zeroCurrentJitterThreshold: Double
    
    public init(zeroCurrentJitterThreshold: Double = 0.025) {
        self.zeroCurrentJitterThreshold = zeroCurrentJitterThreshold
    }
    
    public func reset() {
        state.reset()
        lastUptime = nil
        lastCurrent = 0.0
        lastPower = 0.0
    }
    
    public func step(uptime: TimeInterval, currentSignedAmps: Double, voltageVolts: Double) -> PrecisionIntegratorState {
        // 零点漂移死区抑制
        let cleanCurrent: Double
        if abs(currentSignedAmps) <= zeroCurrentJitterThreshold {
            cleanCurrent = 0.0
        } else {
            cleanCurrent = currentSignedAmps
        }
        
        let powerWatts = voltageVolts * cleanCurrent
        
        guard let prevTime = lastUptime else {
            lastUptime = uptime
            lastCurrent = cleanCurrent
            lastPower = powerWatts
            return state
        }
        
        let deltaTSeconds = uptime - prevTime
        
        // 过滤系统休眠、卡顿导致的异常跨度（> 5秒）或时钟反转
        if deltaTSeconds <= 0.0 || deltaTSeconds > 5.0 {
            lastUptime = uptime
            lastCurrent = cleanCurrent
            lastPower = powerWatts
            return state
        }
        
        let deltaTHours = deltaTSeconds / 3600.0
        
        // 梯形法则计算平均功率与电流
        let avgCurrent = (lastCurrent + cleanCurrent) / 2.0
        let avgPower = (lastPower + powerWatts) / 2.0
        
        if avgCurrent < 0.0 {
            state.dischargeAh += abs(avgCurrent) * deltaTHours
            state.dischargeWh += abs(avgPower) * deltaTHours
        } else if avgCurrent > 0.0 {
            state.rechargeAh += avgCurrent * deltaTHours
            state.rechargeWh += avgPower * deltaTHours
        }
        
        lastUptime = uptime
        lastCurrent = cleanCurrent
        lastPower = powerWatts
        
        return state
    }
}

// MARK: - Transient DCIR Calculator
public final class DCIRCalculator {
    private struct Sample {
        let uptime: TimeInterval
        let current: Double
        let voltage: Double
    }
    
    private var sampleRingBuffer: [Sample] = []
    private var recentEstimations: [Double] = []
    
    private let minStepDeltaAmps: Double
    private let maxStepWindowSeconds: TimeInterval
    private let ewmaAlpha: Double
    private var filteredInternalResistance: Double?
    
    public init(
        minStepDeltaAmps: Double = 1.0,
        maxStepWindowSeconds: TimeInterval = 2.0,
        ewmaAlpha: Double = 0.20
    ) {
        self.minStepDeltaAmps = minStepDeltaAmps
        self.maxStepWindowSeconds = maxStepWindowSeconds
        self.ewmaAlpha = ewmaAlpha
    }
    
    public func reset() {
        sampleRingBuffer.removeAll()
        recentEstimations.removeAll()
        filteredInternalResistance = nil
    }
    
    public func feed(uptime: TimeInterval, currentAmps: Double, voltageVolts: Double) -> Double? {
        let sample = Sample(uptime: uptime, current: currentAmps, voltage: voltageVolts)
        sampleRingBuffer.append(sample)
        
        sampleRingBuffer.removeAll { uptime - $0.uptime > maxStepWindowSeconds }
        
        guard let oldest = sampleRingBuffer.first else { return filteredInternalResistance }
        
        let deltaI = sample.current - oldest.current
        let deltaV = sample.voltage - oldest.voltage
        let deltaT = sample.uptime - oldest.uptime
        
        // 判定条件：
        // 1. 时间窗口在 0.8s ~ 2.0s 内
        // 2. 电流突变幅度满足阈值
        // 3. 关键物理定律约束：电压阶跃与电流突变反向（放电增加压降，充电增加压升）
        if abs(deltaI) >= minStepDeltaAmps && deltaT >= 0.8 && (deltaI * deltaV) < 0 {
            let resistanceOhms = abs(deltaV) / abs(deltaI)
            let resistanceMilliOhms = resistanceOhms * 1000.0
            
            // 聚合物电芯物理合理区间 (10mΩ ~ 600mΩ)
            if resistanceMilliOhms >= 10.0 && resistanceMilliOhms <= 600.0 {
                recentEstimations.append(resistanceMilliOhms)
                if recentEstimations.count > 5 {
                    recentEstimations.removeFirst()
                }
                
                let sorted = recentEstimations.sorted()
                let medianR = sorted[sorted.count / 2]
                
                if let currentEWMA = filteredInternalResistance {
                    filteredInternalResistance = (ewmaAlpha * medianR) + ((1.0 - ewmaAlpha) * currentEWMA)
                } else {
                    filteredInternalResistance = medianR
                }
                
                sampleRingBuffer.removeAll()
            }
        }
        
        return filteredInternalResistance
    }
}
