import SwiftUI

struct ContentView: View {
    @EnvironmentObject var project: ProjectModel

    var body: some View {
        TabView {
            PickView()
                .tabItem { Label("Live Photos", systemImage: "livephoto") }
            LoopsView()
                .tabItem { Label("Loops", systemImage: "arrow.triangle.2.circlepath") }
                .badge(project.clips.count)
            ReelView()
                .tabItem { Label("Reel", systemImage: "film.stack") }
        }
        .overlay(alignment: .bottom) {
            if project.isBusy { BusyBar().padding(.bottom, 60) }
        }
        .animation(.default, value: project.isBusy)
    }
}

/// Progress for long jobs, with a stop button.
struct BusyBar: View {
    @EnvironmentObject var project: ProjectModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.busyTitle).font(.subheadline.weight(.semibold))
                ProgressView(value: project.busyProgress)
            }
            Button("Stop") { project.cancelBusy() }.buttonStyle(.bordered)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .shadow(radius: 8, y: 4)
    }
}

/// A row of pills; one is selected.
struct Chips<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { option in
                    Button(option.1) { selection = option.0 }
                        .buttonStyle(ChipStyle(selected: selection == option.0))
                }
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor : Color(.separator), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    func messageBanner(_ text: Binding<String?>) -> some View {
        overlay(alignment: .top) {
            if let msg = text.wrappedValue {
                Text(msg)
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .onTapGesture { text.wrappedValue = nil }
                    .task { try? await Task.sleep(nanoseconds: 4_000_000_000); if text.wrappedValue == msg { text.wrappedValue = nil } }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
