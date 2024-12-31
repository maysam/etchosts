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
    private var authRef: AuthorizationRef?
    
    private init() {
        var auth: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, AuthorizationFlags(), &auth)
        if status == errAuthorizationSuccess {
            self.authRef = auth
        }
    }
    
    func requestAuthorization() -> Bool {
        guard let authRef = self.authRef else { return false }
        
        let rightName = "system.privilege.admin"
        var item = AuthorizationItem(
            name: rightName.withCString { UnsafePointer<Int8>($0) },
            valueLength: 0,
            value: nil,
            flags: 0)
        
        var rights = AuthorizationRights(count: 1, items: &item)
        
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        
        let status = AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
        return status == errAuthorizationSuccess
    }
    
    func modifyHostsFile(content: String) throws {
        guard let authRef = self.authRef else {
            throw NSError(domain: "HostFileManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Authorization not initialized"])
        }
        
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
    @State private var showingAuthAlert = false
    
    // Function to validate IPv4 address
    private func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }
    
    // Function to validate IPv6 address
    private func isValidIPv6(_ ip: String) -> Bool {
        let parts = ip.split(separator: ":")
        guard parts.count <= 8 else { return false }
        
        return parts.allSatisfy { part in
            let hexPart = String(part)
            guard hexPart.count <= 4 else { return false }
            return hexPart.allSatisfy { $0.isHexDigit }
        }
    }
    
    // Function to validate IP address (IPv4 or IPv6)
    private func isValidIP(_ ip: String) -> Bool {
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
            .alert("Administrator Privileges Required", isPresented: $showingAuthAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This app requires administrator privileges to modify the hosts file. Please run the app with sudo privileges or grant necessary permissions.")
            }
        }
    }
    
    private func loadHostsFile() {
        do {
            let content = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            hostEntries = lines.enumerated().compactMap { (index, line) in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty {
                    return nil
                }
                
                let isComment = trimmedLine.hasPrefix("#")
                let lineToProcess = isComment ? String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmedLine
                
                let components = lineToProcess.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                
                guard components.count >= 2,
                      isValidIP(components[0]) else { return nil }
                
                return HostEntry(
                    ip: components[0],
                    domain: components[1],
                    originalLine: line,
                    isEnabled: !isComment,
                    lineNumber: index
                )
            }
        } catch {
            showError(message: "Error reading hosts file: \(error.localizedDescription)")
        }
    }
    
    private func toggleHostEntry(entry: HostEntry) {
        // Request authorization first
        if !HostFileManager.shared.requestAuthorization() {
            showingAuthAlert = true
            return
        }
        
        do {
            let content = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            var lines = content.components(separatedBy: .newlines)
            let enabled = entry.originalLine.hasPrefix("#")
            
            let newLine: String
            if entry.isEnabled {
                // Add comment if it doesn't exist
                newLine = "# " + entry.originalLine
            } else {
                // Remove comment if it exists
                newLine = String(entry.originalLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            
            lines[entry.lineNumber] = newLine
            
            let newContent = lines.joined(separator: "\n")
            
            // Use authorization to modify hosts file directly
            try HostFileManager.shared.modifyHostsFile(content: newContent)
            
            // Reload the hosts file to reflect changes
            loadHostsFile()
            
        } catch {
            showError(message: "Error updating hosts file: \(error.localizedDescription)")
        }
    }
    
    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

#Preview {
    ContentView()
}
