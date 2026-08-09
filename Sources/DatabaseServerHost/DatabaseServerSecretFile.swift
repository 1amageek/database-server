import Darwin
import Foundation

enum DatabaseServerSecretFile {
    private static let maximumSecretBytes = 64 * 1_024

    static func readPassword(path: String) throws -> String {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NativeDatabaseStorageError.invalidPasswordFile
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { handle.closeFile() }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == geteuid(),
              metadata.st_size > 0,
              metadata.st_size <= maximumSecretBytes else {
            throw NativeDatabaseStorageError.invalidPasswordFile
        }
        let expectedCount = Int(metadata.st_size)
        var data = try handle.read(upToCount: expectedCount + 1) ?? Data()
        guard data.count == expectedCount else {
            throw NativeDatabaseStorageError.invalidPasswordFile
        }
        if data.last == 0x0A {
            data.removeLast()
            if data.last == 0x0D { data.removeLast() }
        }
        guard !data.isEmpty,
              let password = String(data: data, encoding: .utf8) else {
            throw NativeDatabaseStorageError.invalidPasswordFile
        }
        return password
    }
}
