import Foundation
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import AppKit
import UserNotifications

// MARK: - 屏幕亮度控制
private typealias DisplayServicesSetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DisplayServicesGetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

nonisolated private final class ScreenBrightnessController: @unchecked Sendable {
    static let shared = ScreenBrightnessController()
    private var originalBrightness: Float? = nil
    private let lock = NSLock()
    
    private let setBrightnessPtr: DisplayServicesSetBrightnessFunc?
    private let getBrightnessPtr: DisplayServicesGetBrightnessFunc?
    
    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let h = handle {
            if let symSet = dlsym(h, "DisplayServicesSetBrightness") {
                self.setBrightnessPtr = unsafeBitCast(symSet, to: DisplayServicesSetBrightnessFunc.self)
            } else {
                self.setBrightnessPtr = nil
            }
            if let symGet = dlsym(h, "DisplayServicesGetBrightness") {
                self.getBrightnessPtr = unsafeBitCast(symGet, to: DisplayServicesGetBrightnessFunc.self)
            } else {
                self.getBrightnessPtr = nil
            }
        } else {
            self.setBrightnessPtr = nil
            self.getBrightnessPtr = nil
        }
    }
    
    func dimForFastCharge() {
        lock.lock()
        defer { lock.unlock() }
        guard let setFunc = setBrightnessPtr, let getFunc = getBrightnessPtr else { return }
        let mainDisplay = CGMainDisplayID()
        var current: Float = 0.5
        if getFunc(mainDisplay, &current) == 0 && originalBrightness == nil {
            originalBrightness = current
        }
        _ = setFunc(mainDisplay, 0.08)
    }
    
    func restoreBrightness() {
        lock.lock()
        defer { lock.unlock() }
        guard let setFunc = setBrightnessPtr, let orig = originalBrightness else { return }
        _ = setFunc(CGMainDisplayID(), orig)
        originalBrightness = nil
    }
}

enum DischargeStressMode: String, CaseIterable, Identifiable {
    case silent = "静音"
    case balanced = "均衡"
    case aggressive = "激进"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .silent: return "常规放电 (0% CPU)"
        case .balanced: return "中度负载 ~20W (50% 核心)"
        case .aggressive: return "快速放电 50W+ (多核满载)"
        }
    }
}

enum CalibrationPhase: String {
    case waitingForTrigger = "待机"
    case chargingToFull = "初充阶段 (充至 100%)"
    case discharging = "校准放电 (放至 10%)"
    case rechargingToFull = "回充阶段 (充至 100%)"
    case completed = "校准完成"
}

struct CalibrationDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let percentage: Double
    let power: Double
    let voltage: Double
    let amperage: Double
    let temperature: Double
}

public struct AggregatedBatteryHealth {
    public let validSessionsCount: Int
    public let trueCapacityMAh: Double
    public let trueCapacityWh: Double
    public let trueHealthPercentage: Double
    public let confidenceScore: Double
}

@MainActor final class BatteryCalibrationManager: ObservableObject {
    @Published var currentPhase: CalibrationPhase = .waitingForTrigger
    @Published var currentPercentage: Int = 0
    @Published var currentVoltage: Double = 0.0
    @Published var signedAmperage: Double = 0.0
    @Published var currentAmperage: Double = 0.0
    @Published var currentPower: Double = 0.0
    @Published var currentTemperature: Double = 0.0
    
    @Published var designCapacityMAh: Double = 0.0
    @Published var cycleCount: Int = 0
    @Published var batterySerialNumber: String = "--"
    @Published var hardwareModel: String = "--"
    
    @Published var isCharging: Bool = false
    @Published var isExternalConnected: Bool = false
    @Published var isDischargingOnAC: Bool = false
    @Published var isAlDenteRunning: Bool = false
    @Published var isAlDenteCalibrating: Bool = false
    
    @Published var internalResistanceMilliohm: Double = 0.0
    
    @Published var stressMode: DischargeStressMode = .balanced {
        didSet {
            if isSessionRunning && currentPhase == .discharging {
                startStressLoad()
            }
        }
    }
    
    private var rawHistoryPoints: [CalibrationDataPoint] = []
    @Published private(set) var chartDisplayPoints: [CalibrationDataPoint] = []
    @Published private(set) var dischargeCurvePoints: [CalibrationDataPoint] = []
    
    @Published var dischargeEnergyWh: Double = 0.0
    @Published var dischargeEnergyAh: Double = 0.0
    @Published var calculatedCapacityWh: Double = 0.0
    @Published var calculatedCapacityMAh: Double = 0.0
    @Published var batteryHealthPercentage: Double = 0.0
    @Published var estimatedRemainingMinutes: Int = 0
    @Published var totalDischargeRuntimeMinutes: Int = 0
    
