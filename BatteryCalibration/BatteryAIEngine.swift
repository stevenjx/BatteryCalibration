import Foundation

/// 基于硬件固件先验遥测与在线多周期滤波的电池 AI 估算引擎
public final class BatteryAIEngine: @unchecked Sendable {
    public static let shared = BatteryAIEngine()
    
    // MARK: - 状态量：滤波后的平滑功耗与 24 小时时段特征分布
    private var filteredPowerWatts: Double = 0.0
    private var powerVariance: Double = 1.0
    private let measurementNoise: Double = 0.45
    private let processNoise: Double = 0.04
    
    // 过去 24 小时各小时段平均功耗跟踪桶 (0 ~ 23)
    private var hourlyPowerSum: [Double] = Array(repeating: 0.0, count: 24)
    private var hourlyPowerCount: [Int] = Array(repeating: 0, count: 24)
    
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - 1. 卡尔曼滤波实时平滑整机瞬时功耗
    public func filterInstantPower(rawWatts: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        
        let absInput = max(0.5, abs(rawWatts))
        if filteredPowerWatts == 0.0 {
            filteredPowerWatts = absInput
            return filteredPowerWatts
        }
        
        let pEst = powerVariance + processNoise
        let kGain = pEst / (pEst + measurementNoise)
        filteredPowerWatts = filteredPowerWatts + kGain * (absInput - filteredPowerWatts)
        powerVariance = (1.0 - kGain) * pEst
        
        let currentHour = Calendar.current.component(.hour, from: Date())
        hourlyPowerSum[currentHour] += filteredPowerWatts
        hourlyPowerCount[currentHour] += 1
        
        return filteredPowerWatts
    }
    
    // MARK: - 2. 真实容量与真实健康度推理 (先验固件基准 + 多周期校准自适应)
    public func inferTrueHealth(
        history: [CalibrationHistoryRecord],
        designCapMAh: Double,
        hardwareMaxCapMAh: Double
    ) -> (trueCapacityMAh: Double, trueHealthPct: Double, confidence: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        let validDesign = designCapMAh > 0 ? designCapMAh : 6075.0
        // 系统固件基准（即系统设置读取的最大容量），若无法直接读取则以设计容量回退
        let baselineMaxCap = hardwareMaxCapMAh > 500 ? hardwareMaxCapMAh : validDesign
        
        let validHistory = history.filter { $0.calculatedCapacityMAh > 500 && $0.batteryHealthPercentage > 0 }
        
        // 当尚无有效校准记录时，以硬件电量计的真实最大容量作为绝对基准
        if validHistory.isEmpty {
            let trueHealth = min(100.0, max(1.0, (baselineMaxCap / validDesign) * 100.0))
            return (baselineMaxCap, trueHealth, 85.0)
        }
        
        // 当存在校准历史记录时，执行指数衰减加权在线融合
        var totalWeight: Double = 0.0
        var weightedCapacity: Double = 0.0
        
        for (idx, record) in validHistory.prefix(6).enumerated() {
            let decay = exp(-Double(idx) * 0.35)
            let coulombicFactor = record.coulombicEfficiency > 0 ? min(1.0, record.coulombicEfficiency / 100.0) : 0.95
            let finalWeight = decay * coulombicFactor
            
            totalWeight += finalWeight
            weightedCapacity += record.calculatedCapacityMAh * finalWeight
        }
        
        let calibratedCap = weightedCapacity / totalWeight
        // 融合硬件先验 (35%) 与实测校准轮次 (65%)
        let blendedCap = (calibratedCap * 0.65) + (baselineMaxCap * 0.35)
        let blendedHealth = min(100.0, max(1.0, (blendedCap / validDesign) * 100.0))
        let confidence = min(99.0, 85.0 + Double(validHistory.count) * 3.0)
        
        return (blendedCap, blendedHealth, confidence)
    }
    
    // MARK: - 3. 精准剩余续航推算 (修复 Wh 计算溢出问题)
    public func predictRemainingMinutes(
        currentPct: Int,
        currentVoltage: Double,
        smoothedPower: Double,
        trueFullCapMAh: Double
    ) -> Int {
        guard smoothedPower > 0.5, trueFullCapMAh > 0 else { return 0 }
        
        // 电池当前真实剩余容量 (mAh)
        let remainingMAh = trueFullCapMAh * (Double(currentPct) / 100.0)
        
        // 单节/组平均工作电压（标称取 11.4V ~ 12.0V 范围限制，防止除零或过高）
        let operationalVoltage = max(10.5, min(12.6, currentVoltage > 1.0 ? currentVoltage : 11.4))
        
        // 剩余可用总能量 (Wh) = mAh * V / 1000
        let remainingWh = (remainingMAh * operationalVoltage) / 1000.0
        
        // 提取时段典型消耗特征
        let currentHour = Calendar.current.component(.hour, from: Date())
        var historicalHourAvg = smoothedPower
        if hourlyPowerCount[currentHour] > 3 {
            historicalHourAvg = hourlyPowerSum[currentHour] / Double(hourlyPowerCount[currentHour])
        }
        
        // 动态混合平滑瞬时功耗与时段特征
        let blendedPower = (smoothedPower * 0.8) + (historicalHourAvg * 0.2)
        guard blendedPower >= 0.8 else { return 0 }
        
        let remainingHours = remainingWh / blendedPower
        let calculatedMinutes = Int(remainingHours * 60.0)
        
        // 上限合理化钳制在 24 小时以内，防止待机极低功耗产生虚高
        return min(1440, max(1, calculatedMinutes))
    }
}
