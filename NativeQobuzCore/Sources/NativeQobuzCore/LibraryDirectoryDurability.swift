import Darwin

enum LibraryDirectoryDurability {
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    static func synchronize(
        _ directories: [(descriptor: Int32, path: String)],
        operation: String
    ) throws {
        var synchronized = Set<Identity>()
        for directory in directories {
            var status = stat()
            guard fstat(directory.descriptor, &status) == 0 else {
                throw mappedError(
                    operation: "fstat-directory-before-\(operation)",
                    path: directory.path,
                    code: errno
                )
            }
            guard synchronized.insert(Identity(device: status.st_dev, inode: status.st_ino)).inserted else {
                continue
            }
            guard fsync(directory.descriptor) == 0 else {
                throw mappedError(
                    operation: operation,
                    path: directory.path,
                    code: errno
                )
            }
        }
    }
}