    @Published var aggregatedHealth: AggregatedBatteryHealth? = nil
    
    @Published var dischargeElapsedSeconds: TimeInterval = 0
    @Published var dischargeAveragePower: Double = 0.0
    @Published var finalDischargeDurationText: String = "--"
    
    @Published var rechargeEnergyWh: Double = 0.0
    @Published var rechargeEnergyAh: Double = 0.0
    @Published var coulombicEfficiency: Double = 0.0
    
    @Published var logHistory: [String] = []
    @Published var lastReportURL: URL? = nil
    @Published var lastCSVURL: URL? = nil
    @Published var isThermalCutoffActive: Bool = false
    @Published var isFastChargeThrottlingActive: Bool = false
    
    @Published var historyRecords: [CalibrationHistoryRecord] = []
    
    // 用户可配置的高级设置项
    @Published var highTempThreshold: Double {
        didSet { UserDefaults.standard.set(highTempThreshold, forKey: "highTempThreshold") }
    }
    @Published var resumeTempThreshold: Double {
        didSet { UserDefaults.standard.set(resumeTempThreshold, forKey: "resumeTempThreshold") }
    }
    @Published var dischargeTargetPercentage: Int {
        didSet { UserDefaults.standard.set(dischargeTargetPercentage, forKey: "dischargeTargetPercentage") }
    }
    @Published var autoExportReports: Bool {
        didSet { UserDefaults.standard.set(autoExportReports, forKey: "autoExportReports") }
    }
    @Published var soundAlertEnabled: Bool {
        didSet { UserDefaults.standard.set(soundAlertEnabled, forKey: "soundAlertEnabled") }
    }
    
    private let precisionEngine = PrecisionIntegrationEngine(zeroCurrentJitterThreshold: 0.025)
    private let dcirCalculator = DCIRCalculator(minStepDeltaAmps: 1.0, maxStepWindowSeconds: 2.0)
    
    private var assertionID: IOPMAssertionID = 0
    private var isAssertionActive: Bool = false
    private var monitorTask: Task<Void, Never>?
    private var stressTasks: [Task<Void, Never>] = []
    
    private var sessionStartDate: Date?
    private var dischargePhaseStartDate: Date?
    private var startDischargePercentage: Int = 100
    private(set) var isSessionRunning: Bool = false
    private var downsampleCounter: Int = 0
    private var sessionRecordedPoints: [CalibrationDataPoint] = []
    
    private let alDenteBundleID = "com.apphousekitchen.aldente-pro"
    
    init() {
        let storedHigh = UserDefaults.standard.double(forKey: "highTempThreshold")
        self.highTempThreshold = storedHigh > 0 ? storedHigh : 45.0
        
        let storedResume = UserDefaults.standard.double(forKey: "resumeTempThreshold")
        self.resumeTempThreshold = storedResume > 0 ? storedResume : 39.0
        
        let storedTarget = UserDefaults.standard.integer(forKey: "dischargeTargetPercentage")
        self.dischargeTargetPercentage = storedTarget > 0 ? storedTarget : 10
        
        let storedExport = UserDefaults.standard.object(forKey: "autoExportReports")
        self.autoExportReports = (storedExport as? Bool) ?? true
        
        let storedSound = UserDefaults.standard.object(forKey: "soundAlertEnabled")
        self.soundAlertEnabled = (storedSound as? Bool) ?? true
        
        requestNotificationPermission()
        fetchHardwareInfo()
        fetchBatteryDetails()
        checkAlDenteStatus()
        self.historyRecords = HistoryStorageManager.shared.loadHistory()
        recalculateMultiSessionHealth()
        startMonitoringEngine()
    }
    
    deinit {
        monitorTask?.cancel()
        for task in stressTasks {
            task.cancel()
        }
        if isAssertionActive {
            IOPMAssertionRelease(assertionID)
        }
        ScreenBrightnessController.shared.restoreBrightness()
    }
    
