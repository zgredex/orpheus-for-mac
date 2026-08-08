import Darwin
import Foundation

public extension LibraryFileSystem {
    func removeFile(_ path: LibraryRelativePath, ifPresent: Bool = false) throws {
        try root.withParent(of: path) { parent, leaf in
            guard let metadata = try metadata(named: leaf, in: parent, path: path) else {
                if ifPresent { return }
                throw LibraryFileSystemError.missing(path.rawValue)
            }
            if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
            if metadata.kind == .hardLink { throw LibraryFileSystemError.hardLink(path.rawValue) }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            let result = leaf.withCString { unlinkat(parent, $0, 0) }
            guard result == 0 else {
                throw mappedError(operation: "unlinkat", path: path.rawValue, code: errno)
            }
            try LibraryDirectoryDurability.synchronize(
                [(parent, path.parent.rawValue)],
                operation: "fsync-parent-after-unlinkat"
            )
        }
    }

    func replaceItem(at destination: LibraryRelativePath, with source: LibraryRelativePath) throws {
        try root.withParent(of: source) { sourceParent, sourceLeaf in
            guard let sourceMetadata = try metadata(named: sourceLeaf, in: sourceParent, path: source) else {
                throw LibraryFileSystemError.missing(source.rawValue)
            }
            if sourceMetadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(source.rawValue) }
            if sourceMetadata.kind == .hardLink { throw LibraryFileSystemError.hardLink(source.rawValue) }
            guard sourceMetadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(source.rawValue)
            }
            try root.withParent(of: destination, create: true) { destinationParent, destinationLeaf in
                try requireSafeReplacement(named: destinationLeaf, in: destinationParent, path: destination)
                let result = sourceLeaf.withCString { sourceName in
                    destinationLeaf.withCString { destinationName in
                        renameat(sourceParent, sourceName, destinationParent, destinationName)
                    }
                }
                guard result == 0 else {
                    throw mappedError(operation: "renameat-replace", path: destination.rawValue, code: errno)
                }
                try synchronizeMoveParents(
                    source: (sourceParent, source.parent.rawValue),
                    destination: (destinationParent, destination.parent.rawValue),
                    operation: "fsync-parent-after-replace"
                )
            }
        }
    }

    func moveItem(at source: LibraryRelativePath, to destination: LibraryRelativePath) throws {
        try renameNewItem(at: source, to: destination, allowingSymbolicLink: false)
    }

    /// Renames a rejected regular file or symbolic-link leaf without opening
    /// it or resolving its target. This is intentionally separate from
    /// `moveItem`, whose normal Library contract rejects symbolic links.
    func quarantineItem(at source: LibraryRelativePath, to destination: LibraryRelativePath) throws {
        try renameNewItem(at: source, to: destination, allowingSymbolicLink: true)
    }

    private func renameNewItem(
        at source: LibraryRelativePath,
        to destination: LibraryRelativePath,
        allowingSymbolicLink: Bool
    ) throws {
        let operationKind = allowingSymbolicLink ? "quarantine" : "move"
        try root.withParent(of: source) { sourceParent, sourceLeaf in
            guard let sourceMetadata = try metadata(named: sourceLeaf, in: sourceParent, path: source) else {
                throw LibraryFileSystemError.missing(source.rawValue)
            }
            if sourceMetadata.kind == .symbolicLink, !allowingSymbolicLink {
                throw LibraryFileSystemError.symbolicLink(source.rawValue)
            }
            if sourceMetadata.kind == .hardLink, !allowingSymbolicLink {
                throw LibraryFileSystemError.hardLink(source.rawValue)
            }
            guard sourceMetadata.kind == .regularFile
                    || (allowingSymbolicLink
                        && (sourceMetadata.kind == .symbolicLink || sourceMetadata.kind == .hardLink)) else {
                throw LibraryFileSystemError.notRegularFile(source.rawValue)
            }
            try root.withParent(of: destination, create: true) { destinationParent, destinationLeaf in
                guard try metadata(named: destinationLeaf, in: destinationParent, path: destination) == nil else {
                    throw LibraryFileSystemError.system(
                        operation: "renameat-existing-\(operationKind)",
                        path: destination.rawValue,
                        code: EEXIST
                    )
                }
                let result = sourceLeaf.withCString { sourceName in
                    destinationLeaf.withCString { destinationName in
                        renameat(sourceParent, sourceName, destinationParent, destinationName)
                    }
                }
                guard result == 0 else {
                    throw mappedError(
                        operation: "renameat-\(operationKind)",
                        path: source.rawValue,
                        code: errno
                    )
                }
                try synchronizeMoveParents(
                    source: (sourceParent, source.parent.rawValue),
                    destination: (destinationParent, destination.parent.rawValue),
                    operation: "fsync-parent-after-\(operationKind)"
                )
            }
        }
    }

    private func synchronizeMoveParents(
        source: (descriptor: Int32, path: String),
        destination: (descriptor: Int32, path: String),
        operation: String
    ) throws {
        try LibraryDirectoryDurability.synchronize(
            [destination, source],
            operation: operation
        )
    }
}
