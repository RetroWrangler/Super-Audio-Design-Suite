#!/usr/bin/env swift

import Foundation

class TrackTimingAnalyzer {
    private let fileHandle: FileHandle
    
    init(url: URL) throws {
        self.fileHandle = try FileHandle(forReadingFrom: url)
    }
    
    deinit {
        fileHandle.closeFile()
    }
    
    func readSector(_ sector: UInt32) throws -> Data {
        let offset = UInt64(sector) * UInt64(2048)
        try fileHandle.seek(toOffset: offset)
        return fileHandle.readData(ofLength: 2048)
    }
    
    func analyzeTrackTiming() throws {
        print("=== Track Timing Analysis ===")
        
        // Read Area TOC sector 540
        let areaTOC = try readSector(540)
        
        // Parse track count
        let trackCount = UInt16(bigEndian: areaTOC.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt16.self) })
        print("Track count: \(trackCount)")
        
        if trackCount > 20 {
            print("❌ Track count seems too high - possible parsing error")
            return
        }
        
        // Track entries start at offset 20 in Area TOC
        var offset = 20
        
        for i in 0..<Int(trackCount) {
            guard offset + 16 <= areaTOC.count else {
                print("❌ Track \(i+1): Not enough data in TOC")
                break
            }
            
            // Parse track entry (each track is 16 bytes)
            let trackNum = areaTOC[offset]
            
            // Track start sector (4 bytes, big-endian)
            let startSector = UInt32(bigEndian: areaTOC.withUnsafeBytes { 
                $0.load(fromByteOffset: offset + 4, as: UInt32.self) 
            })
            
            // Track length in sectors (4 bytes, big-endian)  
            let lengthSectors = UInt32(bigEndian: areaTOC.withUnsafeBytes {
                $0.load(fromByteOffset: offset + 8, as: UInt32.self)
            })
            
            // Track timing (minutes, seconds)
            let minutes = areaTOC[offset + 12]
            let seconds = areaTOC[offset + 13]
            
            print("Track \(trackNum):")
            print("  Start sector: \(startSector)")
            print("  Length: \(lengthSectors) sectors (\(lengthSectors * 2048) bytes)")
            print("  Duration: \(minutes):\(String(format: "%02d", seconds))")
            
            // Check if audio data exists at this sector
            do {
                let audioData = try readSector(startSector)
                let uniqueBytes = Set(audioData.prefix(256))
                print("  Audio check: \(uniqueBytes.count) unique bytes", terminator: "")
                
                if uniqueBytes.count < 5 {
                    print(" - ❌ Too uniform, might be zeros/padding")
                } else if uniqueBytes.count > 100 {
                    print(" - ✓ Good diversity, looks like audio")
                } else {
                    print(" - ⚠️ Medium diversity")
                }
                
                // Check for DSD patterns (common in DSD files)
                let first32 = Array(audioData.prefix(32))
                print("  First bytes: \(first32.map { String(format: "%02x", $0) }.prefix(16).joined(separator: " "))")
                
            } catch {
                print("  Audio check: ❌ Can't read sector \(startSector)")
            }
            
            offset += 16
        }
        
        // Check file size vs expected audio data
        let fileSize = try fileHandle.seekToEnd()
        let totalSectors = fileSize / 2048
        print("\nFile has \(totalSectors) sectors total")
        
        if totalSectors < 600 {
            print("⚠️ File seems small for SACD with \(trackCount) tracks")
        }
    }
}

let isoPath = "/Volumes/cory/Desktop/SACD_R_Generated.iso"
do {
    let analyzer = try TrackTimingAnalyzer(url: URL(fileURLWithPath: isoPath))
    try analyzer.analyzeTrackTiming()
} catch {
    print("Error: \(error)")
}