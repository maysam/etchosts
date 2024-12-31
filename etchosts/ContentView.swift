//
//  ContentView.swift
//  etchosts
//
//  Created by maysam torabi on 30.12.2024.
//

import SwiftUI
import Foundation
import ServiceManagement
import Security
import Cocoa

struct HostEntry: Identifiable {
    let id = UUID()
    let ip: String
    let domain: String
    let originalLine: String
    var isEnabled: Bool
    let lineNumber: Int
}

class HostFileManager {
    static let shared = HostFileManager()
    
    private init() {}
    
    func modifyHostsFile(content: String) throws {
        // First write content to a temporary file
        let tempFilePath = NSTemporaryDirectory().appending("hosts.tmp")
        let tempURL = URL(fileURLWithPath: tempFilePath)
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        
        // AppleScript command to move the file with sudo
        let appleScript = "do shell script \"mv \(tempFilePath) /etc/hosts\" with administrator privileges"
        let script = NSAppleScript(source: appleScript)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        if let error = error {
            throw NSError(domain: "HostFileManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute privileged operation: \(error)"])
        }
        
        // Clean up temporary file if it still exists
        try? FileManager.default.removeItem(at: tempURL)
    }
}

struct ContentView: View {
    @State private var hostEntries: [HostEntry] = []
    @State private var showError = false
    @State private var errorMessage = ""
    
    // Static IP validation functions
    private static func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }
    
    private static func isValidIPv6(_ ip: String) -> Bool {
        let parts = ip.split(separator: ":")
        guard parts.count <= 8 else { return false }
        
        return parts.allSatisfy { part in
            let hexPart = String(part)
            guard hexPart.count <= 4 else { return false }
            return hexPart.allSatisfy { $0.isHexDigit }
        }
    }
    
    private static func isValidIP(_ ip: String) -> Bool {
        if ip == "255.255.255.255" || ip == "::1" || ip == "127.0.0.1" {
            return true
        }
        return isValidIPv4(ip) || isValidIPv6(ip)
    }
    
    var body: some View {
        NavigationView {
            List(hostEntries, id: \.domain) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.domain)
                            .font(.headline)
                            .strikethrough(!entry.isEnabled, color: .gray)
                        Text(entry.ip)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .strikethrough(!entry.isEnabled, color: .gray)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleHostEntry(entry: entry)
                }
            }
            .navigationTitle("Hosts File Entries")
            .onAppear {
                loadHostsFile()
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func loadHostsFile() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)
                
                let newEntries = lines.enumerated().compactMap { (index: Int, line: String) -> HostEntry? in
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.isEmpty {
                        return nil
                    }
                    
                    let isComment = trimmedLine.hasPrefix("#")
                    let lineToProcess = isComment ? String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmedLine
                    
                    let components = lineToProcess.components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    
                    guard components.count >= 2,
                          Self.isValidIP(components[0]) else { return nil }
                    
                    return HostEntry(
                        ip: components[0],
                        domain: components[1],
                        originalLine: line,
                        isEnabled: !isComment,
                        lineNumber: index
                    )
                }
                
                DispatchQueue.main.async {
                    self.hostEntries = newEntries
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }
    
    private func toggleHostEntry(entry: HostEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
                var lines = content.components(separatedBy: .newlines)
                let enabled = entry.originalLine.hasPrefix("#")
                
                let newLine: String
                if enabled {
                    // Remove comment if it exists
                    newLine = String(entry.originalLine.dropFirst()).trimmingCharacters(in: .whitespaces)
                } else {
                    // Add comment if it doesn't exist
                    newLine = "# " + entry.originalLine
                }
                
                lines[entry.lineNumber] = newLine
                let newContent = lines.joined(separator: "\n")
                
                // Use authorization to modify hosts file directly
                try HostFileManager.shared.modifyHostsFile(content: newContent)
                
                DispatchQueue.main.async {
                    // Reload the hosts file to reflect changes
                    self.loadHostsFile()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }
    
    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Hide dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Hide menu bar items
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var hostEntries: [HostEntry] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "Hosts"
            button.action = #selector(menuBarItemClicked)
        }
        loadHostsFile()
    }

    @objc func menuBarItemClicked() {
        let menu = NSMenu()
        for entry in hostEntries {
            let menuItem = NSMenuItem(title: entry.domain, action: #selector(toggleEntry(_:)), keyEquivalent: "")
            menuItem.state = entry.isEnabled ? .on : .off
            menuItem.representedObject = entry
            menu.addItem(menuItem)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    @objc func toggleEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HostEntry else { return }
        toggleHostEntry(entry: entry)
        menuBarItemClicked() // Refresh menu
    }

    @objc func openHostsFile() {
        // Implement functionality to open or modify the hosts file
        NSWorkspace.shared.open(URL(fileURLWithPath: "/etc/hosts"))
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func loadHostsFile() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)
                
                let newEntries = lines.enumerated().compactMap { (index: Int, line: String) -> HostEntry? in
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.isEmpty {
                        return nil
                    }
                    
                    let isComment = trimmedLine.hasPrefix("#")
                    let lineToProcess = isComment ? String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmedLine
                    
                    let components = lineToProcess.components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    
                    guard components.count >= 2,
                          self.isValidIP(components[0]) else { return nil }
                    
                    return HostEntry(
                        ip: components[0],
                        domain: components[1],
                        originalLine: line,
                        isEnabled: !isComment,
                        lineNumber: index
                    )
                }
                
                DispatchQueue.main.async {
                    self.hostEntries = newEntries
                }
            } catch {
                print("Error reading hosts file: \(error.localizedDescription)")
            }
        }
    }

    private func toggleHostEntry(entry: HostEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
                var lines = content.components(separatedBy: .newlines)
                let enabled = entry.originalLine.hasPrefix("#")
                
                let newLine: String
                if enabled {
                    // Remove comment if it exists
                    newLine = String(entry.originalLine.dropFirst()).trimmingCharacters(in: .whitespaces)
                } else {
                    // Add comment if it doesn't exist
                    newLine = "# " + entry.originalLine
                }
                
                lines[entry.lineNumber] = newLine
                let newContent = lines.joined(separator: "\n")
                
                // Use authorization to modify hosts file directly
                try HostFileManager.shared.modifyHostsFile(content: newContent)
                
                DispatchQueue.main.async {
                    // Reload the hosts file to reflect changes
                    self.loadHostsFile()
                }
            } catch {
                print("Error updating hosts file: \(error.localizedDescription)")
            }
        }
    }

    private func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }

    private func isValidIPv6(_ ip: String) -> Bool {
        let parts = ip.split(separator: ":")
        guard parts.count <= 8 else { return false }
        
        return parts.allSatisfy { part in
            let hexPart = String(part)
            guard hexPart.count <= 4 else { return false }
            return hexPart.allSatisfy { $0.isHexDigit }
        }
    }
    
    private func isValidIP(_ ip: String) -> Bool {
        if ip == "255.255.255.255" || ip == "::1" || ip == "127.0.0.1" {
            return true
        }
        return isValidIPv4(ip) || isValidIPv6(ip)
    }
}

#Preview {
    ContentView()
}
