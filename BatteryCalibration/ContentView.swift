import SwiftUI
import Charts

enum AppThemeColor: String, CaseIterable, Identifiable {
    case blue = "蓝色"
    case orange = "橙色"
    case cyan = "青色"
    case green = "绿色"
    
    var id: String { rawValue }
    
    var color: Color {
        switch self {
        case .blue: return .blue
        case .orange: return .orange
        case .cyan: return .cyan
        case .green: return .green
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case auto = "跟随系统"
    case light = "浅色"
    case dark = "深色"
    
    var id: String { rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: BatteryCalibrationManager
    @State private var isShowingHistorySheet: Bool = false
    @AppStorage("appThemeColor") private var appTheme: AppThemeColor = .blue
    @AppStorage("appAppearanceMode") private var appearanceMode: AppAppearanceMode = .auto
    @Environment(\.colorScheme) private var systemColorScheme
    
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedTab: String? = "monitor"
    
    private var activeColorScheme: ColorScheme {
        appearanceMode.colorScheme ?? systemColorScheme
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                // 侧边栏导航列表
                List(selection: $selectedTab) {
                    Section(header: Text("概览")) {
                        NavigationLink(value: "monitor") {
                            Label("校准监视", systemImage: "gauge.with.needle")
                        }
                    }
                }
                .listStyle(.sidebar)
                
                Spacer()
                
                Divider()
                
                // 底部偏好设置按钮与署名信息
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: {
                        selectedTab = "settings"
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 13, weight: .medium))
                            Text("偏好设置")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(selectedTab == "settings" ? appTheme.color : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selectedTab == "settings"
                                ? appTheme.color.opacity(activeColorScheme == .dark ? 0.2 : 0.12)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery Calibration v1.0.0")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Steven Yang")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                if selectedTab == "settings" {
                    SettingsEmbeddedView(manager: manager)
                } else {
                    mainMonitorView
                }
            }
            .frame(minWidth: 700, minHeight: 580)
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .sheet(isPresented: $isShowingHistorySheet) {
            HistoryManagementView(manager: manager, isPresented: $isShowingHistorySheet)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
    
    private var mainMonitorView: some View {
        VStack(spacing: 11) {
            headerIntegratedCard
            CalibrationPipelineCard(manager: manager, accentColor: appTheme.color)
            bentoDoubleDeckGrid
            
            // 图 1 需求位置：在电量趋势上面，展示 CPU功耗、CPU温度、风扇转速
            telemetryGaugeStrip
            
            dualOscilloscopeSection
                .frame(minHeight: 140, idealHeight: 170, maxHeight: 280)
            footerControlDeck
            collapsibleConsoleSection
                .frame(minHeight: 90, maxHeight: .infinity)
        }
        .padding(14)
        .background(
            Color(nsColor: activeColorScheme == .dark ? .windowBackgroundColor : .windowBackgroundColor)
        )
    }
    
    // MARK: - 1. 顶部主遥测卡片
    private var headerIntegratedCard: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                DynamicPowerGauge(
                    percentage: manager.currentPercentage,
                    isCharging: manager.isCharging,
                    isDischarging: manager.currentPhase == .discharging || manager.currentPhase == .dischargingToBuffer,
                    accentColor: appTheme.color
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("主监视器")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        phaseBadgeView
                    }
                    Text(headerStatusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.isAlDenteRunning ? (manager.isAlDenteCalibrating ? Color.orange : Color.green) : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(manager.isAlDenteRunning ? (manager.isAlDenteCalibrating ? "AlDente 校准中" : "AlDente 已就绪") : "AlDente 未运行")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                TelemetryGridItem(title: "电压", value: String(format: "%.2f", manager.currentVoltage), unit: "V", color: .primary)
                Divider().frame(height: 24).opacity(0.2)
                TelemetryGridItem(title: "电流", value: String(format: "%.2f", manager.signedAmperage), unit: "A", color: amperageColor)
                Divider().frame(height: 24).opacity(0.2)
                TelemetryGridItem(title: "功率", value: String(format: "%.2f", manager.currentPower), unit: "W", color: .orange)
                Divider().frame(height: 24).opacity(0.2)
                TelemetryGridItem(title: "电池温度", value: manager.currentTemperature > 0.0 ? String(format: "%.1f", manager.currentTemperature) : "--", unit: "°C", color: manager.currentTemperature >= manager.highTempThreshold ? .red : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                activeColorScheme == .dark
                    ? Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(activeColorScheme == .dark ? 0.08 : 0.12), lineWidth: 0.8)
            )
        }
        .padding(11)
        .modernGlassCard(colorScheme: activeColorScheme)
    }
    
    private var headerStatusText: String {
        if manager.isDischargingOnAC {
            return "放电中"
        } else if manager.isCharging {
            return "正在充电"
        } else if manager.isExternalConnected {
            return "电源已连接 (未充电)"
        } else {
            return "电池放电中"
        }
    }
    
    private var amperageColor: Color {
        if manager.signedAmperage < -0.05 { return .orange }
        if manager.signedAmperage > 0.05 { return .green }
        return .primary
    }
    
    private var phaseBadgeView: some View {
        let (badgeColor, icon, text): (Color, String, String) = {
            switch manager.currentPhase {
            case .discharging: return (.orange, "arrow.down.circle.fill", "放电标定")
            case .chargingToFull: return (appTheme.color, "arrow.up.circle.fill", "初充阶段")
            case .rechargingToFull: return (.purple, "bolt.shield.fill", "复充标定")
            case .holdingAtFull: return (.blue, "pause.circle.fill", "满电静置")
            case .dischargingToBuffer: return (.orange, "battery.75", "回落缓冲")
            case .completed: return (.green, "checkmark.circle.fill", "校准完成")
            case .waitingForTrigger: return (.secondary, "pause.circle.fill", "就绪")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(badgeColor.opacity(activeColorScheme == .dark ? 0.16 : 0.12))
        .clipShape(Capsule())
    }
    
    // MARK: - 3. Bento 双层指标网格
    private var bentoDoubleDeckGrid: some View {
        HStack(spacing: 8) {
            // 左侧：续航与功耗评估卡片
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("续航评估", systemImage: "timer")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.orange)
                    Spacer()
                    if manager.aiPredictedRemainingMinutes > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                            Text("AI 增强预测")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.purple)
                    } else if manager.currentPhase == .discharging {
                        Text("推算中")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                    }
                }
                
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("预估续航")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        let activeMinutes = manager.aiPredictedRemainingMinutes > 0 ? manager.aiPredictedRemainingMinutes : manager.estimatedRemainingMinutes
                        Text(activeMinutes > 0 ? "\(activeMinutes / 60)h \(activeMinutes % 60)m" : "--")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundColor(activeMinutes > 0 ? .orange : .secondary)
                    }
                    .frame(minWidth: 100, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全周期总耗时")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(manager.totalDischargeRuntimeMinutes > 0 ? "\(manager.totalDischargeRuntimeMinutes / 60)h \(manager.totalDischargeRuntimeMinutes % 60)m" : "--")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    .frame(minWidth: 100, alignment: .leading)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("平均功耗")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(String(format: "%.1f W", manager.dischargeAveragePower))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(10)
            .modernGlassCard(colorScheme: activeColorScheme)
            
            // 右侧：健康度与真实容量评估卡片
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("健康度与容量", systemImage: "gauge.with.needle.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(appTheme.color)
                    Spacer()
                    if manager.aiConfidence > 0 {
                        Text("置信度: \(Int(manager.aiConfidence))%")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.purple)
                    } else if let agg = manager.aggregatedHealth {
                        Text("多周期融合: \(agg.validSessionsCount) 次 (\(Int(agg.confidenceScore))%)")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text("循环: \(manager.cycleCount)次")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("真实总容量")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        let displayCap = manager.aiTrueCapacityMAh > 0 ? manager.aiTrueCapacityMAh : (manager.aggregatedHealth?.trueCapacityMAh ?? manager.calculatedCapacityMAh)
                        Text(displayCap > 0 ? "\(Int(displayCap)) mAh" : "--")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundColor(displayCap > 0 ? appTheme.color : .secondary)
                    }
                    .frame(minWidth: 100, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("综合健康度 (SOH)")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        let displayHealth = manager.aiTrueHealthPct > 0 ? manager.aiTrueHealthPct : (manager.aggregatedHealth?.trueHealthPercentage ?? manager.batteryHealthPercentage)
                        Text(displayHealth > 0 ? String(format: "%.1f%%", displayHealth) : "--")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(displayHealth >= 80 ? .green : (displayHealth > 0 ? .orange : .secondary))
                    }
                    .frame(minWidth: 100, alignment: .leading)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("直流内阻 (DCIR)")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(manager.internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", manager.internalResistanceMilliohm) : "--")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(10)
            .modernGlassCard(colorScheme: activeColorScheme)
        }
    }
    
