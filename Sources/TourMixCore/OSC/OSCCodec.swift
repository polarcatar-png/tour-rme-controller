import Foundation

/// OSC 1.0 参数值（全面支持 `'f'`, `'i'`, `'s'`, `'T'`, `'F'`）。
public enum OSCArgument: Equatable, Sendable {
    case float32(Float)
    case int32(Int32)
    case string(String)
    case bool(Bool)

    /// 提取 `Float`（兼容 `float32` / `int32` / `bool`）。
    public var floatValue: Float? {
        switch self {
        case .float32(let value):
            return value
        case .int32(let value):
            return Float(value)
        case .bool(let value):
            return value ? 1.0 : 0.0
        case .string:
            return nil
        }
    }

    /// 提取 `Double`（兼容 `float32` / `int32` / `bool`）。
    public var doubleValue: Double? {
        switch self {
        case .float32(let value):
            return Double(value)
        case .int32(let value):
            return Double(value)
        case .bool(let value):
            return value ? 1.0 : 0.0
        case .string:
            return nil
        }
    }

    /// 提取四舍五入后的 `Int`（兼容 `int32` / 有限 `float32` / `bool`）。
    public var intValue: Int? {
        switch self {
        case .int32(let value):
            return Int(value)
        case .float32(let value):
            guard value.isFinite else { return nil }
            return Int(value.rounded())
        case .bool(let value):
            return value ? 1 : 0
        case .string:
            return nil
        }
    }

    /// 按 TotalMix 开关阈值（`>= 0.5`）提取布尔值。
    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .float32(let value):
            return value >= 0.5
        case .int32(let value):
            return value != 0
        case .string:
            return nil
        }
    }

    /// 提取字符串参数。
    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

/// 单条 OSC 1.0 消息。
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(address: String, arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    /// 构造默认单 `Float32` 参数的 TotalMix OSC 指令消息。
    public static func float(_ address: String, _ value: Float = 1.0) -> OSCMessage {
        OSCMessage(address: address, arguments: [.float32(value)])
    }

    /// 构造将 `Double` 编码为 4 字节 `Float32` (`'f'`) 的 TotalMix OSC 指令消息。
    public static func float(_ address: String, _ value: Double) -> OSCMessage {
        OSCMessage(address: address, arguments: [.float32(Float(value))])
    }

    /// 构造单字符串参数的 OSC 消息（如修改通道名）。
    public static func string(_ address: String, _ value: String) -> OSCMessage {
        OSCMessage(address: address, arguments: [.string(value)])
    }
}

/// OSC 1.0 数据包（单条消息或支持多层嵌套的 `#bundle`）。
public enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle(timeTag: UInt64, elements: [OSCPacket])

    /// 将包内所有消息（含多层嵌套 `#bundle`）按顺序展开为扁平消息数组。
    public var flattenedMessages: [OSCMessage] {
        switch self {
        case .message(let msg):
            return [msg]
        case .bundle(_, let elements):
            return elements.flatMap(\.flattenedMessages)
        }
    }
}

/// OSC 1.0 编解码错误定义。
public enum OSCCodecError: Error, Equatable, Sendable, LocalizedError {
    case emptyData
    case unterminatedString
    case invalidUTF8String
    case invalidAddress(String)
    case invalidTypeTagString(String)
    case unsupportedTypeTag(Character)
    case truncatedPayload
    case invalidBundleHeader
    case invalidBundleElementSize(Int32)
    case bundleRecursionDepthExceeded

    public var errorDescription: String? {
        switch self {
        case .emptyData:
            return "OSC 数据包为空"
        case .unterminatedString:
            return "OSC 字符串缺少 NUL 终止符或对齐越界"
        case .invalidUTF8String:
            return "OSC 字符串包含非法 UTF-8 字节"
        case .invalidAddress(let addr):
            return "非法 OSC 地址：\(addr)"
        case .invalidTypeTagString(let tags):
            return "非法 OSC 类型标签串：\(tags)"
        case .unsupportedTypeTag(let tag):
            return "不支持的 OSC 参数类型标签：'\(tag)'"
        case .truncatedPayload:
            return "OSC 参数负载长度不足（截断包）"
        case .invalidBundleHeader:
            return "非法 OSC #bundle 头部（不足 16 字节）"
        case .invalidBundleElementSize(let size):
            return "非法 OSC #bundle 子元素长度：\(size)"
        case .bundleRecursionDepthExceeded:
            return "OSC #bundle 嵌套深度超限"
        }
    }
}

/// 零依赖 OSC 1.0 二进制编解码器。
///
/// - 发送编码辅助方法默认将所有数值参数编码为 4 字节大端 `Float32` (`'f'`)，严格对齐 TotalMix FX Global OSC 规范。
/// - 接收解码器完整支持 `'f'`, `'i'`, `'s'`, `'T'`, `'F'` 以及多层嵌套 `#bundle` 安全解包（越界防御零崩溃）。
public enum OSCCodec: Sendable {
    public static let immediateTimeTag: UInt64 = 1
    public static let maxDefaultBundleDepth: Int = 16

