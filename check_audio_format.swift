#!/usr/bin/env swift

import Foundation

let isoPath = "/Volumes/cory/Desktop/SACD_R_Generated.iso"

do {
    let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: isoPath))
    defer { fileHandle.closeFile() }
    
    print("=== Audio Format Analysis ===")
    
    // Read Area TOC to get first track location
    try fileHandle.seek(toOffset: 540 * 2048)
    let areaTOC = fileHandle.readData(ofLength: 2048)
    
    // Get first track start sector
    let firstTrackData = areaTOC.subdata(in: 20..<36)
    let startSector = firstTrackData.subdata(in: 4..<8).withUnsafeBytes { 
        $0.load(as: UInt32.self).bigEndian 
    }
    
    print("First track starts at sector: \(startSector)")
    
    // Read audio data from first track
    try fileHandle.seek(toOffset: UInt64(startSector) * 2048)
    let audioData = fileHandle.readData(ofLength: 2048)
    
    print("First 64 bytes of audio data:")
    let first64 = Array(audioData.prefix(64))
    for i in stride(from: 0, to: 64, by: 16) {
        let lineBytes = Array(first64[i..<min(i+16, 64)])
        let hex = lineBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "%04x: %s", i, hex))
    }
    
    // Check if this looks like a DSF or DFF file header
    let header = String(data: audioData.prefix(4), encoding: .ascii) ?? "Unknown"
    print("\nFile header signature: '\(header)'")
    
    if header == "DSD " {
        print("✓ This looks like a DSF file header")
    } else if header == "FRM8" {
        print("✓ This looks like a DFF file header")
    } else {
        print("⚠️ Unknown header - might be raw DSD data or corrupted")
    }
    
    // Check for repetitive patterns that might indicate problems
    let uniqueBytes = Set(audioData.prefix(1024))
    print("Unique bytes in first 1KB: \(uniqueBytes.count)")
    
    if uniqueBytes.count < 10 {
        print("❌ Very low diversity - might be padding or corrupted")
    } else if uniqueBytes.count > 200 {
        print("✓ High diversity - looks like valid audio")
    } else {
        print("⚠️ Medium diversity")
    }
    
    // Check if the timing information in TOC is correct
    let minutes = firstTrackData[12]
    let seconds = firstTrackData[13]
    print("\nTrack duration from TOC: \(minutes):\(String(format: "%02d", seconds))")
    
    if minutes == 0 && seconds == 0 {
        print("❌ Track duration is 0:00 - this is the problem!")
        print("The Oppo can't play because it thinks the track has no duration")
    } else {
        print("✓ Track has valid duration")
    }
    
} catch {
    print("Error: \(error)")
}