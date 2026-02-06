import Foundation
import Compression

/// A simple archive format for bundling link archive files (HTML + assets) into a single compressed blob.
/// Used for reliable CloudKit sync, then extracted locally.
public enum ArchiveBundle {

    /// Creates a compressed archive from all files in the given directory.
    /// - Parameter directoryURL: The directory containing files to archive (e.g., Links/<uuid>/)
    /// - Returns: Compressed data containing all files, or nil if archiving fails
    public static func create(from directoryURL: URL) -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return nil }

        var files: [String: Data] = [:]
        let directoryPath = directoryURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }

            guard fileURL.path.hasPrefix(prefix) else { continue }
            let relativePath = String(fileURL.path.dropFirst(prefix.count))
            guard !relativePath.isEmpty else { continue }

            guard let data = try? Data(contentsOf: fileURL) else { continue }
            files[relativePath] = data
        }

        guard !files.isEmpty else { return nil }

        // Serialize the dictionary
        guard let archived = try? NSKeyedArchiver.archivedData(withRootObject: files, requiringSecureCoding: false) else {
            return nil
        }

        // Compress the data
        return compress(archived)
    }

    /// Extracts an archive to the given directory.
    /// - Parameters:
    ///   - data: The compressed archive data
    ///   - directoryURL: The destination directory
    /// - Returns: True if extraction succeeded
    @discardableResult
    public static func extract(_ data: Data, to directoryURL: URL) -> Bool {
        let fileManager = FileManager.default

        // Decompress
        guard let decompressed = decompress(data) else { return false }

        // Unarchive
        guard let files = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSData.self], from: decompressed) as? [String: Data] else {
            return false
        }

        // Create destination directory
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return false
        }

        // Write files
        for (relativePath, fileData) in files {
            let fileURL = directoryURL.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()

            do {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try fileData.write(to: fileURL, options: .atomic)
            } catch {
                // Continue with other files even if one fails
                continue
            }
        }

        return true
    }

    // MARK: - Compression Helpers

    private static func compress(_ data: Data) -> Data? {
        let sourceSize = data.count
        guard sourceSize > 0 else { return nil }

        // LZFSE can produce slightly larger output for incompressible data.
        // Retry with a larger destination buffer instead of failing silently.
        var destinationBufferSize = max(sourceSize + 256, 64 * 1024)
        var compressedPayload: Data?

        for _ in 0..<6 {
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
            defer { destinationBuffer.deallocate() }

            let compressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
                guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBuffer,
                    destinationBufferSize,
                    sourcePointer,
                    sourceSize,
                    nil,
                    COMPRESSION_LZFSE
                )
            }

            if compressedSize > 0 {
                compressedPayload = Data(bytes: destinationBuffer, count: compressedSize)
                break
            }

            destinationBufferSize *= 2
        }

        guard let compressedPayload else { return nil }

        // Store original size as little-endian for stable decoding across architectures.
        var originalSizeLE = UInt64(sourceSize).littleEndian
        var result = Data()
        result.append(Data(bytes: &originalSizeLE, count: MemoryLayout<UInt64>.size))
        result.append(compressedPayload)
        return result
    }

    private static func decompress(_ data: Data) -> Data? {
        guard data.count > MemoryLayout<UInt64>.size else { return nil }

        // Read original size without assuming pointer alignment.
        let header = data.prefix(MemoryLayout<UInt64>.size)
        var sizeLE: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &sizeLE) { dst in
            header.copyBytes(to: dst)
        }
        let originalSizeUInt64 = UInt64(littleEndian: sizeLE)
        let maxAllowedBytes = UInt64(SyncPolicy.maximumMaxFileSizeMB) * 1_048_576
        guard originalSizeUInt64 > 0,
              originalSizeUInt64 <= maxAllowedBytes,
              originalSizeUInt64 <= UInt64(Int.max) else { return nil }
        let originalSize = Int(originalSizeUInt64)

        let compressedData = data.dropFirst(MemoryLayout<UInt64>.size)

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = compressedData.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                originalSize,
                sourcePointer,
                compressedData.count,
                nil,
                COMPRESSION_LZFSE
            )
        }

        guard decompressedSize == originalSize else { return nil }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}