    // MARK: - Encoding

    /// 编码单条 `OSCMessage` 为 4 字节对齐二进制流。
    public static func encode(_ message: OSCMessage) -> Data {
        var data = Data()
        data.reserveCapacity(32 + message.arguments.count * 8)
        appendOSCString(message.address, to: &data)

        var typeTags = ","
        typeTags.reserveCapacity(1 + message.arguments.count)
        for arg in message.arguments {
            switch arg {
            case .float32:
                typeTags.append("f")
            case .int32:
                typeTags.append("i")
            case .string:
                typeTags.append("s")
            case .bool(let flag):
                typeTags.append(flag ? "T" : "F")
            }
        }
        appendOSCString(typeTags, to: &data)

        for arg in message.arguments {
            switch arg {
            case .float32(let value):
                appendUInt32BE(value.bitPattern, to: &data)
            case .int32(let value):
                appendUInt32BE(UInt32(bitPattern: value), to: &data)
            case .string(let value):
                appendOSCString(value, to: &data)
            case .bool:
                // 'T' 与 'F' 在负载区占 0 字节
                break
            }
        }
        return data
    }

    /// 编码 `OSCPacket`（支持单条消息或嵌套 `#bundle`）。
    public static func encode(_ packet: OSCPacket) -> Data {
        switch packet {
        case .message(let message):
            return encode(message)
        case .bundle(let timeTag, let elements):
            var data = Data()
            appendOSCString("#bundle", to: &data) // 固定 8 字节 "#bundle\0"
            appendUInt64BE(timeTag, to: &data)    // 固定 8 字节 timetag
            for element in elements {
                let encodedElement = encode(element)
                appendUInt32BE(UInt32(encodedElement.count), to: &data)
                data.append(encodedElement)
            }
            return data
        }
    }

    /// TotalMix 发送辅助方法：默认将单数值参数编码为 4 字节大端 `Float32` (`'f'`)。
    public static func encodeFloatCommand(_ address: String, value: Float = 1.0) -> Data {
        encode(OSCMessage(address: address, arguments: [.float32(value)]))
    }

    /// TotalMix 发送辅助方法：将 `Double` 转为 4 字节大端 `Float32` (`'f'`) 编码。
    public static func encodeFloatCommand(_ address: String, doubleValue: Double) -> Data {
        encode(OSCMessage(address: address, arguments: [.float32(Float(doubleValue))]))
    }

    /// TotalMix 发送辅助方法：将开关布尔值编码为 `1.0f` / `0.0f` 大端 `Float32` (`'f'`)。
    public static func encodeToggleCommand(_ address: String, enabled: Bool) -> Data {
        encode(OSCMessage(address: address, arguments: [.float32(enabled ? 1.0 : 0.0)]))
    }

    /// TotalMix 发送辅助方法：编码字符串参数命令（如 `/output/0/name`）。
    public static func encodeStringCommand(_ address: String, value: String) -> Data {
        encode(OSCMessage(address: address, arguments: [.string(value)]))
    }

    // MARK: - Decoding

