import Foundation
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - 动态屏幕亮度控制器 (私有框架 DisplayServices)
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
        case .silent: return "轻载放电 (0% CPU)"
        case .balanced: return "恒载放电 ~20W (50% 核心)"
        case .aggressive: return "快速放电 50W+ (全核心压测)"
        }
    }
}

enum CalibrationPhase: String {
    case waitingForTrigger = "待机"
    case chargingToFull = "充电中 (至 100%)"
    case discharging = "放电中 (至 10%)"
    case rechargingToFull = "再充中 (至 100%)"
    case holdingAtFull = "保持中 (饱和静置)"
    case dischargingToBuffer = "回落放电中 (至 80%)"
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
    @Published var cycleCount: Int = 0
    @Published var batterySerialNumber: String = "--"
    @Published var hardwareModel: String = "--"
    
    @Published var isCharging: Bool = false
    @Published var isExternalConnected: Bool = false
    @Published var isDischargingOnAC: Bool = false
    @Published var isAlDenteRunning: Bool = false
    @Published var isAlDenteCalibrating: Bool = false
    
    @Published var internalResistanceMilliohm: Double = 0.0
    
    // MARK: - 电芯平衡与单体压差
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
    
    // MARK: - SMC 硬件控制状态
    @Published var isHardwareControlAvailable: Bool = false
    @Published var isChargingInhibitedByApp: Bool = false
    
    @Published var historyRecords: [CalibrationHistoryRecord] = []
    
    // 开机自启动状态
    @Published var isLaunchAtLogin: Bool = false
    
    // 用户可配置阈值
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
    
