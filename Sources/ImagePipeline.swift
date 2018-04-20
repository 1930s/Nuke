// The MIT License (MIT)
//
// Copyright (c) 2015-2018 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - ImageTask

/// - important: Make sure that you access Task properties only from the
/// delegate queue.
public /* final */ class ImageTask: Hashable {
    public let taskId: Int
    public private(set) var request: ImageRequest

    public fileprivate(set) var completedUnitCount: Int64 = 0
    public fileprivate(set) var totalUnitCount: Int64 = 0

    public var completion: Completion?
    public var progressHandler: ProgressHandler?
    public var progressiveImageHandler: ProgressiveImageHandler?

    public typealias Completion = (_ result: Result<Image>) -> Void
    public typealias ProgressHandler = (_ completed: Int64, _ total: Int64) -> Void
    public typealias ProgressiveImageHandler = (_ image: Image) -> Void

    public fileprivate(set) var metrics: Metrics

    fileprivate weak private(set) var pipeline: ImagePipeline?
    fileprivate weak var session: ImagePipeline.Session?
    fileprivate var isCancelled = false

    public init(taskId: Int, request: ImageRequest, pipeline: ImagePipeline) {
        self.taskId = taskId
        self.request = request
        self.pipeline = pipeline
        self.metrics = Metrics(taskId: taskId, timeStarted: _now())
    }

    public func cancel() {
        pipeline?._imageTaskCancelled(self)
    }

    public func setPriority(_ priority: ImageRequest.Priority) {
        request.priority = priority
        pipeline?._imageTask(self, didUpdatePriority: priority)
    }

    public static func ==(lhs: ImageTask, rhs: ImageTask) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}

// MARK: - ImagePipeline