    // MARK: - 精简 3 联仪表盘面板 (CPU功耗 / CPU温度 / 风扇转速)
    private var telemetryGaugeStrip: some View {
        HStack(spacing: 8) {
            TelemetryGaugeMiniCard(
                title: "CPU 功耗",
                value: String(format: "%.1f", manager.cpuPowerWatts),
                unit: "W",
                icon: "cpu",
                color: .orange,
                progress: min(1.0, manager.cpuPowerWatts / 50.0),
                colorScheme: activeColorScheme
            )
            TelemetryGaugeMiniCard(
                title: "CPU 温度",
                value: manager.cpuTemperatureCelsius > 0 ? String(format: "%.0f", manager.cpuTemperatureCelsius) : "--",
                unit: "°C",
                icon: "thermometer.medium",
                color: manager.cpuTemperatureCelsius >= 80 ? .red : .orange,
                progress: min(1.0, max(0.0, (manager.cpuTemperatureCelsius - 30.0) / 70.0)),
                colorScheme: activeColorScheme
            )
            FanSpeedAnimatedGaugeCard(
                rpm: manager.fanSpeedRPM,
                colorScheme: activeColorScheme
            )
        }
    }
    
    // MARK: - 4. 实时动态双示波器
    private var dualOscilloscopeSection: some View {
        HStack(spacing: 8) {
            let dischargePoints = manager.dischargeCurvePoints.isEmpty ? manager.chartDisplayPoints : manager.dischargeCurvePoints
            PrecisionScopeCard(
                title: manager.currentPhase == .discharging ? "放电衰减曲线 (100%~\(manager.dischargeTargetPercentage)%)" : "电量趋势 (SOC)",
                badgeValue: "\(manager.currentPercentage)%",
                badgeUnit: "SOC",
                tint: appTheme.color,
                yDomain: 0...100,
                unitSuffix: "%",
                yStepValues: [Double(manager.dischargeTargetPercentage), 50, 100],
                points: dischargePoints,
                valueKeyPath: \.percentage,
                colorScheme: activeColorScheme
            )
            
            let maxPower = max(35.0, (manager.chartDisplayPoints.map(\.power).max() ?? 20.0) + 5.0)
            PrecisionScopeCard(
                title: "瞬时功率",
                badgeValue: String(format: "%.2f", manager.currentPower),
                badgeUnit: "W",
                tint: .orange,
                yDomain: 0...maxPower,
                unitSuffix: "W",
                yStepValues: [0, maxPower * 0.5, maxPower],
                points: manager.chartDisplayPoints,
                valueKeyPath: \.power,
                colorScheme: activeColorScheme
            )
        }
    }
    
