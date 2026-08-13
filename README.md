# Super Audio Design Suite

A macOS authoring suite for creating SACD+ hybrid audio discs and SACDx archival discs, with deterministic track ordering, verified ISO generation, and direct optical-disc burning.

## Current Status

### ✅ SACD+ Mode - **FULLY FUNCTIONAL**
The SACD+ authoring pipeline is complete and working:
- Creates hybrid discs with both PCM and DSD folders
- Generated discs play perfectly on all compatible players
- Supports both stereo and multichannel DSD audio
- Full metadata and track information support

### ✅ SACDx Mode - **FULLY FUNCTIONAL**
The SACDx authoring pipeline is complete and working:
- Creates deterministic discs containing both an ISO backup and directly accessible DSD paths
- Supports stereo and multichannel DSF album folders
- Verifies authored ISO contents and track ordering before completion
- Supports verified direct ISO burning through Experimental Mode

ALL MODES REQUIRE DVD+R OR DVD+R DL

What is SACD+?
--------------

**SACD+ is a new, advanced disc format that builds upon Sony's DSD DISC specification, combining high-quality DSD audio with additional PCM compatibility (If hybrid mode is enabled) layers.** Unlike traditional SACDs, SACD+ discs include dedicated PCM build folders that can be accessed by:

- **Compatible SACD players** (plays the native DSD streams)
- **Computer DVD drives** (can access PCM build folders)
- **Media players with folder support** (can play PCM versions)
- **Network audio systems** (via PCM folder streaming)

SACD+ maintains the full DSD DISC structure while adding PCM build folders for enhanced compatibility without requiring a separate CD layer.

SACD+ Details
-------------

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
        ├── 📄 Track001.flac
        ├── 📄 Track002.flac
        └── 📄 Track003.flac
```

### **Hybrid Mode**
Hybrid Mode is enabled by default and is the standard SACD+ configuration:
- **DSD folder**: Native DSD streams (2.8224 MHz, 1-bit)
- **PCM_DISC folder**: Lossless FLAC support files
- **Uncompressed Support Mode**: Uses WAV instead of FLAC, with substantially higher disc-space requirements
- **Compatibility**: SACD players use DSD, computers can access PCM folder

Hybrid Mode can be disabled to create a DSD-only disc, but this removes the PCM compatibility path that SACD+ was designed to provide.

### **Multichannel Mode**
Multichannel Mode adds a separate multichannel album path, using `ALBUM02` by default, for multichannel DSF files and matching lossless FLAC support files (or WAV in Uncompressed Support Mode). Maximum Compatibility Mode may remain enabled for the stereo path, including its MP3 copies, but combining both modes requires substantial disc capacity.

### **Maximum Compatibility Mode**
Advanced SACD+ configuration:
- **DSD folder**: Native DSD streams (stereo and/or multichannel)
- **PCM_DISC/ALBUM01**: Stereo FLAC tracks by default, or WAV in Uncompressed Support Mode
- **PCM_DISC/ALBUM02**: MP3 compatibility tracks when Multichannel Mode is off
- **PCM_DISC/ALBUM03**: MP3 compatibility tracks when Multichannel Mode reserves ALBUM02
- **Uncompressed Support Mode**: Replaces the FLAC path with WAV while retaining the MP3 compatibility path
- **MP3 availability**: MP3 can only be added when Maximum Compatibility Mode is selected
- **Capacity impact**: Storing both WAV and MP3 support copies uses considerably more disc space than standard FLAC Hybrid Mode

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
        ├── 📄 Track001.flac          ← Lossless FLAC path (WAV in Uncompressed Support Mode)
        ├── 📄 Track002.flac
        ├── 📄 Track003.flac
        ├── 📄 Track004.mp3           ← MP3 compatibility section
        ├── 📄 Track005.mp3
        └── 📄 Track006.mp3
```

## Features

- **Drag & Drop Interface**: Easy audio file management
- **Multiple Format Support**: DSF, WAV, FLAC input files
- **Real-time Preview**: Audio analysis and format validation
- **Metadata Support**: Track titles, artist information, and album details
- **Quality Control**: Automatic audio format verification and conversion
- **Progress Tracking**: Real-time disc creation progress with detailed logging
- **Optional Track Renaming**: Keep deterministic `TRACK###` disc names by default, or preserve original filenames with an explicit playback-order warning

## System Requirements

- macOS 15.0 or later
- Xcode 14.0+ (for development)
- Bundled universal `mkisofs` from dvdrtools 0.2.1 for deterministic SACD+ UDF authoring; license and corresponding source are included in the app resources
- DVD+R DL burner (for SACD+ creation)
- Sufficient disk space (SACDs can be 4-8GB)

## Usage

Before a direct burn, open **SACD Design Suite → Settings…** to choose a specific
DVD writer, or leave the burner set to **Automatic** to let macOS select it.

