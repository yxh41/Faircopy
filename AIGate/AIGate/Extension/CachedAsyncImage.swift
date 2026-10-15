//
//  CachedAsyncImage.swift
//  guTravel
//
//  Created by GonzaloMR on 26/8/24.
//

import SwiftUI

/// CachedAsyncImage creates a SwiftUI view that loads, caches and displays an image asynchronously, using AsyncImagePhase to split the view to be displayed depending on the state of the image.
/// Switching also between the different views in an animated way.
///
/// Using a custom cache to occupy as much memory as we need and avoiding the errors that URLCache.shared can give.
///
///
/// Way to use it:
///
/// CachedAsyncImage(url: imageUrl) { phase in
///     switch phase {
///     case .empty:
///         ProgressView()
///     case .success(let image):
///         image.resizable()
///             .scaledToFill()
///     case .failure:
///         Image(.error)
///     @unknown default:
///         Image(.error)
///     }
/// }

struct CachedAsyncImage<Content: View>: View {
    @StateObject private var loader: ImageLoader

    private let content: (AsyncImagePhase) -> Content

    init(url: URL?, scale _: CGFloat = 1, animation _: Animation = .default, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.content = content
        _loader = StateObject(wrappedValue: ImageLoader(url: url))
    }

    var body: some View {
        content(loader.phase)
            .onAppear {
                Task {
                    await loader.load()
                }
            }
    }
}

private class ImageLoader: ObservableObject {
    @Published var phase: AsyncImagePhase = .empty

    private let scale: CGFloat
    private let animation: Animation

    private let url: URL?

    /// The default URLCache.shared has a very limited capacity, which prevents us from storing many images, so we use a custom URLCache that will not only work better, but will also be used only for caching images and will give us extra control over how much ram and disk memory we want our app to occupy.
    /// Also URLCache.shared may not be configured to cache content on disk, limiting its effectiveness to memory only.
    private static let cache: URLCache = {
        let memoryCapacity = 100 * 1024 * 1024 // 100 MB
        let diskCapacity = 500 * 1024 * 1024 // 500 MB
        return URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: "imagesCache")
    }()

    init(url: URL?, scale: CGFloat = 1, animation: Animation = .default) {
        self.scale = scale
        self.animation = animation
        self.url = url
    }

    @MainActor
    func load() async {
        phase = .empty

        guard let url else {
            withAnimation(animation) {
                phase = .failure(URLError(.badURL))
            }
            return
        }

        /// Check if the image is in cache
        if let cachedResponse = ImageLoader.cache.cachedResponse(for: URLRequest(url: url)),
           let cachedImage = UIImage(data: cachedResponse.data, scale: scale)
        {
            withAnimation(animation) {
                phase = .success(Image(uiImage: cachedImage))
            }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            if let image = UIImage(data: data, scale: scale) {
                let cachedData = CachedURLResponse(response: response, data: data)

                /// Cache the response
                ImageLoader.cache.storeCachedResponse(cachedData, for: URLRequest(url: url))

                withAnimation(animation) {
                    phase = .success(Image(uiImage: image))
                }
            } else {
                throw URLError(.cannotDecodeContentData)
            }

        } catch {
            withAnimation(animation) {
                phase = .failure(error)
            }
        }
    }
}