/// `ImagePipeline` implements an image loading pipeline. It loads image data using
/// data loader (`DataLoading`), then creates an image using `DataDecoding`
/// object, and transforms the image using processors (`Processing`) provided
/// in the `Request`.
///
/// Pipeline combines the requests with the same `loadKey` into a single request.
/// The request only gets cancelled when all the registered handlers are.
///
/// `ImagePipeline` limits the number of concurrent requests (the default maximum limit
/// is 5). It also rate limits the requests to prevent `Loader` from trashing
/// underlying systems (e.g. `URLSession`). The rate limiter only comes into play
/// when the requests are started and cancelled at a high rate (e.g. fast
/// scrolling through a collection view).
///
/// `ImagePipeline` features can be configured using `Loader.Options`.
///
/// `ImagePipeline` is thread-safe.
public /* final */ class ImagePipeline {
    public let configuration: Configuration

    // This is a queue on which we access the sessions.
    private let queue = DispatchQueue(label: "com.github.kean.Nuke.ImagePipeline")

    // On this queue we access data buffers and perform decoding.
    private let dataQueue = DispatchQueue(label: "com.github.kean.Nuke.ImagePipeline.DecodingQueue")

    // Image loading sessions. One or more tasks can be handled by the same session.
    private var sessions = [AnyHashable: Session]()

    private var nextTaskId: Int32 = 0
    private var nextSessionId: Int32 = 0

    private let rateLimiter: RateLimiter

    /// Shared between multiple pipelines. In the future version we might feature
    /// more customization options.
    private static var resumableDataCache = _Cache<String, ResumableData>(costLimit: 32 * 1024 * 1024, countLimit: 100)

    /// Shared image pipeline.
    public static var shared = ImagePipeline()

    public struct Configuration {
        /// Data loader using by the pipeline.
        public var dataLoader: DataLoading

        public var dataLoadingQueue = OperationQueue()

        /// Default implementation uses shared `ImageDecoderRegistry` to create
        /// a decoder that matches the context.
        public var imageDecoder: (ImageDecodingContext) -> ImageDecoding = {
            return ImageDecoderRegistry.shared.decoder(for: $0)
        }

        /// Image cache used by the pipeline.
        public var imageCache: ImageCaching?

        /// Returns a processor for the context. By default simply returns
        /// `request.processor`. Please keep in mind that you can override the
        /// processor from the request using this option but you're not going
        /// to override the processor used as a cache key.
        public var imageProcessor: (ImageProcessingContext) -> AnyImageProcessor? = {
            return $0.request.processor
        }

        public var imageProcessingQueue = OperationQueue()

        /// `true` by default. If `true` loader combines the requests with the
        /// same `loadKey` into a single request. The request only gets cancelled
        /// when all the registered requests are.
        public var isDeduplicationEnabled = true

        /// `true` by default. It `true` loader rate limits the requests to
        /// prevent `Loader` from trashing underlying systems (e.g. `URLSession`).
        /// The rate limiter only comes into play when the requests are started
        /// and cancelled at a high rate (e.g. scrolling through a collection view).
        public var isRateLimiterEnabled = true

        /// `false` by default.
        public var isProgressiveDecodingEnabled = false

        /// `true` by default.
        public var isResumableDataEnabled = true

        /// Creates default configuration.
        /// - parameter dataLoader: `DataLoader()` by default.
        /// - parameter imageCache: `Cache.shared` by default.
        /// - parameter options: Options which can be used to customize loader.
        public init(dataLoader: DataLoading = DataLoader(), imageCache: ImageCaching? = ImageCache.shared) {
            self.dataLoader = dataLoader
            self.imageCache = imageCache

            self.dataLoadingQueue.maxConcurrentOperationCount = 6
            self.imageProcessingQueue.maxConcurrentOperationCount = 2
        }
    }

    /// Initializes `Loader` instance with the given loader, decoder.
    /// - parameter configuration: `Configuration()` by default.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.rateLimiter = RateLimiter(queue: queue)
    }

    public convenience init(_ configure: (inout ImagePipeline.Configuration) -> Void) {
        var configuration = ImagePipeline.Configuration()
        configure(&configuration)
        self.init(configuration: configuration)
    }

    // MARK: Loading Images

    /// Loads an image with the given url.
    @discardableResult public func loadImage(with url: URL, completion: @escaping ImageTask.Completion) -> ImageTask {
        return loadImage(with: ImageRequest(url: url), completion: completion)
    }

    /// Loads an image for the given request using image loading pipeline.
    @discardableResult public func loadImage(with request: ImageRequest, completion: @escaping ImageTask.Completion) -> ImageTask {
        let task = ImageTask(taskId: Int(OSAtomicIncrement32(&nextTaskId)), request: request, pipeline: self)
        task.completion = completion
        queue.async {
            guard !task.isCancelled else { return } // Fast preflight check
            self._startLoadingImage(for: task)
        }
        return task
    }

    private func _startLoadingImage(for task: ImageTask) {
        if let image = _cachedImage(for: task.request) {
            task.metrics.isMemoryCacheHit = true
            DispatchQueue.main.async {
                task.completion?(.success(image))
            }
            return
        }

        let session = _createSession(with: task.request)
        task.session = session

        task.metrics.session = session.metrics
        task.metrics.wasSubscibedToExistingTask = !session.tasks.isEmpty

        // Register handler with a session.
        session.tasks.insert(task)

        // Update data operation priority (in case it was already started).
        session.dataOperation?.queuePriority = session.priority.queuePriority
    }

    fileprivate func _imageTask(_ task: ImageTask, didUpdatePriority: ImageRequest.Priority) {
        queue.async {
            guard let session = task.session else { return }
            session.dataOperation?.queuePriority = session.priority.queuePriority
        }
    }

    // Cancel the session in case all handlers were removed.
    fileprivate func _imageTaskCancelled(_ task: ImageTask) {
        queue.async {
            guard !task.isCancelled else { return }
            task.isCancelled = true

            task.metrics.wasCancelled = true
            task.metrics.timeCompleted = _now()

            guard let session = task.session else { return } // executing == true
            session.tasks.remove(task)
            // Cancel the session when there are no remaining tasks.
            if session.tasks.isEmpty {
                self._tryToSaveResumableData(for: session)
                self._removeSession(session)
                session.cts.cancel()
            }
        }
    }

    // MARK: Managing Sessions

    private func _createSession(with request: ImageRequest) -> Session {
        // Check if session for the given key already exists.
        //
        // This part is more clever than I would like. The reason why we need a
        // key even when deduplication is disabled is to have a way to retain
        // a session by storing it in `sessions` dictionary.
        let key = configuration.isDeduplicationEnabled ? request.loadKey : UUID()
        if let session = sessions[key] {
            return session
        }
        let session = Session(sessionId: Int(OSAtomicIncrement32(&nextSessionId)), request: request, key: key)
        sessions[key] = session
        _loadImage(for: session) // Start the pipeline
        return session
    }

    private func _removeSession(_ session: Session) {
        // Check in case we already started a new session for the same loading key.
        if sessions[session.key] === session {
            // By removing a session we get rid of all the stuff that is no longer
            // needed after completing associated tasks. This includes completion
            // and progress closures, individual requests, etc. The user may still
            // hold a reference to `ImageTask` at this point, but it doesn't
            // store almost anythng.
            sessions[session.key] = nil
        }
    }

    // MARK: Image Pipeline
    //
    // This is where the images actually get loaded.

    private func _loadImage(for session: Session) {
        // Use rate limiter to prevent trashing of the underlying systems
        if configuration.isRateLimiterEnabled {
            // Rate limiter is synchronized on pipeline's queue. Delayed work is
            // executed asynchronously also on this same queue.
            rateLimiter.execute(token: session.cts.token) { [weak self, weak session] in
                guard let session = session else { return }
                self?._loadData(for: session)
            }
        } else { // Start loading immediately.
            _loadData(for: session)
        }
    }

    private func _loadData(for session: Session) {
        let token = session.cts.token
        guard !token.isCancelling else { return } // Preflight check

        // Wrap data request in an operation to limit maximum number of
        // concurrent data tasks.
        let operation = Operation(starter: { [weak self, weak session] finish in
            guard let session = session else { finish(); return }
            self?._actuallyLoadData(for: session, finish: finish)
        })

        operation.queuePriority = session.priority.queuePriority
        self.configuration.dataLoadingQueue.addOperation(operation)
        token.register { [weak operation] in operation?.cancel() }

        // FIXME: This is not an accurate metric
        session.metrics.timeDataLoadingStarted = _now()
        session.dataOperation = operation
    }

    // This methods gets called inside data loading operation (Operation).
    private func _actuallyLoadData(for session: Session, finish: @escaping () -> Void) {
        var urlRequest = session.request.urlRequest

        // Read and remove resumable data from cache (we're going to insert it
        // back in cache if the request fails again).
        if configuration.isResumableDataEnabled,
            let url = urlRequest.url?.absoluteString,
            let resumableData = ImagePipeline.resumableDataCache.removeValue(forKey: url) {
            // Update headers to add "Range" and "If-Range" headers
            resumableData.resume(request: &urlRequest)
            // Save resumable data so that when we receive the first response
            // we can use it (in case resumable data wasn't stale).
            session.resumableData = resumableData
        }

        let task = configuration.dataLoader.loadData(
            with: urlRequest,
            didReceiveData: { [weak self, weak session] (data, response) in
                self?.queue.async {
                    guard let session = session else { return }
                    self?._session(session, didReceiveData: data, response: response)
                }
            },
            completion: { [weak self, weak session] (error) in
                finish() // Important! Mark Operation as finished.
                self?.queue.async {
                    guard let session = session else { return }
                    self?._session(session, didFinishLoadingDataWithError: error)
                }
        })
        session.cts.token.register {
            task.cancel()
            finish() // Make sure we always finish the operation.
        }
    }

    private func _session(_ session: Session, didReceiveData data: Data, response: URLResponse) {
        // This is the first response that we've received.
        if session.urlResponse == nil, let resumableData = session.resumableData {
            if ResumableData.isResumedResponse(response) {
                session.data = resumableData.data
                session.downloadedDataCount = resumableData.data.count
            }
            session.resumableData = nil // Get rid of resumable data anyway
        }

        let downloadedDataCount = session.downloadedDataCount + data.count
        session.downloadedDataCount = downloadedDataCount
        session.urlResponse = response

        // Save boring metrics
        session.metrics.downloadedDataCount = downloadedDataCount
        session.metrics.urlResponse = response

        // Update tasks' progress and call progress closures if any
        let (completed, total) = (Int64(downloadedDataCount), response.expectedContentLength)
        let tasks = session.tasks
        DispatchQueue.main.async {
            for task in tasks { // We access tasks only on main thread
                (task.completedUnitCount, task.totalUnitCount) = (completed, total)
                task.progressHandler?(completed, total)
            }
        }

        let isProgerssive = configuration.isProgressiveDecodingEnabled

        // Create a decoding session (if none) which consists of a data buffer
        // and an image decoder. We access both exclusively on `decodingQueue`.
        if session.decoder == nil {
            let context = ImageDecodingContext(request: session.request, urlResponse: response, data: data)
            session.decoder = configuration.imageDecoder(context)
        }
        let decoder = session.decoder!

        dataQueue.async { [weak self, weak session] in
            guard let session = session else { return }

            // Append data (we always do it)
            session.data.append(data)

            // Check if progressive decoding is enabled (disabled by default)
            guard isProgerssive else { return }

            // Check if we haven't loaded an entire image yet. We give decoder
            // an opportunity to decide whether to decode this chunk or not.
            // In case `expectedContentLength` is undetermined (e.g. 0) we
            // don't allow progressive decoding.
            guard data.count < response.expectedContentLength else { return }

            // Produce partial image
            guard let image = decoder.decode(data: session.data, isFinal: false) else { return }
            let scanNumber: Int? = (decoder as? ImageDecoder)?.numberOfScans // Need a public way to implement this.
            self?.queue.async {
                self?._session(session, didDecodePartialImage: image, scanNumber: scanNumber)
            }
        }
    }

    private func _session(_ session: Session, didFinishLoadingDataWithError error: Swift.Error?) {
        session.metrics.timeDataLoadingFinished = _now()

        guard error == nil else {
            _tryToSaveResumableData(for: session)
            _session(session, completedWith: .failure(error ?? Error.decodingFailed))
            return
        }

        // A few checks, which we should never encounter those cases in practice
        guard session.downloadedDataCount > 0, let decoder = session.decoder else {
            _session(session, completedWith: .failure(error ?? Error.decodingFailed))
            return
        }

        dataQueue.async { [weak self, weak session] in
            guard let session = session else { return }
            // Produce final image
            let image = autoreleasepool {
                decoder.decode(data: session.data, isFinal: true)
            }
            session.data.removeAll() // We no longer need the data.
            self?.queue.async {
                self?._session(session, didDecodeImage: image)
            }
        }
    }

    private func _tryToSaveResumableData(for session: Session) {
        // Try to save resumable data in case the task was cancelled
        // (`URLError.cancelled`) or failed to complete with other error.
        if configuration.isResumableDataEnabled,
            let response = session.urlResponse,
            session.downloadedDataCount > 0, // Just in case
            let url = session.request.urlRequest.url {
            dataQueue.async { // We can only access data buffer on this queue
                if let resumableData = ResumableData(response: response, data: session.data) {
                    ImagePipeline.resumableDataCache.set(resumableData, forKey: url.absoluteString, cost: session.data.count)
                }
            }
        }
    }

    private func _session(_ session: Session, didDecodePartialImage image: Image, scanNumber: Int?) {
        // Producing faster than able to consume, skip this partial.
        // As an alternative we could store partial in a buffer for later, but
        // this is an option which is simpler to implement.
        guard session.processingPartialOperation == nil else { return }

        let context = ImageProcessingContext(image: image, request: session.request, isFinal: false, scanNumber: scanNumber)
        guard let processor = configuration.imageProcessor(context) else {
            _session(session, didProducePartialImage: image)
            return
        }

        let operation = BlockOperation { [weak self, weak session] in
            guard let session = session else { return }
            let image = autoreleasepool { processor.process(image) }
            self?.queue.async {
                session.processingPartialOperation = nil
                if let image = image {
                    self?._session(session, didProducePartialImage: image)
                }
            }
        }
        session.processingPartialOperation = operation
        configuration.imageProcessingQueue.addOperation(operation)
    }

    private func _session(_ session: Session, didDecodeImage image: Image?) {
        session.decoder = nil // Decoding session completed, no longer need decoder.
        session.metrics.timeDecodingFinished = _now()

        guard let image = image else {
            _session(session, completedWith: .failure(Error.decodingFailed))
            return
        }

        // Check if processing is required, complete immediatelly if not.
        let context = ImageProcessingContext(image: image, request: session.request, isFinal: true, scanNumber: nil)
        guard let processor = configuration.imageProcessor(context) else {
            _session(session, completedWith: .success(image))
            return
        }

        let operation = BlockOperation { [weak self, weak session] in
            guard let session = session else { return }
            let image = autoreleasepool { processor.process(image) }
            let result = image.map(Result.success) ?? .failure(Error.processingFailed)
            self?.queue.async {
                session.metrics.timeProcessingFinished = _now()
                self?._session(session, completedWith: result)
            }
        }
        session.cts.token.register { [weak operation] in operation?.cancel() }
        configuration.imageProcessingQueue.addOperation(operation)
    }

    private func _session(_ session: Session, didProducePartialImage image: Image) {
        // Check if we haven't completed the session yet by producing a final image.
        guard !session.isCompleted else { return }
        let tasks = session.tasks
        DispatchQueue.main.async {
            for task in tasks {
                task.progressiveImageHandler?(image)
            }
        }
    }

    private func _session(_ session: Session, completedWith result: Result<Image>) {
        if let image = result.value {
            _store(image: image, for: session.request)
        }
        session.isCompleted = true

        // Cancel any outstanding parital processing.
        session.processingPartialOperation?.cancel()

        let tasks = session.tasks
        tasks.forEach { $0.metrics.timeCompleted = _now() }
        DispatchQueue.main.async {
            for task in tasks {
                task.completion?(result)
            }
        }
        _removeSession(session)
    }

    // MARK: Memory Cache Helpers

    private func _cachedImage(for request: ImageRequest) -> Image? {
        guard request.memoryCacheOptions.readAllowed else { return nil }
        return configuration.imageCache?[request]
    }

    private func _store(image: Image, for request: ImageRequest) {
        guard request.memoryCacheOptions.writeAllowed else { return }
        configuration.imageCache?[request] = image
    }

    // MARK: Session

    /// A image loading session. During a lifetime of a session handlers can
    /// subscribe to and unsubscribe from it.
    fileprivate final class Session {
        let sessionId: Int
        var isCompleted: Bool = false // there is probably a way to remote this

        /// The original request with which the session was created.
        let request: ImageRequest
        let key: AnyHashable // loading key
        let cts = _CancellationTokenSource()

        // Registered image tasks.
        var tasks = Set<ImageTask>()

        // Data loading session.
        weak var dataOperation: Foundation.Operation?
        var downloadedDataCount: Int = 0
        var urlResponse: URLResponse?
        var resumableData: ResumableData?
        lazy var data = Data() // Can only be access to dataQueue!

        // Decoding session.
        var decoder: ImageDecoding?

        // Progressive decoding.
        var processingPartialOperation: Foundation.Operation?

        // Metrics that we collect during the lifetime of a session.
        let metrics: ImageTask.Metrics.SessionMetrics

        init(sessionId: Int, request: ImageRequest, key: AnyHashable) {
            self.sessionId = sessionId
            self.request = request
            self.key = key
            self.metrics = ImageTask.Metrics.SessionMetrics(sessionId: sessionId)
        }

        var priority: ImageRequest.Priority {
            return tasks.map { $0.request.priority }.max() ?? .normal
        }
    }

    // MARK: Errors

    /// Error returns by `Loader` class itself. `Loader` might also return
    /// errors from underlying `DataLoading` object.
    public enum Error: Swift.Error, CustomDebugStringConvertible {
        case decodingFailed
        case processingFailed

        public var debugDescription: String {
            switch self {
            case .decodingFailed: return "Failed to create an image from the image data"
            case .processingFailed: return "Failed to process the image"
            }
        }
    }
}

