import SwiftUI

@main
struct BatteryCalibratorApp: App {
    @StateObject private var manager = BatteryCalibrationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
        }
        .defaultSize(width: 760, height: 600)
        
        // MARK: - MenuBar 菜单栏常驻
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
                
                // AI 精准剩余续航展示
                if manager.aiPredictedRemainingMinutes > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                                .foregroundColor(.purple)
                            Text("AI精准续航")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Text("\(manager.aiPredictedRemainingMinutes / 60)h \(manager.aiPredictedRemainingMinutes % 60)m")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                } else if manager.currentPhase == .discharging && manager.estimatedRemainingMinutes > 0 {
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
            
            // 实时功耗与部件分布
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    CompactMiniMetric(title: "整机功率", value: String(format: "%.2f W", manager.currentPower), icon: "bolt.fill", color: .orange)
                    CompactMiniMetric(title: "剩余电量", value: String(format: "%.0f mAh", manager.aiEstimatedRemainingMAh), icon: "battery.50", color: .primary)
                }
                GridRow {
                    CompactMiniMetric(title: "CPU 预估", value: String(format: "%.1f W", manager.estimatedCpuPower), icon: "cpu", color: .primary)
                    CompactMiniMetric(title: "屏幕 / 主板", value: String(format: "%.1fW / %.1fW", manager.estimatedScreenPower, manager.estimatedBoardPower), icon: "display", color: .primary)
                }
                GridRow {
                    CompactMiniMetric(title: "真实健康度", value: manager.aiTrueHealthPct > 0 ? String(format: "%.1f%%", manager.aiTrueHealthPct) : "--", icon: "heart.fill", color: manager.aiTrueHealthPct >= 80 ? .green : .orange)
                    CompactMiniMetric(title: "真实全容量", value: manager.aiTrueCapacityMAh > 0 ? String(format: "%.0f mAh", manager.aiTrueCapacityMAh) : "--", icon: "gauge.with.needle", color: .primary)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
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
