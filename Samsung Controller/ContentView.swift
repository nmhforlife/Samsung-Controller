//
//  ContentView.swift
//  Samsung Controller
//
//  Created by Greg Rhoades on 5/15/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var controller = TVController(host: "")
    @State private var selectedTab: String = "Remote"
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $selectedTab) {
                Label("Remote", systemImage: "tv")
                    .tag("Remote")
                Label("Logs", systemImage: "text.alignleft")
                    .tag("Logs")
                Label("Settings", systemImage: "gear")
                    .tag("Settings")
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 200)
        } detail: {
            // Main Content Area
            switch selectedTab {
            case "Remote":
                RemoteView(controller: controller)
            case "Logs":
                LogsView(controller: controller)
            case "Settings":
                SettingsView(controller: controller)
            default:
                Text("Select a tab")
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToSettings"))) { _ in
            selectedTab = "Settings"
        }
        .onAppear {
            // Auto-connect to last device if available
            if let lastDevice = UserDefaults.standard.string(forKey: "lastConnectedDevice"),
               !lastDevice.isEmpty {
                controller.connectToDevice(lastDevice)
            }
        }
    }
}

struct RemoteView: View {
    @ObservedObject var controller: TVController
    @State private var showingSourceMenu = false
    @Environment(\.colorScheme) var colorScheme
    
    // Custom colors
    private let backgroundColor = Color(NSColor.windowBackgroundColor)
    private let buttonColor = Color(NSColor.controlBackgroundColor)
    private let buttonPressedColor = Color.accentColor.opacity(0.2)
    private let accentColor = Color.accentColor
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color(NSColor.windowBackgroundColor).opacity(0.8)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Connection Status and Device Selection
                HStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(controller.isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    // Device Selection
                    Picker("Device", selection: $controller.selectedDeviceId) {
                        ForEach(controller.availableDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .frame(width: 250)
                    .onChange(of: controller.selectedDeviceId) { oldValue, newValue in
                        if !newValue.isEmpty {
                            controller.connectToDevice(newValue)
                        }
                    }
                }
                .padding(.horizontal)
                
                if !controller.isConnected {
                    VStack(spacing: 12) {
                        Text("Not Connected")
                            .font(.headline)
                        Text("Please connect to your TV in Settings")
                            .foregroundColor(.secondary)
                        Button("Open Settings") {
                            NotificationCenter.default.post(name: NSNotification.Name("SwitchToSettings"), object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Main Remote Control Area
                    VStack(spacing: 20) {
                        // Source Selection
                        Menu {
                            ForEach(controller.availableSources, id: \.self) { sourceId in
                                Button(action: {
                                    controller.selectSource(sourceId)
                                }) {
                                    Label(controller.appList[sourceId] ?? sourceId, systemImage: "cable.connector")
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                Text("Input Source")
                                Image(systemName: "chevron.down")
                            }
                            .frame(width: 150, height: 36)
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.bordered)
                        .disabled(!controller.isConnected)
                        
                        // Power Button
                        Button(action: { controller.sendCommand("KEY_POWER") }) {
                            Image(systemName: "power")
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 56, height: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .shadow(color: .red.opacity(0.3), radius: 5, x: 0, y: 2)
                        
                        // Volume Controls
                        HStack(spacing: 20) {
                            RemoteButton(action: { controller.sendCommand("KEY_VOLDOWN") }) {
                                Image(systemName: "speaker.fill")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            
                            RemoteButton(action: { controller.sendCommand("KEY_MUTE") }) {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            
                            RemoteButton(action: { controller.sendCommand("KEY_VOLUP") }) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 22, weight: .medium))
                            }
                        }
                        
                        // Channel Controls
                        HStack(spacing: 20) {
                            RemoteButton(action: { controller.sendCommand("KEY_CHANNELDOWN") }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            
                            RemoteButton(action: { controller.sendCommand("KEY_CHANNELUP") }) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 22, weight: .medium))
                            }
                        }
                        
                        // Navigation Pad
                        VStack(spacing: 8) {
                            RemoteButton(action: { controller.sendCommand("KEY_UP") }) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            
                            HStack(spacing: 8) {
                                RemoteButton(action: { controller.sendCommand("KEY_LEFT") }) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 22, weight: .medium))
                                }
                                
                                RemoteButton(action: { controller.sendCommand("KEY_ENTER") }) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 22, weight: .medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .shadow(color: .accentColor.opacity(0.3), radius: 5, x: 0, y: 2)
                                
                                RemoteButton(action: { controller.sendCommand("KEY_RIGHT") }) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 22, weight: .medium))
                                }
                            }
                            
                            RemoteButton(action: { controller.sendCommand("KEY_DOWN") }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 22, weight: .medium))
                            }
                        }
                        
                        // Menu Controls
                        HStack(spacing: 20) {
                            RemoteButton(action: { controller.sendCommand("KEY_HOME") }) {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            
                            RemoteButton(action: { controller.sendCommand("KEY_MENU") }) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            
                            RemoteButton(action: { controller.sendCommand("KEY_RETURN") }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 22, weight: .medium))
                            }
                        }
                    }
                    .padding(30)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
                    )
                    .padding()
                }
            }
        }
    }
}

