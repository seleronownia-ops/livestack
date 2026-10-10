import SwiftUI
import LiveStackCore

/// Step 2: the ordered loops, composition buttons, and a way into each editor.
struct LoopsView: View {
    @EnvironmentObject var project: ProjectModel

    var body: some View {
        NavigationStack {
            List {
                if project.clips.isEmpty {
                    ContentUnavailableView("No loops yet", systemImage: "arrow.triangle.2.circlepath", description: Text("Pick Live Photos in the first tab. Each becomes a loop here, cut automatically to its liveliest half second."))
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        HStack(spacing: 10) {
                            Button("Auto cut") { project.autoCutAll() }.buttonStyle(.borderedProminent)
                            Button("Shuffle") { project.shuffle() }.buttonStyle(.bordered)
                            Button("Full clips") { project.resetAll() }.buttonStyle(.bordered)
                        }
                        .disabled(project.isBusy)
                        Text("Auto cut finds the liveliest half second of each Live Photo and bounces it a few times. Shuffle rolls new cuts, pace, transitions and order. Everything stays editable.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Loops, in reel order") {
                        ForEach(project.clips) { clip in
                            NavigationLink(value: clip.id) { LoopRow(clip: clip) }
                        }
                        .onMove { project.move(from: $0, to: $1) }
                        .onDelete { set in set.map { project.clips[$0].id }.forEach { project.remove($0) } }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Loops")
            .toolbar {
                if !project.clips.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Remove all", role: .destructive) { project.removeAll() }.disabled(project.isBusy)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in LoopEditorView(clipID: id) }
            .messageBanner($project.message)
        }
    }
}

struct LoopRow: View {
    let clip: LoopClip

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb = clip.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(clip.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(String(format: "window %.1f–%.1f s", clip.spec.windowStart, clip.spec.windowStart + clip.spec.windowLength))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            if clip.loopAsset == nil { ProgressView() }
        }
    }
}
