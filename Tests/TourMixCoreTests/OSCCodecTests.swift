import Foundation
import Testing
@testable import TourMixCore

@Suite("OSCCodec 零依赖二进制编解码与嵌套 #bundle 测试")
struct OSCCodecTests {
    @Test("默认数值命令编码为 4 字节对齐的大端 Float32 ('f')")
    func floatCommandEncoding() throws {
        let encoded = OSCCodec.encodeFloatCommand("/sendall", value: 2.0)
        // "/sendall" (8B) + 4B NUL padding = 12B
        // ",f\0\0" = 4B
        // Float32(2.0) = 0x40000000 = 4B -> 合计 20 字节
        #expect(encoded.count == 20)
        #expect(encoded.count % 4 == 0)

        let tailFloatBytes = Array(encoded.suffix(4))
        #expect(tailFloatBytes == [0x40, 0x00, 0x00, 0x00])

        let decoded = try OSCCodec.decodeMessages(encoded)
        #expect(decoded == [OSCMessage(address: "/sendall", arguments: [.float32(2.0)])])
    }

    @Test("完整支持 'f', 'i', 's', 'T', 'F' 混合参数编解码")
    func mixedArgumentRoundTrip() throws {
        let original = OSCMessage(
            address: "/output/0/CompositeCheck",
            arguments: [
                .float32(-300.0),
                .int32(42),
                .string("Fireface UCX (23908219)"),
                .bool(true),
                .bool(false),
            ]
        )

        let data = OSCCodec.encode(original)
        #expect(data.count % 4 == 0)

        let messages = try OSCCodec.decodeMessages(data)
        #expect(messages.count == 1)
        #expect(messages[0] == original)
        #expect(messages[0].arguments[0].doubleValue == -300.0)
        #expect(messages[0].arguments[1].intValue == 42)
        #expect(messages[0].arguments[2].stringValue == "Fireface UCX (23908219)")
        #expect(messages[0].arguments[3].boolValue == true)
        #expect(messages[0].arguments[4].boolValue == false)
    }

    @Test("多层嵌套 #bundle 按序展开为扁平 [OSCMessage]")
    func nestedBundleFlattening() throws {
        let msg1 = OSCMessage.string("/status/device", "Fireface UCX (23908219)")
        let msg2 = OSCMessage.float("/output/0/volume", Float(-12.5))
        let msg3 = OSCMessage.float("/output/0/mute", Float(1.0))
        let msg4 = OSCMessage(address: "/controlroom/dim", arguments: [.int32(0)])

        let innerBundle = OSCPacket.bundle(
            timeTag: 0x0000_0000_0000_0001,
            elements: [.message(msg2), .message(msg3)]
        )
        let outerBundle = OSCPacket.bundle(
            timeTag: 0x1234_5678_9ABC_DEF0,
            elements: [.message(msg1), innerBundle, .message(msg4)]
        )

        let raw = OSCCodec.encode(outerBundle)
        // 验证前 8 字节精确为 "#bundle\0"
        #expect(Array(raw.prefix(8)) == Array("#bundle\0".utf8))

        let flattened = try OSCCodec.decodeMessages(raw)
        #expect(flattened == [msg1, msg2, msg3, msg4])
    }

    @Test("畸形、截断与越界 #bundle 防御性抛错且绝不崩溃")
    func malformedAndTruncatedPacketsDoNotCrash() {
        // 1. 空包
        #expect(throws: OSCCodecError.emptyData) {
            _ = try OSCCodec.decodeMessages(Data())
        }

        // 2. 缺少 NUL 结尾的字符串
        let noNull = Data([0x2F, 0x6F, 0x75, 0x74])
        #expect(throws: OSCCodecError.unterminatedString) {
            _ = try OSCCodec.decodeMessages(noNull)
        }

        // 3. #bundle 头不足 16 字节
        let shortBundle = Data("#bundle\0\u{00}\u{00}\u{00}\u{01}".utf8)
        #expect(throws: OSCCodecError.invalidBundleHeader) {
            _ = try OSCCodec.decodeMessages(shortBundle)
        }

        // 4. #bundle 子元素 size 声明超过剩余长度（越界攻击防御）
        var forgedBundle = Data("#bundle\0".utf8)
        forgedBundle.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // timetag
        forgedBundle.append(contentsOf: [0x00, 0x01, 0x00, 0x00]) // 谎称长度 65536
        forgedBundle.append(contentsOf: [0x2F, 0x61, 0x00, 0x00])
        #expect(throws: OSCCodecError.invalidBundleElementSize(65536)) {
            _ = try OSCCodec.decodeMessages(forgedBundle)
        }

        // 5. #bundle 子元素 size 为负数
        var negativeSizeBundle = Data("#bundle\0".utf8)
        negativeSizeBundle.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        negativeSizeBundle.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFC]) // -4
        #expect(throws: OSCCodecError.invalidBundleElementSize(-4)) {
            _ = try OSCCodec.decodeMessages(negativeSizeBundle)
        }
    }
}