    // MARK: - 5. 底部负载模式控制栏与触发按钮
    private var footerControlDeck: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Text("放电负载")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                
                Picker("", selection: $manager.stressMode) {
                    Text("静音").tag(DischargeStressMode.silent)
                    Text("均衡").tag(DischargeStressMode.balanced)
                    Text("性能").tag(DischargeStressMode.aggressive)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                activeColorScheme == .dark
                    ? Color(nsColor: .controlBackgroundColor).opacity(0.6)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
            
            Spacer()
            
            if manager.currentPhase == .waitingForTrigger || manager.currentPhase == .completed {
                Button(action: { manager.startCalibrationSession() }) {
                    Label("开始校准", systemImage: "play.fill")
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(appTheme.color)
            } else {
                Button(action: { manager.stopCalibrationSession() }) {
                    Label("终止校准", systemImage: "stop.fill")
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            
            Button(action: { isShowingHistorySheet = true }) {
                Label("历史记录", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
        }
    }
    
    // MARK: - 6. 系统事件与遥测日志控制台
    private var collapsibleConsoleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("系统事件与遥测日志")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(manager.logHistory.count) 条事件")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(manager.logHistory.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(Color.primary.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(
                    activeColorScheme == .dark
                        ? Color(nsColor: .textBackgroundColor).opacity(0.35)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.85)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(activeColorScheme == .dark ? 0.08 : 0.12), lineWidth: 0.8)
                )
                .onChange(of: manager.logHistory.count) { oldCount, newCount in
                    if newCount > 0 {
                        withAnimation {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 校准管道全景状态卡片
private struct CalibrationPipelineCard: View {
    @ObservedObject var manager: BatteryCalibrationManager
    let accentColor: Color
    
    var body: some View {
        HStack(spacing: 0) {
            stageItem(
                title: "充电至\n100%",
                iconType: .charge100,
                isActive: manager.currentPhase == .chargingToFull
            )
            
            arrowDivider
            
            stageItem(
                title: "放电至\n\(manager.dischargeTargetPercentage)%",
                iconType: .discharge10,
                isActive: manager.currentPhase == .discharging
            )
            
            arrowDivider
            
            stageItem(
                title: "充电至\n100%",
                iconType: .charge100,
                isActive: manager.currentPhase == .rechargingToFull
            )
            
            arrowDivider
            
            stageItem(
                title: "保持\n满电静置",
                iconType: .hold,
                isActive: manager.currentPhase == .holdingAtFull
            )
            
            arrowDivider
            
            stageItem(
                title: "放电到\n80%",
                iconType: .discharge80,
                isActive: manager.currentPhase == .dischargingToBuffer
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
        )
    }
    
    private enum PipelineIconType {
        case charge100
        case discharge10
        case hold
        case discharge80
    }
    
    private func stageItem(title: String, iconType: PipelineIconType, isActive: Bool) -> some View {
        VStack(spacing: 6) {
            stageIcon(for: iconType, isActive: isActive)
                .frame(width: 32, height: 22, alignment: .center)
            
            Text(title)
                .font(.system(size: 9.5, weight: isActive ? .bold : .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(isActive ? .primary : .secondary)
                .lineSpacing(-1)
                .frame(height: 24, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    private func stageIcon(for type: PipelineIconType, isActive: Bool) -> some View {
        let activeColor: Color = {
            switch type {
            case .charge100: return .green
            case .discharge10, .discharge80: return .orange
            case .hold: return .blue
            }
        }()
        let inactiveColor = Color.secondary.opacity(0.4)
        let displayColor = isActive ? activeColor : inactiveColor
        
        ZStack {
            switch type {
            case .charge100:
                ZStack {
                    Image(systemName: "battery.100")
                        .font(.system(size: 20))
                    Image(systemName: "plus")
                        .font(.system(size: 7.5, weight: .heavy))
                        .offset(x: -1.2)
                }
            case .discharge10:
                ZStack {
                    Image(systemName: "battery.25")
                        .font(.system(size: 20))
                    Image(systemName: "minus")
                        .font(.system(size: 7.5, weight: .heavy))
                        .offset(x: -1.2)
                }
            case .hold:
                ZStack {
                    Image(systemName: "battery.100")
                        .font(.system(size: 20))
                    Image(systemName: "pause.fill")
                        .font(.system(size: 6.5, weight: .heavy))
                        .offset(x: -1.2)
                }
            case .discharge80:
                ZStack {
                    Image(systemName: "battery.75")
                        .font(.system(size: 20))
                    Image(systemName: "minus")
                        .font(.system(size: 7.5, weight: .heavy))
                        .offset(x: -1.2)
                }
            }
        }
        .foregroundColor(displayColor)
        .frame(width: 32, height: 22, alignment: .center)
        .scaleEffect(isActive ? 1.15 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
    }
    
    private var arrowDivider: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary.opacity(0.4))
                .frame(width: 22, height: 22, alignment: .center)
            
            Spacer()
                .frame(height: 24)
        }
    }
}

// MARK: - 主动态环形电量表盘
private struct DynamicPowerGauge: View {
    let percentage: Int
    let isCharging: Bool
    let isDischarging: Bool
    var accentColor: Color = .blue
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.01, min(1.0, Double(percentage) / 100.0))))
                .stroke(
                    LinearGradient(
                        colors: percentage <= 20 ? [.red, .orange] : (isCharging ? [.green, .mint] : [accentColor, .cyan]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(
                    color: (isCharging ? Color.green : (percentage <= 20 ? Color.red : accentColor)).opacity(0.35),
                    radius: 3
                )
            VStack(spacing: 0) {
                Image(systemName: isCharging ? "bolt.fill" : (isDischarging ? "flame.fill" : "battery.100"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isCharging ? .green : (isDischarging ? .orange : accentColor))
                Text("\(percentage)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

// MARK: - 高精度动态示波器卡片组件
struct PrecisionScopeCard: View {
    let title: String
    let badgeValue: String
    let badgeUnit: String
    let tint: Color
    let yDomain: ClosedRange<Double>
    let unitSuffix: String
    let yStepValues: [Double]
    let points: [CalibrationDataPoint]
    let valueKeyPath: KeyPath<CalibrationDataPoint, Double>
    let colorScheme: ColorScheme
    
    @State private var selectedPoint: CalibrationDataPoint? = nil
    @State private var indicatorXPosition: CGFloat? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .shadow(color: tint.opacity(0.6), radius: 2)
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.primary.opacity(0.85))
                }
                Spacer()
                if let probe = selectedPoint {
                    HStack(spacing: 4) {
                        Text(probe.timestamp, style: .time)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", probe[keyPath: valueKeyPath])) \(unitSuffix)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(tint)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 1.5) {
                        Text(badgeValue)
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundColor(tint)
                        Text(badgeUnit)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            
            ZStack(alignment: .topLeading) {
                Chart {
                    ForEach(points) { pt in
                        AreaMark(
                            x: .value("时间", pt.timestamp),
                            y: .value("数值", pt[keyPath: valueKeyPath])
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tint.opacity(colorScheme == .dark ? 0.35 : 0.20), tint.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        
                        LineMark(
                            x: .value("时间", pt.timestamp),
                            y: .value("数值", pt[keyPath: valueKeyPath])
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(tint)
                    }
                    
                    if let probe = selectedPoint {
                        RuleMark(x: .value("探针", probe.timestamp))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(Color.primary.opacity(0.5))
                            
                        PointMark(
                            x: .value("探针", probe.timestamp),
                            y: .value("数值", probe[keyPath: valueKeyPath])
                        )
                        .symbolSize(36)
                        .foregroundStyle(tint)
                    } else if let lastPt = points.last {
                        PointMark(
                            x: .value("最新", lastPt.timestamp),
                            y: .value("数值", lastPt[keyPath: valueKeyPath])
                        )
                        .symbolSize(22)
                        .foregroundStyle(tint)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: yStepValues) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.1))
                        AxisValueLabel {
                            if let d = val.as(Double.self) {
                                Text("\(Int(d))\(unitSuffix)")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.08))
                        AxisValueLabel()
                            .font(.system(size: 7.5))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        updateProbeLocation(at: value.location, proxy: proxy, geometry: geometry)
                                    }
                                    .onEnded { _ in
                                        selectedPoint = nil
                                        indicatorXPosition = nil
                                    }
                            )
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateProbeLocation(at: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    selectedPoint = nil
                                    indicatorXPosition = nil
                                }
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                
                if let probe = selectedPoint, let posX = indicatorXPosition {
                    HStack(spacing: 4) {
                        Text(probe.timestamp, style: .time)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(Int(probe.percentage))%")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.blue)
                        Text(String(format: "%.1fW", probe.power))
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                    .offset(x: min(max(posX - 45, 4), 190), y: 2)
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                        : Color(nsColor: .controlBackgroundColor)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.12), lineWidth: 0.8)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.04),
            radius: 3, x: 0, y: 1
        )
    }
    
    private func updateProbeLocation(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let plotOriginX = geometry[plotFrame].origin.x
        let currentX = location.x - plotOriginX
        guard let targetDate: Date = proxy.value(atX: currentX) else { return }
        if let nearest = points.min(by: { abs($0.timestamp.timeIntervalSince(targetDate)) < abs($1.timestamp.timeIntervalSince(targetDate)) }) {
            self.selectedPoint = nearest
            self.indicatorXPosition = location.x
        }
    }
}

// MARK: - 顶栏数字监控微单元
struct TelemetryGridItem: View {
    let title: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                    .foregroundColor(color)
                Text(unit)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 硬件仪表盘卡片与风扇动图组件 (CPU 功耗/温度/风扇)
private struct TelemetryGaugeMiniCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    let progress: Double
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0.0, to: CGFloat(max(0.04, min(1.0, progress))))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(value)
                        .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                        .foregroundColor(.primary)
                    Text(unit)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .modernGlassCard(colorScheme: colorScheme)
    }
}

private struct FanSpeedAnimatedGaugeCard: View {
    let rpm: Int
    let colorScheme: ColorScheme
    @State private var rotationAngle: Double = 0.0

    private var animationDuration: Double {
        if rpm <= 0 { return 0 }
        return max(0.2, 3200.0 / Double(max(rpm, 400)))
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.cyan.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0.0, to: CGFloat(min(1.0, Double(rpm) / 6500.0)))
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.cyan)
                    .rotationEffect(.degrees(rotationAngle))
            }
            .frame(width: 32, height: 32)
            .onAppear {
                guard rpm > 0 else { return }
                withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
                    rotationAngle = 360.0
                }
            }
            .onChange(of: rpm > 0) { _, isSpinning in
                if isSpinning {
                    withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
                        rotationAngle = 360.0
                    }
                } else {
                    withAnimation(.default) {
                        rotationAngle = 0.0
                    }
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("风扇转速")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(rpm > 0 ? "\(rpm)" : "0")
                        .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                        .foregroundColor(.primary)
                    Text("RPM")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .modernGlassCard(colorScheme: colorScheme)
    }
}

// MARK: - 现代毛玻璃 Card Modifier
extension View {
    func modernGlassCard(colorScheme: ColorScheme) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(nsColor: .controlBackgroundColor).opacity(0.8)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.12),
                        lineWidth: 0.8
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.06),
                radius: colorScheme == .dark ? 4 : 3,
                x: 0,
                y: 1
            )
    }
}

// MARK: - 历史记录管理 Sheet
struct HistoryManagementView: View {
    @ObservedObject var manager: BatteryCalibrationManager
    @Binding var isPresented: Bool
    @State private var selectedRecordID: UUID? = nil
    
    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.blue)
                    Text("历史校准记录")
                        .font(.headline)
                }
                Spacer()
                if !manager.historyRecords.isEmpty {
                    Button(role: .destructive, action: {
                        manager.clearAllHistory()
                    }) {
                        Text("清空记录")
                    }
                    .buttonStyle(.bordered)
                }
                Button("完成") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            
            Divider()
            
            if manager.historyRecords.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "archivebox")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("暂无已保存的校准数据")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.historyRecords, selection: $selectedRecordID) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(dateFormatter.string(from: record.startDate), systemImage: "calendar")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            Text("SOH: \(String(format: "%.1f%%", record.batteryHealthPercentage))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(record.batteryHealthPercentage >= 80 ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .foregroundColor(record.batteryHealthPercentage >= 80 ? .green : .orange)
                                .clipShape(Capsule())
                            
                            Button(action: {
                                manager.deleteHistoryRecord(id: record.id)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        HStack(spacing: 12) {
                            GridItemMetric(title: "测定容量", value: "\(Int(record.calculatedCapacityMAh)) mAh")
                            GridItemMetric(title: "放电能耗", value: "\(String(format: "%.2f", record.dischargeEnergyWh)) Wh")
                            GridItemMetric(title: "设计容量", value: "\(Int(record.designCapacityMAh)) mAh")
                            GridItemMetric(title: "库仑效率", value: "\(String(format: "%.1f%%", record.coulombicEfficiency))")
                            GridItemMetric(title: "循环次数", value: "\(record.cycleCount) 次")
                            if record.internalResistanceMilliohm > 0 {
                                GridItemMetric(title: "DCIR", value: "\(String(format: "%.1f mΩ", record.internalResistanceMilliohm))")
                            }
                        }
                        
                        if record.reportFilePath != nil || record.csvFilePath != nil {
                            HStack(spacing: 8) {
                                if let report = record.reportFilePath, FileManager.default.fileExists(atPath: report) {
                                    Button("查看文本报告") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report)])
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption2)
                                }
                                if let csv = record.csvFilePath, FileManager.default.fileExists(atPath: csv) {
                                    Button("CSV 遥测数据") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: csv)])
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption2)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 580, minHeight: 380)
    }
}

