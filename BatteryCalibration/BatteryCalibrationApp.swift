import SwiftUI

@main
struct BatteryCalibratorApp: App {
    @StateObject private var manager = BatteryCalibrationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
        }
        .defaultSize(width: 760, height: 600)
        // MARK: - MenuBar 状态栏常驻卡片
        MenuBarExtra {
            MenuBarControlPanel(manager: manager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menuBarBatteryIcon)
                Text("\(manager.currentPercentage)%")
                if abs(manager.currentPower) >= 0.1 {
                    Text(String(format: "%.1fW", manager.currentPower))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
    
    private var menuBarBatteryIcon: String {
        if manager.isCharging {
            return "bolt.batteryblock.fill"
        } else if manager.isDischargingOnAC {
            return "battery.100.bolt"
        } else {
            let pct = manager.currentPercentage
            if pct >= 85 { return "battery.100" }
            if pct >= 60 { return "battery.75" }
            if pct >= 35 { return "battery.50" }
            if pct >= 15 { return "battery.25" }
            return "battery.0"
        }
    }
}

// MARK: - MenuBar Card Control Panel View
struct MenuBarControlPanel: View {
    @ObservedObject var manager: BatteryCalibrationManager
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: manager.isCharging ? "bolt.batteryblock.fill" : "battery.100")
                        .font(.title2)
                        .foregroundColor(manager.isCharging ? .green : .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(manager.currentPercentage)%")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text(manager.currentPhase.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if manager.currentPhase == .discharging && manager.estimatedRemainingMinutes > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("预估剩余")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("\(manager.estimatedRemainingMinutes) 分钟")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 4)
            
            Divider()
            
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    CompactMiniMetric(title: "实时功率", value: String(format: "%.2f W", manager.currentPower), icon: "bolt.fill", color: .orange)
                    CompactMiniMetric(title: "总线电压", value: String(format: "%.2f V", manager.currentVoltage), icon: "waveform", color: .primary)
                }
                GridRow {
                    CompactMiniMetric(title: "充放电流", value: String(format: "%.2f A", manager.signedAmperage), icon: "speedometer", color: manager.signedAmperage < -0.05 ? .orange : (manager.signedAmperage > 0.05 ? .green : .primary))
                    CompactMiniMetric(title: "电池温度", value: String(format: "%.1f °C", manager.currentTemperature), icon: "thermometer.medium", color: manager.currentTemperature >= 45.0 ? .red : .primary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("放电负载策略")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Picker("", selection: $manager.stressMode) {
                    ForEach(DischargeStressMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Divider()
            
            HStack(spacing: 8) {
                if manager.currentPhase == .waitingForTrigger || manager.currentPhase == .completed {
                    Button(action: {
                        manager.startCalibrationSession()
                    }) {
                        Label("启动校准", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    Button(action: {
                        manager.stopCalibrationSession()
                    }) {
                        Label("终止校准", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                }
                .buttonStyle(.bordered)
                .help("退出程序")
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

private struct CompactMiniMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            Spacer()
        }
        .padding(6)
        .background(Color(nsColor: .quaternaryLabelColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
