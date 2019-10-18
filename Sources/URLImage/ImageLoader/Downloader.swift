//
//  Downloader.swift
//  
//
//  Created by Dmytro Anokhin on 19/09/2019.
//

import Foundation
import CoreGraphics


class Downloader {

    let url: URL

    let task: URLSessionTask

    let remoteFileCache: RemoteFileCacheService

    let imageProcessingService: ImageProcessingService

    init(url: URL, task: URLSessionTask, remoteFileCache: RemoteFileCacheService, imageProcessingService: ImageProcessingService) {
        self.url = url
        self.task = task
        self.remoteFileCache = remoteFileCache
        self.imageProcessingService = imageProcessingService
    }

    var completionCallback: (() -> Void)?

    var expiryDate: Date? = nil

    func resume(after delay: Double) {
        assert(!handlers.isEmpty, "Starting to load the image at \(url) but no handlers created")

        guard transition(to: .scheduled) else {
            return
        }

        remoteFileCache.getFile(withRemoteURL: url) { localURL in

            if let localURL = localURL {
                if let image = createCGImage(fileURL: localURL) {
                    guard self.transition(to: .finishing) else {
                        return
                    }

                    self.notifyObserversAboutCompletion(image)

                    guard self.transition(to: .finished) else {
                        return
                    }

                    self.completionCallback?()

                    return
                }
                else {
                    // Not able to load image from file. This is inconsistent state: URL is still registered in the local cache but the file was removed or corrupted. Remove file from the cache and redownload.
                    try? self.remoteFileCache.delete(fileName: localURL.lastPathComponent)
                }

//                if let imageWrapper = ImageWrapper(fileURL: localURL) { // Loaded from disk
//
//
//                    guard self.transition(to: .finished) else {
//                        return
//                    }
//
//                    self.notifyObserversAboutCompletion(imageWrapper)
//                    self.completionCallback?()
//
//                    return
//                }
//                else {
//                    // URL is still registered in the local cache but the file was removed
//                    try? self.remoteFileCache.delete(fileName: localURL.lastPathComponent)
//                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                // Load from network
                guard self.transition(to: .loading) else {
                    return
                }

                self.task.resume()
            }
        }
    }

    func cancel() {
        assert(handlers.isEmpty, "Cancelling loading the image at \(url) while some handlers are still attached")

        guard transition(to: .cancelling) else {
            return
        }

        task.cancel()
    }

    private(set) var handlers = Set<ImageLoadHandler>()

    func addHandler(_ handler: ImageLoadHandler) {
        handlers.insert(handler)
    }

    func removeHandler(_ handler: ImageLoadHandler) {
        handlers.remove(handler)
    }

    func complete(with error: Error?) {
        switch error {
            case .none:
                transition(to: .finished)
                completionCallback?()

            case .some(let nsError as NSError):
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    if transition(to: .cancelled) {
                        completionCallback?()
                    }
                }
                else {
                    if transition(to: .failed) {
                        completionCallback?()
                    }
                }
        }
    }

    // MARK: Private

    private var state: LoadingState = .initial

    @discardableResult
    fileprivate func transition(to newState: LoadingState) -> Bool {
        guard state.canTransition(to: newState) else {
            // print("Can not transition from \(state) to \(newState)")
            return false
        }

        state = newState
        return true
    }

    fileprivate func notifyObserversAboutProgress(_ progress: Float?) {
        for handler in handlers {
            handler.observer.progress(progress)
        }
    }

    fileprivate func notifyObserversAboutPartial(_ imageProxy: ImageProxy) {
        for handler in handlers {
            handler.observer.partial(imageProxy)
        }
    }

    fileprivate func notifyObserversAboutCompletion(_ imageProxy: ImageProxy) {
        for handler in handlers {
            handler.observer.completion(imageProxy)
        }
    }

    fileprivate func notifyObserversAboutCompletion(_ image: CGImage) {
        for handler in handlers {
            if let processor = handler.processor {
                imageProcessingService.processImage(image, usingProcessor: processor) { resultImage in
                    let imageProxy: ImageProxy = ImageWrapper(cgImage: resultImage)
                    handler.observer.completion(imageProxy)
                }
            }
            else {
                let imageProxy: ImageProxy = ImageWrapper(cgImage: image)
                handler.observer.completion(imageProxy)
            }
        }
    }
}


final class FileDownloader: Downloader {

    func finishDownloading(with tmpURL: URL) {
        guard transition(to: .finishing) else {
            return
        }

        guard let localURL = try? remoteFileCache.addFile(withRemoteURL: url, sourceURL: tmpURL, expiryDate: expiryDate) else {
            // Failed to cache the file
            transition(to: .failed)
            return
        }

        guard let imageWrapper = ImageWrapper(fileURL: localURL) else {
            // Failed to read the file
            // Remove the file from the cache
            try? remoteFileCache.delete(fileName: localURL.lastPathComponent)
            transition(to: .failed)
            return
        }

        DispatchQueue.main.async {
            self.notifyObserversAboutCompletion(imageWrapper)
        }
    }

    func progress(_ progress: Float?) {
        DispatchQueue.main.async {
            self.notifyObserversAboutProgress(progress)
        }
    }
}


final class DataDownloader: Downloader {

    private var imageWrapper = IncrementalImageWrapper()

    func append(data: Data) {
        imageWrapper.append(data)
        
        DispatchQueue.main.async {
            self.notifyObserversAboutPartial(self.imageWrapper)
        }
    }

    func finishDownloading() {
        guard transition(to: .finishing) else {
            return
        }

        imageWrapper.isFinal = true

        guard !imageWrapper.isEmpty else {
            transition(to: .failed)
            return
        }

        guard let _ = try? remoteFileCache.createFile(withRemoteURL: url, data: imageWrapper.data, expiryDate: expiryDate) else {
            // Failed to cache the file
            transition(to: .failed)
            return
        }

        DispatchQueue.main.async {
            self.notifyObserversAboutCompletion(self.imageWrapper)
        }
    }
}
