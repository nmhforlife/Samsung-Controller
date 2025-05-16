# Samsung TV Controller

A modern macOS application for controlling Samsung Smart TVs using SmartThings integration and local WebSocket connection.

## Features

- 🎯 Modern SwiftUI interface with intuitive remote control layout
- 🔄 Dual control methods:
  - SmartThings API integration for cloud control
  - Local WebSocket connection for low-latency control
- 📱 Input source management with friendly names
- 🔌 Automatic device discovery
- 🔐 Secure token management
- 📊 Real-time connection status monitoring
- 📝 Detailed logging system

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later
- Swift 5.9 or later
- SmartThings Developer Account
- Samsung Smart TV with SmartThings integration

## Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/nmhforlife/Samsung-Controller.git
   ```

2. Open the project in Xcode:
   ```bash
   cd Samsung-Controller
   open "Samsung Controller.xcodeproj"
   ```

3. Build and run the application (⌘R)

4. In the Settings tab:
   - Enter your SmartThings token
   - Click "Discover Devices" to find your TV
   - Enter your TV's IP address
   - Click "Connect" to establish connection

## Usage

### Remote Control
- Power button: Turn TV on/off
- Volume controls: Adjust volume and mute
- Channel controls: Change channels
- Navigation pad: Control TV menu
- Menu buttons: Home, Menu, and Return functions
- Input source selector: Switch between TV inputs

### Connection Status
- Green indicator: Connected
- Red indicator: Disconnected
- Device selection dropdown: Switch between multiple TVs

### Logs
- View detailed connection and command logs
- Monitor authentication status
- Track device discovery process

## Architecture

The app uses a dual-control architecture:
1. SmartThings API for cloud-based control
2. Local WebSocket connection for direct TV control

Key components:
- `TVController`: Core controller class managing connections and commands
- `ContentView`: Main UI implementation using SwiftUI
- `RemoteView`: Remote control interface
- `SettingsView`: Device configuration and connection management
- `LogsView`: Log monitoring interface

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Samsung SmartThings API
- SwiftUI framework
- Apple's Human Interface Guidelines 