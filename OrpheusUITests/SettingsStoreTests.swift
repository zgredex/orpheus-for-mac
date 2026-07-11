import XCTest
@testable import OrpheusUI

final class SettingsStoreTests: XCTestCase {
    func testRoundTripPreservesLargeUnknownIntegerExactly() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let settingsURL = temp.appendingPathComponent("settings.json")
        try Data(#"{"future_counter":9007199254740993}"#.utf8).write(to: settingsURL)

        let document = try SettingsStore.load(from: settingsURL)
        try SettingsStore.save(document, to: settingsURL)
        let saved = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(saved.contains("9007199254740993"))
    }

    func testRoundTripPreservesUnknownTopLevelFields() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let settingsURL = temp.appendingPathComponent("settings.json")
        let original = """
        {
          "global": {
            "general": {
              "download_path": "./downloads/",
              "download_quality": "hifi",
              "search_limit": 10
            },
            "advanced": {
              "codec_conversions": {"alac": "flac"}
            }
          },
          "extensions": {
            "custom": {
              "unknown": true
            }
          },
          "modules": {
            "qobuz": {
              "app_id": "app",
              "app_secret": "secret",
              "quality_format": "{bit_depth}B",
              "user_id": "user",
              "auth_token": "token"
            }
          },
          "future_field": {
            "nested": [1, "two", false]
          }
        }
        """
        try original.data(using: .utf8)!.write(to: settingsURL)

        var document = try SettingsStore.load(from: settingsURL)
        document.downloadQuality = "lossless"
        document.qobuzAuthToken = "new-token"
        try SettingsStore.save(document, to: settingsURL)

