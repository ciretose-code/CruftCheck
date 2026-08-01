import AppKit
import SwiftUI

@main
struct CruftCheckApp: App {
    /// One scanner for the whole app. `@State` owns it; `@Observable` means SwiftUI
    /// tracks only the properties each view actually reads.
    @State private var scanner = ScannerViewModel()

    var body: some Scene {
        Window("Cruft/Check", id: "main") {
            ContentView(scanner: scanner)
                .frame(minWidth: 680, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { scanner.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(scanner.isScanning)

                Button("Reveal Trash") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}
