import SwiftUI
import Charts

enum AppThemeColor: String, CaseIterable, Identifiable {
    case blue = "经典蓝"
    case orange = "活力橙"
    case cyan = "工业青"
    case green = "极客绿"
    
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

struct ContentView: View {
    @ObservedObject var manager: BatteryCalibrationManager
    @State private var isShowingHistorySheet: Bool = false
    @State private var isShowingSettingsSheet: Bool = false
    @AppStorage("appThemeColor") private var appTheme: AppThemeColor = .blue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            headerIntegratedCard
            bentoDoubleDeckGrid
            
            // 示波图区域：设为弹性伸缩
            dualOscilloscopeSection
                .frame(minHeight: 140, idealHeight: 170, maxHeight: 280)
            
            footerControlDeck
            
            // 底部控制台：占据垂直剩余扩展空间
            collapsibleConsoleSection
                .frame(minHeight: 90, maxHeight: .infinity)
        }
        .padding(12)
        .frame(minWidth: 740, idealWidth: 780, maxWidth: .infinity, minHeight: 560, idealHeight: 650, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingHistorySheet) {
            HistoryManagementView(manager: manager, isPresented: $isShowingHistorySheet)
        }
        .sheet(isPresented: $isShowingSettingsSheet) {
            SettingsView(manager: manager, isPresented: $isShowingSettingsSheet)
        }
    }

    // MARK: - 1. 紧凑集成式状态与遥测卡片
    private var headerIntegratedCard: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                DynamicPowerGauge(
                    percentage: manager.currentPercentage,
                    isCharging: manager.isCharging,
                    isDischarging: manager.currentPhase == .discharging,
                    accentColor: appTheme.color
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("电池校准监视器")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        phaseBadgeView
                    }
                    Text(headerStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.isAlDenteRunning ? (manager.isAlDenteCalibrating ? Color.orange : Color.green) : Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                        Text(manager.isAlDenteRunning ? (manager.isAlDenteCalibrating ? "AlDente 校准联动中" : "AlDente 待命中") : "未检测到 AlDente")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                TelemetryGridItem(title: "总线电压", value: String(format: "%.2f", manager.currentVoltage), unit: "V", color: .primary)
                Divider().frame(height: 24).opacity(0.2)
                TelemetryGridItem(title: "充放电流", value: String(format: "%.2f", manager.signedAmperage), unit: "A", color: amperageColor)
                Divider().frame(height: 24).opacity(0.2)
                TelemetryGridItem(title: "瞬时功率", value: String(format: "%.2f", manager.currentPower), unit: "W", color: .orange)
                Divider().frame(height: 24).opacity(0.2)
                TelemetryGridItem(title: "电池温度", value: manager.currentTemperature > 0.0 ? String(format: "%.1f", manager.currentTemperature) : "--", unit: "°C", color: manager.currentTemperature >= manager.highTempThreshold ? .red : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(colorScheme == .dark ? 0.35 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .modernGlassCard(colorScheme: colorScheme)
    }

    private var headerStatusText: String {
        if manager.isDischargingOnAC {
            return "AlDente 旁路校准放电中"
        } else if manager.isCharging {
            return "正在充电"
        } else if manager.isExternalConnected {
            return "已连接电源 (待机)"
        } else {
            return "电池供电运行中"
        }
    }

    private var amperageColor: Color {
        if manager.signedAmperage < -0.05 { return .orange }
        if manager.signedAmperage > 0.05 { return .green }
        return .primary
    }

    private var phaseBadgeView: some View {
        let (badgeColor, icon): (Color, String) = {
            switch manager.currentPhase {
            case .discharging: return (.orange, "arrow.down.circle.fill")
            case .chargingToFull: return (appTheme.color, "arrow.up.circle.fill")
            case .rechargingToFull: return (.purple, "bolt.shield.fill")
            case .completed: return (.green, "checkmark.circle.fill")
            case .waitingForTrigger: return (.secondary, "pause.circle.fill")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(manager.currentPhase.rawValue).font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(badgeColor.opacity(colorScheme == .dark ? 0.16 : 0.12))
        .clipShape(Capsule())
    }

    // MARK: - 2. 双栏 Bento 矩阵
    private var bentoDoubleDeckGrid: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("100%~10% 放电工况预估", systemImage: "timer")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.orange)
                    Spacer()
                    if manager.currentPhase == .discharging {
                        Text("放电中")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                    }
                }
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("预估剩余放电时间")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        Text(manager.estimatedRemainingMinutes > 0 ? "\(manager.estimatedRemainingMinutes / 60)h \(manager.estimatedRemainingMinutes % 60)m" : "--")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundColor(manager.estimatedRemainingMinutes > 0 ? .orange : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("区间总工时 (100%~10%)")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        Text(manager.totalDischargeRuntimeMinutes > 0 ? "\(manager.totalDischargeRuntimeMinutes / 60)h \(manager.totalDischargeRuntimeMinutes % 60)m" : "--")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("平均功耗")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f W", manager.dischargeAveragePower))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(9)
            .modernGlassCard(colorScheme: colorScheme)

            // 右卡片：多周期加权真实健康度与实测容量
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("真实容量与健康度 (多周期评定)", systemImage: "gauge.with.needle.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(appTheme.color)
                    Spacer()
                    if let agg = manager.aggregatedHealth {
                        Text("基于 \(agg.validSessionsCount) 次校准 (置信度 \(Int(agg.confidenceScore))%)")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text("循环数: \(manager.cycleCount)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(manager.aggregatedHealth != nil ? "综合真实容量" : "单次实测容量")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        let displayCap = manager.aggregatedHealth?.trueCapacityMAh ?? manager.calculatedCapacityMAh
                        Text(displayCap > 0 ? "\(Int(displayCap)) mAh" : "--")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundColor(displayCap > 0 ? appTheme.color : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(manager.aggregatedHealth != nil ? "真实健康度 (SOH)" : "单次健康度")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        let displayHealth = manager.aggregatedHealth?.trueHealthPercentage ?? manager.batteryHealthPercentage
                        Text(displayHealth > 0 ? String(format: "%.1f%%", displayHealth) : "--")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(displayHealth >= 80 ? .green : (displayHealth > 0 ? .orange : .secondary))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("直流内阻 (DCIR)")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        Text(manager.internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", manager.internalResistanceMilliohm) : "--")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(9)
            .modernGlassCard(colorScheme: colorScheme)
        }
    }

    // MARK: - 3. 示波器区域
    private var dualOscilloscopeSection: some View {
        HStack(spacing: 8) {
            let dischargePoints = manager.dischargeCurvePoints.isEmpty ? manager.chartDisplayPoints : manager.dischargeCurvePoints
            PrecisionScopeCard(
                title: manager.currentPhase == .discharging ? "放电特性曲线 (100%~10%)" : "电量走势 (SOC)",
                badgeValue: "\(manager.currentPercentage)%",
                badgeUnit: "SOC",
                tint: appTheme.color,
                yDomain: 0...100,
                unitSuffix: "%",
                yStepValues: [10, 50, 100],
                points: dischargePoints,
                valueKeyPath: \.percentage,
                colorScheme: colorScheme
            )

            let maxPower = max(35.0, (manager.chartDisplayPoints.map(\.power).max() ?? 20.0) + 5.0)
            PrecisionScopeCard(
                title: "瞬时充放功率",
                badgeValue: String(format: "%.2f", manager.currentPower),
                badgeUnit: "W",
                tint: .orange,
                yDomain: 0...maxPower,
                unitSuffix: "W",
                yStepValues: [0, maxPower * 0.5, maxPower],
                points: manager.chartDisplayPoints,
                valueKeyPath: \.power,
                colorScheme: colorScheme
            )
        }
    }

    // MARK: - 4. 底部控制栏（含设置按钮）
    private var footerControlDeck: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Text("放电负载策略")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("", selection: $manager.stressMode) {
                    ForEach(DischargeStressMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 195)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.6 : 0.75))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))

            Spacer()

            if manager.currentPhase == .waitingForTrigger || manager.currentPhase == .completed {
                Button(action: { manager.startCalibrationSession() }) {
                    Label("启动校准流程", systemImage: "play.fill")
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
                Label("历史归档", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            
            // 设置按钮 (⚙️)
            Button(action: { isShowingSettingsSheet = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(appTheme.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .help("首选项与高级配置")
        }
    }

    // MARK: - 5. 弹性控制台日志区域
    private var collapsibleConsoleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("实时遥测与底层校准日志")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(manager.logHistory.count) 条事件")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(manager.logHistory.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(Color.primary.opacity(0.88))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.35 : 0.45))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                .onChange(of: manager.logHistory.count) { newCount in
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

// MARK: - 动态环形进度条
private struct DynamicPowerGauge: View {
    let percentage: Int
    let isCharging: Bool
    let isDischarging: Bool
    var accentColor: Color = .blue

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 5)

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

// MARK: - 示波器卡片视图
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
                    .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.1))
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
                                colors: [tint.opacity(colorScheme == .dark ? 0.35 : 0.22), tint.opacity(0.0)],
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
                            x: .value("探针点", probe.timestamp),
                            y: .value("探针值", probe[keyPath: valueKeyPath])
                        )
                        .symbolSize(36)
                        .foregroundStyle(tint)
                    } else if let lastPt = points.last {
                        PointMark(
                            x: .value("当前点", lastPt.timestamp),
                            y: .value("当前值", lastPt[keyPath: valueKeyPath])
                        )
                        .symbolSize(22)
                        .foregroundStyle(tint)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: yStepValues) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
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
                            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
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
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                    .offset(x: min(max(posX - 45, 4), 190), y: 2)
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colorScheme == .dark ? Color(nsColor: .quaternaryLabelColor).opacity(0.35) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.02), radius: 3, x: 0, y: 1)
    }

    private func updateProbeLocation(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotOriginX = geometry[proxy.plotAreaFrame].origin.x
        let currentX = location.x - plotOriginX
        guard let targetDate: Date = proxy.value(atX: currentX) else { return }
        if let nearest = points.min(by: { abs($0.timestamp.timeIntervalSince(targetDate)) < abs($1.timestamp.timeIntervalSince(targetDate)) }) {
            self.selectedPoint = nearest
            self.indicatorXPosition = location.x
        }
    }
}

