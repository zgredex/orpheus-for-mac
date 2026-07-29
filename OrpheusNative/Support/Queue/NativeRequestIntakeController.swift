import Foundation
import NativeQobuzCore

enum NativeRequestIntakeAction {
    case open(QobuzRequest)
    case search(String)
}

struct NativeRequestIntakeOutcome {
    let action: NativeRequestIntakeAction?
    let clearsInput: Bool
    let updatesNotice: Bool
    let notice: String?
    let requiresConfiguration: Bool
}

enum NativeSubmittedText {
    case success(String)
    case failure(String)
}

@MainActor
final class NativeRequestIntakeController {
    private let linkInbox: NativeLinkInboxController

    init(linkInbox: NativeLinkInboxController) {
        self.linkInbox = linkInbox
    }

    func submit(_ input: String) -> NativeRequestIntakeOutcome {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return unchanged }
        let extraction = QobuzLinkParser.extract(from: value)
        qobuzLog.info(
            "input",
            "User input classified",
            metadata: [
                "characterCount": String(value.count),
                "validLinks": String(extraction.links.count),
                "duplicateLinks": String(extraction.duplicateCount),
                "invalidQobuzLinks": String(extraction.invalidQobuzURLs.count),
                "mode": extraction.links.isEmpty ? "search" : "links"
            ]
        )
        if extraction.links.count == 1, extraction.duplicateCount == 0,
           let link = extraction.links.first {
            return NativeRequestIntakeOutcome(
                action: .open(link.request),
                clearsInput: true,
                updatesNotice: true,
                notice: extraction.invalidQobuzURLs.isEmpty
                    ? nil
                    : "Ignored \(extraction.invalidQobuzURLs.count) invalid Qobuz URL.",
                requiresConfiguration: false
            )
        }
        if !extraction.links.isEmpty {
            let result = linkInbox.add(extraction.links)
            let invalid = extraction.invalidQobuzURLs.count
            let notice: String? = if result.duplicateOnly {
                "Those links are already in the review inbox."
            } else if invalid > 0 {
                "Added the valid links for review and ignored \(invalid) unsupported Qobuz URL\(invalid == 1 ? "" : "s")."
            } else {
                nil
            }
            return NativeRequestIntakeOutcome(
                action: nil,
                clearsInput: true,
                updatesNotice: true,
                notice: notice,
                requiresConfiguration: result.requiresConfiguration
            )
        }
        if !extraction.invalidQobuzURLs.isEmpty {
            return NativeRequestIntakeOutcome(
                action: nil,
                clearsInput: false,
                updatesNotice: true,
                notice: "The Qobuz URL is not a supported track, album, playlist, artist, or label link.",
                requiresConfiguration: false
            )
        }
        return NativeRequestIntakeOutcome(
            action: .search(value),
            clearsInput: true,
            updatesNotice: false,
            notice: nil,
            requiresConfiguration: false
        )
    }

    func importedText(from url: URL) throws -> String {
        do {
            let data = try NativeBoundedFileReader.readComplete(
                url,
                maximumBytes: 2 * 1_024 * 1_024,
                followSymbolicLinks: true
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw NativeQobuzError.invalidResponse("The imported link file is not valid UTF-8 text.")
            }
            qobuzLog.notice(
                "input.import",
                "Link text file imported",
                metadata: [
                    "sourcePath": url.path,
                    "characterCount": String(text.count),
                    "sourceBytes": String(data.count)
                ]
            )
            return text
        } catch {
            qobuzLog.error(
                "input.import",
                "Link text file could not be read",
                metadata: ["sourcePath": url.path],
                error: error
            )
            throw error
        }
    }

    func submittedText(from url: URL) -> NativeSubmittedText {
        if ["orpheus-for-mac", "orpheus-native"].contains(url.scheme?.lowercased() ?? "") {
            guard let submitted = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value else {
                return .failure("The Orpheus link did not contain a Qobuz URL.")
            }
            return .success(submitted)
        }
        return .success(url.absoluteString)
    }

    private var unchanged: NativeRequestIntakeOutcome {
        NativeRequestIntakeOutcome(
            action: nil,
            clearsInput: false,
            updatesNotice: false,
            notice: nil,
            requiresConfiguration: false
        )
    }
}