        let reloaded = try SettingsStore.load(from: settingsURL)
        XCTAssertEqual(reloaded.downloadQuality, "lossless")
        XCTAssertEqual(reloaded.qobuzAuthToken, "new-token")
        XCTAssertEqual(reloaded[path: ["modules", "qobuz", "quality_format"]]?.stringValue, "{bit_depth}B")
        XCTAssertNotNil(reloaded[path: ["extensions", "custom", "unknown"]])
        XCTAssertNotNil(reloaded[path: ["future_field", "nested"]])
    }

    func testPrepareRuntimeSanitizesCopiedTemplateSettingsAndPreservesUserSettingsOnRelaunch() throws {
        let temp = try makeTempDirectory()
        let template = temp.appendingPathComponent("Template", isDirectory: true)
        let support = temp.appendingPathComponent("Support", isDirectory: true)
        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        try writeTemplateSettings(
            under: template,
            authToken: "template-token",
            userID: "template-user",
            downloadPath: "./downloads"
        )

        let runtime = RuntimeLocator(
            applicationSupportRoot: support,
            defaultDownloadURL: downloads,
            templateURL: template
        )

        try runtime.prepareRuntime()

        var copied = try SettingsStore.load(from: runtime.settingsURL)
        XCTAssertEqual(copied.qobuzAuthToken, "")
        XCTAssertEqual(copied.qobuzUserID, "")
        XCTAssertEqual(copied.downloadPath, downloads.path)

        copied.qobuzAuthToken = "user-token"
        copied.qobuzUserID = "user-id"
        try SettingsStore.save(copied, to: runtime.settingsURL)

        try runtime.prepareRuntime()

        let preserved = try SettingsStore.load(from: runtime.settingsURL)
        XCTAssertEqual(preserved.qobuzAuthToken, "user-token")
        XCTAssertEqual(preserved.qobuzUserID, "user-id")
    }

    func testPrepareRuntimeRemovesAbandonedStagingDirectories() throws {
        let temp = try makeTempDirectory()
        let template = temp.appendingPathComponent("Template", isDirectory: true)
        let support = temp.appendingPathComponent("Support", isDirectory: true)
        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        try writeTemplateSettings(
            under: template,
            authToken: "",
            userID: "",
            downloadPath: downloads.path
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let staleInstall = support.appendingPathComponent(".OrpheusDL.staging.old", isDirectory: true)
        let staleRefresh = support.appendingPathComponent(".OrpheusDL.refresh.old", isDirectory: true)
        try FileManager.default.createDirectory(at: staleInstall, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleRefresh, withIntermediateDirectories: true)

        let runtime = RuntimeLocator(
            applicationSupportRoot: support,
            defaultDownloadURL: downloads,
            templateURL: template
        )
        try runtime.prepareRuntime()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleInstall.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRefresh.path))
    }

    func testPrepareRuntimeDoesNotDeleteExistingRuntimeWhenTemplateResolutionFails() throws {
        let temp = try makeTempDirectory()
        let support = temp.appendingPathComponent("Support", isDirectory: true)
        let runtimeProject = support.appendingPathComponent("OrpheusDL", isDirectory: true)
        let marker = runtimeProject.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: runtimeProject, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: marker)

        let runtime = RuntimeLocator(
            applicationSupportRoot: support,
            defaultDownloadURL: temp.appendingPathComponent("Downloads", isDirectory: true),
            templateURL: temp.appendingPathComponent("MissingTemplate", isDirectory: true)
        )

        XCTAssertThrowsError(try runtime.prepareRuntime())
        XCTAssertEqual(try String(contentsOf: marker), "keep me")
    }

    func testPrepareRuntimeReplacesIncompleteExistingRuntimeAfterStagingSucceeds() throws {
        let temp = try makeTempDirectory()
        let template = temp.appendingPathComponent("Template", isDirectory: true)
        let support = temp.appendingPathComponent("Support", isDirectory: true)
        let runtimeProject = support.appendingPathComponent("OrpheusDL", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeProject, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: runtimeProject.appendingPathComponent("old.txt"))
        try writeTemplateSettings(
            under: template,
            authToken: "template-token",
            userID: "template-user",
            downloadPath: "./downloads"
        )

        let runtime = RuntimeLocator(
            applicationSupportRoot: support,
            defaultDownloadURL: temp.appendingPathComponent("Downloads", isDirectory: true),
            templateURL: template
        )

        try runtime.prepareRuntime()

        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeProject.appendingPathComponent("old.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.settingsURL.path))
    }

    func testPrepareRuntimeRefreshesCodeAndPreservesMutableRuntimeFiles() throws {
        let temp = try makeTempDirectory()
        let template = temp.appendingPathComponent("Template", isDirectory: true)
        let support = temp.appendingPathComponent("Support", isDirectory: true)
        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        try writeTemplateSettings(
            under: template,
            authToken: "template-token",
            userID: "template-user",
            downloadPath: "./downloads"
        )
        try Data("v1".utf8).write(to: template.appendingPathComponent("orpheus.py"))

        let runtime = RuntimeLocator(
            applicationSupportRoot: support,
            defaultDownloadURL: downloads,
            templateURL: template
        )

        try runtime.prepareRuntime()

        var settings = try SettingsStore.load(from: runtime.settingsURL)
        settings.qobuzAuthToken = "user-token"
        settings.qobuzUserID = "user-id"
        try SettingsStore.save(settings, to: runtime.settingsURL)

        let session = runtime.runtimeProjectURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("loginstorage.bin")
        try Data("session".utf8).write(to: session)
        let runtimeDownload = runtime.runtimeProjectURL
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("track.flac")
        try FileManager.default.createDirectory(at: runtimeDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: runtimeDownload)
        let runtimeTemp = runtime.runtimeProjectURL
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent("scratch.tmp")
        try FileManager.default.createDirectory(at: runtimeTemp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("temp".utf8).write(to: runtimeTemp)

        try Data("v2".utf8).write(to: template.appendingPathComponent("orpheus.py"))
        try runtime.prepareRuntime()

        XCTAssertEqual(try String(contentsOf: runtime.runtimeProjectURL.appendingPathComponent("orpheus.py")), "v2")
        let preserved = try SettingsStore.load(from: runtime.settingsURL)
        XCTAssertEqual(preserved.qobuzAuthToken, "user-token")
        XCTAssertEqual(preserved.qobuzUserID, "user-id")
        XCTAssertEqual(try String(contentsOf: session), "session")
        XCTAssertEqual(try String(contentsOf: runtimeDownload), "audio")
        XCTAssertEqual(try String(contentsOf: runtimeTemp), "temp")
    }

    func testHelperResolutionPrefersOnedirAndFallsBackToLegacyBinary() throws {
        let temp = try makeTempDirectory()
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let helperDir = resources.appendingPathComponent("orpheus-helper", isDirectory: true)
        let onedirHelper = helperDir.appendingPathComponent("orpheus-helper")
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: onedirHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onedirHelper.path)

        let runtime = RuntimeLocator(
            applicationSupportRoot: temp.appendingPathComponent("Support", isDirectory: true),
            defaultDownloadURL: temp.appendingPathComponent("Downloads", isDirectory: true),
            resourceURL: resources
        )

        XCTAssertEqual(runtime.helperURL.path, onedirHelper.path)

        try FileManager.default.removeItem(at: helperDir)
        let legacyHelper = resources.appendingPathComponent("orpheus-helper")
        try Data("#!/bin/sh\n".utf8).write(to: legacyHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyHelper.path)

        XCTAssertEqual(runtime.helperURL.path, legacyHelper.path)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTemplateSettings(
        under template: URL,
        authToken: String,
        userID: String,
        downloadPath: String
    ) throws {
        let config = template.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let settings = """
        {
          "global": {
            "general": {
              "download_path": "\(downloadPath)",
              "download_quality": "hifi"
            },
            "advanced": {
              "codec_conversions": {"alac": "flac"}
            }
          },
          "modules": {
            "qobuz": {
              "app_id": "app",
              "app_secret": "secret",
              "user_id": "\(userID)",
              "auth_token": "\(authToken)"
            }
          }
        }
        """
        try Data(settings.utf8).write(to: config.appendingPathComponent("settings.json"))
    }
}