    /// 解码二进制流为结构化 `OSCPacket`（含越界与递归深度防御）。
    public static func decodePacket(_ data: Data, maxDepth: Int = maxDefaultBundleDepth) throws -> OSCPacket {
        guard !data.isEmpty else {
            throw OSCCodecError.emptyData
        }
        return try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return try decodePacketSlice(bytes: bytes, start: 0, end: bytes.count, depth: 0, maxDepth: maxDepth)
        }
    }

    /// 解码二进制流并将所有单条消息或嵌套 `#bundle` 展开为 `[OSCMessage]`。
    public static func decodeMessages(_ data: Data, maxDepth: Int = maxDefaultBundleDepth) throws -> [OSCMessage] {
        let packet = try decodePacket(data, maxDepth: maxDepth)
        return packet.flattenedMessages
    }

    // MARK: - Internal Helpers

    private static func paddingCount(forNullTerminatedLength length: Int) -> Int {
        (4 - (length % 4)) % 4
    }

    private static func appendOSCString(_ string: String, to data: inout Data) {
        let utf8 = Array(string.utf8)
        data.append(contentsOf: utf8)
        let nullPlusPadding = 1 + paddingCount(forNullTerminatedLength: utf8.count + 1)
        data.append(contentsOf: repeatElement(UInt8(0), count: nullPlusPadding))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func decodePacketSlice(
        bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int,
        depth: Int,
        maxDepth: Int
    ) throws -> OSCPacket {
        guard depth <= maxDepth else {
            throw OSCCodecError.bundleRecursionDepthExceeded
        }
        guard start < end else {
            throw OSCCodecError.emptyData
        }

        let header = try readOSCString(bytes: bytes, offset: start, end: end)
        if header.value == "#bundle" {
            // "#bundle\0" (8B) + timetag (8B) = 至少 16B
            guard header.nextOffset - start == 8, header.nextOffset + 8 <= end else {
                throw OSCCodecError.invalidBundleHeader
            }
            let timeTag = try readUInt64BE(bytes: bytes, offset: header.nextOffset, end: end)
            var cursor = header.nextOffset + 8
            var elements: [OSCPacket] = []

            while cursor < end {
                guard cursor + 4 <= end else {
                    throw OSCCodecError.truncatedPayload
                }
                let rawSize = Int32(bitPattern: try readUInt32BE(bytes: bytes, offset: cursor, end: end))
                cursor += 4

                let remaining = end - cursor
                guard rawSize > 0, Int(rawSize) <= remaining else {
                    throw OSCCodecError.invalidBundleElementSize(rawSize)
                }
                let elementEnd = cursor + Int(rawSize)
                let child = try decodePacketSlice(
                    bytes: bytes,
                    start: cursor,
                    end: elementEnd,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
                elements.append(child)
                cursor = elementEnd
            }

            return .bundle(timeTag: timeTag, elements: elements)
        }

        let message = try decodeMessageAfterAddress(
            address: header.value,
            cursorAfterAddress: header.nextOffset,
            bytes: bytes,
            end: end
        )
        return .message(message)
    }

    private static func decodeMessageAfterAddress(
        address: String,
        cursorAfterAddress: Int,
        bytes: UnsafeBufferPointer<UInt8>,
        end: Int
    ) throws -> OSCMessage {
        guard address.hasPrefix("/") else {
            throw OSCCodecError.invalidAddress(address)
        }

        // 兼容极少数省略类型标签串的无参 OSC 1.0 消息
        if cursorAfterAddress == end {
            return OSCMessage(address: address, arguments: [])
        }

        let tagHeader = try readOSCString(bytes: bytes, offset: cursorAfterAddress, end: end)
        guard tagHeader.value.hasPrefix(",") else {
            throw OSCCodecError.invalidTypeTagString(tagHeader.value)
        }

        var cursor = tagHeader.nextOffset
        let tags = tagHeader.value.dropFirst()
        var arguments: [OSCArgument] = []
        arguments.reserveCapacity(tags.count)

        for tag in tags {
            switch tag {
            case "f":
                let bits = try readUInt32BE(bytes: bytes, offset: cursor, end: end)
                cursor += 4
                arguments.append(.float32(Float(bitPattern: bits)))
            case "i":
                let bits = try readUInt32BE(bytes: bytes, offset: cursor, end: end)
                cursor += 4
                arguments.append(.int32(Int32(bitPattern: bits)))
            case "s":
                let str = try readOSCString(bytes: bytes, offset: cursor, end: end)
                cursor = str.nextOffset
                arguments.append(.string(str.value))
            case "T":
                arguments.append(.bool(true))
            case "F":
                arguments.append(.bool(false))
            default:
                throw OSCCodecError.unsupportedTypeTag(tag)
            }
        }

        return OSCMessage(address: address, arguments: arguments)
    }

    private static func readOSCString(
        bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        end: Int
    ) throws -> (value: String, nextOffset: Int) {
        guard offset < end else {
            throw OSCCodecError.truncatedPayload
        }

        var nulIndex: Int?
        for idx in offset..<end {
            if bytes[idx] == 0 {
                nulIndex = idx
                break
            }
        }
        guard let nul = nulIndex else {
            throw OSCCodecError.unterminatedString
        }

        let consumedWithNul = (nul - offset) + 1
        let alignedNext = nul + 1 + paddingCount(forNullTerminatedLength: consumedWithNul)
        guard alignedNext <= end else {
            throw OSCCodecError.unterminatedString
        }

        let slice = UnsafeBufferPointer(rebasing: bytes[offset..<nul])
        guard let text = String(bytes: slice, encoding: .utf8) else {
            throw OSCCodecError.invalidUTF8String
        }
        return (text, alignedNext)
    }

    private static func readUInt32BE(
        bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        end: Int
    ) throws -> UInt32 {
        guard offset >= 0, end - offset >= 4 else {
            throw OSCCodecError.truncatedPayload
        }
        let b0 = UInt32(bytes[offset]) << 24
        let b1 = UInt32(bytes[offset + 1]) << 16
        let b2 = UInt32(bytes[offset + 2]) << 8
        let b3 = UInt32(bytes[offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func readUInt64BE(
        bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        end: Int
    ) throws -> UInt64 {
        guard offset >= 0, end - offset >= 8 else {
            throw OSCCodecError.truncatedPayload
        }
        let high = UInt64(try readUInt32BE(bytes: bytes, offset: offset, end: end)) << 32
        let low = UInt64(try readUInt32BE(bytes: bytes, offset: offset + 4, end: end))
        return high | low
    }
}
