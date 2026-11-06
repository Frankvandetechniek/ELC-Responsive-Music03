import AppKit
import ELCCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started from `swift run` (no bundle): behave like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

extension AppModel {
    static let shared = AppModel()
}

@main
struct ELCResponsiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("ELC Responsive") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandMenu("Show") {
                Button(model.blackout ? "Release Blackout" : "Blackout") { model.blackout.toggle() }
                    .keyboardShortcut("b", modifiers: [.command])
                Button("Next Look") { model.nextLook() }
                    .keyboardShortcut("l", modifiers: [.command])
                Toggle("Hold Look", isOn: $model.holdLook)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Play / Pause") { model.togglePlay() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Next Track") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Tap Tempo") { model.tapTempo() }
                    .keyboardShortcut("t", modifiers: [.command])
            }
        }

        Window("DMX Monitor", id: "dmx-monitor") {
            DMXMonitorView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Theme

enum Theme {
    static let green = Color(red: 0.0, green: 0.85, blue: 0.3)
    static let magenta = Color(red: 0.95, green: 0.1, blue: 0.75)
    static let purple = Color(red: 0.55, green: 0.2, blue: 1.0)
    static let panel = Color(white: 0.11)
    static let panelBorder = Color(white: 0.2)
    static let background = Color(white: 0.07)

    static func color(_ c: RGB, intensity: Double = 1) -> Color {
        Color(red: c.r * intensity, green: c.g * intensity, blue: c.b * intensity)
    }
}

struct Panel<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let t = trailing { t }
            }
            content
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder, lineWidth: 1))
    }
}

/// A button that is active only while pressed (flash / strobe).
struct MomentaryButton: View {
    let title: String
    let color: Color
    let action: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(pressed ? color : color.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color, lineWidth: 1))
            .foregroundStyle(pressed ? Color.black : Color.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; action(true) } }
                    .onEnded { _ in pressed = false; action(false) }
            )
            .help("Hold to \(title.lowercased())")
    }
}
