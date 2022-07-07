#if os(OSX)
import Darwin.C
#else
import Glibc
#endif

public enum SpawnError: Error {
    case CouldNotOpenPipe
    case CouldNotSpawn
}

public typealias OutputClosure = (String) -> Void

public final class Spawn {

    /// The arguments to be executed.
    let args: [String]

    /// Closure to be executed when there is
    /// some data on stdout/stderr streams.
    private var output: OutputClosure?

    /// The PID of the child process.
    private(set) var pid: pid_t = 0

    /// The TID of the thread which will read streams.
    #if os(OSX)
    private(set) var tid: pthread_t? = nil
    private var childFDActions: posix_spawn_file_actions_t? = nil
    #else
    private(set) var tid = pthread_t()
    private var childFDActions = posix_spawn_file_actions_t()
    #endif

    /// The pipe we use to communicate (listen, in this case) with our child process.
    private var outputPipe: [Int32] = [-1, -1]

    public init(
        args: [String],
        envs: [String] = [],
        output: OutputClosure? = nil
    ) throws {
        (self.args, self.output)  = (args, output)

        if pipe(&outputPipe) != 0 {
            throw SpawnError.CouldNotOpenPipe
        }

        // Create a file actions object
        posix_spawn_file_actions_init(&childFDActions)

        // Tie the child's stdout and stderr to our pipe so we can read it
        posix_spawn_file_actions_adddup2(&childFDActions, outputPipe[1], 1)
        posix_spawn_file_actions_adddup2(&childFDActions, outputPipe[1], 2)

        // Convert to c-strings to provide to posix_spawn.
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { $0.withCString(strdup) }
        let cEnvs: [UnsafeMutablePointer<CChar>?] = envs.map { $0.withCString(strdup) }
        // Clean up these c-strings after they're done being used.
        defer {
            for case let arg? in argv { free(arg) }
            for case let env? in cEnvs { free(env) }
        }

        // Actually spawn our new process which runs our command.
        if posix_spawn(&pid, argv[0], &childFDActions, nil, argv + [nil], cEnvs + [nil]) != 0 {
            throw SpawnError.CouldNotSpawn
        }

        // Clean up the file actions object after we're done with it.
        posix_spawn_file_actions_destroy(&childFDActions)

        watchStreams()
    }

    private struct ThreadInfo {
        let outputPipe: [Int32]
        let output: OutputClosure?
    }
    private var threadInfo: ThreadInfo!

    private func watchStreams() {
        func callback(x: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
            let threadInfo = x.assumingMemoryBound(to: ThreadInfo.self).pointee
            let outputPipe = threadInfo.outputPipe
            close(outputPipe[1])
            let bufferSize: size_t = 1024 * 8
            let dynamicBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            while true {
                let amtRead = read(outputPipe[0], dynamicBuffer, bufferSize)
                if amtRead <= 0 {
                    break
                }
                let array = Array(UnsafeBufferPointer(start: dynamicBuffer, count: amtRead))
                let tmp = array  + [UInt8(0)]
                tmp.withUnsafeBufferPointer { ptr in
                    let str = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                    threadInfo.output?(str)
                }
            }
            dynamicBuffer.deallocate()
            return nil
        }

        threadInfo = ThreadInfo(outputPipe: outputPipe, output:output)

        // Create a new thread for listening to the output as our process runs.
        pthread_create(&tid, nil, callback, &threadInfo)
    }

    @discardableResult
    public func waitUntilFinished() -> Int32 {
        var status: Int32 = 0

        // wait for the thread watching the streams to finish
        if let tid = tid {
            pthread_join(tid, nil)
        }

        // wait for spawned process to finish
        waitpid(pid, &status, 0)
        return status
    }
}
