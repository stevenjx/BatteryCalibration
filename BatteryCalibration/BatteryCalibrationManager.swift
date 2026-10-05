import Foundation
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - 屏幕亮度私有控制接口 (用于在快充阶段调暗背光提速)
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
    case silent = "静音放电"
    case balanced = "均衡放电"
    case aggressive = "极速放电"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .silent: return "静音模式 (0% CPU)"
        case .balanced: return "标准放电 ~20W (50% 核心负载)"
        case .aggressive: return "极速负载 50W+ (多核满载)"
        }
    }
}

enum CalibrationPhase: String {
    case waitingForTrigger = "待机就绪"
    case chargingToFull = "初充阶段 (充至 100%)"
    case discharging = "放电标定 (放至 10%)"
    case rechargingToFull = "复充标定 (充至 100%)"
    case holdingAtFull = "满电静置 (消除极化)"
    case dischargingToBuffer = "缓冲回落 (降至 80%)"
    case completed = "校准完毕"
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

@MainActor
final class BatteryCalibrationManager: ObservableObject {
    @Published var currentPhase: CalibrationPhase = .waitingForTrigger
    @Published var currentPercentage: Int = 0
    @Published var currentVoltage: Double = 0.0
    @Published var signedAmperage: Double = 0.0
    @Published var currentAmperage: Double = 0.0
    @Published var currentPower: Double = 0.0
    @Published var currentTemperature: Double = 0.0
    
    @Published var designCapacityMAh: Double = 0.0
    @Published var rawMaxCapacityMAh: Double = 0.0
    @Published var cycleCount: Int = 0
    @Published var batterySerialNumber: String = "--"
    @Published var hardwareModel: String = "--"
    
    // MARK: - 实时硬件遥测状态 (CPU功耗/温度、风扇转速)
    @Published var cpuPowerWatts: Double = 0.0
    @Published var cpuTemperatureCelsius: Double = 0.0
    @Published var fanSpeedRPM: Int = 0
    
    // MARK: - AI 引擎遥测属性
    @Published var aiPredictedRemainingMinutes: Int = 0
    @Published var aiEstimatedRemainingMAh: Double = 0.0
    @Published var aiTrueCapacityMAh: Double = 0.0
    @Published var aiTrueHealthPct: Double = 0.0
    @Published var aiConfidence: Double = 0.0
    
    @Published var estimatedCpuPower: Double = 0.0
    @Published var estimatedScreenPower: Double = 0.0
    @Published var estimatedBoardPower: Double = 0.0
    
    @Published var isCharging: Bool = false
    @Published var isExternalConnected: Bool = false
    @Published var isDischargingOnAC: Bool = false
    @Published var isAlDenteRunning: Bool = false
    @Published var isAlDenteCalibrating: Bool = false
    
    @Published var internalResistanceMilliohm: Double = 0.0
    
    // MARK: - 电池电芯层级数据
    @Published var cellVoltages: [Double] = []
    @Published var cellVoltageDeltaMillivolts: Double = 0.0
    
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
    
    // MARK: - SMC 硬件控制服务状态
    @Published var isHardwareControlAvailable: Bool = false
    @Published var isChargingInhibitedByApp: Bool = false
    
    @Published var historyRecords: [CalibrationHistoryRecord] = []
    @Published var isLaunchAtLogin: Bool = false
    
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
    private var holdingStartDate: Date?
    private let holdingDurationSeconds: TimeInterval = 600
    private var startDischargePercentage: Int = 100
    private(set) var isSessionRunning: Bool = false
    private var downsampleCounter: Int = 0
    private var sessionRecordedPoints: [CalibrationDataPoint] = []
    
    private let alDenteBundleID = "com.apphousekitchen.aldente-pro"
    
    // CPU 负载采样基准
    private var previousCPUTime: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? = nil
    
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
        self.isHardwareControlAvailable = BatteryControlClient.shared.isDaemonRegistered
        checkLaunchAtLoginStatus()
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
    
