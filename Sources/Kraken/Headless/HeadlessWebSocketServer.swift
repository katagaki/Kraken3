import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class HeadlessWebSocketServer {

    private final class Client {
        let fd: Int32
        let writeLock = NSLock()
        init(fd: Int32) { self.fd = fd }
    }

    var onMessage: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?

    private var listener: TCPListener?
    private var clients: [Client] = []
    private let clientsLock = NSLock()
    private let sendQueue = DispatchQueue(label: "kraken.ws.send")

    var clientCount: Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.count
    }

    func start(port: UInt16) throws {
        let listener = try TCPListener(port: port)
        listener.startAccepting { [weak self] fd in
            Thread.detachNewThread {
                self?.serve(fd)
                close(fd)
            }
        }
        self.listener = listener
    }

    func broadcastFrame(_ data: Data) {
        broadcast(opcode: 0x2, payload: data)
    }

    func broadcastJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        broadcast(opcode: 0x1, payload: data)
    }

    // MARK: - Connection lifecycle

    private func serve(_ fd: Int32) {
        guard performHandshake(fd) else { return }

        let client = Client(fd: fd)
        clientsLock.lock()
        clients.append(client)
        clientsLock.unlock()
        DispatchQueue.main.async { self.onClientConnected?() }

        readFrames(client)

        clientsLock.lock()
        clients.removeAll { $0 === client }
        clientsLock.unlock()
    }

    private func performHandshake(_ fd: Int32) -> Bool {
        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 65536, let chunk = SocketIO.readSome(fd) else { return false }
            buffer.append(chunk)
        }
        guard let request = String(data: buffer, encoding: .utf8) else { return false }

        var websocketKey: String?
        for line in request.components(separatedBy: "\r\n") {
            let lowered = line.lowercased()
            if lowered.hasPrefix("sec-websocket-key:") {
                websocketKey = line.dropFirst("sec-websocket-key:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let websocketKey else { return false }

        let magic = websocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = SHA1.digest(Data(magic.utf8)).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        return SocketIO.writeAll(fd, Data(response.utf8))
    }

    // MARK: - Frame reading

    private func readFrames(_ client: Client) {
        var pending = Data()

        func readExactly(_ count: Int) -> Data? {
            while pending.count < count {
                guard let chunk = SocketIO.readSome(client.fd) else { return nil }
                pending.append(chunk)
            }
            let result = pending.subdata(in: 0..<count)
            pending.removeSubrange(0..<count)
            return result
        }

        var messageOpcode: UInt8 = 0
        var messageData = Data()

        while true {
            guard let header = readExactly(2) else { return }
            let fin = header[0] & 0x80 != 0
            let opcode = header[0] & 0x0F
            let masked = header[1] & 0x80 != 0
            var length = Int(header[1] & 0x7F)

            if length == 126 {
                guard let extended = readExactly(2) else { return }
                length = (Int(extended[0]) << 8) | Int(extended[1])
            } else if length == 127 {
                guard let extended = readExactly(8) else { return }
                var value = 0
                for byte in extended { value = (value << 8) | Int(byte) }
                length = value
            }
            guard length <= 10_000_000 else { return }

            var mask: [UInt8] = []
            if masked {
                guard let maskData = readExactly(4) else { return }
                mask = [UInt8](maskData)
            }
            guard var payload = readExactly(length) else { return }
            if masked {
                for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
            }

            switch opcode {
            case 0x1, 0x2:
                messageOpcode = opcode
                messageData = payload
            case 0x0:
                messageData.append(payload)
            case 0x8:
                send(client, opcode: 0x8, payload: Data())
                return
            case 0x9:
                send(client, opcode: 0xA, payload: payload)
                continue
            default:
                continue
            }

            if fin {
                if messageOpcode == 0x1,
                   let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage?(json) }
                }
                messageData = Data()
            }
        }
    }

    // MARK: - Sending

    private func frame(opcode: UInt8, payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            data.append(UInt8(count))
        } else if count <= 0xFFFF {
            data.append(126)
            data.append(UInt8(count >> 8))
            data.append(UInt8(count & 0xFF))
        } else {
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        data.append(payload)
        return data
    }

    private func send(_ client: Client, opcode: UInt8, payload: Data) {
        let data = frame(opcode: opcode, payload: payload)
        client.writeLock.lock()
        _ = SocketIO.writeAll(client.fd, data)
        client.writeLock.unlock()
    }

    private func broadcast(opcode: UInt8, payload: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.clientsLock.lock()
            let snapshot = self.clients
            self.clientsLock.unlock()
            let data = self.frame(opcode: opcode, payload: payload)
            for client in snapshot {
                client.writeLock.lock()
                let ok = SocketIO.writeAll(client.fd, data)
                client.writeLock.unlock()
                if !ok {
                    shutdown(client.fd, 2)  // SHUT_RDWR; the constant's type differs across libcs
                }
            }
        }
    }
}