// MARK: - 实时遥测指标项
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

// MARK: - 玻璃质感圆角卡片修饰器
extension View {
    func modernGlassCard(colorScheme: ColorScheme) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.03), radius: 4, x: 0, y: 1)
    }
}

// MARK: - 历史归档弹窗
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
                    Text("校准历史归档")
                        .font(.headline)
                }
                Spacer()
                if !manager.historyRecords.isEmpty {
                    Button(role: .destructive, action: {
                        manager.clearAllHistory()
                    }) {
                        Text("清空历史")
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
                    Text("暂无校准记录")
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
                            Text("健康度: \(String(format: "%.1f%%", record.batteryHealthPercentage))")
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
                            GridItemMetric(title: "实际容量", value: "\(Int(record.calculatedCapacityMAh)) mAh")
                            GridItemMetric(title: "释放能量", value: "\(String(format: "%.2f", record.dischargeEnergyWh)) Wh")
                            GridItemMetric(title: "标称容量", value: "\(Int(record.designCapacityMAh)) mAh")
                            GridItemMetric(title: "库仑效率", value: "\(String(format: "%.1f%%", record.coulombicEfficiency))")
                            GridItemMetric(title: "循环数", value: "\(record.cycleCount) 次")
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
                                    Button("查看 CSV 数据") {
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

// MARK: - 新增设置视图 (SettingsView)
struct SettingsView: View {
    @ObservedObject var manager: BatteryCalibrationManager
    @Binding var isPresented: Bool
    @AppStorage("appThemeColor") private var appTheme: AppThemeColor = .blue
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(appTheme.color)
                    Text("偏好设置与质检标定")
                        .font(.headline)
                }
                Spacer()
                Button("完成") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            
            Divider()
            
            Form {
                Section(header: Text("界面与交互风格").font(.subheadline).bold()) {
                    Picker("应用强调色", selection: $appTheme) {
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
                
                Section(header: Text("安全保护与阈值控制").font(.subheadline).bold()) {
                    HStack {
                        Text("放电过热熔断保护")
                        Spacer()
                        Text("\(Int(manager.highTempThreshold)) °C")
                            .foregroundColor(.secondary)
                            .monospaced()
                    }
                    Slider(value: $manager.highTempThreshold, in: 38.0...55.0, step: 1.0)
                    
                    HStack {
                        Text("降温自动恢复阈值")
                        Spacer()
                        Text("\(Int(manager.resumeTempThreshold)) °C")
                            .foregroundColor(.secondary)
                            .monospaced()
                    }
                    Slider(value: $manager.resumeTempThreshold, in: 30.0...42.0, step: 1.0)
                }
                
                Section(header: Text("检测设备与硬件出厂信息").font(.subheadline).bold()) {
                    LabeledContent("Mac 机型标识", value: manager.hardwareModel)
                    LabeledContent("电池出厂序列号", value: manager.batterySerialNumber)
                    LabeledContent("设计标称容量", value: "\(Int(manager.designCapacityMAh)) mAh")
                    LabeledContent("电池累计循环", value: "\(manager.cycleCount) 次")
                }
                
                Section(header: Text("关于与开发者信息").font(.subheadline).bold()) {
                    LabeledContent("应用程序", value: "Battery Calibration Pro")
                    LabeledContent("软件版本", value: "1.0.0 (Build 2026.09)")
                    LabeledContent("联动引擎", value: "AlDente Pro Dual-Pipeline")
                    LabeledContent("开发者", value: "Steven Yang (Infinity Computer)")
                }
            }
            .formStyle(.grouped)
            .padding(10)
        }
        .frame(minWidth: 500, minHeight: 460)
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