// MARK - Metrics

extension ImageTask {
    public struct Metrics {

        // Timings

        public let taskId: Int
        public let timeStarted: TimeInterval
        public fileprivate(set) var timeCompleted: TimeInterval? // failed or completed

        // Download session metrics. One more more tasks can share the same
        // session metrics.
        public final class SessionMetrics {
            /// - important: Data loading might start prior to `timeResumed` if the task gets
            /// coalesced with another task.
            public let sessionId: Int
            public fileprivate(set) var timeDataLoadingStarted: TimeInterval?
            public fileprivate(set) var timeDataLoadingFinished: TimeInterval?
            public fileprivate(set) var timeDecodingFinished: TimeInterval?
            public fileprivate(set) var timeProcessingFinished: TimeInterval?
            public fileprivate(set) var urlResponse: URLResponse?
            public fileprivate(set) var downloadedDataCount: Int?

            init(sessionId: Int) { self.sessionId = sessionId }
        }

        public fileprivate(set) var session: SessionMetrics?

        public var totalDuration: TimeInterval? {
            guard let timeCompleted = timeCompleted else { return nil }
            return timeCompleted - timeStarted
        }

        init(taskId: Int, timeStarted: TimeInterval) {
            self.taskId = taskId; self.timeStarted = timeStarted
        }

        // Properties

        /// Returns `true` is the task wasn't the one that initiated image loading.
        public fileprivate(set) var wasSubscibedToExistingTask: Bool = false
        public fileprivate(set) var isMemoryCacheHit: Bool = false
        public fileprivate(set) var wasCancelled: Bool = false
    }
}

// MARK: - Contexts

/// Image decoding context used when selecting which decoder to use.
public struct ImageDecodingContext {
    public let request: ImageRequest
    public let urlResponse: URLResponse
    public let data: Data
}

/// Image processing context used when selecting which processor to use.
public struct ImageProcessingContext {
    public let image: Image
    public let request: ImageRequest
    public let isFinal: Bool
    public let scanNumber: Int? // need a more general purpose way to implement this
}
