#!/usr/bin/env swift

import Foundation

// Simple ISO analyzer to check SACD structure
class ISOAnalyzer {
    private let fileHandle: FileHandle
    private let sectorSize: Int = 2048
    
    init(url: URL) throws {
        self.fileHandle = try FileHandle(forReadingFrom: url)
    }
    
    deinit {
        fileHandle.closeFile()
    }
    
    func readSector(_ sector: UInt32) throws -> Data {
        let offset = UInt64(sector) * UInt64(sectorSize)
        try fileHandle.seek(toOffset: offset)
        return fileHandle.readData(ofLength: sectorSize)
    }
    
    func analyzeStructure() throws {
        print("=== SACD ISO Analysis ===")
        
        // Check first few sectors
        for sector in 0..<20 {
            let data = try readSector(UInt32(sector))
            if !data.allSatisfy({ $0 == 0 }) {
                print("Sector \(sector): Non-empty (\(data.count) bytes)")
                if let ascii = String(data: data.prefix(64), encoding: .ascii) {
                    let printable = ascii.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace) }
                    if !printable.isEmpty {
                        print("  ASCII: \(printable)")
                    }
                }
            }
        }
        
        // Look for SACD signatures throughout
        print("\n=== SACD Signature Scan ===")
        let signatures = ["MASTER.TOC", "SACD", "2CH", "MCH", "TEXT", "TRACK"]
        var foundSectors: [String: [UInt32]] = [:]
        
        let fileSize = try fileHandle.seekToEnd()
        let totalSectors = min(UInt32(fileSize / UInt64(sectorSize)), 1000) // First 1000 sectors
        
        for sector in 0..<totalSectors {
            let data = try readSector(sector)
            
            for signature in signatures {
                if let sigData = signature.data(using: .ascii),
                   data.range(of: sigData) != nil {
                    if foundSectors[signature] == nil {
                        foundSectors[signature] = []
                    }
                    foundSectors[signature]?.append(sector)
                }
            }
        }
        
        for (signature, sectors) in foundSectors.sorted(by: { $0.key < $1.key }) {
            print("\(signature): found at sectors \(sectors.prefix(10))")
        }
        
        // Check for directory structure around common locations
        print("\n=== Directory Structure Check ===")
        let checkSectors: [UInt32] = [16, 32, 64, 128, 256, 512]
        for sector in checkSectors {
            let data = try readSector(sector)
            if let ascii = String(data: data, encoding: .ascii) {
                let files = ascii.components(separatedBy: .controlCharacters)
                    .filter { $0.count > 3 && $0.allSatisfy({ $0.isASCII }) }
                if !files.isEmpty {
                    print("Sector \(sector) filenames: \(files.prefix(5))")
                }
            }
        }
    }
}

// Run analysis
let isoPath = "/Users/cory/Desktop/SACD_R.iso"
do {
    let analyzer = try ISOAnalyzer(url: URL(fileURLWithPath: isoPath))
    try analyzer.analyzeStructure()
} catch {
    print("Error analyzing ISO: \(error)")
}