    private func fetchHardwareInfo() {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        self.hardwareModel = String(cString: model)
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                Task { @MainActor in
                    self.appendLog("已获取系统本地通知权限")
                }
            }
        }
    }
    
    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        if soundAlertEnabled {
            NSSound.beep()
        }
    }
    
    func startMonitoringEngine() {
        appendLog("启动 AppleSmartBattery 遥测引擎...")
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.monitorTick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    
    private func monitorTick() {
        fetchBatteryDetails()
        checkAlDenteStatus()
        
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        
        if let calculatedR = dcirCalculator.feed(uptime: uptime, currentAmps: signedAmperage, voltageVolts: currentVoltage) {
            self.internalResistanceMilliohm = calculatedR
        }
        
        let point = CalibrationDataPoint(
            timestamp: now,
            percentage: Double(currentPercentage),
            power: currentPower,
            voltage: currentVoltage,
            amperage: signedAmperage,
            temperature: currentTemperature
        )
        
        rawHistoryPoints.append(point)
        if rawHistoryPoints.count > 3600 {
            rawHistoryPoints.removeFirst()
        }
        
        downsampleCounter += 1
        if downsampleCounter >= 4 || chartDisplayPoints.isEmpty {
            downsampleCounter = 0
            updateDownsampledChartPoints()
        }
        
        if isAlDenteCalibrating && !isSessionRunning {
            appendLog("检测到 AlDente Pro 启动电池校准，开始自动协同记录...")
            startCalibrationSession()
        } else if !isAlDenteCalibrating && isSessionRunning {
            appendLog("检测到 AlDente Pro 已停止校准，自动终止并同步结算...")
            stopCalibrationSession()
        }
        
        guard isSessionRunning else {
            _ = precisionEngine.step(uptime: uptime, currentSignedAmps: signedAmperage, voltageVolts: currentVoltage)
            return
        }
        
        sessionRecordedPoints.append(point)
        handleThermalCutoff()
        
        let integratedState = precisionEngine.step(uptime: uptime, currentSignedAmps: signedAmperage, voltageVolts: currentVoltage)
        
        if currentPhase == .chargingToFull {
            let hasEnteredDischarge = signedAmperage < -0.05 || isDischargingOnAC
            let isFullAndReady = currentPercentage >= 100 && signedAmperage <= 0.05
            
            if hasEnteredDischarge || isFullAndReady {
                currentPhase = .discharging
                startDischargePercentage = currentPercentage
                sessionStartDate = Date()
                dischargePhaseStartDate = Date()
                dischargeCurvePoints.removeAll()
                dischargeCurvePoints.append(point)
                appendLog("电池已充至 \(currentPercentage)%，进入校准放电阶段 [\(stressMode.rawValue)]...")
                sendLocalNotification(
                    title: "开始校准放电",
                    body: "AlDente 已切入旁路放电，App 正在同步记录高精度曲线"
                )
                startStressLoad()
            }
        } else if currentPhase == .discharging {
            dischargeCurvePoints.append(point)
            dischargeEnergyWh = integratedState.dischargeWh
            dischargeEnergyAh = integratedState.dischargeAh
            
            if let start = dischargePhaseStartDate {
                let elapsed = now.timeIntervalSince(start)
                self.dischargeElapsedSeconds = elapsed
                
                if elapsed > 10.0 {
                    let elapsedHours = elapsed / 3600.0
                    self.dischargeAveragePower = dischargeEnergyWh / elapsedHours
                } else {
                    self.dischargeAveragePower = currentPower
                }
            }
            
            let deltaPercent = Double(startDischargePercentage - currentPercentage) / 100.0
            if deltaPercent >= 0.01 {
                calculatedCapacityWh = dischargeEnergyWh / deltaPercent
                calculatedCapacityMAh = (dischargeEnergyAh / deltaPercent) * 1000.0
                
                if designCapacityMAh > 0 {
                    batteryHealthPercentage = (calculatedCapacityMAh / designCapacityMAh) * 100.0
                }
                
                let percentDropped = Double(startDischargePercentage - currentPercentage)
                if percentDropped > 0 && dischargeElapsedSeconds > 10.0 {
                    let secondsPerPercent = dischargeElapsedSeconds / percentDropped
                    let percentRemaining = max(0.0, Double(currentPercentage - dischargeTargetPercentage))
                    estimatedRemainingMinutes = Int((percentRemaining * secondsPerPercent) / 60.0)
                    
                    let totalDropRange = max(10.0, Double(startDischargePercentage - dischargeTargetPercentage))
                    let totalEstimatedSeconds = totalDropRange * secondsPerPercent
                    totalDischargeRuntimeMinutes = Int(totalEstimatedSeconds / 60.0)
                }
            }
            
            if currentPercentage <= dischargeTargetPercentage {
                let h = Int(dischargeElapsedSeconds) / 3600
                let m = (Int(dischargeElapsedSeconds) % 3600) / 60
                self.finalDischargeDurationText = "\(h)小时\(m)分 (均耗 \(String(format: "%.1f", dischargeAveragePower))W)"
                appendLog("已达放电终点 (\(dischargeTargetPercentage)%)，耗时: \(h)小时\(m)分，平均功率: \(String(format: "%.2f", dischargeAveragePower)) W")
                
                stopStressLoad()
                currentPhase = .rechargingToFull
                applyFastChargingOptimization(enable: true)
                
                sendLocalNotification(
                    title: "放电校准阶段结束",
                    body: "电池已放至目标值，正在等待 AlDente 回充至 100%"
                )
            }
        } else if currentPhase == .rechargingToFull {
            rechargeEnergyWh = integratedState.rechargeWh
            rechargeEnergyAh = integratedState.rechargeAh
            
            if dischargeEnergyAh > 0 && rechargeEnergyAh > 0 {
                coulombicEfficiency = (dischargeEnergyAh / rechargeEnergyAh) * 100.0
            }
            
            if currentPercentage >= 100 && signedAmperage < 0.15 {
                applyFastChargingOptimization(enable: false)
                finishCalibration()
            }
        }
    }
    
    private func applyFastChargingOptimization(enable: Bool) {
        isFastChargeThrottlingActive = enable
        if enable {
            stopStressLoad()
            ScreenBrightnessController.shared.dimForFastCharge()
            appendLog("回充优化已激活: 释放测试负载，降低屏幕背光")
        } else {
            ScreenBrightnessController.shared.restoreBrightness()
            appendLog("回充优化解除: 恢复屏幕背光")
        }
    }
    
    private func updateDownsampledChartPoints() {
        let bucketSize = 8
        guard rawHistoryPoints.count > bucketSize else {
            chartDisplayPoints = rawHistoryPoints
            return
        }
        
        var result: [CalibrationDataPoint] = []
        result.reserveCapacity((rawHistoryPoints.count / bucketSize) + 1)
        
        for i in stride(from: 0, to: rawHistoryPoints.count, by: bucketSize) {
            let endIndex = min(i + bucketSize, rawHistoryPoints.count)
            let slice = rawHistoryPoints[i..<endIndex]
            
            let count = Double(slice.count)
            let avgPercentage = slice.reduce(0.0) { $0 + $1.percentage } / count
            let avgPower = slice.reduce(0.0) { $0 + $1.power } / count
            let avgVoltage = slice.reduce(0.0) { $0 + $1.voltage } / count
            let avgAmp = slice.reduce(0.0) { $0 + $1.amperage } / count
            let avgTemp = slice.reduce(0.0) { $0 + $1.temperature } / count
            
            result.append(CalibrationDataPoint(
                timestamp: slice.last?.timestamp ?? Date(),
                percentage: avgPercentage,
                power: avgPower,
                voltage: avgVoltage,
                amperage: avgAmp,
                temperature: avgTemp
            ))
        }
        chartDisplayPoints = result
    }
    
    private func handleThermalCutoff() {
        guard currentPhase == .discharging else { return }
        
        if currentTemperature >= highTempThreshold && !isThermalCutoffActive {
            isThermalCutoffActive = true
            stopStressLoad()
            sendLocalNotification(
                title: "温度熔断保护",
                body: "电池温度达 \(String(format: "%.1f", currentTemperature))°C，已暂停放电负载"
            )
            appendLog("过热熔断: \(String(format: "%.1f", currentTemperature))°C >= 阈值 \(highTempThreshold)°C，暂停负载")
        } else if currentTemperature <= resumeTempThreshold && isThermalCutoffActive {
            isThermalCutoffActive = false
            startStressLoad()
            sendLocalNotification(
                title: "温度恢复",
                body: "电池温度降至 \(String(format: "%.1f", currentTemperature))°C，继续放电负载"
            )
            appendLog("温度恢复: \(String(format: "%.1f", currentTemperature))°C <= 阈值 \(resumeTempThreshold)°C，继续负载")
        }
    }
    
    func startCalibrationSession() {
        guard !isSessionRunning else { return }
        
        isSessionRunning = true
        
        precisionEngine.reset()
        dcirCalculator.reset()
        
        dischargeEnergyWh = 0.0
        dischargeEnergyAh = 0.0
        rechargeEnergyWh = 0.0
        rechargeEnergyAh = 0.0
        coulombicEfficiency = 0.0
        calculatedCapacityWh = 0.0
        calculatedCapacityMAh = 0.0
        batteryHealthPercentage = 0.0
        estimatedRemainingMinutes = 0
        totalDischargeRuntimeMinutes = 0
        dischargeElapsedSeconds = 0
        dischargeAveragePower = 0.0
        finalDischargeDurationText = "--"
        internalResistanceMilliohm = 0.0
        isThermalCutoffActive = false
        sessionRecordedPoints.removeAll()
        dischargeCurvePoints.removeAll()
        sessionStartDate = Date()
        
        enablePreventSleep()
        appendLog(">>> 开始电池深度校准协同会话 <<<")
        
        if signedAmperage < -0.05 || isDischargingOnAC {
            currentPhase = .discharging
            startDischargePercentage = currentPercentage
            dischargePhaseStartDate = Date()
            appendLog("检测到放电状态，立即同步放电记录...")
            startStressLoad()
        } else {
            currentPhase = .chargingToFull
            dischargePhaseStartDate = nil
            appendLog("当前电量 \(currentPercentage)%，配合 AlDente 进行初充至 100%...")
            stopStressLoad()
        }
    }
    
    func stopCalibrationSession() {
        applyFastChargingOptimization(enable: false)
        stopStressLoad()
        disablePreventSleep()
        isSessionRunning = false
        currentPhase = .waitingForTrigger
        appendLog("校准会话已终止")
    }
    
    private func finishCalibration() {
        applyFastChargingOptimization(enable: false)
        stopStressLoad()
        disablePreventSleep()
        isSessionRunning = false
        currentPhase = .completed
        
        let dischargeFormatted = String(format: "%.2f", dischargeEnergyWh)
        let rechargeFormatted = String(format: "%.2f", rechargeEnergyWh)
        let capacityFormatted = String(format: "%.2f", calculatedCapacityWh)
        let mahFormatted = String(format: "%.0f", calculatedCapacityMAh)
        let healthFormatted = designCapacityMAh > 0 ? String(format: "%.1f%%", batteryHealthPercentage) : "--"
        let coulombicFormatted = rechargeEnergyAh > 0 ? String(format: "%.1f%%", coulombicEfficiency) : "--"
        let dcirFormatted = internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--"
        
        appendLog("==========================================")
        appendLog("            电池校准完整报告             ")
        appendLog("放电耗时: \(finalDischargeDurationText)")
        appendLog("实测放电: \(dischargeFormatted) Wh | 实测回充: \(rechargeFormatted) Wh")
        appendLog("推算实际容量: \(capacityFormatted) Wh (\(mahFormatted) mAh) | 实测健康度: \(healthFormatted)")
        appendLog("库仑效率 (Coulombic Efficiency): \(coulombicFormatted)")
        appendLog("直流内阻 (DCIR): \(dcirFormatted)")
        appendLog("==========================================")
        
        if autoExportReports {
            generateReports(
                dischargeFormatted: dischargeFormatted,
                rechargeFormatted: rechargeFormatted,
                capacityFormatted: capacityFormatted,
                mahFormatted: mahFormatted,
                healthFormatted: healthFormatted,
                coulombicFormatted: coulombicFormatted
            )
        }
        
        let newRecord = CalibrationHistoryRecord(
            startDate: sessionStartDate ?? Date(),
            endDate: Date(),
            startDischargePercentage: startDischargePercentage,
            cycleCount: cycleCount,
            designCapacityMAh: designCapacityMAh,
            calculatedCapacityMAh: calculatedCapacityMAh,
            calculatedCapacityWh: calculatedCapacityWh,
            batteryHealthPercentage: batteryHealthPercentage,
            dischargeEnergyWh: dischargeEnergyWh,
            dischargeEnergyAh: dischargeEnergyAh,
            rechargeEnergyWh: rechargeEnergyWh,
            rechargeEnergyAh: rechargeEnergyAh,
            coulombicEfficiency: coulombicEfficiency,
            internalResistanceMilliohm: internalResistanceMilliohm,
            reportFilePath: lastReportURL?.path,
            csvFilePath: lastCSVURL?.path
        )
        HistoryStorageManager.shared.saveRecord(newRecord)
        self.historyRecords = HistoryStorageManager.shared.loadHistory()
        recalculateMultiSessionHealth()
    }
    
    func recalculateMultiSessionHealth() {
        let validRecords = historyRecords.filter { $0.calculatedCapacityMAh > 1000.0 && $0.batteryHealthPercentage > 0 }
        guard !validRecords.isEmpty else {
            self.aggregatedHealth = nil
            return
        }
        
        let recent = Array(validRecords.prefix(5))
        var totalWeight = 0.0
        var weightedCapacityMAh = 0.0
        var weightedCapacityWh = 0.0
        var weightedHealth = 0.0
        
        for (index, r) in recent.enumerated() {
            let weight = Double(recent.count - index)
            totalWeight += weight
            weightedCapacityMAh += r.calculatedCapacityMAh * weight
            weightedCapacityWh += r.calculatedCapacityWh * weight
            weightedHealth += r.batteryHealthPercentage * weight
        }
        
        let trueCapMAh = weightedCapacityMAh / totalWeight
        let trueCapWh = weightedCapacityWh / totalWeight
        let trueHealth = weightedHealth / totalWeight
        
        let baseConfidence: [Double] = [0.0, 60.0, 80.0, 90.0, 95.0, 99.0]
        let score = baseConfidence[min(recent.count, 5)]
        
        self.aggregatedHealth = AggregatedBatteryHealth(
            validSessionsCount: recent.count,
            trueCapacityMAh: trueCapMAh,
            trueCapacityWh: trueCapWh,
            trueHealthPercentage: trueHealth,
            confidenceScore: score
        )
    }
    
    private func generateReports(
        dischargeFormatted: String,
        rechargeFormatted: String,
        capacityFormatted: String,
        mahFormatted: String,
        healthFormatted: String,
        coulombicFormatted: String
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestampStr = formatter.string(from: Date())
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        
        let txtFileName = "BatteryCalibration_Report_\(timestampStr).txt"
        let txtFileURL = desktopURL.appendingPathComponent(txtFileName)
        
        var reportContent = """
        ==================================================
                 macOS 电池校准高精度检测报告
        ==================================================
        硬件机型: \(hardwareModel)
        电池序列号: \(batterySerialNumber)
        开始时间: \(sessionStartDate?.description(with: .current) ?? "--")
        完成时间: \(Date().description(with: .current))
        起始放电电量: \(startDischargePercentage)%
        放电耗时: \(finalDischargeDurationText)
        循环次数: \(cycleCount) 次
        设计标称容量: \(String(format: "%.0f", designCapacityMAh)) mAh
        单次推算实际容量: \(capacityFormatted) Wh (\(mahFormatted) mAh)
        单次实测健康度: \(healthFormatted)
        """
        
        if let agg = aggregatedHealth {
            reportContent.append("""
            
            ----------------- 多周期综合真实健康度 -------------------
            有效质检样本: \(agg.validSessionsCount) 次
            综合真实实际容量: \(String(format: "%.0f", agg.trueCapacityMAh)) mAh (\(String(format: "%.2f", agg.trueCapacityWh)) Wh)
            综合真实电池健康度: \(String(format: "%.1f%%", agg.trueHealthPercentage))
            质检置信度评分: \(String(format: "%.0f%%", agg.confidenceScore))
            """)
        }
        
        reportContent.append("""
        
        直流内阻 (DCIR): \(internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--")
        实测释放能量: \(dischargeFormatted) Wh (\(String(format: "%.3f", dischargeEnergyAh)) Ah)
        实测回充能量: \(rechargeFormatted) Wh (\(String(format: "%.3f", rechargeEnergyAh)) Ah)
        充放库仑效率: \(coulombicFormatted)
        结束时电压: \(String(format: "%.2f V", currentVoltage))
        结束时温度: \(String(format: "%.1f °C", currentTemperature))
        ----------------- 遥测校准日志 -------------------
        """)
        
        for log in logHistory {
            reportContent.append("\n\(log)")
        }
        reportContent.append("\n==================================================\n")
        try? reportContent.write(to: txtFileURL, atomically: true, encoding: .utf8)
        self.lastReportURL = txtFileURL
        
        let csvFileName = "BatteryTelemetry_\(timestampStr).csv"
        let csvFileURL = desktopURL.appendingPathComponent(csvFileName)
        
        var csvContent = "Timestamp,Percentage,Power(W),Voltage(V),Amperage(A),Temperature(C)\n"
        let isoFormatter = ISO8601DateFormatter()
        for pt in sessionRecordedPoints {
            let row = "\(isoFormatter.string(from: pt.timestamp)),\(pt.percentage),\(String(format: "%.3f", pt.power)),\(String(format: "%.3f", pt.voltage)),\(String(format: "%.3f", pt.amperage)),\(String(format: "%.2f", pt.temperature))\n"
            csvContent.append(row)
        }
        try? csvContent.write(to: csvFileURL, atomically: true, encoding: .utf8)
        self.lastCSVURL = csvFileURL
        
        appendLog("检测报告已导出至桌面: \(txtFileName) 与 \(csvFileName)")
    }
    
    func openLastReportInFinder() {
        guard let url = lastReportURL ?? lastCSVURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    func deleteHistoryRecord(id: UUID) {
        HistoryStorageManager.shared.deleteRecord(id: id)
        self.historyRecords = HistoryStorageManager.shared.loadHistory()
        recalculateMultiSessionHealth()
    }
    
    func clearAllHistory() {
        HistoryStorageManager.shared.clearAll()
        self.historyRecords.removeAll()
        self.aggregatedHealth = nil
    }
    
    private func checkAlDenteStatus() {
        let apps = NSWorkspace.shared.runningApplications
        let running = apps.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleID.localizedCaseInsensitiveContains("aldente")
        }
        
        if self.isAlDenteRunning != running {
            self.isAlDenteRunning = running
            appendLog("AlDente 状态: \(running ? "已运行" : "未运行")")
        }
        
        guard running else {
            if isAlDenteCalibrating {
                isAlDenteCalibrating = false
            }
            return
        }
        
        CFPreferencesAppSynchronize(alDenteBundleID as CFString)
        let stateObj = CFPreferencesCopyAppValue("lastCalibrationState" as CFString, alDenteBundleID as CFString)
        
        var isCalibratingNow = false
        if let stateStr = stateObj as? String {
            isCalibratingNow = (stateStr != "-1")
        } else if let stateNum = stateObj as? NSNumber {
            isCalibratingNow = (stateNum.intValue != -1)
        }
        
        if self.isAlDenteCalibrating != isCalibratingNow {
            self.isAlDenteCalibrating = isCalibratingNow
            appendLog("AlDente Pro 校准模式: \(isCalibratingNow ? "【已启动】" : "【已停止】")")
        }
    }
    
    private func enablePreventSleep() {
        guard !isAssertionActive else { return }
        let reason = "Battery Calibration Active" as CFString
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            255,
            reason,
            &assertionID
        )
        if success == kIOReturnSuccess {
            isAssertionActive = true
            appendLog("已防止系统休眠 (IOPMAssertion)")
        }
    }
    
    private func disablePreventSleep() {
        guard isAssertionActive else { return }
        IOPMAssertionRelease(assertionID)
        isAssertionActive = false
        appendLog("恢复正常系统休眠策略")
    }
    
    private func startStressLoad() {
        stopStressLoad()
        guard !isThermalCutoffActive else { return }
        guard stressMode != .silent else {
            appendLog("负载策略为静音: CPU 负载 0%")
            return
        }
        
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let workersCount: Int
        let sleepMicros: UInt32
        
        switch stressMode {
        case .silent:
            return
        case .balanced:
            workersCount = max(1, coreCount / 2)
            sleepMicros = 2000
        case .aggressive:
            workersCount = max(1, coreCount - 1)
            sleepMicros = 100
        }
        
        for _ in 0..<workersCount {
            let task = Task.detached(priority: .userInitiated) {
                var val: Double = 1.0
                while !Task.isCancelled {
                    for _ in 0..<10_000 {
                        val = sin(val) * cos(val) + tan(0.12345)
                    }
                    usleep(sleepMicros)
                }
            }
            stressTasks.append(task)
        }
        appendLog("放电负载策略已应用 [\(stressMode.rawValue)]: 启动 \(workersCount) 个计算单元")
    }
    
    private func stopStressLoad() {
        if !stressTasks.isEmpty {
            for task in stressTasks {
                task.cancel()
            }
            stressTasks.removeAll()
            appendLog("已释放放电计算负载")
        }
    }
    
    // MARK: - 深度电池属性抓取与温度解析
    private func fetchBatteryDetails() {
        let matchingDict = IOServiceMatching("AppleSmartBattery")
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                
                if let v = dict["Voltage"] as? NSNumber {
                    self.currentVoltage = v.doubleValue / 1000.0
                }
                
                var rawSignedCurrent = 0.0
                if let instAmp = dict["InstantAmperage"] as? NSNumber {
                    let raw = instAmp.int64Value
                    rawSignedCurrent = Double(raw)
                } else if let amp = dict["Amperage"] as? NSNumber {
                    rawSignedCurrent = Double(amp.int64Value)
                }
                
                self.signedAmperage = rawSignedCurrent / 1000.0
                self.currentAmperage = abs(self.signedAmperage)
                self.currentPower = self.currentVoltage * self.currentAmperage
                
                self.isExternalConnected = dict["ExternalConnected"] as? Bool ?? false
                let rawIsCharging = dict["IsCharging"] as? Bool ?? false
                
                if self.signedAmperage < -0.05 {
                    self.isCharging = false
                    self.isDischargingOnAC = self.isExternalConnected
                } else if self.signedAmperage > 0.05 {
                    self.isCharging = true
                    self.isDischargingOnAC = false
                } else {
                    self.isCharging = rawIsCharging
                    self.isDischargingOnAC = false
                }
                
                if let curCap = dict["CurrentCapacity"] as? NSNumber,
                   let maxCap = dict["MaxCapacity"] as? NSNumber,
                   maxCap.doubleValue > 0 {
                    self.currentPercentage = Int((curCap.doubleValue / maxCap.doubleValue) * 100.0)
                }
                
                if let bData = dict["BatteryData"] as? [String: Any] {
                    if let desCap = bData["DesignCapacity"] as? NSNumber {
                        self.designCapacityMAh = desCap.doubleValue
                    }
                } else if let designCap = dict["DesignCapacity"] as? NSNumber {
                    self.designCapacityMAh = designCap.doubleValue
                }
                
                if let cycles = dict["CycleCount"] as? NSNumber {
                    self.cycleCount = cycles.intValue
                }
                if let serial = dict["Serial"] as? String ?? dict["BatterySerialNumber"] as? String {
                    self.batterySerialNumber = serial
                }
            }
        }
        
        // 温度探测
        var resolvedTemp: Double? = nil
        resolvedTemp = fetchBatteryTemperatureViaHID()
        
        if resolvedTemp == nil {
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
                for src in list {
                    guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                    if let t = desc["Temperature"] as? NSNumber {
                        let d = t.doubleValue
                        if d > 2000 {
                            resolvedTemp = (d / 10.0) - 273.15
                        } else if d > 5.0 && d < 90.0 {
                            resolvedTemp = d
                        }
                    }
                }
            }
        }
        
        if let valid = resolvedTemp, valid > 5.0 {
            self.currentTemperature = valid
        }
    }
    
    private func fetchBatteryTemperatureViaHID() -> Double? {
        typealias IOHIDEventSystemClientCreateType = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias IOHIDEventSystemClientSetMatchingType = @convention(c) (AnyObject, CFDictionary) -> Void
        typealias IOHIDEventSystemClientCopyServicesType = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
        typealias IOHIDServiceClientCopyPropertyType = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
        typealias IOHIDServiceClientCopyEventType = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
        typealias IOHIDEventGetFloatValueType = @convention(c) (AnyObject, UInt32) -> Double
        
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        
        guard let clientCreateSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatchingSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyPropSym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let copyEventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloatValSym = dlsym(handle, "IOHIDEventGetFloatValue") else { return nil }
        
        let clientCreate = unsafeBitCast(clientCreateSym, to: IOHIDEventSystemClientCreateType.self)
        let setMatching = unsafeBitCast(setMatchingSym, to: IOHIDEventSystemClientSetMatchingType.self)
        let copyServices = unsafeBitCast(copyServicesSym, to: IOHIDEventSystemClientCopyServicesType.self)
        let copyProp = unsafeBitCast(copyPropSym, to: IOHIDServiceClientCopyPropertyType.self)
        let copyEvent = unsafeBitCast(copyEventSym, to: IOHIDServiceClientCopyEventType.self)
        let getFloatVal = unsafeBitCast(getFloatValSym, to: IOHIDEventGetFloatValueType.self)
        
        guard let clientUnmanaged = clientCreate(kCFAllocatorDefault) else { return nil }
        let client = clientUnmanaged.takeRetainedValue()
        
        let matchDict: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(client, matchDict as CFDictionary)
        
        guard let servicesArrayUnmanaged = copyServices(client) else { return nil }
        let servicesArray = servicesArrayUnmanaged.takeRetainedValue() as [AnyObject]
        
        var candidates: [Double] = []
        for service in servicesArray {
            if let nameRef = copyProp(service, "Product" as CFString)?.takeRetainedValue() as? String {
                let lower = nameRef.lowercased()
                if lower.contains("battery") || lower.contains("gas gauge") || lower.contains("pmu tdev") || lower.contains("tb0t") {
                    if let eventUnmanaged = copyEvent(service, 15, 0, 0) {
                        let event = eventUnmanaged.takeRetainedValue()
                        let temp = getFloatVal(event, 0x000F0000)
                        if temp > 10.0 && temp < 85.0 {
                            candidates.append(temp)
                        }
                    }
                }
            }
        }
        
        return candidates.max()
    }
    
    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logHistory.append("[\(timestamp)] \(text)")
    }
}
