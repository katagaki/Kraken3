import Foundation
import Network

final class ControlSocketServer {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "kraken.ws")
    private var connections: [NWConnection] = []

    var onMessage: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?

    private(set) var clientCount = 0

    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.setup(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("Kraken: WebSocket listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func setup(_ connection: NWConnection) {
        connections.append(connection)
        clientCount = connections.count
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.onClientConnected?() }
                self.receive(on: connection)
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        clientCount = connections.count
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            if error != nil || context?.isFinal == true {
                connection.cancel()
                self.remove(connection)
                return
            }
            if let data,
               let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .text,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async { self.onMessage?(json) }
            }
            self.receive(on: connection)
        }
    }

    func broadcastFrame(_ data: Data) {
        send(data, opcode: .binary)
    }

    func broadcastJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data, opcode: .text)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        queue.async { [weak self] in
            guard let self else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
            for connection in self.connections where connection.state == .ready {
                connection.send(content: data, contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
            }
        }
    }
}
