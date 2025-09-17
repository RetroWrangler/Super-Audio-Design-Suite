#!/usr/bin/env swift

import Foundation

let isoPath = "/Volumes/cory/Desktop/SACD_R_Generated.iso"

do {
    let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: isoPath))
    defer { fileHandle.closeFile() }
    
    // Read Area TOC at sector 540
    try fileHandle.seek(toOffset: 540 * 2048)
    let areaTOC = fileHandle.readData(ofLength: 2048)
    
    print("=== Simple Track Analysis ===")
    
    // Check signature
    let signature = String(data: areaTOC.prefix(8), encoding: .ascii) ?? "Unknown"
    print("Area TOC signature: '\(signature)'")
    
    // Track count at offset 16
    let trackCountBytes = areaTOC.subdata(in: 16..<18)
    let trackCount = trackCountBytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    print("Track count: \(trackCount)")
    
    if trackCount > 0 && trackCount <= 20 {
        // First track entry starts at offset 20
        let firstTrackData = areaTOC.subdata(in: 20..<36)
        
        // Track number
        let trackNum = firstTrackData[0]
        
        // Start sector (big-endian)
        let startSectorBytes = firstTrackData.subdata(in: 4..<8)
        let startSector = startSectorBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Length in sectors
        let lengthBytes = firstTrackData.subdata(in: 8..<12)
        let lengthSectors = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        print("First track:")
        print("  Number: \(trackNum)")
        print("  Start sector: \(startSector)")
        print("  Length: \(lengthSectors) sectors")
        
        // Check if there's actually audio data at that sector
        try fileHandle.seek(toOffset: UInt64(startSector) * 2048)
        let audioSample = fileHandle.readData(ofLength: 64)
        
        let uniqueBytes = Set(audioSample)
        print("  Audio sample: \(uniqueBytes.count) unique bytes")
        
        if uniqueBytes.count == 1 {
            let byte = audioSample[0]
            print("  ❌ All bytes are 0x\(String(format: "%02x", byte)) - likely padding/zeros")
        } else {
            print("  ✓ Varied data - looks like audio")
        }
    }
    
} catch {
    print("Error: \(error)")
}