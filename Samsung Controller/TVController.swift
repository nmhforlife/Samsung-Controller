// Fixed version of the original TVController class.
// Key updates:
// - Removed custom URLProtocol
// - Uses proper WebSocket connection handling
// - Adds retry strategy and port fallback
// - Works only with 8002 and secure connection for Tizen TVs

import Foundation
import Network

struct SmartThingsDevice: Identifiable, Hashable {
    let id: String
    let name: String
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: SmartThingsDevice, rhs: SmartThingsDevice) -> Bool {
        lhs.id == rhs.id
    }
}

class TVController: ObservableObject {
    @Published var isConnected = false
    @Published var isPoweredOn = false
    @Published var logMessages: [LogMessage] = []
    @Published var availableSources: [String] = []
    @Published var appList: [String: String] = [:]
    @Published var availableDevices: [SmartThingsDevice] = []
    @Published var selectedDeviceId: String = ""

    // SmartThings API properties
    @Published var smartThingsToken: String = ""
    @Published var smartThingsDeviceId: String = ""
    
    private let smartThingsBaseURL = "https://api.smartthings.com/v1"
    private var smartThingsHeaders: [String: String] {
        [
            "Authorization": "Bearer \(smartThingsToken)",
            "Content-Type": "application/json"
        ]
    }
    
    var host: String
    private let ports: [UInt16] = [8002, 8001] // secure first
    private var portIndex = 0
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var token: String?
    private var pathMonitor: NWPathMonitor?
    private var isNetworkReachable = false
    private var reconnectTimer: Timer?
    private let reconnectDelay: TimeInterval = 2.0
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 15.0

    var isAuthenticated = false
    private var isConnecting = false
    private let deviceName = "Samsung Controller"
    private let appId = "Samsung Controller"
    private var connectionTimer: Timer?
    private let connectionTimeout: TimeInterval = 10
    private var connectionAttempts = 0
    private let maxConnectionAttempts = 3
    private let connectionDelay: TimeInterval = 2.0
    private var isReconnecting = false

    // UserDefaults keys
    private let tokenKey = "smartThingsToken"
    private let ipKey = "tvIPAddress"
    private let authTokenKey = "tvAuthToken"
    private let lastDeviceKey = "lastConnectedDevice"

    // Mapping of Samsung input sources to SmartThings input source values
    private let smartThingsInputMapping: [String: String] = [
        "TV": "TV",
        "HDMI": "HDMI",
        "HDMI1": "HDMI1",
        "HDMI2": "HDMI2",
        "HDMI3": "HDMI3",
        "HDMI4": "HDMI4",
        "COMPONENT1": "COMPONENT1",
        "COMPONENT2": "COMPONENT2",
        "AV1": "AV1",
        "AV2": "AV2",
        "AV3": "AV3"
    ]

    private var browser: NWBrowser?
    private var discoveredDevices: [String: String] = [:]
    private var isDiscovering = false
    private var knownDeviceIP: String?
    private var knownDeviceName: String?
    private var hasAttemptedKnownIP = false
    private var isLookingForDeviceName = false
    private var discoveryStartTime: Date?
    private var pendingDeviceNameDiscovery = false
    private var discoveryStatusTimer: Timer?

    // Add new property for discovered SmartThings devices with IPs
    @Published var discoveredSmartThingsDevices: [(device: SmartThingsDevice, ip: String?)] = []

    private var isWebSocketConnected = false
    private var isHandshakeSent = false
    private var authenticationTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private var lastReconnectTime: Date?
    private let minReconnectDelay: TimeInterval = 2.0
    private let authenticationTimeout: TimeInterval = 30.0
    private var isWaitingForAuth = false
    private var initialConnectionAttempt = true
    private let connectionRetryDelay: TimeInterval = 5.0

    // Add standard SmartThings input sources
    private let standardInputSources = [
        "AM", "CD", "FM", "HDMI", "HDMI1", "HDMI2", "HDMI3", "HDMI4", "HDMI5", "HDMI6",
        "digitalTv", "USB", "YouTube", "aux", "bluetooth", "digital", "melon", "wifi",
        "network", "optical", "coaxial", "analog1", "analog2", "analog3", "phono"
    ]

    // Add rate limiting properties
    private var lastCapabilitiesRequest: Date?
    private let capabilitiesRequestInterval: TimeInterval = 5.0 // 5 seconds between requests