    private func applyHardwareChargingInhibit(enabled: Bool) {
        guard BatteryControlClient.shared.isDaemonRegistered else {
            appendLog("SMC 控制未启用：Helper 未安装或未提权")
            return
        }
        
        Task {
            do {
                _ = try await BatteryControlClient.shared.setInhibitCharging(enabled: enabled)
                self.isChargingInhibitedByApp = enabled
                self.appendLog(enabled ? "SMC: 阻断硬件充电 (进入纯放电模式)" : "SMC: 恢复正常硬件充电控制")
            } catch {
                self.appendLog("SMC 通信错误: \(error.localizedDescription)")
            }
        }
    }
    
    func checkLaunchAtLoginStatus() {
        self.isLaunchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
    
    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.isLaunchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            appendLog("开机自启设置失败: \(error.localizedDescription)")
            self.isLaunchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
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
                    self.appendLog("通知权限已就绪")
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
        fetchHardwareTelemetry()
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
            appendLog("检测到 AlDente Pro 开始校准，联动启动...")
            startCalibrationSession()
        } else if !isAlDenteCalibrating && isSessionRunning {
            appendLog("AlDente Pro 退出校准状态，联动中止...")
            stopCalibrationSession()
        }
        
        // MARK: - 实时功耗分解估计与 AI 推算 (充电/放电皆保证非零)
        let smoothedP = BatteryAIEngine.shared.filterInstantPower(rawWatts: currentPower)
        let isDischarging = self.signedAmperage < -0.05 || self.isDischargingOnAC
        
        if isDischarging {
            self.estimatedScreenPower = max(0.8, min(6.0, smoothedP * 0.22))
            self.estimatedCpuPower = max(0.5, smoothedP * 0.55)
            self.estimatedBoardPower = max(0.5, smoothedP - self.estimatedScreenPower - self.estimatedCpuPower)
        } else {
            let cpuUsagePct = calculateSystemCPUUsageRatio()
            let baseCpuWatts = max(1.2, cpuUsagePct * 35.0)
            self.estimatedCpuPower = baseCpuWatts
            self.estimatedScreenPower = 2.5
            self.estimatedBoardPower = 3.0
        }
        
        let fallbackHardwareCap = self.rawMaxCapacityMAh > 500 ? self.rawMaxCapacityMAh : (self.designCapacityMAh > 0 ? self.designCapacityMAh * 0.93 : 5649.0)
        let aiHealth = BatteryAIEngine.shared.inferTrueHealth(
            history: self.historyRecords,
            designCapMAh: self.designCapacityMAh > 0 ? self.designCapacityMAh : 6075.0,
            hardwareMaxCapMAh: fallbackHardwareCap
        )
        self.aiTrueCapacityMAh = aiHealth.trueCapacityMAh
        self.aiTrueHealthPct = aiHealth.trueHealthPct
        self.aiConfidence = aiHealth.confidence
        self.aiEstimatedRemainingMAh = self.aiTrueCapacityMAh * (Double(self.currentPercentage) / 100.0)
        