1. **Select Mode**: SACD+ is available by default. Traditional SACD is hidden unless Experimental Mode is enabled.
2. **Add Audio Files**: Add DSF files to the application
3. **Configure Settings**: Set disc title, artist, and track information
4. **Choose Output**: Select **Create ISO** to save the authored image, or **Burn Directly** to author, burn, and verify the disc in one operation
5. **Build or Burn**: Start the SACD+ operation and test the completed disc on your player

## Technical Notes

### Deterministic Track Ordering

Standard SACD+ images are authored with the bundled `mkisofs` tool. This is a
compatibility requirement: some hardware players play files in their physical
UDF directory-record order instead of sorting filenames.

The previous `hdiutil makehybrid` authoring path could write correctly named
tracks in a nonsequential internal order, causing out-of-order playback. The
current build path writes deterministic directory records and inspects the
finished ISO before reporting success. A build is rejected if the internal
`TRACK###` sequence jumps, reverses, or is otherwise invalid.

This correction has been verified with a burned disc on physical playback
hardware. Track renaming remains enabled by default and is recommended for the
strongest compatibility. If renaming is disabled, the original filenames are
preserved and playback order depends on the player interpreting those names.

### SACD+ Advantages
- **Universal Compatibility**: Works on 20+ year old CD players
- **Future-Proof**: Compatible with modern and legacy audio systems
- **High Quality**: Maintains full DSD resolution for capable players
- **Convenient**: No need for specialized playback equipment

### File Formats Supported
- **Input**: DSF, WAV (high-resolution), FLAC
- **Output**: A verified ISO image, or a directly burned and verified optical disc
- **Metadata**: Embedded track and album information

What is SACDx?
--------------

SACDx creates a deterministic UDF data disc containing a complete backup ISO
and a directly accessible DSD Disc path. It intentionally does not inherit
Hybrid Mode and does not create `PCM_DISC`, FLAC, WAV, or MP3 paths.

### SACDx Formatting Details

```text
SACDx Disc Root
├── BACKUP
│   └── <selected backup>.iso
└── DSD_DISC
    ├── ALBUM01                 stereo DSF path
    │   ├── TRACK001.dsf
    │   └── TRACK002.dsf
    └── ALBUM02                 optional multichannel DSF path
        ├── TRACK001.dsf
        └── TRACK002.dsf
```

The embedded backup ISO, stereo DSF files, and optional multichannel DSF files
all count toward disc capacity. SACDx uses the bundled `mkisofs` authoring and
directory-order verification used by SACD+.

When the application’s Experimental Mode is enabled, SACDx also exposes
**Disable Backup Mode**. This changes SACDx into a direct-burn workflow: the
selected ISO is written sector-for-sector with macOS `hdiutil burn` and verified
afterward, equivalent to Finder’s **Burn Disk Image to Disc** action. No new
SACDx filesystem, `BACKUP` folder, or `DSD_DISC` content is created in this
workflow. Leaving Experimental Mode turns the option off automatically.

Experimental SACD Mode
----------------------

Traditional SACD authoring is intentionally kept out of the primary SACD+
workflow. Triple-click the DSD icon at the upper-left of the active mode pane to
toggle Experimental Mode. The icon gains an orange border and Experimental
indicator while active, and the mode selector shows SACD after SACD+.

This mode is intended for lawful authoring of original material using a donor
SACD template that the user is authorized to use. SACD and its related
technologies and trademarks belong to their respective rights holders,
including Sony and Philips. This project is independent and is not affiliated
with or endorsed by those companies.

Current limitations:

- A donor SACD folder or ISO is required for the template-based workflow.
- Generated discs may be recognized by a player without producing audio.
- Audio-sector mapping, control data, and DST handling remain experimental.
- It must not be used to copy, circumvent protections on, or distribute
  unauthorized SACD content.
- SACD+ remains the recommended and verified authoring mode.

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

Super Audio Design Suite is free software licensed under the **GNU General
Public License, version 2 or later (GPL-2.0-or-later)**. You may use, study,
modify, and redistribute the software under the terms of that license. See
[`LICENSE`](LICENSE) for the complete license text.

### Bundled GPL Software

The application bundles `mkisofs` from **dvdrtools 0.2.1** as a separate
executable for deterministic UDF image authoring. It is also distributed under
GPL-2.0-or-later.

The application bundle includes:

- The complete GPL 2.0 license text.
- An `mkisofs` attribution and source notice.
- A universal macOS `mkisofs` executable for Apple Silicon and Intel.
- The corresponding Homebrew-patched dvdrtools source archive.

Upstream project: [dvdrtools](https://savannah.nongnu.org/projects/dvdrtools/)

Users may inspect, modify, rebuild, and replace the bundled `mkisofs`
executable in accordance with the GPL.

## Contributing

A contribution package is available upon request.

---

**For best results, use SACD+ mode which provides both high-quality audio and universal player compatibility.**
