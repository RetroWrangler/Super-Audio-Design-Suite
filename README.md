# SACD Design Suite

A macOS application for authoring Super Audio CDs (SACD) and SACD+ discs.

## **What is SACD+?**

**SACD+ is a new, advanced disc format that builds upon Sony's DSD DISC specification, combining high-quality DSD audio with additional PCM compatibility (If hybrid mode is enabled) layers.** Unlike traditional SACDs, SACD+ discs include dedicated PCM build folders that can be accessed by:

- **Compatible SACD players** (plays the native DSD streams)
- **Computer DVD drives** (can access PCM build folders)
- **Media players with folder support** (can play PCM versions)
- **Network audio systems** (via PCM folder streaming)

SACD+ maintains the full DSD DISC structure while adding PCM build folders for enhanced compatibility without requiring a separate CD layer.

## Current Status

### ✅ SACD+ Mode - **FULLY FUNCTIONAL**
The SACD+ authoring pipeline is complete and working:
- Creates hybrid discs with both CD and SACD layers
- Generated discs play perfectly on all compatible players
- Supports both stereo and multichannel DSD audio
- Full metadata and track information support

### ⚠️ SACD Mode - **EXPERIMENTAL (NOT WORKING)**
The traditional SACD authoring is currently under development:
- **Issue**: Discs are recognized by SACD players but **no audio plays**
- **Status**: Players detect the disc format correctly but audio data is not accessible
- **Cause**: Audio sector mapping or DSD encoding issues in the ISO generation
- **Recommendation**: Use SACD+ mode for functional disc creation

ALL MODES REQUIRE DVD+R OR DVD+R DL

## SACD+ Format Details

### **Disc Structure**
SACD+ discs use Sony's DSD DISC format as the foundation with additional PCM build folders:

```
📁 SACD+ Disc Root (UDF 1.02)
├── 📁 DSD_DISC/                     ← Sony-compatible DSD section
│   └── 📁 Album1/
│       ├── 📄 Track01.dsf 
│       ├── 📄 Track02.dsf
│       └── 📄 Track03.dsf
│
├── 📁 PCM_DISC/                      ← PCM compatibility section
    └── 📁 Album1/
        ├── 📄 Track01.wav
        ├── 📄 Track02.wav
        └── 📄 Track03.wav
```

### **Hybrid Mode**
Standard SACD+ configuration:
- **DSD folder**: Native DSD streams (2.8224 MHz, 1-bit)
- **PCM_BUILD folder**: Stereo PCM versions (24-bit/96kHz)
- **Compatibility**: SACD players use DSD, computers can access PCM folder

### **Dual Hybrid Mode**
Advanced SACD+ configuration:
- **DSD folder**: Native DSD streams (stereo and/or multichannel)
- **PCM_BUILD folder**: Stereo PCM downmix
- **PCM_BUILD_MC folder**: Multichannel PCM versions (5.1/7.1)
- **Maximum compatibility**: Three different ways to access the audio content

```
📁 SACD+ Disc Root (UDF 1.02)
├── 📁 DSD_DISC/                     ← Sony-compatible DSD section
│   └── 📁 Album1/
│       ├── 📄 Track01.dsf
│       ├── 📄 Track02.dsf
│       └── 📄 Track03.dsf
│
├── 📁 PCM_DISC/                      ← PCM compatibility section
    └── 📁 Album1/
        ├── 📄 Track01.wav            ← Stsrt of album in WAV
        ├── 📄 Track02.wav
        ├── 📄 Track03.wav
        ├── 📄 Track04.mp3            ← Start of album in MP3 for complete compatibility
        ├── 📄 Track05.mp3
        └── 📄 Track06.mp3
```

## Features

- **Drag & Drop Interface**: Easy audio file management
- **Multiple Format Support**: DSF, DFF, WAV, FLAC input files
- **Real-time Preview**: Audio analysis and format validation
- **Metadata Support**: Track titles, artist information, and album details
- **Quality Control**: Automatic audio format verification and conversion
- **Progress Tracking**: Real-time disc creation progress with detailed logging

## System Requirements

- macOS 15.0 or later
- Xcode 14.0+ (for development)
- DVD+R DL burner (for SACD+ creation)
- Sufficient disk space (SACDs can be 4-8GB)

## Usage

1. **Select Mode**: Choose between SACD+ (recommended) or SACD (experimental)
2. **Add Audio Files**: Drag DSD files (DSF/DFF) into the application
3. **Configure Settings**: Set disc title, artist, and track information
4. **Generate Disc**: Click "Create SACD+" to build the ISO image
5. **Burn & Test**: Burn to DVD-R DL and test on your SACD player

## Technical Notes

### SACD+ Advantages
- **Universal Compatibility**: Works on 20+ year old CD players
- **Future-Proof**: Compatible with modern and legacy audio systems
- **High Quality**: Maintains full DSD resolution for capable players
- **Convenient**: No need for specialized playback equipment

### File Formats Supported
- **Input**: DSF, DFF, WAV (high-resolution), FLAC
- **Output**: ISO image ready for DVD-R DL burning
- **Metadata**: Embedded track and album information

## Known Issues

- **SACD Mode**: Audio playback not functional (use SACD+ instead)
- **Large Files**: Processing very long tracks (>30 minutes) may be slow
- **Memory Usage**: High-resolution multichannel files require significant RAM

## Development

This is an active development project. The SACD+ implementation is production-ready, while traditional SACD support is being refined.

### Building from Source
```bash
git clone <repository-url>
cd "SACD Design Suite"
open "SACD Design Suite.xcodeproj"
```

## License

[Add your license information here]

## Contributing

[Add contribution guidelines here]

---

**For best results, use SACD+ mode which provides both high-quality audio and universal player compatibility.**
# Super-Audio-Design-Suite
