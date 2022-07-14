#if os(OSX)
import Darwin.C
#else
import Glibc
#endif

public enum SpawnError: Error {
    case CouldNotOpenPty
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

    /// The pty (like a pipe but fakes being a terminal) we use to communicate (listen, in this case) with our child process.
    private var ptyFDs: [Int32] = [-1, -1]
    private var writeRawBytesToStdErr: Bool

    public init(
        args: [String],
        envs: [String] = [],
        writeRawBytesToStdErr: Bool = false,
        output: OutputClosure? = nil
    ) throws {
        (self.args, self.output)  = (args, output)

        self.writeRawBytesToStdErr = writeRawBytesToStdErr

        let ptyFD = posix_openpt(O_RDWR)
        if ptyFD < 0 {
            throw SpawnError.CouldNotOpenPty
        }
        // Grant permissions and unlock our pty
        let grantRet = grantpt(ptyFD)
        if grantRet < 0 {
            throw SpawnError.CouldNotOpenPty
        }
        let unlockRet = unlockpt(ptyFD)
        if unlockRet < 0 {
            throw SpawnError.CouldNotOpenPty
        }

        // Get the file the file descriptor points to
        guard let childPtyName = ptsname(ptyFD) else {
            throw SpawnError.CouldNotOpenPty
        }
        // Create an FD for the child
        let childPtyFD = open(childPtyName, O_RDWR)

        // Save them in pipe format for use later
        ptyFDs = [ptyFD, childPtyFD]

        // Create a file actions object
        posix_spawn_file_actions_init(&childFDActions)

        // Tie the child's stdout and stderr to our pty file descriptor so we can read it
        posix_spawn_file_actions_adddup2(&childFDActions, childPtyFD, 1)
        posix_spawn_file_actions_adddup2(&childFDActions, childPtyFD, 2)

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
        let ptyFDs: [Int32]
        let output: OutputClosure?
        let writeRawBytesToStdErr: Bool
    }
    private var threadInfo: ThreadInfo!

    private func watchStreams() {
        func callback(x: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
            let threadInfo = x.assumingMemoryBound(to: ThreadInfo.self).pointee
            let ptyFDs = threadInfo.ptyFDs
            // Close our child end of the pty, since we don't need it.
            close(ptyFDs[1])

            let bufferSize: size_t = 1024 * 8
            let dynamicBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

            // Don't buffer output to stderr
            // Flush immediately after writing every time
            if threadInfo.writeRawBytesToStdErr {
                setbuf(__stderrp, nil)
            }

            while true {
                let amtRead = read(ptyFDs[0], dynamicBuffer, bufferSize)
                if amtRead <= 0 {
                    break
                }

                if threadInfo.writeRawBytesToStdErr {
                    write(2, dynamicBuffer, amtRead)
                }

                // Create a swift string and pass to output closure for capturing output
                let array = Array(UnsafeBufferPointer(start: dynamicBuffer, count: amtRead))
                let tmp = array  + [UInt8(0)] // null char at end of string so it's properly interpreted by swift as a c str
                tmp.withUnsafeBufferPointer { ptr in
                  let str = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                  threadInfo.output?(str)
                }
            }
            dynamicBuffer.deallocate()
            return nil
        }

        threadInfo = ThreadInfo(ptyFDs: ptyFDs, output:output, writeRawBytesToStdErr: writeRawBytesToStdErr)

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
