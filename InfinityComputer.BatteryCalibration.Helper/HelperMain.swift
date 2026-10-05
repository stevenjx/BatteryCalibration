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
        logger.info("设置禁止充电: \(enabled)")
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
