import Foundation

public struct CalibrationHistoryRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let startDischargePercentage: Int
    public let cycleCount: Int
    public let designCapacityMAh: Double
    public let calculatedCapacityMAh: Double
    public let calculatedCapacityWh: Double
    public let batteryHealthPercentage: Double
    public let dischargeEnergyWh: Double
    public let dischargeEnergyAh: Double
    public let rechargeEnergyWh: Double
    public let rechargeEnergyAh: Double
    public let coulombicEfficiency: Double
    public let internalResistanceMilliohm: Double
    public let reportFilePath: String?
    public let csvFilePath: String?

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        startDischargePercentage: Int,
        cycleCount: Int,
        designCapacityMAh: Double,
        calculatedCapacityMAh: Double,
        calculatedCapacityWh: Double,
        batteryHealthPercentage: Double,
        dischargeEnergyWh: Double,
        dischargeEnergyAh: Double,
        rechargeEnergyWh: Double,
        rechargeEnergyAh: Double,
        coulombicEfficiency: Double,
        internalResistanceMilliohm: Double,
        reportFilePath: String? = nil,
        csvFilePath: String? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.startDischargePercentage = startDischargePercentage
        self.cycleCount = cycleCount
        self.designCapacityMAh = designCapacityMAh
        self.calculatedCapacityMAh = calculatedCapacityMAh
        self.calculatedCapacityWh = calculatedCapacityWh
        self.batteryHealthPercentage = batteryHealthPercentage
        self.dischargeEnergyWh = dischargeEnergyWh
        self.dischargeEnergyAh = dischargeEnergyAh
        self.rechargeEnergyWh = rechargeEnergyWh
        self.rechargeEnergyAh = rechargeEnergyAh
        self.coulombicEfficiency = coulombicEfficiency
        self.internalResistanceMilliohm = internalResistanceMilliohm
        self.reportFilePath = reportFilePath
        self.csvFilePath = csvFilePath
    }
}

public final class HistoryStorageManager {
    public static let shared = HistoryStorageManager()

    private let fileManager = FileManager.default
    private let storageURL: URL

    private init() {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolderURL = appSupportURL.appendingPathComponent("BatteryCalibration", isDirectory: true)

        if !fileManager.fileExists(atPath: appFolderURL.path) {
            try? fileManager.createDirectory(at: appFolderURL, withIntermediateDirectories: true, attributes: nil)
        }
        self.storageURL = appFolderURL.appendingPathComponent("history.json")
    }

    public func loadHistory() -> [CalibrationHistoryRecord] {
        guard fileManager.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CalibrationHistoryRecord].self, from: data)) ?? []
    }

    public func saveRecord(_ record: CalibrationHistoryRecord) {
        var existing = loadHistory()
        existing.insert(record, at: 0)
        persist(records: existing)
    }

    public func deleteRecord(id: UUID) {
        var existing = loadHistory()
        existing.removeAll { $0.id == id }
        persist(records: existing)
    }

    public func clearAll() {
        persist(records: [])
    }

    private func persist(records: [CalibrationHistoryRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: storageURL, options: [.atomic])
        }
    }
}
