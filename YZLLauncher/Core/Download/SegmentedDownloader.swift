import Foundation

private typealias DownloadContinuation = AsyncThrowingStream<DownloadEvent, Error>.Continuation

enum Backoff {
    static func nanoseconds(forAttempt attempt: Int) -> UInt64 {
        UInt64(max(1, attempt) * 250_000_000)
    }
}

private final class ProgressCounter {
    private let lock = NSLock()
    private var downloaded: Int64

    init(initial: Int64) {
        downloaded = initial
    }

    func add(_ delta: Int64) {
        lock.lock()
        downloaded += delta
        lock.unlock()
    }

    func value() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return downloaded
    }
}

/// YZL 分片下载器：HEAD 探测 Range → 分片并发 + 断点续传 + 超时重试 + 慢片拆半；
/// 服务器不认 Range 时自动回退单连接。完成前合并分片并做 SHA-1 校验。
final class SegmentedDownloader {
    static let maxAttemptsPerSegment = 3

    private let session: URLSession
    private let stateStore: ResumeStateStore

    init(session: URLSession? = nil, stateStore: ResumeStateStore = ResumeStateStore()) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 900
            config.httpAdditionalHeaders = ["User-Agent": "YZLLauncher/0.1 (iOS)"]
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        self.stateStore = stateStore
    }

    func download(_ spec: DownloadSpec) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.perform(spec: spec, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func perform(spec: DownloadSpec, continuation: DownloadContinuation) async throws {
        try FileManager.default.createDirectory(
            at: spec.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        continuation.yield(.probing)
        let probe = try await headProbe(spec.url)

        if probe.supportsRange, let total = probe.totalBytes {
            try await segmented(spec: spec, total: total, continuation: continuation)
        } else {
            try await singleConnection(spec: spec, expected: spec.expectedSize ?? probe.totalBytes, continuation: continuation)
        }
    }

    private func headProbe(_ url: URL) async throws -> ProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return ProbeResult(supportsRange: false, totalBytes: nil)
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        return RangeProbe.evaluate(
            statusCode: http.statusCode,
            acceptRanges: http.value(forHTTPHeaderField: "Accept-Ranges"),
            contentLength: length
        )
    }

    private func segmented(spec: DownloadSpec, total: Int64, continuation: DownloadContinuation) async throws {
        if let expected = spec.expectedSize, expected != total {
            throw DownloadFailure.sizeMismatch(expected: expected, actual: total)
        }

        var leaves: [DownloadSegment]
        if let state = stateStore.load(spec.id), state.spec == spec, !state.segments.isEmpty {
            leaves = state.segments
        } else {
            leaves = SegmentPlanner.plan(totalBytes: total, segmentSize: spec.segmentSize)
        }
        stateStore.save(DownloadState(spec: spec, segments: leaves, updatedAt: Date()))

        let alreadyDownloaded = SegmentPlanner.writtenBytes(segments: leaves, partSizes: partSizes(for: spec, segments: leaves))
        let counter = ProgressCounter(initial: alreadyDownloaded)

        continuation.yield(.planned(totalBytes: total, segments: leaves.count, segmented: true))
        continuation.yield(.progress(downloaded: counter.value(), total: total, active: 0))

        var pending = leaves.filter { !isSegmentComplete(spec: spec, segment: $0) }

        do {
            try await withThrowingTaskGroup(of: SegmentOutcome.self) { group in
                var running = 0

                while running < spec.maxConnections, let next = pending.first {
                    pending.removeFirst()
                    group.addTask { try await self.runSegment(next, spec: spec) }
                    running += 1
                }

                while running > 0 {
                    guard let outcome = try await group.next() else { break }
                    running -= 1

                    switch outcome {
                    case .completed(_, let wrote):
                        counter.add(wrote)
                    case .split(let original, let halves):
                        if let index = leaves.firstIndex(of: original) {
                            leaves.remove(at: index)
                        }
                        leaves.append(contentsOf: halves)
                        pending.insert(contentsOf: halves, at: 0)
                        stateStore.save(DownloadState(spec: spec, segments: leaves, updatedAt: Date()))
                    }

                    continuation.yield(.progress(downloaded: counter.value(), total: total, active: running))

                    if let next = pending.first {
                        pending.removeFirst()
                        group.addTask { try await self.runSegment(next, spec: spec) }
                        running += 1
                    }
                }
            }
        } catch DownloadFailure.rejectedRange {
            stateStore.clearParts(for: spec.id)
            try await singleConnection(spec: spec, expected: total, continuation: continuation)
            return
        }

        continuation.yield(.verifying)
        try assemble(spec: spec, leaves: leaves.sorted { $0.start < $1.start }, total: total)
        stateStore.clear(spec.id)
        continuation.yield(.finished(destination: spec.destination, downloaded: total))
    }

    private func runSegment(_ segment: DownloadSegment, spec: DownloadSpec) async throws -> SegmentOutcome {
        let part = stateStore.partURL(for: spec, segment: segment)
        var written = fileSize(at: part)

        if written >= segment.length {
            return .completed(segment: segment, wrote: 0)
        }
        if written > segment.length {
            try? FileManager.default.removeItem(at: part)
            written = 0
        }

        var attempt = 0
        while attempt < Self.maxAttemptsPerSegment {
            attempt += 1
            if Task.isCancelled {
                throw DownloadFailure.cancelled
            }

            var request = URLRequest(url: spec.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=\(segment.start + written)-\(segment.end)", forHTTPHeaderField: "Range")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw DownloadFailure.rejectedRange
                }
                if http.statusCode == 200 {
                    throw DownloadFailure.rejectedRange
                }
                guard http.statusCode == 206 else {
                    throw DownloadFailure.ioFailure("HTTP \(http.statusCode)")
                }

                let expected = segment.length - written
                guard Int64(data.count) == expected else {
                    throw DownloadFailure.sizeMismatch(expected: expected, actual: Int64(data.count))
                }

                try append(data, to: part)
                return .completed(segment: segment, wrote: Int64(data.count))
            } catch let failure as DownloadFailure {
                if failure == .rejectedRange {
                    throw failure
                }
                if attempt >= Self.maxAttemptsPerSegment {
                    if written == 0, let halves = SegmentPlanner.halves(of: segment) {
                        return .split(original: segment, halves: halves)
                    }
                    throw failure
                }
                try? await Task.sleep(nanoseconds: Backoff.nanoseconds(forAttempt: attempt))
            } catch {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw DownloadFailure.cancelled
                }
                if attempt >= Self.maxAttemptsPerSegment {
                    if written == 0, let halves = SegmentPlanner.halves(of: segment) {
                        return .split(original: segment, halves: halves)
                    }
                    throw DownloadFailure.segmentExhausted(start: segment.start, end: segment.end, attempts: attempt)
                }
                try? await Task.sleep(nanoseconds: Backoff.nanoseconds(forAttempt: attempt))
            }
        }

        throw DownloadFailure.segmentExhausted(start: segment.start, end: segment.end, attempts: Self.maxAttemptsPerSegment)
    }

    private func singleConnection(spec: DownloadSpec, expected: Int64?, continuation: DownloadContinuation) async throws {
        let total = expected ?? 0
        continuation.yield(.planned(totalBytes: total, segments: 1, segmented: false))

        let temporary = spec.destination.appendingPathExtension("single")
        let fm = FileManager.default
        if fm.fileExists(atPath: temporary.path) {
            try? fm.removeItem(at: temporary)
        }
        _ = fm.createFile(atPath: temporary.path, contents: Data())

        guard let handle = FileHandle(forWritingAtPath: temporary.path) else {
            throw DownloadFailure.ioFailure("无法创建临时文件")
        }

        var written: Int64 = 0
        var buffer = Data(capacity: 65_536)

        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: spec.url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? handle.close()
                throw DownloadFailure.ioFailure("服务器返回了无法处理的响应")
            }

            for try await byte in bytes {
                if Task.isCancelled {
                    try? handle.close()
                    throw DownloadFailure.cancelled
                }
                buffer.append(byte)
                written += 1
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    continuation.yield(.progress(downloaded: written, total: total, active: 1))
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.close()
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            try? handle.close()
            throw DownloadFailure.ioFailure(error.localizedDescription)
        }

        continuation.yield(.verifying)
        try finalize(spec: spec, temporary: temporary, expectedSize: spec.expectedSize ?? (total > 0 ? total : written))
        stateStore.clearParts(for: spec.id)
        continuation.yield(.finished(destination: spec.destination, downloaded: written))
    }

    private func assemble(spec: DownloadSpec, leaves: [DownloadSegment], total: Int64) throws {
        let fm = FileManager.default
        let temporary = spec.destination.appendingPathExtension("assembling")
        if fm.fileExists(atPath: temporary.path) {
            try? fm.removeItem(at: temporary)
        }
        try fm.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fm.createFile(atPath: temporary.path, contents: Data())

        guard let output = FileHandle(forWritingAtPath: temporary.path) else {
            throw DownloadFailure.ioFailure("无法创建合并文件")
        }

        for segment in leaves {
            let part = stateStore.partURL(for: spec, segment: segment)
            guard let data = fm.contents(atPath: part.path) else {
                try? output.close()
                throw DownloadFailure.ioFailure("缺少分片 \(segment.partName)")
            }
            guard Int64(data.count) == segment.length else {
                try? output.close()
                throw DownloadFailure.sizeMismatch(expected: segment.length, actual: Int64(data.count))
            }
            try output.write(contentsOf: data)
        }
        try output.close()

        try finalize(spec: spec, temporary: temporary, expectedSize: total)
    }

    private func finalize(spec: DownloadSpec, temporary: URL, expectedSize: Int64) throws {
        let fm = FileManager.default
        let size = fileSize(at: temporary)
        guard size == expectedSize else {
            try? fm.removeItem(at: temporary)
            throw DownloadFailure.sizeMismatch(expected: expectedSize, actual: size)
        }

        if let expected = spec.expectedSHA1 {
            guard let actual = SHA1Digest.hex(of: temporary) else {
                try? fm.removeItem(at: temporary)
                throw DownloadFailure.ioFailure("无法读取待校验文件")
            }
            guard actual.lowercased() == expected.lowercased() else {
                try? fm.removeItem(at: temporary)
                throw DownloadFailure.checksumMismatch(expected: expected, actual: actual)
            }
        }

        if fm.fileExists(atPath: spec.destination.path) {
            try fm.removeItem(at: spec.destination)
        }
        try fm.moveItem(at: temporary, to: spec.destination)
    }

    private func append(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: Data())
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw DownloadFailure.ioFailure("无法打开分片 \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw DownloadFailure.ioFailure(error.localizedDescription)
        }
    }

    private func partSizes(for spec: DownloadSpec, segments: [DownloadSegment]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for segment in segments {
            sizes[segment.partName] = fileSize(at: stateStore.partURL(for: spec, segment: segment))
        }
        return sizes
    }

    private func isSegmentComplete(spec: DownloadSpec, segment: DownloadSegment) -> Bool {
        fileSize(at: stateStore.partURL(for: spec, segment: segment)) >= segment.length
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}

enum SegmentOutcome {
    case completed(segment: DownloadSegment, wrote: Int64)
    case split(original: DownloadSegment, halves: [DownloadSegment])
}
