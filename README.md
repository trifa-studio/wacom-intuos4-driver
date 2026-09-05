# Wacom Intuos4 Wireless — Apple Silicon Native macOS Driver

<p align="center">
  <b>A modern, high-performance, user-space macOS driver built in Swift for the Wacom Intuos4 Wireless (PTK-540WL) and USB tablets on Apple Silicon (M1/M2/M3/M4) & Intel.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%20%2B-blue?style=flat-square&logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20(ARM64)%20%7C%20x86__64-brightgreen?style=flat-square" alt="ARM64" />
  <img src="https://img.shields.io/badge/Language-Swift%206-orange?style=flat-square&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Kernel%20Extensions-None%20(100%25%20User--Space)-purple?style=flat-square" alt="Zero KEXT" />
  <img src="https://img.shields.io/badge/Status-Production%20Ready-success?style=flat-square" alt="Status" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License" /></a>
</p>

---

## 📖 Overview

The official Wacom driver for the **Intuos4 Wireless (PTK-540WL)** was discontinued years ago, leaving this high-end professional drawing tablet unsupported on modern Apple Silicon Macs.

**IntuosDriver** is a clean-room native Swift replacement that restores full functionality to the Intuos4, unlocking full wireless Bluetooth and USB operation, physical 4-bit OLED displays, Touch Ring LEDs, sub-millisecond pressure curve mapping, application-aware profiles, and an interactive on-screen Radial Menu without requiring any deprecated kernel extensions (KEXTs).

---

## ✨ Features

### 🎨 Precision Pen Engine
- **2048 Pressure Levels**: Real-time non-linear pressure curves (Soft, Linear, Firm, Custom Gamma, Dead Zone).
- **Anti-Jitter Exponential Smoothing**: Eliminates hand tremor and digitized jitter with dynamic alpha filtering.
- **Dual-Axis Tilt ($\pm 64^\circ$)**: Native CoreGraphics tilt angle vector synthesis for natural shading in Photoshop, Illustrator, Painter, etc.
- **Eraser & Tool Tracking**: Automatic hardware proximity detection and standard pen vs. eraser tip switching.
- **Dual Barrel Switches**: Custom actions for Right-Click, Middle-Click, and Pan/Scroll.

### ⚡ Apple Silicon Native Transports
- **USB Interface**: Zero-latency raw IOHIDManager streaming (`VID 0x056A`, `PID 0x00B9` / `0x00BC`).
- **Bluetooth Wireless**: High-speed 200 Hz raw stream via official Report `0x03` initialization (`PID 0x00BD`).
- **Zero Kernel Extensions**: Runs 100% in user-space with standard macOS Accessibility permissions.

### 🖥️ Physical Tablet Hardware Controls
- **4-Bit Grayscale OLED Displays ($64 \times 32$)**: Clean anti-aliased font rendering streamed across Report `0x21` / `0x23` display transactions.
- **Touch Ring Quadrant LEDs**: 4-mode indicator LEDs with 16-level PWM brightness control (Report `0x20`).
- **72-Step Touch Ring**: Hardware ring encoder with 4 cycling modes (Auto Scroll / Zoom, Cycle Layers, Brush Size, Rotate Canvas).

### 🔮 On-Screen HUD & Radial Menu
- **Transient Frosted-Glass HUD**: Non-intrusive bottom banners on ExpressKey presses, Touch Ring mode switches, and profile changes.
- **8-Sector Cursor Radial Menu**: Circular pie menu anchored under your pen tip for rapid shortcut triggering (`Undo`, `Redo`, `Brush +/-`, `Zoom +/-`, `Hand`, `Eyedropper`).

### 🎯 Multi-Monitor & Display Navigation
- **Display Toggle**: Cycle cursor projection across multiple monitors or span the entire virtual desktop via ExpressKey.
- **Precision Mode**: Constrains tablet active area to a $2\times$ zoom detail window for pixel-accurate retouching.
- **180° Left-Handed Orientation Flip**: Inverts both tablet coordinate tracking and physical OLED text rendering for southpaw artists.

### 💼 Application-Specific Profiles & Key Customizer
- **Automatic App Detection**: Instantly detects when Adobe Photoshop, Illustrator, Blender, Figma, Safari, or other apps gain focus.
- **Live Key & OLED Rebinding**: Rebind any ExpressKey and type custom OLED text labels right from the menu bar settings UI.
- **JSON Profile Backup**: One-click **Export Profiles** and **Import Profiles** for easy sharing and backup.

### 🔋 Power & System Integration
- **Wireless Battery Monitor**: Real-time battery percentage (`🔋 70% ⚡`) and low-battery alerts ($\le 15\%$).
- **Launch at Login**: Integrates with macOS `SMAppService` for automatic startup on boot.
- **Clean Exit**: Right-click context menu and power button to cleanly release HID device handles.

---

## 🚀 Quick Start

### Option A: Download Pre-Built App (Recommended for Artists)
1. Download the latest **`IntuosDriver-v1.0.0-macOS.zip`** from [GitHub Releases](https://github.com/trifa-studio/wacom-intuos4-driver/releases).
2. Unzip and drag `IntuosDriver.app` to your `/Applications` folder.
3. Open `IntuosDriver.app` and grant **Accessibility** permissions when prompted.

### Option B: Build from Source (Developers)
Clone the repository and build the standalone app bundle:

```bash
git clone https://github.com/trifa-studio/wacom-intuos4-driver.git
cd wacom-intuos4-driver/IntuosDriver
./scripts/make-app.sh
```

Then move `IntuosDriver.app` to `/Applications`:

```bash
cp -R IntuosDriver.app /Applications/
open /Applications/IntuosDriver.app
```

### 3. Grant Accessibility Permission
On first launch, macOS will request Accessibility permission:
1. Open **System Settings $\rightarrow$ Privacy & Security $\rightarrow$ Accessibility**.
2. Enable **IntuosDriver**.
3. Re-launch `IntuosDriver.app`.

---

## 🛠️ Reverse-Engineered Hardware Protocols

| Command | Report ID | Payload Format | Description |
| :--- | :--- | :--- | :--- |
| **Bluetooth Switch** | `0x03` | `[0x03, 0x01, 0x01, 0x01]` | Enables 200 Hz raw Wacom Bluetooth packets |
| **LED & Brightness** | `0x20` | `[0x20, Mode\|0x40, Lum, Lum, Lum\|0x30, 0, 0, 0, 0]` | Controls 4 ring LEDs and OLED brightness |
| **OLED Transaction** | `0x21` | `[0x01]` (start) / `[0x00]` (commit) | Wraps OLED screen streaming transactions |
| **OLED Data Block** | `0x23` | `[KeyIdx, BlockIdx, ... 256 bytes]` | 4 blocks of 256 bytes per key (1024 bytes 4-bit) |

---

## 🧪 Testing

Run the decoder/OLED/pressure checks and the separate pointer event regression suite:

```bash
cd IntuosDriver
swift run intuos-tests
swift run intuos-pointer-tests
```

The pointer suite captures events without posting desktop input. It checks taps,
three-point jitter tolerance before dragging, pressure-only tablet updates,
button releases, side-button double clicks, and modifier/click-count transitions.
The standalone runners work with Command Line Tools without XCTest.

After installing, also verify JDownloader LinkGrabber package expansion, Finder
Command-click then unmodified dragging, and fine strokes/pressure in a drawing
app. Event-sequence tests do not establish compatibility with every application.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
