import Foundation
import ServiceManagement
import os.log

@objc(BatteryControlHelperProtocol)
public protocol BatteryControlHelperProtocol: NSObjectProtocol {
    func setInhibitCharging(_ enabled: Bool, withReply reply: @escaping (Bool, NSString?) -> Void)
    func getSMCStatus(withReply reply: @escaping (NSDictionary) -> Void)
}

public final class BatteryControlClient: @unchecked Sendable {
    public static let shared = BatteryControlClient()
    public static let machServiceName = "InfinityComputer.BatteryCalibration.Helper"
    
    private let logger = Logger(subsystem: "InfinityComputer.BatteryCalibration", category: "BatteryControlClient")
    private let connectionLock = NSLock()
    private var xpcConnection: NSXPCConnection?
    
    private init() {}
    
    // MARK: - 守护进程状态检测与注册管理
    
    public var isDaemonRegistered: Bool {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "\(Self.machServiceName).plist")
            return service.status == .enabled
        }
        return false
    }
    
    public func promptInstallDaemon() throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "\(Self.machServiceName).plist")
            if service.status != .enabled {
                try service.register()
            }
        } else {
            throw NSError(
                domain: "BatteryControlClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "macOS 13.0 or later required for SMAppService."]
            )
        }
    }
    
    public func unregisterDaemon() throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "\(Self.machServiceName).plist")
            try service.unregister()
        }
    }
    
    // MARK: - XPC 连接与通信
    
    private func getOrCreateConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        if let connection = xpcConnection {
            return connection
        }
        
        let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
        let interface = NSXPCInterface(with: BatteryControlHelperProtocol.self)
        
        // 显式白名单约束，杜绝 NSObject 泛化告警
        let allowedClasses = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self]) as! Set<AnyHashable>
        interface.setClasses(
            allowedClasses,
            for: #selector(BatteryControlHelperProtocol.getSMCStatus(withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        
        connection.remoteObjectInterface = interface
        
        connection.interruptionHandler = { [weak self] in
            self?.logger.warning("Helper XPC connection interrupted.")
            self?.connectionLock.lock()
            self?.xpcConnection = nil
            self?.connectionLock.unlock()
        }
        
        connection.invalidationHandler = { [weak self] in
            self?.logger.warning("Helper XPC connection invalidated.")
            self?.connectionLock.lock()
            self?.xpcConnection = nil
            self?.connectionLock.unlock()
        }
        
        connection.resume()
        self.xpcConnection = connection
        return connection
    }
    
    public func registerDaemonService() throws {
        try promptInstallDaemon()
    }
    
    public func setInhibitCharging(enabled: Bool) async throws -> Bool {
        let connection = getOrCreateConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            
            guard let helper = remote as? BatteryControlHelperProtocol else {
                continuation.resume(throwing: NSError(
                    domain: "BatteryControlClient",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Remote object does not conform to BatteryControlHelperProtocol"]
                ))
                return
            }
            
            helper.setInhibitCharging(enabled) { success, errMsg in
                if success {
                    continuation.resume(returning: true)
                } else {
                    let message = (errMsg as String?) ?? "Unknown SMC write failure"
                    continuation.resume(throwing: NSError(
                        domain: "BatteryControlClient",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                }
            }
        }
    }
    
    public func getSMCStatus() async throws -> [String: NSNumber] {
        let connection = getOrCreateConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            
            guard let helper = remote as? BatteryControlHelperProtocol else {
                continuation.resume(throwing: NSError(
                    domain: "BatteryControlClient",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to cast remote proxy"]
                ))
                return
            }
            
            helper.getSMCStatus { status in
                continuation.resume(returning: (status as? [String: NSNumber]) ?? [:])
            }
        }
    }
}
