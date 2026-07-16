import AppKit
import SwiftUI
import XCTest

@MainActor
enum RenderedSnapshotHarness {
    private static let signatureColumns = 32
    private static let signatureRows = 20

    static func assertSnapshot<Content: View>(
        named name: String,
        size: CGSize,
        meanTolerance: Double,
        content: Content,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTContext.runActivity(named: "Rendered snapshot: \(name)") { activity in
            guard let rendering = render(content: content, size: size) else {
                XCTFail("Could not render \(name).", file: file, line: line)
                return
            }

            writeArtifact(rendering.png, named: name)
            let actual = reference(
                size: size,
                meanTolerance: meanTolerance,
                rgb: rendering.signature
            )
            writeCandidateReference(actual, named: name)

            let comparison = compare(actual, withReferenceNamed: name)
            let attachment = XCTAttachment(
                data: rendering.png,
                uniformTypeIdentifier: "public.png"
            )
            attachment.name = "\(name).png"
            attachment.lifetime = comparison.failed ? .keepAlways : .deleteOnSuccess
            activity.add(attachment)

            XCTAssertGreaterThan(
                rendering.luminanceSpread,
                4,
                "\(name) rendered as an effectively blank image.",
                file: file,
                line: line
            )
            guard let failure = comparison.failure else { return }
            XCTFail(failure, file: file, line: line)
        }
    }

    private static func render<Content: View>(
        content: Content,
        size: CGSize
    ) -> (png: Data, signature: Data, luminanceSpread: Double)? {
        let framed = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hostingView = NSHostingView(rootView: framed)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let appearance = NSAppearance(named: .darkAqua)
        hostingView.appearance = appearance
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            window.close()
            return nil
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        window.close()
        guard let cgImage = representation.cgImage,
              let png = representation.representation(using: .png, properties: [:]),
              let pixels = downsample(cgImage) else { return nil }
        return (png, pixels.rgb, pixels.luminanceSpread)
    }

    private static func downsample(_ image: CGImage) -> (rgb: Data, luminanceSpread: Double)? {
        let bytesPerPixel = 4
        let bytesPerRow = signatureColumns * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * signatureRows)
        let drewImage = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: signatureColumns,
                height: signatureRows,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: signatureColumns, height: signatureRows)
            )
            return true
        }
        guard drewImage else { return nil }

        var rgb = Data(capacity: signatureColumns * signatureRows * 3)
        var luminance: [Double] = []
        luminance.reserveCapacity(signatureColumns * signatureRows)
        for offset in stride(from: 0, to: rgba.count, by: bytesPerPixel) {
            let red = rgba[offset]
            let green = rgba[offset + 1]
            let blue = rgba[offset + 2]
            rgb.append(red)
            rgb.append(green)
            rgb.append(blue)
            luminance.append(0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue))
        }
        let average = luminance.reduce(0, +) / Double(luminance.count)
        let variance = luminance.reduce(0) { $0 + pow($1 - average, 2) } / Double(luminance.count)
        return (rgb, sqrt(variance))
    }

    private static func reference(
        size: CGSize,
        meanTolerance: Double,
        rgb: Data
    ) -> RenderedSnapshotReference {
        RenderedSnapshotReference(
            schemaVersion: 1,
            platformMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            width: Int(size.width),
            height: Int(size.height),
            columns: signatureColumns,
            rows: signatureRows,
            meanTolerance: meanTolerance,
            rgb: rgb
        )
    }

    private static func compare(
        _ actual: RenderedSnapshotReference,
        withReferenceNamed name: String
    ) -> (failed: Bool, failure: String?) {
        let url = sourceReferenceDirectory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let expected = try? JSONDecoder().decode(RenderedSnapshotReference.self, from: data) else {
            return (true, "Missing or invalid rendered snapshot reference at \(url.path).")
        }
        guard expected.schemaVersion == 1,
              expected.width == actual.width,
              expected.height == actual.height,
              expected.columns == actual.columns,
              expected.rows == actual.rows,
              expected.meanTolerance == actual.meanTolerance,
              expected.rgb.count == actual.rgb.count else {
            return (true, "Rendered snapshot geometry or schema changed for \(name).")
        }
        guard expected.platformMajor == actual.platformMajor else {
            return (false, nil)
        }

        let difference = zip(expected.rgb, actual.rgb).reduce(0.0) {
            $0 + abs(Double($1.0) - Double($1.1))
        } / (Double(actual.rgb.count) * 255)
        let tolerance = expected.meanTolerance
        guard difference <= tolerance else {
            return (
                true,
                String(
                    format: "Rendered snapshot %@ changed (mean RGB difference %.4f, tolerance %.4f).",
                    name,
                    difference,
                    tolerance
                )
            )
        }
        return (false, nil)
    }

    private static var sourceReferenceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ReferenceSnapshots", isDirectory: true)
    }

    private static func writeArtifact(_ png: Data, named name: String) {
        let configured = ProcessInfo.processInfo.environment["ORPHEUS_UI_SNAPSHOT_ARTIFACTS"]
        let directory = configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repositoryRoot.appendingPathComponent("Build/CI/UISnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private static func writeCandidateReference(
        _ reference: RenderedSnapshotReference,
        named name: String
    ) {
        let configured = ProcessInfo.processInfo.environment["ORPHEUS_UI_SNAPSHOT_REFERENCE_OUTPUT"]
        let sourceReference = sourceReferenceDirectory.appendingPathComponent("\(name).json")
        guard configured?.isEmpty == false || !FileManager.default.fileExists(atPath: sourceReference.path) else {
            return
        }
        let directory = configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repositoryRoot.appendingPathComponent("Build/CI/UIReferenceCandidates", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(reference).write(
            to: directory.appendingPathComponent("\(name).json"),
            options: .atomic
        )
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct RenderedSnapshotReference: Codable {
    let schemaVersion: Int
    let platformMajor: Int
    let width: Int
    let height: Int
    let columns: Int
    let rows: Int
    let meanTolerance: Double
    let rgb: Data
}