    init(host: String) {
        self.host = host
        setupSession()
        setupNetworkMonitoring()
        
        // Load saved token
        if let savedToken = UserDefaults.standard.string(forKey: tokenKey) {
            self.smartThingsToken = savedToken
            log("Loaded saved SmartThings token")
            
            // If we have a token, try to discover devices
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.discoverSmartThingsDevice()
                
                // After discovering devices, try to connect to the last device
                if let lastDevice = UserDefaults.standard.string(forKey: self.lastDeviceKey),
                   !lastDevice.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.connectToDevice(lastDevice)
                    }
                }
            }
        } else {
            log("Waiting for SmartThings token")
        }
        
        // Load saved IP
        if let savedIP = UserDefaults.standard.string(forKey: ipKey) {
            self.host = savedIP
            log("Loaded saved IP: \(savedIP)")
        }
        
        // Load saved auth token
        if let savedAuthToken = UserDefaults.standard.string(forKey: authTokenKey) {
            self.token = savedAuthToken
            log("Loaded saved auth token")
        }
        
        // Load last connected device
        if let lastDevice = UserDefaults.standard.string(forKey: lastDeviceKey) {
            self.selectedDeviceId = lastDevice
            log("Loaded last connected device: \(lastDevice)")
        }
    }

    private func setupNetworkMonitoring() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isNetworkReachable = path.status == .satisfied
                if path.status != .satisfied {
                    self?.log("Network is not reachable")
                    self?.disconnect()
                }
            }
        }
        pathMonitor?.start(queue: DispatchQueue.global(qos: .background))
    }

    private func setupSession() {
        let config = URLSessionConfiguration.default
        // Increase timeout intervals to prevent premature timeouts
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        
        // Create a custom URLSession that accepts self-signed certificates
        let delegate = CustomURLSessionDelegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        // Reduce ping interval to keep connection more active
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func sendPing() {
        guard isConnected && isAuthenticated else { return }
        
        let ping = """
        {
          "method": "ms.remote.ping",
          "params": {
            "token": "\(token ?? "")"
          }
        }
        """
        
        webSocketTask?.send(.string(ping)) { [weak self] error in
            if let error = error {
                self?.log("Ping failed: \(error.localizedDescription)")
                // Only attempt reconnection if we get a timeout or connection error
                if (error as NSError).code == NSURLErrorTimedOut ||
                   (error as NSError).code == NSURLErrorNotConnectedToInternet {
                    self?.handleConnectionError()
                }
            }
        }
    }

    private func handleConnectionError() {
        log("Connection error detected, attempting to reconnect...")
        disconnect()
        connect()
    }

    func disconnect() {
        log("🔌 Disconnecting...")
        
        // Cancel all timers
        connectionTimer?.invalidate()
        connectionTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        authenticationTimer?.invalidate()
        authenticationTimer = nil
        
        // Close WebSocket connection
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.isAuthenticated = false
            self.isConnecting = false
            self.isWebSocketConnected = false
            self.isHandshakeSent = false
            self.isWaitingForAuth = false
            self.initialConnectionAttempt = true
            self.smartThingsDeviceId = ""
            self.availableSources = []
            self.appList = [:]
        }
        log("✅ Disconnected")
    }

    private func handleConnectionTimeout() {
        log("⏰ Connection timeout on port \(ports[portIndex])")
        
        // Only disconnect if we're not in initial connection attempt
        if !initialConnectionAttempt {
            disconnect()
        }
        
        if connectionAttempts < maxConnectionAttempts {
            isReconnecting = true
            reconnectAttempts += 1
            
            if reconnectAttempts <= maxReconnectAttempts {
                log("🔄 Attempting to reconnect (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")
                // Use a longer delay for reconnection attempts
                let delay = initialConnectionAttempt ? connectionRetryDelay : connectionDelay
                reconnectTimer?.invalidate()
                reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.initialConnectionAttempt = false
                    if self.portIndex + 1 < self.ports.count {
                        self.portIndex += 1
                        self.connect()
                    } else {
                        self.portIndex = 0 // Reset to first port
                        self.connect()
                    }
                }
            } else {
                log("❌ Maximum reconnect attempts reached")
                isReconnecting = false
            }
        } else {
            log("❌ Maximum connection attempts reached")
            connectionAttempts = 0
            isReconnecting = false
        }
    }

    func connect() {
        guard !isConnecting else {
            log("Connection attempt already in progress")
            return
        }

        guard isNetworkReachable else {
            log("Network is not reachable")
            return
        }

        guard portIndex < ports.count else {
            log("All ports failed. Please check your network or TV settings.")
            disconnect()
            return
        }

        // Validate IP address format
        let components = host.components(separatedBy: ".")
        guard components.count == 4,
              components.allSatisfy({ Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }) else {
            log("Invalid IP address format")
            return
        }

        // If we're already authenticated and connected, don't reconnect
        if isAuthenticated && isWebSocketConnected && token != nil {
            log("Already authenticated and connected, skipping connection")
            return
        }

        // If we're reconnecting, add a delay
        if isReconnecting {
            DispatchQueue.main.asyncAfter(deadline: .now() + connectionDelay) { [weak self] in
                self?.performConnection()
            }
            return
        }

        performConnection()
    }

    deinit {
        disconnect()
        pathMonitor?.cancel()
        stopDiscovery()
    }

    private func performConnection() {
        log("🔄 Starting connection process...")
        
        // Check if we're already connected
        if isWebSocketConnected && isAuthenticated {
            log("✅ Already connected and authenticated")
            return
        }
        
        // Prevent multiple simultaneous connection attempts
        if isConnecting {
            log("⚠️ Connection attempt already in progress")
            return
        }
        
        isConnecting = true
        
        // Try to get token from UserDefaults if not set
        if token == nil {
            if let savedToken = UserDefaults.standard.string(forKey: authTokenKey) {
                token = savedToken
                log("🔑 Loaded saved token from UserDefaults: \(savedToken)")
            } else {
                log("⚠️ No saved token found in UserDefaults")
            }
        } else {
            log("🔑 Using existing token: \(token!)")
        }
        
        let port = ports[portIndex]
        let scheme = (port == 8002) ? "wss" : "ws"
        let encodedName = deviceName.data(using: .utf8)?.base64EncodedString() ?? deviceName
        let tokenParam = token != nil ? "&token=\(token!)" : ""
        let urlString = "\(scheme)://\(host):\(port)/api/v2/channels/samsung.remote.control?name=\(encodedName)\(tokenParam)"

        guard let url = URL(string: urlString) else {
            log("❌ Invalid URL for WebSocket")
            disconnect()
            isConnecting = false
            return
        }

        log("🔌 Creating WebSocket connection with token: \(token ?? "none")")

        // Create new connection
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // Start receiving messages
        receiveMessage()

        // Always send handshake
        log("🤝 Sending handshake with token: \(token ?? "none")")
        sendHandshake()
        
        // Set a connection timeout
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.isAuthenticated {
                self.log("⏰ Connection timeout")
                self.disconnect()
                self.isConnecting = false
            }
        }
    }

    private func receiveMessage() {
        guard let webSocketTask = webSocketTask else {
            log("❌ No WebSocket task available for receiving messages")
            return
        }
        
        log("📥 Waiting for message...")
        webSocketTask.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.log("📥 Received string message: \(text)")
                    self.handleResponse(text)
                case .data(let data):
                    if let str = String(data: data, encoding: .utf8) {
                        self.log("📥 Received data message: \(str)")
                        self.handleResponse(str)
                    }
                @unknown default:
                    self.log("❓ Received unknown message type")
                }
                // Continue receiving messages
                self.receiveMessage()
            case .failure(let error):
                self.log("❌ Receive error: \(error.localizedDescription)")
                self.handleWebSocketError(error)
            }
        }
    }

    private func handleWebSocketError(_ error: Error) {
        log("❌ WebSocket error: \(error.localizedDescription)")
        
        // Check if it's a connection error
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                log("🌐 No internet connection")
            case .timedOut:
                log("⏰ Connection timed out")
            case .cannotConnectToHost:
                log("🔌 Cannot connect to host")
            case .networkConnectionLost:
                log("📡 Network connection lost")
            default:
                log("❓ Unknown connection error: \(urlError.code)")
            }
        }
        
        // Only attempt to reconnect if we're not already reconnecting
        if !isReconnecting {
            isReconnecting = true
            reconnectAttempts += 1
            
            if reconnectAttempts <= maxReconnectAttempts {
                log("🔄 Attempting to reconnect (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")
                // Use a longer delay for reconnection attempts
                let delay = initialConnectionAttempt ? connectionRetryDelay : minReconnectDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.initialConnectionAttempt = false
                    self?.connect()
                }
            } else {
                log("❌ Maximum reconnect attempts reached")
                isReconnecting = false
            }
        }
    }

    private func handleResponse(_ response: String) {
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let event = json["event"] as? String {
                switch event {
                case "ms.channel.connect":
                    if let data = json["data"] as? [String: Any] {
                        // Check for additional auth requirement
                        if let additionalAuthRequired = data["additionalAuthCodeRequired"] as? Int,
                           additionalAuthRequired == 1 {
                            log("🔐 Additional authentication required")
                            // Send handshake with saved token
                            if let savedToken = UserDefaults.standard.string(forKey: authTokenKey) {
                                log("🔑 Using saved token for additional auth: \(savedToken)")
                                self.token = savedToken
                                self.sendHandshake()
                            } else {
                                log("⚠️ No saved token found for additional auth")
                                self.sendHandshake()
                            }
                            return
                        }
                        
                        // Get the client ID from the response
                        if let clientId = data["id"] as? String {
                            log("🔑 Received client ID: \(clientId)")
                            
                            // Set authentication state
                            DispatchQueue.main.async {
                                self.isAuthenticated = true
                                self.isConnected = true
                                self.isConnecting = false
                                self.isReconnecting = false
                                self.isWaitingForAuth = false
                                self.connectionAttempts = 0
                                self.isWebSocketConnected = true
                            }
                            
                            connectionTimer?.invalidate()
                            authenticationTimer?.invalidate()
                            startPingTimer()
                            
                            // Update available sources after successful connection
                            self.updateAvailableSources()
                        }
                    }
                case "ms.channel.unauthorized":
                    log("🚫 Unauthorized access. Please accept the pairing request on your TV")
                    // Clear the saved token since it's no longer valid
                    UserDefaults.standard.removeObject(forKey: authTokenKey)
                    UserDefaults.standard.synchronize() // Force immediate save
                    token = nil
                    isAuthenticated = false
                    isWebSocketConnected = false
                    isWaitingForAuth = false
                    isConnecting = false
                    handleUnauthorized()
                default:
                    break
                }
            }
        }
    }

    private func handleUnauthorized() {
        disconnect()
        // Cancel any existing reconnect timer
        reconnectTimer?.invalidate()
        
        // Only attempt to reconnect if we're not already authenticated and we haven't exceeded attempts
        if !isAuthenticated && reconnectAttempts < maxReconnectAttempts {
            // Schedule a new reconnect attempt with a longer delay
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay * 2, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.portIndex + 1 < self.ports.count {
                    self.portIndex += 1
                    self.connect()
                } else {
                    self.portIndex = 0 // Reset to first port
                    self.connect()
                }
            }
        } else {
            log("❌ Maximum reconnect attempts reached or already authenticated")
            isReconnecting = false
        }
    }

    private func getCapabilityDetails(_ capabilityId: String) {
        let url = URL(string: "\(smartThingsBaseURL)/capabilities/\(capabilityId)")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = smartThingsHeaders
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to get capability details: \(error.localizedDescription)")
            return
        }

            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.log("Detailed capability info for \(capabilityId):")
                if let commands = json["commands"] as? [[String: Any]] {
                    self.log("    Available commands:")
                    for command in commands {
                        if let name = command["name"] as? String {
                            self.log("      - \(name)")
                            if let arguments = command["arguments"] as? [[String: Any]] {
                                for arg in arguments {
                                    if let argName = arg["name"] as? String,
                                       let argType = arg["type"] as? String {
                                        self.log("        Argument: \(argName) (Type: \(argType))")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.resume()
    }

    private func mapKeyToSmartThingsCommand(_ key: String) -> (capability: String, command: String, arguments: [Any]) {
        switch key {
        case "KEY_POWER":
            return ("switch", "on", [])
        case "KEY_VOLUP":
            return ("audioVolume", "setVolume", [1]) // Increment by 1
        case "KEY_VOLDOWN":
            return ("audioVolume", "setVolume", [-1]) // Decrement by 1
        case "KEY_MUTE":
            return ("audioMute", "mute", [])
        case "KEY_CHANNELUP":
            return ("tvChannel", "channelUp", [])
        case "KEY_CHANNELDOWN":
            return ("tvChannel", "channelDown", [])
        case "KEY_UP":
            return ("samsungvd.remoteControl", "button", ["UP"])
        case "KEY_DOWN":
            return ("samsungvd.remoteControl", "button", ["DOWN"])
        case "KEY_LEFT":
            return ("samsungvd.remoteControl", "button", ["LEFT"])
        case "KEY_RIGHT":
            return ("samsungvd.remoteControl", "button", ["RIGHT"])
        case "KEY_ENTER":
            return ("samsungvd.remoteControl", "button", ["OK"])
        case "KEY_HOME":
            return ("samsungvd.remoteControl", "button", ["HOME"])
        case "KEY_MENU":
            return ("samsungvd.remoteControl", "button", ["MENU"])
        case "KEY_RETURN":
            return ("samsungvd.remoteControl", "button", ["BACK"])
        default:
            return ("samsungvd.remoteControl", "button", [key.replacingOccurrences(of: "KEY_", with: "")])
        }
    }

    func sendCommand(_ key: String) {
        // Check if we should use local connection
        let useLocalConnection = [
            "KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT",
            "KEY_ENTER", "KEY_HOME", "KEY_MENU", "KEY_RETURN",
            "KEY_VOLUP", "KEY_VOLDOWN", "KEY_MUTE"  // Add volume controls to local connection
        ].contains(key)
        
        if useLocalConnection {
            // Use local WebSocket connection
            if !isAuthenticated {
                log("🔌 Not authenticated for local connection, attempting to connect...")
                connect()
                // Retry the command after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.sendCommand(key)
                }
                return
            }
            
            let command = """
            {
              "method": "ms.remote.control",
              "params": {
                "Cmd": "Click",
                "DataOfCmd": "\(key)",
                "TypeOfRemote": "SendRemoteKey"
              }
            }
            """
            
            log("🔊 Sending local command: \(key)")
            webSocketTask?.send(.string(command)) { [weak self] error in
                if let error = error {
                    self?.log("❌ Failed to send local command: \(error.localizedDescription)")
                    // If command fails, try to reconnect and retry
                    self?.connect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.sendCommand(key)
                    }
                } else {
                    self?.log("✅ Successfully sent local command: \(key)")
                }
            }
            return
        }
        
        // For other commands, use SmartThings API
        guard !smartThingsDeviceId.isEmpty else {
            log("❌ No SmartThings device ID available")
            return
        }
        
        log("📡 Sending command via SmartThings: \(key)")
        
        // Map the key to the appropriate SmartThings command
        let (capability, command, arguments) = mapKeyToSmartThingsCommand(key)
        log("📡 Mapped to capability: \(capability), command: \(command), arguments: \(arguments)")
        
        // Use SmartThings API to send command
        let url = URL(string: "\(smartThingsBaseURL)/devices/\(smartThingsDeviceId)/commands")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = smartThingsHeaders
        
        let body: [String: Any] = [
            "commands": [
                [
                    "component": "main",
                    "capability": capability,
                    "command": command,
                    "arguments": arguments
                ]
            ]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("❌ Failed to send command: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    self.log("✅ Successfully sent command: \(key)")
                } else {
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = json["message"] as? String {
                        self.log("❌ Failed to send command: \(message)")
                    } else {
                        self.log("❌ Failed to send command with status: \(httpResponse.statusCode)")
                    }
                }
            }
        }.resume()
    }

    private func updateAvailableSources() {
        // Check if we need to rate limit
        if let lastRequest = lastCapabilitiesRequest,
           Date().timeIntervalSince(lastRequest) < capabilitiesRequestInterval {
            log("⏳ Rate limiting capabilities request")
            return
        }
        
        lastCapabilitiesRequest = Date()
        
        // First get device capabilities
        let capabilitiesURL = URL(string: "\(smartThingsBaseURL)/devices/\(smartThingsDeviceId)")!
        var capabilitiesRequest = URLRequest(url: capabilitiesURL)
        capabilitiesRequest.allHTTPHeaderFields = smartThingsHeaders
        
        log("📺 Querying device capabilities...")
        
        URLSession.shared.dataTask(with: capabilitiesRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to get device capabilities: \(error.localizedDescription)")
                self.updateSourcesWithFallback()
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                self.log("📺 Capabilities response status: \(httpResponse.statusCode)")
            }
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.log("📺 Device capabilities response: \(json)")
                
                // Check for samsungvd.mediaInputSource capability
                if let components = json["components"] as? [[String: Any]] {
                    for component in components {
                        if let _ = component["id"] as? String,
                           let capabilities = component["capabilities"] as? [[String: Any]] {
                            for capability in capabilities {
                                if let capabilityId = capability["id"] as? String,
                                   capabilityId == "samsungvd.mediaInputSource" {
                                    // Found Samsung-specific mediaInputSource capability, now get its status
                                    self.getSamsungInputSourceStatus()
                                    return
                                }
                            }
                        }
                    }
                }
                
                // If we get here, we didn't find the Samsung-specific capability
                self.log("📺 No samsungvd.mediaInputSource capability found, using fallback")
                self.updateSourcesWithFallback()
            } else {
                self.log("Invalid capabilities response format")
                self.updateSourcesWithFallback()
            }
        }.resume()
    }

    private func getSamsungInputSourceStatus() {
        let statusURL = URL(string: "\(smartThingsBaseURL)/devices/\(smartThingsDeviceId)/components/main/capabilities/samsungvd.mediaInputSource/status")!
        var statusRequest = URLRequest(url: statusURL)
        statusRequest.allHTTPHeaderFields = smartThingsHeaders
        
        log("📺 Querying Samsung input source status...")
        
        URLSession.shared.dataTask(with: statusRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to get Samsung input source status: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateSourcesWithFallback()
                }
                return
            }
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.log("📺 Samsung input source status response: \(json)")
                
                // Try to get supported input sources map
                if let supportedInputSourcesMap = json["supportedInputSourcesMap"] as? [String: Any],
                   let sources = supportedInputSourcesMap["value"] as? [[String: Any]] {
                    // We got a list of supported sources with IDs and names
                    var availableSources: [String] = []
                    var newAppList: [String: String] = [:]
                    
                    for source in sources {
                        if let id = source["id"] as? String,
                           let name = source["name"] as? String {
                            // Use the ID as the key and name as the value
                            newAppList[id] = name
                            availableSources.append(id)
                            self.log("📺 Found input source: \(name) (ID: \(id))")
                        }
                    }
                    
                    // Sort sources alphabetically by name
                    availableSources.sort { id1, id2 in
                        let name1 = newAppList[id1] ?? id1
                        let name2 = newAppList[id2] ?? id2
                        return name1 < name2
                    }
                    
                    DispatchQueue.main.async {
                        self.appList = newAppList
                        self.availableSources = availableSources
                        self.log("📺 Updated available sources: \(availableSources.map { "\(newAppList[$0] ?? $0) (\($0))" }.joined(separator: ", "))")
                    }
                } else if let supportedInputSources = json["supportedInputSources"] as? [String: Any],
                          let sources = supportedInputSources["value"] as? [String] {
                    // We got a simple list of supported sources
                    var availableSources: [String] = []
                    var newAppList: [String: String] = [:]
                    
                    for source in sources {
                        newAppList[source] = source
                        availableSources.append(source)
                        self.log("📺 Found input source: \(source)")
                    }
                    
                    // Sort sources alphabetically
                    availableSources.sort()
                    
                    DispatchQueue.main.async {
                        self.appList = newAppList
                        self.availableSources = availableSources
                        self.log("📺 Updated available sources: \(availableSources.joined(separator: ", "))")
                    }
                } else {
                    // If we don't get any supported sources, use the standard ones
                    self.log("📺 No supported sources found, using standard sources")
                    DispatchQueue.main.async {
                        self.updateSourcesWithFallback()
                    }
                }
            } else {
                self.log("Invalid status response format")
                DispatchQueue.main.async {
                    self.updateSourcesWithFallback()
                }
            }
        }.resume()
    }

    private func updateSourcesWithFallback() {
        // Only use fallback if we don't have any sources yet
        if availableSources.isEmpty {
            // Use standard SmartThings input sources as fallback
            var fallbackSources = standardInputSources
            
            // Add any additional sources from appList
            for (id, _) in appList {
                if !fallbackSources.contains(id) {
                    fallbackSources.append(id)
                }
            }
            
            // Sort sources alphabetically
            fallbackSources.sort()
            
            // Create a new app list for fallback sources
            var newAppList: [String: String] = [:]
            for source in fallbackSources {
                newAppList[source] = source
            }
            
            self.appList = newAppList
            self.availableSources = fallbackSources
            self.log("📺 Using fallback sources: \(fallbackSources.joined(separator: ", "))")
        } else {
            self.log("📺 Keeping existing sources: \(availableSources.map { "\(appList[$0] ?? $0) (\($0))" }.joined(separator: ", "))")
        }
    }

    func selectSource(_ source: String) {
        guard !smartThingsDeviceId.isEmpty else {
            log("No SmartThings device ID available")
            return
        }
        
        log("📺 Attempting to select source ID: \(source)")
        log("📺 Current available sources: \(availableSources)")
        
        // Use the source ID directly since we're already passing it from the UI
        let sourceId = source
        
        // Use SmartThings API to change input source
        let url = URL(string: "\(smartThingsBaseURL)/devices/\(smartThingsDeviceId)/commands")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = smartThingsHeaders
        
        let body: [String: Any] = [
            "commands": [
                [
                    "component": "main",
                    "capability": "samsungvd.mediaInputSource",
                    "command": "setInputSource",
                    "arguments": [sourceId]
                ]
            ]
        ]
        
        log("📺 Sending command body: \(body)")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("❌ Failed to change input source: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    self.log("✅ Successfully changed input source to ID: \(sourceId)")
                } else {
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.log("❌ Failed to change input source. Response: \(json)")
                        if let message = json["message"] as? String {
                            self.log("❌ Error message: \(message)")
                        }
                    } else {
                        self.log("❌ Failed to change input source with status: \(httpResponse.statusCode)")
                    }
                }
            }
        }.resume()
    }

    private func requestAppList() {
        log("📱 Requesting app list...")
        
        // Try the newer method first
        let command = """
        {
          "method": "ms.application.get_installed_app",
          "params": {
            "token": "\(token ?? "")"
          }
        }
        """
        
        webSocketTask?.send(.string(command)) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to request app list: \(error.localizedDescription)")
                // If the first method fails, try the older method
                self.tryLegacyAppList()
            } else {
                self.log("Requested app list")
            }
        }
    }

    private func tryLegacyAppList() {
        log("📱 Trying legacy app list method...")
        
        let command = """
        {
          "method": "ms.application.get",
          "params": {
            "token": "\(token ?? "")"
          }
        }
        """
        
        webSocketTask?.send(.string(command)) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to request app list with legacy method: \(error.localizedDescription)")
                // If both methods fail, use basic sources
                DispatchQueue.main.async {
                    self.appList = [:]
                    self.updateAvailableSources()
                }
            } else {
                self.log("Requested app list with legacy method")
            }
        }
    }

    private func log(_ msg: String) {
        // Only log messages related to authentication and token handling
        if msg.contains("token") || msg.contains("auth") || msg.contains("Token") || 
           msg.contains("🔑") || msg.contains("🔐") || msg.contains("🤝") {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let entry = LogMessage(message: "[\(timestamp)] \(msg)", timestamp: Date())
            DispatchQueue.main.async {
                self.logMessages.append(entry)
                print(entry.message)
            }
        }
    }

    func setSmartThingsToken(_ token: String) {
        smartThingsToken = token
        // Save token to UserDefaults
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.synchronize() // Force immediate save
        log("Saved new SmartThings token")
        
        // Try to discover devices immediately
        discoverSmartThingsDevice()
    }
    
    func setTVIP(_ ip: String, forDeviceId deviceId: String? = nil) {
        host = ip
        if let deviceId = deviceId {
            // Save IP for specific device
            UserDefaults.standard.set(ip, forKey: "\(ipKey)_\(deviceId)")
        } else {
            // Save IP for current device
            UserDefaults.standard.set(ip, forKey: ipKey)
        }
        log("Saved new IP: \(ip)")
        
        // If we have a token, try to discover the device
        if !smartThingsToken.isEmpty {
            log("Found token, attempting to discover device...")
            discoverSmartThingsDevice()
        }
    }

    func discoverSmartThingsDevice() {
        guard !smartThingsToken.isEmpty else {
            log("No SmartThings token available")
            return
        }
        
        log("Searching for devices in SmartThings...")
        let url = URL(string: "\(smartThingsBaseURL)/devices")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = smartThingsHeaders
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to find devices: \(error.localizedDescription)")
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                self.log("Invalid response when finding devices")
                return
            }
            
            var devices: [(device: SmartThingsDevice, ip: String?)] = []
            for device in items {
                if let type = device["type"] as? String,
                   let label = device["label"] as? String,
                   let deviceId = device["deviceId"] as? String {
                    
                    // Only add display devices
                    if type == "OCF" && (label.contains("Odyssey") || label.contains("TV") || label.contains("OLED")) {
                        let smartThingsDevice = SmartThingsDevice(id: deviceId, name: label)
                        // Try to get IP from saved value
                        let savedIP = UserDefaults.standard.string(forKey: "\(self.ipKey)_\(deviceId)")
                        devices.append((device: smartThingsDevice, ip: savedIP))
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.discoveredSmartThingsDevices = devices
                self.availableDevices = devices.map { $0.device }
                
                // If we have a last connected device, select it
                if let lastDevice = UserDefaults.standard.string(forKey: self.lastDeviceKey),
                   devices.contains(where: { $0.device.id == lastDevice }) {
                    self.selectedDeviceId = lastDevice
                    // Auto-connect to the last device
                    self.connectToDevice(lastDevice)
                } else if let firstDevice = devices.first?.device {
                    self.selectedDeviceId = firstDevice.id
                }
            }
        }.resume()
    }
    
    private func stopDiscovery() {
        log("Stopping discovery")
        discoveryStatusTimer?.invalidate()
        discoveryStatusTimer = nil
        browser?.cancel()
        browser = nil
        isDiscovering = false
        isLookingForDeviceName = false
        discoveryStartTime = nil
        pendingDeviceNameDiscovery = false
        log("🔍 Discovery stopped")
    }
    
    private var currentDeviceOCF: [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["deviceId": smartThingsDeviceId]),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return response["ocf"] as? [String: Any]
    }
    
    func connectToDevice(_ deviceId: String) {
        guard !deviceId.isEmpty else {
            log("No device ID provided")
            return
        }
        
        // Save the selected device
        UserDefaults.standard.set(deviceId, forKey: lastDeviceKey)
        UserDefaults.standard.synchronize()
        
        smartThingsDeviceId = deviceId
        log("Connecting to device: \(deviceId)")
        
        // Add a delay before starting the connection process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            
            // Get device capabilities
            let capabilitiesURL = URL(string: "\(self.smartThingsBaseURL)/devices/\(deviceId)")!
            var capabilitiesRequest = URLRequest(url: capabilitiesURL)
            capabilitiesRequest.allHTTPHeaderFields = self.smartThingsHeaders
            
            URLSession.shared.dataTask(with: capabilitiesRequest) { [weak self] data, response, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("Failed to get device capabilities: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.isConnected = false
                    }
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        DispatchQueue.main.async {
                            self.isConnected = true
                        }
                        if let data = data,
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.log("Device capabilities response: \(json)")
                            
                            // Get device IP from network information
                            if let ocf = json["ocf"] as? [String: Any],
                               let networkInfo = ocf["networkInfo"] as? [String: Any],
                               let ip = networkInfo["ip"] as? String {
                                self.log("Found IP from network info: \(ip)")
                                self.host = ip
                                UserDefaults.standard.set(ip, forKey: "\(self.ipKey)_\(deviceId)")
                                
                                // Add a delay before connecting
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    self.connect()
                                }
                            } else {
                                // Try to get IP from saved value
                                if let savedIP = UserDefaults.standard.string(forKey: "\(self.ipKey)_\(deviceId)") {
                                    self.log("Using saved IP for device: \(savedIP)")
                                    self.host = savedIP
                                    
                                    // Add a delay before connecting
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        self.connect()
                                    }
                                } else {
                                    self.log("No IP address found. Please enter the IP address manually.")
                                }
                            }
                            
                            // Get available input sources immediately
                            self.getAvailableInputSources()
                            
                            // Log all available capabilities and their commands
                            if let components = json["components"] as? [[String: Any]] {
                                for component in components {
                                    if let componentId = component["id"] as? String,
                                       let capabilities = component["capabilities"] as? [[String: Any]] {
                                        self.log("Component: \(componentId)")
                                        for capability in capabilities {
                                            if let capabilityId = capability["id"] as? String,
                                               let version = capability["version"] as? Int {
                                                self.log("  Capability: \(capabilityId) (v\(version))")
                                                
                                                // Get detailed capability information
                                                self.getCapabilityDetails(capabilityId)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.isConnected = false
                        }
                        self.log("Failed to connect to device with status: \(httpResponse.statusCode)")
                    }
                }
            }.resume()
        }
    }

    private func getAvailableInputSources() {
        let url = URL(string: "\(smartThingsBaseURL)/devices/\(smartThingsDeviceId)/components/main/capabilities/samsungvd.mediaInputSource/status")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = smartThingsHeaders
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("Failed to get available input sources: \(error.localizedDescription)")
                return
            }
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let supportedInputSourcesMap = json["supportedInputSourcesMap"] as? [String: Any],
               let sources = supportedInputSourcesMap["value"] as? [[String: Any]] {
                
                self.log("Found \(sources.count) input sources in response")
                
                var monitorSources: [String: String] = [:]
                for source in sources {
                    if let id = source["id"] as? String,
                       let name = source["name"] as? String {
                        // Use the name as the key and ID as the value
                        monitorSources[name] = id
                        self.log("Added source: \(name) (ID: \(id))")
                    }
                }
                
                DispatchQueue.main.async {
                    self.appList = monitorSources
                    self.updateAvailableSources()
                    self.log("Updated input sources with \(monitorSources.count) sources from monitor")
                }
            } else {
                self.log("No input sources found in response")
            }
        }.resume()
    }

    private func sendHandshake() {
        guard !isHandshakeSent else {
            log("⚠️ Handshake already sent, skipping")
            return
        }
        
        isHandshakeSent = true
        
        // Create a unique ID for this connection
        let connectionId = UUID().uuidString
        
        let handshake = """
        {
          "method": "ms.channel.connect",
          "params": {
            "name": "\(deviceName)",
            "deviceName": "\(deviceName)",
            "deviceType": "macOS",
            "deviceOS": "macOS",
            "appId": "\(appId)",
            "id": "\(connectionId)",
            "token": "\(token ?? "")",
            "type": "remote",
            "isHost": false,
            "version": "2.0.0",
            "deviceId": "\(smartThingsDeviceId)"
          }
        }
        """

        log("🤝 Sending handshake with ID: \(connectionId) and token: \(token ?? "none")")
        webSocketTask?.send(.string(handshake)) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("❌ Failed to send handshake: \(error.localizedDescription)")
                self.isHandshakeSent = false
                // Try to reconnect if handshake fails
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.connect()
                }
            } else {
                self.log("✅ Handshake sent successfully")
                // Start a timer to wait for authorization
                self.authenticationTimer?.invalidate()
                self.authenticationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    if !self.isAuthenticated {
                        self.log("⚠️ Authorization timeout - please accept the pairing request on your TV")
                        self.handleUnauthorized()
                    }
                }
            }
        }
    }
}

// Custom URLSession delegate to handle self-signed certificates
class CustomURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept self-signed certificates
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
} 
