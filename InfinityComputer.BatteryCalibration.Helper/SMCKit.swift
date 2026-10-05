import Foundation
import IOKit

public final class SMCKit {
    public static let shared = SMCKit()
    
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    
    // SMC 驱动核心数据结构 (AppleSMC 通信协议)
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
    
    // MARK: - 硬件遥测多类型解析扩展 (双架构支持)
    
    public func readBytes(keyString: String) -> (bytes: [UInt8], dataType: UInt32)? {
        lock.lock()
        defer { lock.unlock() }
        
        let key = fourCharToUInt32(keyString)
        guard let keyInfo = readKeyInfo(key: key) else { return nil }
        
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key
        input.data8 = SMCCommand.readBytes.rawValue
        input.keyInfo = keyInfo
        
        guard callSMC(inputStructure: &input, outputStructure: &output) else {
            return nil
        }
        
        let size = Int(keyInfo.dataSize)
        var result = [UInt8]()
        let mirror = Mirror(reflecting: output.bytes)
        for (idx, child) in mirror.children.enumerated() {
            if idx < size, let val = child.value as? UInt8 {
                result.append(val)
            }
        }
        return (result, keyInfo.dataType)
    }
    
    public func readNumericValue(keyString: String) -> Double? {
        guard let data = readBytes(keyString: keyString), !data.bytes.isEmpty else { return nil }
        let bytes = data.bytes
        
        switch data.dataType {
        case 0x66706532: // fpe2: unsigned 14.2 fixed point (风扇转速)
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case 0x73703738: // sp78: signed 7.8 fixed point (Intel 温度)
            guard bytes.count >= 2 else { return nil }
            let raw = (Int16(bytes[0]) << 8) | Int16(bytes[1])
            return Double(raw) / 256.0
        case 0x75693136: // ui16: unsigned 16-bit int
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw)
        case 0x666C7420: // flt: 4-byte IEEE 754 浮点
                    guard bytes.count >= 4 else { return nil }
                    var val: Float32 = 0
                    withUnsafeMutableBytes(of: &val) { ptr in
                        bytes.withUnsafeBytes { bPtr in
                            ptr.copyMemory(from: UnsafeRawBufferPointer(start: bPtr.baseAddress, count: 4))
                        }
                    }
                    return Double(val)
        default:
            if bytes.count == 1 {
                return Double(bytes[0])
            } else if bytes.count == 2 {
                let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
                return Double(raw)
            }
            return nil
        }
    }
    
    /// 设置充电阻断 (Bypass Mode)
    public func setChargingInhibit(enabled: Bool) -> (success: Bool, message: String) {
        let inhibitValue: UInt8 = enabled ? 0x01 : 0x00
        var successKeys: [String] = []
        var failedKeys: [String] = []
        
        let candidateKeys = ["CH0B", "CH0C", "CH0I"]
        
        for key in candidateKeys {
            if writeUInt8(keyString: key, value: inhibitValue) {
                successKeys.append(key)
            } else {
                failedKeys.append(key)
            }
        }
        
        if successKeys.isEmpty {
            let bclmVal: UInt8 = enabled ? 10 : 100
            if writeUInt8(keyString: "BCLM", value: bclmVal) {
                successKeys.append("BCLM(\(bclmVal)%)")
            }
        }
        
        if !successKeys.isEmpty {
            return (true, "已成功写入 SMC 阻断键: [\(successKeys.joined(separator: ", "))] -> \(inhibitValue)")
        } else {
            return (false, "SMC 写入失败：[\(candidateKeys.joined(separator: ", "))] 未响应或 AppleSMC 被系统保护")
        }
    }
}
