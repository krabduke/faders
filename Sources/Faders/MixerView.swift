import SwiftUI
import ServiceManagement

struct MixerView: View {
    @ObservedObject var mixer: Mixer
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)

            Text("Apps")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if mixer.apps.isEmpty {
                Text("Apps show up here when they play sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(mixer.apps) { app in AppRow(mixer: mixer, app: app) }
                }
            }

            if let problem = mixer.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sound").font(.headline)
                Spacer(minLength: 12)
                Text(mixer.outputName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let volume = mixer.mainVolume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(volume) }, set: { mixer.setMainVolume(Float($0)) }))
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset all") { mixer.resetAll() }
                .disabled(!mixer.hasChanges)
                .help("Put every app back to 100% and unmute them")
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Faders: login item change failed: \(error)")
                }
                opensAtLogin = SMAppService.mainApp.status == .enabled
            }))
            .toggleStyle(.checkbox)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
    }
}

private struct AppRow: View {
    @ObservedObject var mixer: Mixer
    let app: AudioApp

    var body: some View {
        let muted = mixer.isMuted(app)
        let volume = mixer.volume(of: app)

        HStack(spacing: 10) {
            Button { mixer.toggleMute(app) } label: {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .opacity(muted ? 0.35 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if muted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(.red))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).lineLimit(1)
                    if app.isPlaying && !muted {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: app.tint))
                            .accessibilityLabel("Playing")
                    }
                    Spacer()
                    Text(muted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(volume) }, set: { mixer.setVolume(Float($0), for: app) }))
                    .tint(Color(nsColor: app.tint))
                    .controlSize(.small)
                    .disabled(muted)
                    .accessibilityLabel("\(app.name) volume")
            }
        }
        .contextMenu {
            Button("Reset to 100%") { mixer.setVolume(1, for: app) }
            Button(muted ? "Unmute" : "Mute") { mixer.toggleMute(app) }
        }
    }
}
