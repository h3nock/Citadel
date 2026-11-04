import NIO
import NIOEmbedded
import XCTest
@testable import Citadel

final class SFTPRenameWireTests: XCTestCase {
    // SFTP v3 section 6.5: request ID and two strings, with no flags field.
    // This fixture is independent of Citadel's serializer and parser.
    private let renamePacket: [UInt8] = [
        0, 0, 0, 21,       // Payload length.
        18,                // SSH_FXP_RENAME.
        0, 0, 0, 7,        // Request ID.
        0, 0, 0, 4, 47, 111, 108, 100, // /old
        0, 0, 0, 4, 47, 110, 101, 119, // /new
    ]

    func testEncoderWritesV3RenameWithoutFlags() throws {
        let channel = EmbeddedChannel(handler: MessageToByteHandler(SFTPMessageSerializer()))
        defer { XCTAssertNoThrow(try channel.finish()) }

        try channel.writeOutbound(SFTPMessage.rename(.init(
            requestId: 7,
            oldPath: "/old",
            newPath: "/new",
            flags: 0
        )))

        let encoded = try XCTUnwrap(channel.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(Array(encoded.readableBytesView), renamePacket)
    }

    func testDecoderAcceptsV3RenameWithoutFlags() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        defer { XCTAssertNoThrow(try channel.finish()) }

        try channel.writeInbound(ByteBuffer(bytes: renamePacket))

        guard case .rename(let rename) = try XCTUnwrap(channel.readInbound(as: SFTPMessage.self)) else {
            return XCTFail("Expected a rename request")
        }
        XCTAssertEqual(rename.requestId, 7)
        XCTAssertEqual(rename.oldPath, "/old")
        XCTAssertEqual(rename.newPath, "/new")
        XCTAssertEqual(rename.flags, 0)
    }

    func testDecoderRejectsTrailingRenameFlags() throws {
        for flags: UInt8 in [0, 2] {
            var packet = renamePacket
            packet[3] = 25
            packet += [0, 0, 0, flags]
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
            defer { _ = try? channel.finish() }

            XCTAssertThrowsError(try channel.writeInbound(ByteBuffer(bytes: packet))) { error in
                guard case SFTPError.invalidPayload(let type) = error else {
                    return XCTFail("Expected an invalid rename payload, got \(error)")
                }
                XCTAssertEqual(type, .rename)
            }
        }
    }
}

extension EndToEndTests {
    func testV3RenameRejectsFlagsWithoutClosingTheSFTPChannel() async throws {
        final class RenameDelegate: SFTPDelegate, @unchecked Sendable {
            func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
                XCTAssertEqual(oldPath, "/old")
                XCTAssertEqual(newPath, "/new")
                XCTAssertEqual(flags, 0)
                return .ok
            }
        }

        try await runTest(
            perform: { server, client in
                server.enableSFTP(withDelegate: RenameDelegate())
                let sftp = try await client.openSFTP()

                do {
                    try await sftp.rename(at: "/old", to: "/new", flags: 1)
                    XCTFail("SFTP v3 cannot represent rename flags")
                } catch CitadelError.unsupported {
                    // A rejected option must not close the usable SFTP channel.
                }

                try await sftp.rename(at: "/old", to: "/new")
                try await sftp.close()
            },
            matchingError: { _ in false },
            expectsFailure: false
        )
    }
}
