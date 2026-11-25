import Foundation
import agtermCore

/// Reads through the origin's granted channel for replicas, and bounded descriptors for local pages.
@MainActor
enum LinuxTextReads {
    static func location(_ page: LinuxHtmlOverlayPage) -> (path: String, line: Int?)? {
        switch page.overlay.source {
        case .text(let path, let line), .replica(let path, .text(let line)): (path, line)
        default: nil
        }
    }

    static func text(_ page: LinuxHtmlOverlayPage, completion: @escaping @MainActor (Result<String, TextProbe.Failure>) -> Void) {
        guard let location = location(page) else { return }
        if case .replica = page.overlay.source {
            guard let channel = page.controller?.replicaPages[page.id]?.channel else { return completion(.failure(.unreadable(location.path))) }
            channel.fetch(location.path) { result in
                guard case .success(let resource) = result else { return completion(.failure(.unreadable(location.path))) }
                read(resource.path, retaining: resource, completion: completion)
            }
        } else { read(location.path, retaining: nil, completion: completion) }
    }

    private static func read(_ path: String, retaining resource: LinuxPageResource?,
                             completion: @escaping @MainActor (Result<String, TextProbe.Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = withExtendedLifetime(resource) { TextProbe.load(path: path) }
            runOnMain { MainActor.assumeIsolated { completion(result) } }
        }
    }

    static func log(_ page: LinuxHtmlOverlayPage, stamp: BoundedFile.FileStamp?,
                    completion: @escaping @MainActor (Result<TextProbe.LogRead?, TextProbe.Failure>) -> Void) {
        guard let location = location(page), let log = page.overlay.textLog else { return }
        if case .replica = page.overlay.source {
            guard let channel = page.controller?.replicaPages[page.id]?.channel else { return completion(.failure(.unreadable(location.path))) }
            channel.logTail(unchangedFrom: stamp) { result in
                completion(result.map { $0.map { TextProbe.LogRead($0, tail: log.tail) } }.mapError { _ in .unreadable(location.path) })
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                let result = TextProbe.loadLog(path: location.path, tail: log.tail, unchangedFrom: stamp)
                runOnMain { MainActor.assumeIsolated { completion(result) } }
            }
        }
    }
}
