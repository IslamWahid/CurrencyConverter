import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DeviceStatusBar()

                    NavigationLink {
                        MirrorView()
                    } label: {
                        MirrorHero(isMirroring: model.isMirroring)
                    }
                    .buttonStyle(.plain)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 16) {
                        NavigationLink { PhotoCastView() } label: {
                            FeatureTile(title: "Photos", subtitle: "Show pictures on TV",
                                        systemImage: "photo.on.rectangle.angled", colors: [.orange, .pink])
                        }
                        NavigationLink { VideoCastView() } label: {
                            FeatureTile(title: "Videos", subtitle: "Play your videos",
                                        systemImage: "play.rectangle.fill", colors: [.purple, .indigo])
                        }
                        NavigationLink { WebCastView() } label: {
                            FeatureTile(title: "Web Video", subtitle: "Cast a video link",
                                        systemImage: "globe", colors: [.teal, .blue])
                        }
                        NavigationLink { HelpView() } label: {
                            FeatureTile(title: "Help", subtitle: "Setup & tips",
                                        systemImage: "questionmark.circle.fill", colors: [.green, .mint])
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Screen Mirror")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .overlay(alignment: .top) { BannerView() }
    }
}

private struct MirrorHero: View {
    let isMirroring: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Screen Mirroring")
                    .font(.title2.bold())
                Text(isMirroring ? "Your screen is live" : "Show your whole iPhone screen on your TV")
                    .font(.subheadline)
                    .opacity(0.9)
                Label(isMirroring ? "Mirroring" : "Start", systemImage: isMirroring ? "dot.radiowaves.left.and.right" : "play.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.25), in: Capsule())
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct FeatureTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Transient status / error message shown at the top of the screen.
struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let banner = model.banner {
            Label(banner.message, systemImage: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(banner.isError ? Color.red : Color.green, in: Capsule())
                .shadow(radius: 8, y: 4)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.banner = nil }
                .task(id: banner.id) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if model.banner?.id == banner.id {
                        withAnimation { model.banner = nil }
                    }
                }
        }
    }
}
