import Foundation
import IOKit

public final class SMCKit {
    public static let shared = SMCKit()
    
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    
    // SMC 结构体定义 (对齐 AppleSMC 驱动协议)
    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    
    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }
    
    private enum SMCCommand: UInt8 {
        case readKeyInfo = 9
        case readBytes = 5
        case writeBytes = 6
    }
    
    private init() {
        _ = openConnection()
    }
    
    deinit {
        closeConnection()
    }
    
    private func openConnection() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return result == kIOReturnSuccess
    }
    
    private func closeConnection() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }
    
    private func fourCharToUInt32(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        return result
    }
    
    private func callSMC(inputStructure: inout SMCParamStruct, outputStructure: inout SMCParamStruct) -> Bool {
        guard openConnection() else { return false }
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        let result = IOConnectCallStructMethod(
            connection,
            2, // SMC index
            &inputStructure,
            inputSize,
            &outputStructure,
            &outputSize
        )
        return result == kIOReturnSuccess && outputStructure.result == 0
    }
    
    private func readKeyInfo(key: UInt32) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key
        input.data8 = SMCCommand.readKeyInfo.rawValue
        
        guard callSMC(inputStructure: &input, outputStructure: &output) else {
            return nil
        }
        return output.keyInfo
    }
    
    public func writeUInt8(keyString: String, value: UInt8) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let key = fourCharToUInt32(keyString)
        guard readKeyInfo(key: key) != nil else {
            return false
        }
        
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key
        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = 1
        input.bytes.0 = value
        
        return callSMC(inputStructure: &input, outputStructure: &output)
    }
    
    public func readUInt8(keyString: String) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        
        let key = fourCharToUInt32(keyString)
        guard let keyInfo = readKeyInfo(key: key), keyInfo.dataSize == 1 else {
            return nil
        }
        
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key
        input.data8 = SMCCommand.readBytes.rawValue
        input.keyInfo = keyInfo
        
        guard callSMC(inputStructure: &input, outputStructure: &output) else {
            return nil
        }
        return output.bytes.0
    }
    
    /// 设置硬件充电阻断状态
    /// Apple Silicon 机型主要适配键：CH0B, CH0C (1 = 阻断充电/绕过充电，0 = 恢复充电)
    /// Intel 机型主要适配键：BCLM (充电阈值上限) 或 CH0I
    public func setChargingInhibit(enabled: Bool) -> (success: Bool, message: String) {
            let inhibitValue: UInt8 = enabled ? 0x01 : 0x00
            var successKeys: [String] = []
            var failedKeys: [String] = []
            
            // 针对 Apple Silicon / Intel 常见充电抑制 Key
            let candidateKeys = ["CH0B", "CH0C", "CH0I"]
            
            for key in candidateKeys {
                if writeUInt8(keyString: key, value: inhibitValue) {
                    successKeys.append(key)
                } else {
                    failedKeys.append(key)
                }
            }
            
            // Intel 平台 BCLM 限额补充回落
            if successKeys.isEmpty {
                let bclmVal: UInt8 = enabled ? 10 : 100
                if writeUInt8(keyString: "BCLM", value: bclmVal) {
                    successKeys.append("BCLM(\(bclmVal)%)")
                }
            }
            
            if !successKeys.isEmpty {
                return (true, "成功写入 SMC 寄存器: [\(successKeys.joined(separator: ", "))] -> \(inhibitValue)")
            } else {
                return (false, "SMC 控制寄存器写入均未响应（尝试了 \(candidateKeys.joined(separator: ", "))），请检查是否有 AppleSMC 权限。")
            }
        }
}
