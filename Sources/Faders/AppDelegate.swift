import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let mixer = Mixer()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "App volumes")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: MixerView(mixer: mixer))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        // Debug hook for scripts/snapshot.sh: renders the popover to a PNG.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.krabduke.faders.snapshot"), object: nil, queue: .main) { [weak self] note in
            guard let self, let path = note.object as? String else { return }
            self.snapshot(to: path)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Taps are torn down with the process anyway; this just makes it immediate.
        mixer.setVisible(false)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            mixer.setVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        mixer.setVisible(false)
    }

    private func snapshot(to path: String) {
        if !popover.isShown { togglePopover() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let view = self?.popover.contentViewController?.view.window?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