// MARK: - 设置嵌入视图
private struct SettingsEmbeddedView: View {
    @ObservedObject var manager: BatteryCalibrationManager
    @AppStorage("appThemeColor") private var appTheme: AppThemeColor = .blue
    @AppStorage("appAppearanceMode") private var appearanceMode: AppAppearanceMode = .auto
    
    var body: some View {
        Form {
            Section(header: Text("外观与样式").font(.subheadline).bold()) {
                Picker("主题模式", selection: $appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                
                Picker("强调色", selection: $appTheme) {
                    ForEach(AppThemeColor.allCases) { theme in
                        HStack {
                            Circle().fill(theme.color).frame(width: 8, height: 8)
                            Text(theme.rawValue)
                        }
                        .tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Section(header: Text("制定与控制").font(.subheadline).bold()) {
                Toggle("开机自启", isOn: Binding(
                    get: { manager.isLaunchAtLogin },
                    set: { manager.setLaunchAtLogin(enabled: $0) }
                ))
                
                Picker("放电终止阈值", selection: $manager.dischargeTargetPercentage) {
                    Text("5% (极深校准)").tag(5)
                    Text("10% (推荐标准)").tag(10)
                    Text("15% (温和模式)").tag(15)
                    Text("20% (快速校准)").tag(20)
                }
                
                Toggle("阶段切换提示音", isOn: $manager.soundAlertEnabled)
                Toggle("完成后自动导出报告及 CSV", isOn: $manager.autoExportReports)
            }
            
            Section(header: Text("温控保护").font(.subheadline).bold()) {
                HStack {
                    Text("过热保护阈值")
                    Spacer()
                    Text("\(Int(manager.highTempThreshold)) °C")
                        .foregroundColor(.secondary)
                        .monospaced()
                }
                Slider(value: $manager.highTempThreshold, in: 38.0...55.0, step: 1.0)
                
                HStack {
                    Text("负载恢复阈值")
                    Spacer()
                    Text("\(Int(manager.resumeTempThreshold)) °C")
                        .foregroundColor(.secondary)
                        .monospaced()
                }
                Slider(value: $manager.resumeTempThreshold, in: 30.0...42.0, step: 1.0)
            }
            
            Section(header: Text("遥测与诊断").font(.subheadline).bold()) {
                LabeledContent("测定满充容量", value: manager.aiTrueCapacityMAh > 0 ? "\(Int(manager.aiTrueCapacityMAh)) mAh" : "--")
                LabeledContent("真实健康度", value: manager.aiTrueHealthPct > 0 ? String(format: "%.1f%%", manager.aiTrueHealthPct) : "--")
                LabeledContent("剩余容量", value: manager.aiEstimatedRemainingMAh > 0 ? "\(Int(manager.aiEstimatedRemainingMAh)) mAh" : "--")
                LabeledContent("CPU 功耗", value: String(format: "%.2f W", manager.estimatedCpuPower))
                LabeledContent("屏幕功耗", value: String(format: "%.2f W", manager.estimatedScreenPower))
                LabeledContent("主板与外设功耗", value: String(format: "%.2f W", manager.estimatedBoardPower))
            }
            
            Section(header: Text("硬件诊断参数").font(.subheadline).bold()) {
                LabeledContent("设备型号标识", value: manager.hardwareModel)
                LabeledContent("电池序列号", value: manager.batterySerialNumber)
                LabeledContent("出厂设计容量", value: "\(Int(manager.designCapacityMAh)) mAh")
                LabeledContent("循环计数", value: "\(manager.cycleCount) 次")
                
                if !manager.cellVoltages.isEmpty {
                    LabeledContent("多串电芯电压", value: manager.cellVoltages.map { String(format: "%.3fV", $0) }.joined(separator: " | "))
                    LabeledContent("电芯压差 (ΔV)", value: String(format: "%.1f mV %@", manager.cellVoltageDeltaMillivolts, manager.cellVoltageDeltaMillivolts <= 15 ? "(极佳)" : (manager.cellVoltageDeltaMillivolts <= 40 ? "(正常)" : "(不均衡)")))
                }
            }
            
            Section(header: Text("关于此软件").font(.subheadline).bold()) {
                LabeledContent("应用名称", value: "Battery Calibration")
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("开发者支持", value: "s251147jx@gmail.com")
                LabeledContent("版权所有", value: "Steven Yang (Infinity Computer)")
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }
}

private struct GridItemMetric: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }
}