        if isDischarging {
            self.aiPredictedRemainingMinutes = BatteryAIEngine.shared.predictRemainingMinutes(
                currentPct: self.currentPercentage,
                currentVoltage: self.currentVoltage,
                smoothedPower: smoothedP,
                trueFullCapMAh: self.aiTrueCapacityMAh
            )
        } else {
            self.aiPredictedRemainingMinutes = 0
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
                appendLog("初充完成，已自动转入深度放电阶段 (\(currentPercentage)%) [\(stressMode.rawValue)]...")
                sendLocalNotification(
                    title: "初充完成",
                    body: "电池已充至 \(currentPercentage)%，开始进入深度放电校准阶段。"
                )
                startStressLoad()
                applyHardwareChargingInhibit(enabled: true)
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
                self.finalDischargeDurationText = "\(h)小时 \(m)分 (均耗 \(String(format: "%.1f", dischargeAveragePower))W)"
                appendLog("放电标定完成 (\(dischargeTargetPercentage)%)，总耗时: \(h)小时\(m)分，平均放电功率: \(String(format: "%.2f", dischargeAveragePower)) W")
                
                stopStressLoad()
                applyHardwareChargingInhibit(enabled: false)
                currentPhase = .rechargingToFull
                applyFastChargingOptimization(enable: true)
                
                sendLocalNotification(
                    title: "放电标定完毕",
                    body: "电量已放至目标值，请保持充电器连接以完成 100% 满电回充标定。"
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
                currentPhase = .holdingAtFull
                holdingStartDate = Date()
                appendLog("电池已充至 100%，进入满电静置标定阶段 (10 分钟)...")
                sendLocalNotification(
                    title: "满电静置阶段",
                    body: "电池已充饱至 100%，系统正在进行满充极化消除标定。"
                )
            }
        } else if currentPhase == .holdingAtFull {
            if let start = holdingStartDate, now.timeIntervalSince(start) >= holdingDurationSeconds {
                appendLog("满电静置标定完成，开始降至 80% 缓冲寿命电量...")
                currentPhase = .dischargingToBuffer
                applyHardwareChargingInhibit(enabled: true)
                sendLocalNotification(
                    title: "开始缓冲回落",
                    body: "校准基本完成，正在微量放电至 80% 健康存储状态。"
                )
            }
        } else if currentPhase == .dischargingToBuffer {
            if currentPercentage <= 80 {
                appendLog("已回落至 80% 最佳安全电量，校准流程彻底完成！")
                applyHardwareChargingInhibit(enabled: false)
                finishCalibration()
            }
        }
    }
    
    private func applyFastChargingOptimization(enable: Bool) {
        isFastChargeThrottlingActive = enable
        if enable {
            stopStressLoad()
            ScreenBrightnessController.shared.dimForFastCharge()
            appendLog("已开启快充优化策略：抑制后台负载并调暗屏幕")
        } else {
            ScreenBrightnessController.shared.restoreBrightness()
            appendLog("恢复正常屏幕亮度与负载配置")
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
                title: "过热熔断触发",
                body: "电池温度已达到 \(String(format: "%.1f", currentTemperature))°C，放电负载已挂起降温。"
            )
            appendLog("过热熔断: \(String(format: "%.1f", currentTemperature))°C >= 阈值 \(highTempThreshold)°C，暂停负载")
        } else if currentTemperature <= resumeTempThreshold && isThermalCutoffActive {
            isThermalCutoffActive = false
            startStressLoad()
            sendLocalNotification(
                title: "温度恢复正常",
                body: "电池温度降至 \(String(format: "%.1f", currentTemperature))°C，放电负载已重新激活。"
            )
            appendLog("温度恢复: \(String(format: "%.1f", currentTemperature))°C <= 恢复线 \(resumeTempThreshold)°C，恢复负载")
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
        holdingStartDate = nil
        
        enablePreventSleep()
        appendLog(">>> 开始电池深度校准流程 <<<")
        
        if signedAmperage < -0.05 || isDischargingOnAC {
            currentPhase = .discharging
            startDischargePercentage = currentPercentage
            dischargePhaseStartDate = Date()
            appendLog("当前正在放电，直接进入放电标定阶段...")
            startStressLoad()
            applyHardwareChargingInhibit(enabled: true)
        } else {
            currentPhase = .chargingToFull
            dischargePhaseStartDate = nil
            appendLog("等待电池充满至 100%...")
            stopStressLoad()
        }
    }
    
    func stopCalibrationSession() {
        applyFastChargingOptimization(enable: false)
        stopStressLoad()
        applyHardwareChargingInhibit(enabled: false)
        disablePreventSleep()
        isSessionRunning = false
        currentPhase = .waitingForTrigger
        holdingStartDate = nil
        appendLog("校准任务已被用户中止")
    }
    
