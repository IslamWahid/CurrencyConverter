import PhotosUI
import SwiftUI

struct PhotoCastView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: [PhotosPickerItem] = []
    @State private var photos: [PreparedPhoto] = []
    @State private var index = 0
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 16) {
            DeviceStatusBar()

            if photos.isEmpty {
                EmptyMediaState(systemImage: "photo.on.rectangle.angled",
                                title: "Show your photos on the big screen",
                                message: "Pick photos, then swipe through them — your TV follows along.")
            } else {
                TabView(selection: $index) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 4)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 28) {
                    Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left.circle.fill") }
                        .disabled(index == 0)
                    Text("\(index + 1) of \(photos.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { index = min(photos.count - 1, index + 1) } label: { Image(systemName: "chevron.right.circle.fill") }
                        .disabled(index >= photos.count - 1)
                }
                .font(.largeTitle)

                Button {
                    castCurrent()
                } label: {
                    Label("Show on TV", systemImage: "tv")
                }
                .buttonStyle(.bordered)
            }

            PhotosPicker(selection: $selection, maxSelectionCount: 30, matching: .images) {
                Label(photos.isEmpty ? "Choose Photos" : "Choose Other Photos", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .overlay {
            if isLoading {
                ProgressView("Preparing photos…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { items in
            Task { await load(items) }
        }
        .onChange(of: index) { _ in castCurrent() }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        var prepared: [PreparedPhoto] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let photo = try? await Task.detached(operation: { try MediaPreparer.preparePhoto(data) }).value {
                prepared.append(photo)
            }
        }
        guard !prepared.isEmpty else {
            return model.showError("Those photos couldn't be loaded.")
        }
        photos = prepared
        index = 0
        castCurrent()
    }

    private func castCurrent() {
        guard photos.indices.contains(index) else { return }
        let photo = photos[index]
        Task { await model.cast(file: photo.url, mimeType: "image/jpeg", kind: .image, title: "Photo \(index + 1)") }
    }
}

struct VideoCastView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: PhotosPickerItem?
    @State private var video: PreparedVideo?
    @State private var isPreparing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DeviceStatusBar()

                if let video {
                    Group {
                        if let thumbnail = video.thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFit()
                        } else {
                            Image(systemName: "film").font(.system(size: 64)).frame(height: 180)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    PlaybackControls()
                        .environmentObject(model)

                    Button {
                        cast(video)
                    } label: {
                        Label("Play on TV from start", systemImage: "tv")
                    }
                    .buttonStyle(.bordered)
                } else {
                    EmptyMediaState(systemImage: "play.rectangle.fill",
                                    title: "Watch your videos on TV",
                                    message: "Pick a video from your library to play it on your TV.")
                }

                PhotosPicker(selection: $selection, matching: .videos) {
                    Label(video == nil ? "Choose Video" : "Choose Another Video", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .overlay {
            if isPreparing {
                ProgressView("Preparing video…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Videos")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                return model.showError("That video couldn't be loaded.")
            }
            let prepared = await MediaPreparer.prepareVideo(movie.url)
            video = prepared
            cast(prepared)
        } catch {
            model.showError(error.localizedDescription)
        }
    }

    private func cast(_ video: PreparedVideo) {
        Task { await model.cast(file: video.url, mimeType: video.mimeType, kind: .video, title: "Video") }
    }
}

struct WebCastView: View {
    @EnvironmentObject private var model: AppModel
    @State private var link = ""
    @State private var hasCast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceStatusBar()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Video link").font(.headline)
                    TextField("https://example.com/video.mp4", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(cast)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button {
                            if let text = UIPasteboard.general.string { link = text }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button(action: cast) {
                            Label("Cast to TV", systemImage: "tv")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(url == nil)
                    }
                    Text("Use a direct link to a video (.mp4, .m3u8), photo or audio file. "
                         + "Pages like YouTube can't be cast this way — use Screen Mirroring instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if hasCast {
                    PlaybackControls()
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Web Video")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var url: URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func cast() {
        guard let url else { return }
        hasCast = true
        Task { await model.cast(remoteURL: url) }
    }
}

struct PlaybackControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var volume: Double = 20

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 40) {
                controlButton("stop.fill", label: "Stop") { model.stopPlayback() }
                controlButton("pause.fill", label: "Pause") { model.pause() }
                controlButton("play.fill", label: "Play") { model.play() }
            }
            if model.selectedDevice?.renderingControl != nil {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...100, step: 1) { editing in
                        if !editing { model.setVolume(Int(volume)) }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func controlButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.15), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct EmptyMediaState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}
