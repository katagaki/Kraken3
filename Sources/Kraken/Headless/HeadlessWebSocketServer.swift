import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class HeadlessWebSocketServer {

    private final class Client {
        let fd: Int32
        let sessionID: String
        // Per-client so one stalled link cannot block writes to anyone else.
        let sendQueue = DispatchQueue(label: "kraken.ws.client")
        init(fd: Int32, sessionID: String) {
            self.fd = fd
            self.sessionID = sessionID
        }
    }

    var onMessage: ((String, [String: Any]) -> Void)?
    var onClientConnected: ((String) -> Void)?
    var onClientDisconnected: ((String) -> Void)?

    private var clients: [Client] = []
    private let clientsLock = NSLock()

    func accept(fd: Int32, key: String, sessionID: String) {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let acceptKey = SHA1.digest(Data(magic.utf8)).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        guard SocketIO.writeAll(fd, Data(response.utf8)) else { return }

        let client = Client(fd: fd, sessionID: sessionID)
        clientsLock.lock()
        clients.append(client)
        clientsLock.unlock()
        onClientConnected?(sessionID)

        readFrames(client)

        clientsLock.lock()
        clients.removeAll { $0 === client }
        clientsLock.unlock()
        // Drain pending writes before the caller closes the fd, so a queued
        // send can never hit a recycled descriptor.
        client.sendQueue.sync {}
        onClientDisconnected?(sessionID)
    }

    func sendFrame(toSession sessionID: String, _ data: Data) {
        broadcast(toSession: sessionID, opcode: 0x2, payload: data)
    }

    func sendJSON(toSession sessionID: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        broadcast(toSession: sessionID, opcode: 0x1, payload: data)
    }

    func closeSession(_ sessionID: String) {
        clientsLock.lock()
        let doomed = clients.filter { $0.sessionID == sessionID }
        clientsLock.unlock()
        for client in doomed {
            shutdown(client.fd, 2)
        }
    }

    func sessionsWithClients() -> Set<String> {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return Set(clients.map(\.sessionID))
    }

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
                    onMessage?(client.sessionID, json)
                }
                messageData = Data()
            }
        }
    }

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
        client.sendQueue.sync {
            _ = SocketIO.writeAll(client.fd, data)
        }
    }

    private func broadcast(toSession sessionID: String, opcode: UInt8, payload: Data) {
        clientsLock.lock()
        let snapshot = clients.filter { $0.sessionID == sessionID }
        clientsLock.unlock()
        guard !snapshot.isEmpty else { return }
        let data = frame(opcode: opcode, payload: payload)
        for client in snapshot {
            client.sendQueue.async {
                if !SocketIO.writeAll(client.fd, data) {
                    shutdown(client.fd, 2)
                }
            }
        }
    }
}
