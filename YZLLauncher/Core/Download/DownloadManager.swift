import Foundation
import Combine

enum DownloadPhase: Equatable {
    case queued
    case probing
    case running
    case verifying
    case finished(URL)
    case failed(String)
    case cancelled
}

struct DownloadJob: Identifiable, Equatable {
    let id: String
    var phase: DownloadPhase = .queued
    var downloaded: Int64 = 0
    var total: Int64 = 0
    var segmented: Bool = false
    var activeSegments: Int = 0
    var startedAt: Date = Date()

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(downloaded) / Double(total))
    }

    var speedBytesPerSecond: Double {
        switch phase {
        case .running:
            let seconds = max(Date().timeIntervalSince(startedAt), 0.5)
            return Double(downloaded) / seconds
        default:
            return 0
        }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [String: DownloadJob] = [:]

    private let downloader: SegmentedDownloader
    private var tasks: [String: Task<Void, Never>] = [:]

    init(downloader: SegmentedDownloader = SegmentedDownloader()) {
        self.downloader = downloader
    }

    func job(for id: String) -> DownloadJob? {
        jobs[id]
    }

    func start(_ spec: DownloadSpec) {
        tasks[spec.id]?.cancel()
        tasks[spec.id] = nil
        jobs[spec.id] = DownloadJob(id: spec.id)

        let downloader = self.downloader
        tasks[spec.id] = Task { @MainActor in
            do {
                for try await event in downloader.download(spec) {
                    self.apply(event, to: spec.id)
                }
            } catch let failure as DownloadFailure {
                if failure == .cancelled {
                    jobs[spec.id]?.phase = .cancelled
                } else {
                    jobs[spec.id]?.phase = .failed(failure.localizedDescription)
                }
            } catch {
                jobs[spec.id]?.phase = .failed(error.localizedDescription)
            }
            tasks[spec.id] = nil
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    private func apply(_ event: DownloadEvent, to id: String) {
        guard var job = jobs[id] else { return }
        switch event {
        case .probing:
            job.phase = .probing
        case .planned(let total, _, let segmented):
            job.phase = .running
            job.total = total
            job.segmented = segmented
        case .progress(let downloaded, let total, let active):
            job.phase = .running
            job.downloaded = downloaded
            if total > 0 {
                job.total = total
            }
            job.activeSegments = active
        case .verifying:
            job.phase = .verifying
        case .finished(let destination, let downloaded):
            job.phase = .finished(destination)
            job.downloaded = downloaded
            if job.total <= 0 {
                job.total = downloaded
            }
        }
        jobs[id] = job
    }
}
