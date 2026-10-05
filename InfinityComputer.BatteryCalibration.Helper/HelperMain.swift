import Foundation
import os.log

final class BatteryControlHelperDelegate: NSObject, NSXPCListenerDelegate, BatteryControlHelperProtocol {
    private let logger = Logger(subsystem: "InfinityComputer.BatteryCalibration.Helper", category: "Daemon")
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let interface = NSXPCInterface(with: BatteryControlHelperProtocol.self)
        
        let allowedClasses = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self]) as! Set<AnyHashable>
        interface.setClasses(
            allowedClasses,
            for: #selector(BatteryControlHelperProtocol.getSMCStatus(withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            allowedClasses,
            for: #selector(BatteryControlHelperProtocol.getHardwareSensors(withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        
        newConnection.exportedInterface = interface
        newConnection.exportedObject = self
        
        newConnection.interruptionHandler = { [weak self] in
            self?.logger.notice("Main App XPC connection interrupted.")
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.logger.notice("Main App XPC connection invalidated.")
        }
        
        newConnection.resume()
        return true
    }
    
    // MARK: - BatteryControlHelperProtocol
    
    func setInhibitCharging(_ enabled: Bool, withReply reply: @escaping (Bool, NSString?) -> Void) {
        logger.info("收到设置阻断充电请求: \(enabled)")
        let result = SMCKit.shared.setChargingInhibit(enabled: enabled)
        if result.success {
            reply(true, nil)
        } else {
            reply(false, result.message as NSString)
        }
    }
    
    func getSMCStatus(withReply reply: @escaping (NSDictionary) -> Void) {
        let status = NSMutableDictionary()
        for key in ["CH0B", "CH0C", "CH0I", "BCLM"] {
            if let val = SMCKit.shared.readUInt8(keyString: key) {
                status[key] = NSNumber(value: val)
            }
        }
        reply(status)
    }

    func getHardwareSensors(withReply reply: @escaping (NSDictionary) -> Void) {
        let dict = NSMutableDictionary()
        
        // 1. 读取风扇转速 (通用 SMC 键: F0Ac, F1Ac)
        if let f0 = SMCKit.shared.readNumericValue(keyString: "F0Ac") {
            dict["fanRPM"] = NSNumber(value: f0)
        } else if let f1 = SMCKit.shared.readNumericValue(keyString: "F1Ac") {
            dict["fanRPM"] = NSNumber(value: f1)
        }

        // 2. 读取 Intel / 通用 SMC CPU & GPU 温度
        if let tc0p = SMCKit.shared.readNumericValue(keyString: "TC0P") ?? SMCKit.shared.readNumericValue(keyString: "TC0E") {
            dict["cpuTemp"] = NSNumber(value: tc0p)
        }
        if let tg0p = SMCKit.shared.readNumericValue(keyString: "TG0P") ?? SMCKit.shared.readNumericValue(keyString: "TG0D") {
            dict["gpuTemp"] = NSNumber(value: tg0p)
        }

        // 3. 读取 SMC 功耗键 (Intel: PCPC=CPU, PCPG=GPU)
        if let pcpc = SMCKit.shared.readNumericValue(keyString: "PCPC") {
            dict["cpuPower"] = NSNumber(value: pcpc)
        }
        if let pcpg = SMCKit.shared.readNumericValue(keyString: "PCPG") {
            dict["gpuPower"] = NSNumber(value: pcpg)
        }

        reply(dict)
    }
}

@main
struct HelperDaemonMain {
    static func main() {
        let delegate = BatteryControlHelperDelegate()
        let listener = NSXPCListener(machServiceName: "InfinityComputer.BatteryCalibration.Helper")
        listener.delegate = delegate
        listener.resume()
        
        RunLoop.main.run()
    }
}
