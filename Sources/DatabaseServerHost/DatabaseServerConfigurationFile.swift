import Darwin
import Foundation

enum DatabaseServerConfigurationFile {
    private static let maximumConfigurationBytes = 1 * 1_024 * 1_024

    static func read(from url: URL) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DatabaseServerLaunchConfigurationError.invalidDocument
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { handle.closeFile() }
        let byteCount = try validateFile(descriptor: descriptor)
        let data = try handle.read(upToCount: byteCount + 1) ?? Data()
        guard data.count == byteCount else {
            throw DatabaseServerLaunchConfigurationError.invalidDocument
        }
        return data
    }

    static func create(
        _ data: Data,
        at url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try DatabasePrivateDirectory.ensure(directory)
        } catch DatabasePrivateDirectory.Failure.invalidDirectory {
            throw DatabaseServerLaunchConfigurationError
                .invalidConfigurationPermissions
        } catch {
            throw DatabaseServerLaunchConfigurationError
                .configurationWriteFailed
        }

        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DatabaseServerLaunchConfigurationError
                .configurationAlreadyExists
        }
        var shouldRemove = true
        var didCloseDescriptor = false
        defer {
            if !didCloseDescriptor {
                _ = Darwin.close(descriptor)
            }
            if shouldRemove { _ = Darwin.unlink(url.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw DatabaseServerLaunchConfigurationError
                        .configurationWriteFailed
                }
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DatabaseServerLaunchConfigurationError
                .configurationWriteFailed
        }
        _ = try validateFile(descriptor: descriptor)
        guard Darwin.close(descriptor) == 0 else {
            didCloseDescriptor = true
            throw DatabaseServerLaunchConfigurationError
                .configurationWriteFailed
        }
        didCloseDescriptor = true
        try synchronizeDirectory(directory)
        shouldRemove = false
    }

    private static func validateFile(descriptor: Int32) throws -> Int {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= maximumConfigurationBytes else {
            throw DatabaseServerLaunchConfigurationError
                .invalidConfigurationPermissions
        }
        return Int(metadata.st_size)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DatabaseServerLaunchConfigurationError
                .configurationWriteFailed
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DatabaseServerLaunchConfigurationError
                .configurationWriteFailed
        }
    }
}
