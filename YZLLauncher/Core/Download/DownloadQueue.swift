import Foundation
import Combine

enum QueuePhase: Equatable {
    case idle
    case running
    case finished
    case cancelled
    case failed(String)
}

struct QueueState: Equatable {
    var phase: QueuePhase = .idle
    /// 这一次队列对应的版本 id；共享队列时用它区分“别的版本刚下完”的状态。
    var batchID: String?
    var totalFiles: Int = 0
    var doneFiles: Int = 0
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var activeFiles: Int = 0
    var failures: [String] = []
    var startedAt: Date?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(doneBytes) / Double(totalBytes))
    }

    var speedBytesPerSecond: Double {
        guard phase == .running, let startedAt else { return 0 }
        return Double(doneBytes) / max(Date().timeIntervalSince(startedAt), 0.5)
    }
}

private enum FileOutcome {
    case done(id: String, bytes: Int64)
    case failed(id: String, message: String)
    case cancelled(id: String)
}

private final class FileProgressAggregator {
    private let lock = NSLock()
    private var inFlight: [String: Int64] = [:]
    private var finishedBytes: Int64 = 0
    private var finishedCount: Int = 0

    func update(_ id: String, downloaded: Int64) {
        lock.lock()
        if (inFlight[id] ?? 0) < downloaded {
            inFlight[id] = downloaded
        }
        lock.unlock()
    }

    func markDone(_ id: String, bytes: Int64) {
        lock.lock()
        inFlight[id] = nil
        finishedBytes += bytes
        finishedCount += 1
        lock.unlock()
    }

    func snapshot() -> (bytes: Int64, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (finishedBytes + inFlight.values.reduce(0, +), finishedCount)
    }
}

/// 多文件安装队列：文件级并发 8，每个文件内部再走分片下载器，
/// 聚合进度只在真正下完时到 100%，失败文件单独列出。
@MainActor
final class DownloadQueue: ObservableObject {
    @Published private(set) var state = QueueState()

    private let downloader: SegmentedDownloader
    private let fileConcurrency: Int
    private var runTask: Task<Void, Never>?

    init(downloader: SegmentedDownloader = SegmentedDownloader(), fileConcurrency: Int = 8) {
        self.downloader = downloader
        self.fileConcurrency = min(max(fileConcurrency, 1), 16)
    }

    func start(_ specs: [DownloadSpec], batchID: String? = nil, completion: (() -> Void)? = nil) {
        guard state.phase != .running, runTask == nil else { return }

        var next = QueueState()
        next.phase = .running
        next.batchID = batchID
        next.totalFiles = specs.count
        next.totalBytes = specs.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }
        next.startedAt = Date()
        state = next

        let snapshot = specs
        runTask = Task {
            await self.execute(snapshot, completion: completion)
            self.runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func execute(_ specs: [DownloadSpec], completion: (() -> Void)?) async {
        // runOne 是 nonisolated，不能再跨 actor 读 self.downloader：
        // Swift 5 只警告，Swift 6 会直接报错。在 MainActor 上下文先取出再传参。
        let downloader = self.downloader
        let counter = FileProgressAggregator()
        var pending = specs
        var inflight = 0
        var failures: [String] = []
        var sawCancellation = false

        await withTaskGroup(of: FileOutcome.self) { group in
            while inflight < fileConcurrency, let first = pending.first {
                pending.removeFirst()
                group.addTask { await self.runOne(first, counter: counter, downloader: downloader) }
                inflight += 1
            }

            while inflight > 0 {
                guard let outcome = await group.next() else { break }
                inflight -= 1

                switch outcome {
                case .done(let id, let bytes):
                    counter.markDone(id, bytes: bytes)
                case .cancelled(let id):
                    sawCancellation = true
                    counter.markDone(id, bytes: 0)
                case .failed(let id, let message):
                    failures.append("\(id)：\(message)")
                    counter.markDone(id, bytes: 0)
                }

                let snapshot = counter.snapshot()
                state.doneBytes = snapshot.bytes
                state.doneFiles = snapshot.count
                state.activeFiles = inflight

                if let next = pending.first {
                    pending.removeFirst()
                    group.addTask { await self.runOne(next, counter: counter, downloader: downloader) }
                    inflight += 1
                }
            }
        }

        state.failures = failures
        state.activeFiles = 0

        if sawCancellation || Task.isCancelled {
            state.phase = .cancelled
        } else if failures.isEmpty && state.doneFiles == state.totalFiles {
            state.phase = .finished
            completion?()
        } else {
            state.phase = .failed("\(failures.count) 个文件失败")
        }
    }

    nonisolated private func runOne(_ spec: DownloadSpec,
                                    counter: FileProgressAggregator,
                                    downloader: SegmentedDownloader) async -> FileOutcome {
        let expectedBytes = spec.expectedSize ?? 0

        // 断点续传/重试时，已经完整且哈希一致的旧文件直接跳过，只补缺口。
        if let expectedSHA1 = spec.expectedSHA1,
           FileManager.default.fileExists(atPath: spec.destination.path),
           let actual = SHA1Digest.hex(of: spec.destination),
           actual.caseInsensitiveCompare(expectedSHA1) == .orderedSame {
            return .done(id: spec.id, bytes: expectedBytes)
        }

        do {
            for try await event in downloader.download(spec) {
                switch event {
                case .progress(let downloaded, _, _):
                    counter.update(spec.id, downloaded: downloaded)
                case .finished(_, let downloaded):
                    counter.update(spec.id, downloaded: downloaded)
                default:
                    break
                }
            }
            return .done(id: spec.id, bytes: expectedBytes)
        } catch let failure as DownloadFailure {
            if failure == .cancelled {
                return .cancelled(id: spec.id)
            }
            return .failed(id: spec.id, message: failure.localizedDescription)
        } catch {
            return .failed(id: spec.id, message: error.localizedDescription)
        }
    }
}
