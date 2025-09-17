#!/usr/bin/env swift

import Foundation

let isoPath = "/Volumes/cory/Desktop/SACD_R_Generated.iso"

do {
    let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: isoPath))
    defer { fileHandle.closeFile() }
    
    print("=== Debug Area TOC Generation ===")
    
    // Read Area TOC sector 540
    try fileHandle.seek(toOffset: 540 * 2048)
    let areaTOC = fileHandle.readData(ofLength: 2048)
    
    // Print raw bytes for first track entry (starts at offset 20)
    print("Raw Area TOC bytes for first track (offset 20-35):")
    let trackEntry = areaTOC.subdata(in: 20..<36)
    for (i, byte) in trackEntry.enumerated() {
        print("Offset \(20 + i): 0x\(String(format: "%02x", byte)) (\(byte))")
    }
    
    // Parse each field manually
    let trackNum = trackEntry[0]
    let formatFlags = trackEntry[1] 
    
    // Start sector (big-endian, 4 bytes at offset 4)
    let startBytes = Array(trackEntry[4..<8])
    let startSector = UInt32(bigEndian: startBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
    
    // Length (big-endian, 4 bytes at offset 8)  
    let lengthBytes = Array(trackEntry[8..<12])
    let lengthSectors = UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
    
    // Duration (offset 12-13)
    let minutes = trackEntry[12]
    let seconds = trackEntry[13]
    
    print("\nParsed first track:")
    print("Track number: \(trackNum)")
    print("Format flags: 0x\(String(format: "%02x", formatFlags))")
    print("Start sector: \(startSector)")
    print("Length: \(lengthSectors) sectors")
    print("Duration: \(minutes):\(String(format: "%02d", seconds))")
    
    // The problem: if startSector is 0, then currentSector calculation is wrong
    if startSector == 0 {
        print("❌ BUG: Start sector is 0 - Area TOC generation is broken")
    } else if startSector >= 560 {
        print("✓ Start sector looks reasonable")
    } else {
        print("⚠️ Start sector seems low")
    }
    
    if minutes == 0 && seconds == 0 {
        print("❌ BUG: Duration is 0:00 - track timing calculation is broken")
    } else {
        print("✓ Duration looks valid")
    }
    
} catch {
    print("Error: \(error)")
}