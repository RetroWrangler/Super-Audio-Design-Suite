#!/usr/bin/env swift

import Foundation

let isoPath = "/Volumes/cory/Desktop/Fleetwood mac - Rumours (2011 - Rock) [Flac 24-88 SACD 5.1]/SACD_R_Generated.iso"

do {
    let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: isoPath))
    defer { fileHandle.closeFile() }
    
    print("=== Audio Sector Analysis ===")
    
    // Check what's at sector 560 (where first track should be)
    try fileHandle.seek(toOffset: 560 * 2048)
    let audioData = fileHandle.readData(ofLength: 2048)
    
    print("Audio at sector 560 (first track):")
    print("First 32 bytes:", audioData.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))
    
    // Check if it's a DFF file header
    let header = String(data: audioData.prefix(4), encoding: .ascii) ?? "Unknown"
    print("Header signature: '\(header)'")
    
    if header == "FRM8" {
        print("✓ Found DFF file header")
        
        // DFF files have chunk size at offset 4-7
        let chunkSize = audioData.subdata(in: 4..<8).withUnsafeBytes { 
            $0.load(as: UInt32.self).bigEndian 
        }
        print("DFF chunk size: \(chunkSize) bytes")
        
        // Check for DSD marker at offset 8
        let dsdMarker = String(data: audioData.subdata(in: 8..<12), encoding: .ascii) ?? "Unknown"
        print("DSD marker: '\(dsdMarker)'")
        
    } else if header == "DSD " {
        print("✓ Found DSF file header")
    } else {
        print("❌ Unknown audio format - this is the problem!")
        print("Expected DFF (FRM8) or DSF (DSD ) header")
    }
    
    // Check data diversity
    let uniqueBytes = Set(audioData)
    print("Unique bytes in sector: \(uniqueBytes.count)")
    
    if uniqueBytes.count == 1 {
        let byte = audioData[0]
        print("❌ All bytes are 0x\(String(format: "%02x", byte)) - no audio data!")
    } else if uniqueBytes.count < 50 {
        print("⚠️ Low diversity - might be corrupted")
    } else {
        print("✓ Good diversity - audio data present")
    }
    
    // The critical issue: SACD players expect raw DSD audio streams, not DFF/DSF files
    print("\n=== CRITICAL ISSUE IDENTIFIED ===")
    print("SACD players expect raw DSD audio streams in specific frame format,")
    print("but we're copying complete DFF/DSF files which include headers and metadata.")
    print("We need to extract just the raw DSD audio data from the DFF files!")
    
} catch {
    print("Error: \(error)")
}