    // MARK: - SMC 硬件充电阻断控制
    private func applyHardwareChargingInhibit(enabled: Bool) {
        guard BatteryControlClient.shared.isDaemonRegistered else {
            appendLog("SMC 控制跳过: 特权 Helper 服务未激活")
            return
        }
        
        Task {
            do {
                _ = try await BatteryControlClient.shared.setInhibitCharging(enabled: enabled)
                self.isChargingInhibitedByApp = enabled
                self.appendLog(enabled ? "SMC: 已强制阻断供电充电 (旁路放电开启)" : "SMC: 已解除充电限制 (恢复正常供电/充电)")
            } catch {
                self.appendLog("SMC 充电写入异常: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - 开机自启动设置
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
            appendLog("设置自启动失败: \(error.localizedDescription)")
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
                    self.appendLog("已获取系统通知权限")
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
            appendLog("检测到 AlDente Pro 启动校准，同步启动监测会话...")
            startCalibrationSession()
        } else if !isAlDenteCalibrating && isSessionRunning {
            appendLog("检测到 AlDente Pro 退出校准，同步停止监测会话...")
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
                appendLog("满电已就绪，进入放电校准阶段 (当前 \(currentPercentage)%)，启动负载策略 [\(stressMode.rawValue)]...")
                sendLocalNotification(
                    title: "放电阶段已开始",
                    body: "校准已开始电池放电过程，当前电量 \(currentPercentage)%"
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
                self.finalDischargeDurationText = "\(h)小时 \(m)分钟 (平均功率 \(String(format: "%.1f", dischargeAveragePower))W)"
                appendLog("放电达到目标阈值 (\(dischargeTargetPercentage)%)，放电耗时: \(h)小时\(m)分钟，平均功耗: \(String(format: "%.2f", dischargeAveragePower)) W")
                
                stopStressLoad()
                applyHardwareChargingInhibit(enabled: false)
                currentPhase = .rechargingToFull
                applyFastChargingOptimization(enable: true)
                
                sendLocalNotification(
                    title: "放电阶段已完成",
                    body: "电池已放电至目标阈值，将开始重新回充至 100%"
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
                appendLog("电池已充饱至 100%，进入保持沉淀阶段 (持续静置 10 分钟以校准极化电压)...")
                sendLocalNotification(
                    title: "电池已充满",
                    body: "电池达到 100% 满电，正在进行静置保持。"
                )
            }
        } else if currentPhase == .holdingAtFull {
            if let start = holdingStartDate, now.timeIntervalSince(start) >= holdingDurationSeconds {
                appendLog("保持静置阶段结束，阻断充电并启动放电回落至 80% 安全储存电量...")
                currentPhase = .dischargingToBuffer
                applyHardwareChargingInhibit(enabled: true)
                sendLocalNotification(
                    title: "开始回落放电",
                    body: "电池正在降至 80% 的长期健康存储电量。"
                )
            }
        } else if currentPhase == .dischargingToBuffer {
            if currentPercentage <= 80 {
                appendLog("电量已安全回落至 80%，恢复供电控制，校准全流程结束。")
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
            appendLog("已开启极速回充策略 (降低屏幕功耗与系统发热)")
        } else {
            ScreenBrightnessController.shared.restoreBrightness()
            appendLog("回充完成，已恢复屏幕原始亮度")
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
                title: "过热熔断保护触发",
                body: "电池温度达到 \(String(format: "%.1f", currentTemperature))°C，已暂停放电负载压测。"
            )
            appendLog("温度熔断保护: \(String(format: "%.1f", currentTemperature))°C >= 阈值 \(highTempThreshold)°C，停止压测")
        } else if currentTemperature <= resumeTempThreshold && isThermalCutoffActive {
            isThermalCutoffActive = false
            startStressLoad()
            sendLocalNotification(
                title: "温度恢复正常",
                body: "电池温度降至 \(String(format: "%.1f", currentTemperature))°C，已恢复放电负载。"
            )
            appendLog("温度已冷却: \(String(format: "%.1f", currentTemperature))°C <= 恢复阈值 \(resumeTempThreshold)°C，恢复压测")
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
        appendLog(">>> 校准监测会话已启动 <<<")
        
        if signedAmperage < -0.05 || isDischargingOnAC {
            currentPhase = .discharging
            startDischargePercentage = currentPercentage
            dischargePhaseStartDate = Date()
            appendLog("系统正处于放电状态，直接进入放电监测阶段...")
            startStressLoad()
            applyHardwareChargingInhibit(enabled: true)
        } else {
            currentPhase = .chargingToFull
            dischargePhaseStartDate = nil
            appendLog("系统当前处于供电/充电状态，等待先充至 100%...")
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
        appendLog("校准监测会话已停止")
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
        appendLog("            电池校准过程已全部完成            ")
        appendLog("放电阶段总时长: \(finalDischargeDurationText)")
        appendLog("放电净能量: \(dischargeFormatted) Wh | 回充净能量: \(rechargeFormatted) Wh")
        appendLog("计算电池容量: \(capacityFormatted) Wh (\(mahFormatted) mAh) | 健康度: \(healthFormatted)")
        appendLog("库伦效率 (Coulombic Efficiency): \(coulombicFormatted)")
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
        macOS 电池校准精准度测算报告
        ==================================================
        设备机型: \(hardwareModel)
        电池序列号: \(batterySerialNumber)
        开始时间: \(sessionStartDate?.description(with: .current) ?? "--")
        结束时间: \(Date().description(with: .current))
        放电起始电量: \(startDischargePercentage)%
        放电持续时间: \(finalDischargeDurationText)
        电池循环计数: \(cycleCount) 次
        设计标称容量: \(String(format: "%.0f", designCapacityMAh)) mAh
        本次实测容量: \(capacityFormatted) Wh (\(mahFormatted) mAh)
        本次实测健康度: \(healthFormatted)
        """
        
        if let agg = aggregatedHealth {
            reportContent.append("""
            
            ----------------- 多周期综合评定 -----------------
            有效校准样本数: \(agg.validSessionsCount) 次
            综合真实容量: \(String(format: "%.0f", agg.trueCapacityMAh)) mAh (\(String(format: "%.2f", agg.trueCapacityWh)) Wh)
            综合真实健康度: \(String(format: "%.1f%%", agg.trueHealthPercentage))
            置信度评分: \(String(format: "%.0f%%", agg.confidenceScore))
            """)
        }
        
        reportContent.append("""
        
        ----------------- 电池物理特性参数 -----------------
        电池直流内阻 (DCIR): \(internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--")
        单体电芯电压分布: \(cellVoltages.map { String(format: "%.3fV", $0) }.joined(separator: ", "))
        单体最大压差 (ΔV): \(String(format: "%.1f mV", cellVoltageDeltaMillivolts))
        放电总净能量: \(dischargeFormatted) Wh (\(String(format: "%.3f", dischargeEnergyAh)) Ah)
        回充总吸收能量: \(rechargeFormatted) Wh (\(String(format: "%.3f", rechargeEnergyAh)) Ah)
        库伦充电效率: \(coulombicFormatted)
        当前实时电压: \(String(format: "%.2f V", currentVoltage))
        当前电池温度: \(String(format: "%.1f °C", currentTemperature))
        ----------------- 会话完整执行日志 -----------------
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
        
        appendLog("校准报表已自动导出至桌面: \(txtFileName) 与 \(csvFileName)")
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
            appendLog("AlDente 运行状态更新: \(running ? "已运行" : "未运行")")
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
            appendLog("AlDente Pro 校准流程: \(isCalibratingNow ? "进行中" : "待命/停止")")
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
            appendLog("已成功激活防休眠锁 (IOPMAssertion)")
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
            appendLog("静音模式: CPU 放电负载保持 0%")
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
        appendLog("已开启放电加速负载 [\(stressMode.rawValue)]: 启动 \(workersCount) 个工作线程")
    }
    
    private func stopStressLoad() {
        if !stressTasks.isEmpty {
            for task in stressTasks {
                task.cancel()
            }
            stressTasks.removeAll()
            appendLog("放电加速负载已全部停止")
        }
    }
    
    // MARK: - 电池信息获取与温度校准
    private func fetchBatteryDetails() {
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
                
                // 3. 供电状态
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
                
                // 4. 百分比与容量
                if let curCap = dict["CurrentCapacity"] as? NSNumber,
                   let maxCap = dict["MaxCapacity"] as? NSNumber,
                   maxCap.doubleValue > 0 {
                    self.currentPercentage = Int((curCap.doubleValue / maxCap.doubleValue) * 100.0)
                }
                
                // 提取单体电芯电压 (Cell Voltage) 与设计容量
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
                } else if let designCap = dict["DesignCapacity"] as? NSNumber {
                    self.designCapacityMAh = designCap.doubleValue
                }
                
                if let cycles = dict["CycleCount"] as? NSNumber {
                    self.cycleCount = cycles.intValue
                }
                if let serial = dict["Serial"] as? String ?? dict["BatterySerialNumber"] as? String {
                    self.batterySerialNumber = serial
                }
                
                // 5. 原生读取 AppleSmartBattery 温度
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
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
                for src in list {
                    guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                    if let t = desc["Temperature"] as? NSNumber {
                        let d = t.doubleValue
                        if d > 20000 {
                            resolvedTemp = (d / 100.0) - 273.15
                        } else if d > 2000 {
                            resolvedTemp = (d / 10.0) - 273.15
                        } else if d > 5.0 && d < 90.0 {
                            resolvedTemp = d
                        }
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