    private func finishCalibration() {
        applyFastChargingOptimization(enable: false)
        stopStressLoad()
        applyHardwareChargingInhibit(enabled: false)
        disablePreventSleep()
        isSessionRunning = false
        currentPhase = .completed
        holdingStartDate = nil
        
        let dischargeFormatted = String(format: "%.2f", dischargeEnergyWh)
        let rechargeFormatted = String(format: "%.2f", rechargeEnergyWh)
        let capacityFormatted = String(format: "%.2f", calculatedCapacityWh)
        let mahFormatted = String(format: "%.0f", calculatedCapacityMAh)
        let healthFormatted = designCapacityMAh > 0 ? String(format: "%.1f%%", batteryHealthPercentage) : "--"
        let coulombicFormatted = rechargeEnergyAh > 0 ? String(format: "%.1f%%", coulombicEfficiency) : "--"
        let dcirFormatted = internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--"
        
        appendLog("==========================================")
        appendLog("          电池深度校准圆满完成            ")
        appendLog("总放电耗时: \(finalDischargeDurationText)")
        appendLog("放电能耗: \(dischargeFormatted) Wh | 复充能耗: \(rechargeFormatted) Wh")
        appendLog("测定容量: \(capacityFormatted) Wh (\(mahFormatted) mAh) | 健康度: \(healthFormatted)")
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
        macOS 电池校准专业分析报告
        ==================================================
        设备型号: \(hardwareModel)
        电池序列号: \(batterySerialNumber)
        校准启动时间: \(sessionStartDate?.description(with: .current) ?? "--")
        标定结束时间: \(Date().description(with: .current))
        起始放电电量: \(startDischargePercentage)%
        总放电时间: \(finalDischargeDurationText)
        当前循环计数: \(cycleCount) 次
        出厂设计容量: \(String(format: "%.0f", designCapacityMAh)) mAh
        实测有效容量: \(capacityFormatted) Wh (\(mahFormatted) mAh)
        单次测算健康度: \(healthFormatted)
        """
        
        if let agg = aggregatedHealth {
            reportContent.append("""
            
            ----------------- 多周期加权健康评估 -----------------
            有效校准样本数: \(agg.validSessionsCount) 次
            综合真实总容量: \(String(format: "%.0f", agg.trueCapacityMAh)) mAh (\(String(format: "%.2f", agg.trueCapacityWh)) Wh)
            综合真实健康度: \(String(format: "%.1f%%", agg.trueHealthPercentage))
            置信度评分: \(String(format: "%.0f%%", agg.confidenceScore))
            """)
        }
        
        reportContent.append("""
        
        ----------------- 电芯性能与内阻 -----------------
        直流内阻 (DCIR): \(internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--")
        电芯电压组: \(cellVoltages.map { String(format: "%.3fV", $0) }.joined(separator: ", "))
        电芯压差 (ΔV): \(String(format: "%.1f mV", cellVoltageDeltaMillivolts))
        放电释放能耗: \(dischargeFormatted) Wh (\(String(format: "%.3f", dischargeEnergyAh)) Ah)
        复充吸收能耗: \(rechargeFormatted) Wh (\(String(format: "%.3f", rechargeEnergyAh)) Ah)
        库仑效率: \(coulombicFormatted)
        终止端电压: \(String(format: "%.2f V", currentVoltage))
        终止电池温度: \(String(format: "%.1f °C", currentTemperature))
        ----------------- 过程操作日志 -----------------
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
        
        appendLog("报告已自动导出至桌面: \(txtFileName) 与 \(csvFileName)")
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
            appendLog("AlDente 状态更新: \(running ? "已运行" : "未运行")")
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
            appendLog("AlDente Pro 校准联动: \(isCalibratingNow ? "进入校准中" : "就绪")")
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
            appendLog("已获取系统防休眠锁 (IOPMAssertion)")
        }
    }
    
    private func disablePreventSleep() {
        guard isAssertionActive else { return }
        IOPMAssertionRelease(assertionID)
        isAssertionActive = false
        appendLog("已释放防休眠锁")
    }
    