// Custom button style for remote buttons
struct RemoteButton<Content: View>: View {
    let action: () -> Void
    let content: Content
    @State private var isPressed = false
    
    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = false
                }
            }
        }) {
            content
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isPressed ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                        .shadow(color: isPressed ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.1),
                               radius: isPressed ? 2 : 4,
                               x: 0,
                               y: isPressed ? 1 : 2)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1.0)
    }
}

struct LogsView: View {
    @ObservedObject var controller: TVController
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(controller.logMessages) { message in
                    Text(message.message)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct SettingsView: View {
    @ObservedObject var controller: TVController
    @State private var smartThingsToken: String = ""
    @State private var isDiscovering = false
    @State private var deviceIPs: [String: String] = [:]
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("SmartThings Token") {
                        TextField("Enter your SmartThings token", text: $smartThingsToken)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                    }
                    
                    HStack(spacing: 16) {
                        Button("Save Token") {
                            controller.setSmartThingsToken(smartThingsToken)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(smartThingsToken.isEmpty)
                        
                        Button("Discover Devices") {
                            isDiscovering = true
                            controller.discoverSmartThingsDevice()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDiscovering)
                    }
                }
            } header: {
                Text("SmartThings Integration")
            }
            
            Section {
                if controller.discoveredSmartThingsDevices.isEmpty {
                    Text("No devices discovered. Click 'Discover Devices' to search.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(controller.discoveredSmartThingsDevices, id: \.device.id) { deviceInfo in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(deviceInfo.device.name)
                                .font(.headline)
                            
                            HStack {
                                TextField("Enter IP address", text: Binding(
                                    get: { deviceIPs[deviceInfo.device.id] ?? deviceInfo.ip ?? "" },
                                    set: { newValue in
                                        deviceIPs[deviceInfo.device.id] = newValue
                                        controller.setTVIP(newValue, forDeviceId: deviceInfo.device.id)
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onAppear {
                                    if let ip = deviceInfo.ip {
                                        deviceIPs[deviceInfo.device.id] = ip
                                    }
                                }
                                
                                Button("Connect") {
                                    if let ip = deviceIPs[deviceInfo.device.id] {
                                        controller.setTVIP(ip, forDeviceId: deviceInfo.device.id)
                                        controller.connectToDevice(deviceInfo.device.id)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(deviceIPs[deviceInfo.device.id] == nil)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Discovered Devices")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(controller.isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(.secondary)
                    }
                    
                    if !controller.smartThingsDeviceId.isEmpty {
                        LabeledContent("SmartThings Device") {
                            Text(controller.smartThingsDeviceId)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if !controller.host.isEmpty {
                        LabeledContent("Local IP") {
                            Text(controller.host)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Connection Status")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Add this extension for the placeholder
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {
        
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

#Preview {
    ContentView()
}
