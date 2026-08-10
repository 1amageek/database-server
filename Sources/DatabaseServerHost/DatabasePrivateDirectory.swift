import Darwin
import Foundation

enum DatabasePrivateDirectory {
    enum Failure: Error, Sendable {
        case invalidDirectory
        case creationFailed
    }

    static func ensure(_ url: URL) throws {
        let target = url.standardizedFileURL
        var missing: [URL] = []
        var cursor = target

        while true {
            var metadata = stat()
            if Darwin.lstat(cursor.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw Failure.invalidDirectory
                }
                break
            }
            guard errno == ENOENT else {
                throw Failure.invalidDirectory
            }
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw Failure.invalidDirectory
            }
            cursor = parent
        }

        for directory in missing.reversed() {
            if Darwin.mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
                throw Failure.creationFailed
            }
            try validate(directory)
        }
        try validate(target)
    }

    private static func validate(_ url: URL) throws {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == geteuid() else {
            throw Failure.invalidDirectory
        }
    }
}