    private func startStressLoad() {
        stopStressLoad()
        guard !isThermalCutoffActive else { return }
        guard stressMode != .silent else {
            appendLog("放电负载模式: 静音放电 (CPU 核心负载 0%)")
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
        appendLog("启动放电负载 [\(stressMode.rawValue)]: 激活 \(workersCount) 个算力线程")
    }
    
    private func stopStressLoad() {
        if !stressTasks.isEmpty {
            for task in stressTasks {
                task.cancel()
            }
            stressTasks.removeAll()
            appendLog("已停止全部放电核心负载")
        }
    }
    
    // MARK: - 硬件遥测综合引擎 (CPU功耗/CPU温度/风扇转速)
    private func fetchHardwareTelemetry() {
        // 1. 读取系统各物理探针温度
        let hidMetrics = fetchHIDSensorsLocal()
        if let cTemp = hidMetrics.cpuTemp, cTemp > 10.0 && cTemp < 115.0 {
            self.cpuTemperatureCelsius = cTemp
        }
        
        // 2. 实时功耗同步 (保证充电与放电均能精准体现瞬时功耗)
        let smoothedP = BatteryAIEngine.shared.filterInstantPower(rawWatts: currentPower)
        if self.signedAmperage < -0.05 || self.isDischargingOnAC {
            self.cpuPowerWatts = max(0.8, smoothedP * 0.55)
        } else {
            let cpuPct = calculateSystemCPUUsageRatio()
            self.cpuPowerWatts = max(1.2, cpuPct * 45.0)
        }
        
        // 3. 若 Helper 守护进程在线，异步获取底层特权硬件读数 (SMC F0Ac / 温度)
        if isHardwareControlAvailable {
            Task { [weak self] in
                guard let self = self else { return }
                if let sensors = try? await BatteryControlClient.shared.getHardwareSensors() {
                    await MainActor.run {
                        if let rpm = sensors["fanRPM"]?.intValue, rpm >= 0 {
                            self.fanSpeedRPM = rpm
                        }
                        if let cTemp = sensors["cpuTemp"]?.doubleValue, cTemp > 15.0 {
                            self.cpuTemperatureCelsius = cTemp
                        }
                        if let cPow = sensors["cpuPower"]?.doubleValue, cPow > 0.1 {
                            self.cpuPowerWatts = cPow
                        }
                    }
                }
            }
        }
    }
    
    // 获取 macOS 原生 CPU 活跃率 (0.0 ~ 1.0)
    private func calculateSystemCPUUsageRatio() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numProcessors: natural_t = 0
        
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numProcessors,
            &cpuInfo,
            &numCpuInfo
        )
        
        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return 0.05
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCpuInfo * UInt32(MemoryLayout<integer_t>.stride)))
        }
        
        var totalUser: UInt32 = 0
        var totalSystem: UInt32 = 0
        var totalIdle: UInt32 = 0
        var totalNice: UInt32 = 0
        
        let cpuLoadArray = info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numProcessors)) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: Int(numProcessors)))
        }
        
        for cpu in cpuLoadArray {
            totalUser += cpu.cpu_ticks.0
            totalSystem += cpu.cpu_ticks.1
            totalIdle += cpu.cpu_ticks.2
            totalNice += cpu.cpu_ticks.3
        }
        
        guard let prev = previousCPUTime else {
            previousCPUTime = (totalUser, totalSystem, totalIdle, totalNice)
            return 0.08
        }
        
        let diffUser = Double(totalUser - prev.user)
        let diffSystem = Double(totalSystem - prev.system)
        let diffIdle = Double(totalIdle - prev.idle)
        let diffNice = Double(totalNice - prev.nice)
        let totalDiff = diffUser + diffSystem + diffIdle + diffNice
        
        previousCPUTime = (totalUser, totalSystem, totalIdle, totalNice)
        
        if totalDiff > 0 {
            let active = diffUser + diffSystem + diffNice
            return min(1.0, max(0.01, active / totalDiff))
        }
        return 0.05
    }
    
    private func fetchHIDSensorsLocal() -> (cpuTemp: Double?, gpuTemp: Double?) {
        typealias IOHIDCreateFunc = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias IOHIDSetMatchFunc = @convention(c) (AnyObject, CFDictionary) -> Void
        typealias IOHIDCopyServicesFunc = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
        typealias IOHIDCopyPropFunc = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
        typealias IOHIDCopyEventFunc = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
        typealias IOHIDGetFloatFunc = @convention(c) (AnyObject, UInt32) -> Double
        
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return (nil, nil) }
        defer { dlclose(handle) }
        
        guard let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyPropSym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let copyEvtSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloatSym = dlsym(handle, "IOHIDEventGetFloatValue") else {
            return (nil, nil)
        }
        
        let clientCreate = unsafeBitCast(createSym, to: IOHIDCreateFunc.self)
        let setMatching = unsafeBitCast(matchSym, to: IOHIDSetMatchFunc.self)
        let copyServices = unsafeBitCast(copyServSym, to: IOHIDCopyServicesFunc.self)
        let copyProp = unsafeBitCast(copyPropSym, to: IOHIDCopyPropFunc.self)
        let copyEvent = unsafeBitCast(copyEvtSym, to: IOHIDCopyEventFunc.self)
        let getFloatVal = unsafeBitCast(getFloatSym, to: IOHIDGetFloatFunc.self)
        
        guard let clientObj = clientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return (nil, nil) }
        let matchDict: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(clientObj, matchDict as CFDictionary)
        
        guard let services = copyServices(clientObj)?.takeRetainedValue() as? [AnyObject] else { return (nil, nil) }
        
        var cpuValues: [Double] = []
        
        for service in services {
            if let name = copyProp(service, "Product" as CFString)?.takeRetainedValue() as? String {
                let n = name.lowercased()
                if let evt = copyEvent(service, 15, 0, 0)?.takeRetainedValue() {
                    let temp = getFloatVal(evt, 0x000F0000)
                    if temp > 15.0 && temp < 110.0 {
                        if n.contains("cpu") || n.contains("pcore") || n.contains("ecore") || n.contains("die") || n.contains("soc") {
                            cpuValues.append(temp)
                        }
                    }
                }
            }
        }
        
        let avgCpu = cpuValues.isEmpty ? nil : (cpuValues.reduce(0.0, +) / Double(cpuValues.count))
        return (avgCpu, nil)
    }
    
    // MARK: - 底层电池遥测 IOPS / IORegistry 读取
    
    private func fetchBatteryDetails() {
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let curPct = desc[kIOPSCurrentCapacityKey] as? NSNumber {
                    self.currentPercentage = curPct.intValue
                }
                if let isChargingNum = desc[kIOPSIsChargingKey] as? Bool {
                    self.isCharging = isChargingNum
                }
            }
        }
        
        let matchingDict = IOServiceMatching("AppleSmartBattery")
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        
        var resolvedTemp: Double? = nil
        
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                
                // 1. 电压
                if let v = dict["Voltage"] as? NSNumber {
                    self.currentVoltage = v.doubleValue / 1000.0
                }
                
                // 2. 电流与功率
                var rawSignedCurrent = 0.0
                if let instAmp = dict["InstantAmperage"] as? NSNumber {
                    rawSignedCurrent = Double(instAmp.int64Value)
                } else if let amp = dict["Amperage"] as? NSNumber {
                    rawSignedCurrent = Double(amp.int64Value)
                }
                
                self.signedAmperage = rawSignedCurrent / 1000.0
                self.currentAmperage = abs(self.signedAmperage)
                self.currentPower = self.currentVoltage * self.currentAmperage
                
                // 3. 充电器与放电状态
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
                
                // 4. 容量与多电芯组电压
                var parsedMaxCap: Double = 0.0
                
                if let bData = dict["BatteryData"] as? [String: Any] {
                    if let desCap = bData["DesignCapacity"] as? NSNumber {
                        self.designCapacityMAh = desCap.doubleValue
                    }
                    if let rawCellArray = bData["CellVoltage"] as? [NSNumber], !rawCellArray.isEmpty {
                        let parsedCells = rawCellArray.map { $0.doubleValue / 1000.0 }
                        self.cellVoltages = parsedCells
                        if let maxV = parsedCells.max(), let minV = parsedCells.min() {
                            self.cellVoltageDeltaMillivolts = (maxV - minV) * 1000.0
                        }
                    }
                    
                    if let nom = bData["NominalChargeCapacity"] as? NSNumber, nom.doubleValue > 500 {
                        parsedMaxCap = nom.doubleValue
                    } else if let raw = bData["RawMaxCapacity"] as? NSNumber, raw.doubleValue > 500 {
                        parsedMaxCap = raw.doubleValue
                    } else if let life = bData["LifetimeData"] as? [String: Any],
                              let rawLife = life["RawMaxCapacity"] as? NSNumber, rawLife.doubleValue > 500 {
                        parsedMaxCap = rawLife.doubleValue
                    }
                } else if let designCap = dict["DesignCapacity"] as? NSNumber {
                    self.designCapacityMAh = designCap.doubleValue
                }
                
                if parsedMaxCap <= 500 {
                    if let nom = dict["NominalChargeCapacity"] as? NSNumber, nom.doubleValue > 500 {
                        parsedMaxCap = nom.doubleValue
                    } else if let rawMax = dict["AppleRawMaxCapacity"] as? NSNumber, rawMax.doubleValue > 500 {
                        parsedMaxCap = rawMax.doubleValue
                    } else if let maxC = dict["MaxCapacity"] as? NSNumber, maxC.doubleValue > 500 {
                        parsedMaxCap = maxC.doubleValue
                    }
                }
                
                if parsedMaxCap > 500 {
                    self.rawMaxCapacityMAh = parsedMaxCap
                }
                
                if let cycles = dict["CycleCount"] as? NSNumber {
                    self.cycleCount = cycles.intValue
                }
                if let serial = dict["Serial"] as? String ?? dict["BatterySerialNumber"] as? String {
                    self.batterySerialNumber = serial
                }
                
                // 5. 温度
                if let rawTemp = dict["Temperature"] as? NSNumber {
                    let val = rawTemp.doubleValue
                    if val > 20000 {
                        resolvedTemp = (val / 100.0) - 273.15
                    } else if val > 2000 {
                        resolvedTemp = (val / 10.0) - 273.15
                    } else if val > 100 && val < 1000 {
                        resolvedTemp = val / 10.0
                    } else if val > 5 && val < 90 {
                        resolvedTemp = val
                    }
                }
            }
        }
        
        if resolvedTemp == nil {
            resolvedTemp = fetchBatteryTemperatureViaHID()
        }
        
        if let valid = resolvedTemp, valid > 5.0 && valid < 85.0 {
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
        
        var batteryCellTemps: [Double] = []
        var fallbackTemps: [Double] = []
        
        for service in servicesArray {
            if let nameRef = copyProp(service, "Product" as CFString)?.takeRetainedValue() as? String {
                let lower = nameRef.lowercased()
                if let eventUnmanaged = copyEvent(service, 15, 0, 0) {
                    let event = eventUnmanaged.takeRetainedValue()
                    let temp = getFloatVal(event, 0x000F0000)
                    if temp > 10.0 && temp < 80.0 {
                        if lower.contains("gas gauge") || lower.contains("battery") {
                            batteryCellTemps.append(temp)
                        } else if lower.contains("tb0t") {
                            fallbackTemps.append(temp)
                        }
                    }
                }
            }
        }
        
        if !batteryCellTemps.isEmpty {
            return batteryCellTemps.reduce(0.0, +) / Double(batteryCellTemps.count)
        }
        return fallbackTemps.first
    }
    
    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logHistory.append("[\(timestamp)] \(text)")
    }
}
