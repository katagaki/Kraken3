import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class CDPConnection {

    var onEvent: ((String, [String: Any], String?) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let commandFD: Int32
    private let responseFD: Int32
    private let pid: pid_t

    private var nextID = 0
    private var completions: [Int: ([String: Any]) -> Void] = [:]
    private let lock = NSLock()

    init(chromiumPath: String, arguments: [String]) throws {
        var commandPipe: [Int32] = [0, 0]
        var responsePipe: [Int32] = [0, 0]
        guard pipe(&commandPipe) == 0, pipe(&responsePipe) == 0 else {
            throw SocketError(message: "pipe() failed")
        }

        // Chromium reads CDP messages from fd 3 and writes them to fd 4.
        #if os(Linux)
        var fileActions = posix_spawn_file_actions_t()
        #else
        var fileActions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, commandPipe[0], 3)
        posix_spawn_file_actions_adddup2(&fileActions, responsePipe[1], 4)

        var argv: [UnsafeMutablePointer<CChar>?] = ([chromiumPath] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)

        var childPID: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(&childPID, chromiumPath, &fileActions, nil,
                            argvBuffer.baseAddress!, envpBuffer.baseAddress!)
            }
        }
        posix_spawn_file_actions_destroy(&fileActions)
        argv.forEach { if let pointer = $0 { free(pointer) } }
        envp.forEach { if let pointer = $0 { free(pointer) } }

        close(commandPipe[0])
        close(responsePipe[1])
        guard result == 0 else {
            close(commandPipe[1])
            close(responsePipe[0])
            throw SocketError(message: "failed to launch Chromium at \(chromiumPath) (posix_spawn: \(result))")
        }

        commandFD = commandPipe[1]
        responseFD = responsePipe[0]
        pid = childPID

        startReader()
        startWaiter()
    }

    func send(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil,
              completion: (([String: Any]) -> Void)? = nil) {
        lock.lock()
        nextID += 1
        let id = nextID
        if let completion { completions[id] = completion }
        lock.unlock()

        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { message["sessionId"] = sessionId }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0)

        lock.lock()
        _ = SocketIO.writeAll(commandFD, data)
        lock.unlock()
    }

    private func startReader() {
        let fd = responseFD
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                guard let chunk = SocketIO.readSome(fd) else { return }
                buffer.append(chunk)
                while let terminator = buffer.firstIndex(of: 0) {
                    let message = buffer.subdata(in: buffer.startIndex..<terminator)
                    buffer.removeSubrange(buffer.startIndex...terminator)
                    self?.dispatch(message)
                }
            }
        }
    }

    private func dispatch(_ message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            lock.lock()
            let completion = completions.removeValue(forKey: id)
            lock.unlock()
            if let completion {
                let result = object["result"] as? [String: Any] ?? object
                DispatchQueue.main.async { completion(result) }
            }
        } else if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            let sessionId = object["sessionId"] as? String
            DispatchQueue.main.async { self.onEvent?(method, params, sessionId) }
        }
    }

    private func startWaiter() {
        let childPID = pid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            DispatchQueue.main.async { self?.onExit?(status) }
        }
    }
}
