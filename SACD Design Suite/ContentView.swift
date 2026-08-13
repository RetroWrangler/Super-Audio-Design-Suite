//  ContentView.swift
//  SACD Design Suite
//  Created by Cory on 9/8/25

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation
import AVFoundation
import DiscRecording

// MARK: - Extensions

extension URL {
    var fileSize: Int64? {
        do {
            let resourceValues = try self.resourceValues(forKeys: [.fileSizeKey])
            return Int64(resourceValues.fileSize ?? 0)
        } catch {
            return nil
        }
    }
}

// MARK: - Models

enum AuthoringMode: String, CaseIterable, Identifiable {
    case sacdPlus = "SACD+"
    case sacdX = "SACDx"
    case sacdR   = "SACD"
    var id: String { rawValue }
}

struct TrackItem: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var title: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
}

private struct ExperimentalTriggerButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.62 : 1.0)
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.16)
                    : (active ? Color.orange.opacity(0.14) : Color.clear)
            )
            .cornerRadius(10)
            .shadow(color: configuration.isPressed ? .clear : .black.opacity(0.12), radius: 3, y: 2)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

enum TrackDropTarget {
    case sacdPlusStereoDSF
    case sacdPlusMultichannelDSF
    case hybridStereoLossless
    case maximumCompatibilityLossless
    case maximumCompatibilityMP3
    case hybridMultichannelLossless
    case sacdRDSF
    case sacdXStereoDSF
    case sacdXMultichannelDSF
}

// MARK: - UDF 1.02 ISO Parser

struct UDFVolumeDescriptor {
    let sectorSize: UInt32 = 2048
    let volumeDescriptorSequenceNumber: UInt32
    let primaryVolumeDescriptor: Data
}

struct UDFFileEntry {
    let name: String
    let isDirectory: Bool
    let startSector: UInt32
    let length: UInt64
    let data: Data?
}

// MARK: - DSD File Analysis

struct DSDFileInfo {
    let url: URL
    let format: DSDFormat
    let sampleRate: UInt32
    let channels: UInt32
    let bitsPerSample: UInt32
    let sampleCount: UInt64
    let duration: TimeInterval
    let fileSize: UInt64
    
    var durationSamples: UInt64 { sampleCount }
    var durationSeconds: Double { Double(sampleCount) / Double(sampleRate) }
    var trackLengthSectors: UInt32 { 
        // Calculate sectors needed for this track (2048 bytes per sector)
        UInt32((fileSize + 2047) / 2048)
    }
}

enum DSDFormat {
    case dsf

    var fileExtension: String { "dsf" }
}

class DSDFileParser {
    static func parseFile(at url: URL) throws -> DSDFileInfo {
        let data = try Data(contentsOf: url)
        let fileSize = UInt64(data.count)
        
        let ext = url.pathExtension.lowercased()
        guard ext == "dsf" else {
            throw NSError(domain: "DSDParser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Only DSF files are supported"])
        }

        return try parseDSF(data: data, url: url, fileSize: fileSize)
    }
    
    private static func parseDSF(data: Data, url: URL, fileSize: UInt64) throws -> DSDFileInfo {
        guard data.count >= 28 else {
            throw NSError(domain: "DSDParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "DSF file too small"])
        }
        
        // Check DSD chunk header
        let dsdHeader = data.subdata(in: 0..<4)
        guard String(data: dsdHeader, encoding: .ascii) == "DSD " else {
            throw NSError(domain: "DSDParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid DSF header"])
        }
        
        // Skip to FMT chunk (typically at offset 28)
        guard data.count >= 52 else {
            throw NSError(domain: "DSDParser", code: 3, userInfo: [NSLocalizedDescriptionKey: "DSF file missing FMT chunk"])
        }
        
        let fmtHeader = data.subdata(in: 28..<32)
        guard String(data: fmtHeader, encoding: .ascii) == "fmt " else {
            throw NSError(domain: "DSDParser", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid DSF FMT chunk"])
        }
        
        // Read FMT chunk data (little-endian)
        let channelNum = data.withUnsafeBytes { $0.load(fromByteOffset: 52, as: UInt32.self) }
        let samplingFreq = data.withUnsafeBytes { $0.load(fromByteOffset: 56, as: UInt32.self) }
        let bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: 60, as: UInt32.self) }
        let sampleCount = data.withUnsafeBytes { $0.load(fromByteOffset: 64, as: UInt64.self) }
        
        let duration = Double(sampleCount) / Double(samplingFreq)
        
        return DSDFileInfo(
            url: url,
            format: .dsf,
            sampleRate: samplingFreq,
            channels: channelNum,
            bitsPerSample: bitsPerSample,
            sampleCount: sampleCount,
            duration: duration,
            fileSize: fileSize
        )
    }
    
    // Extract raw DSD audio data from DSF file
    static func extractRawDSDFromDSF(url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        
        // DSF structure: DSD header + audio data
        guard data.count >= 28,
              String(data: data.prefix(4), encoding: .ascii) == "DSD " else {
            throw NSError(domain: "DSDParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid DSF file format"])
        }
        
        // In DSF, audio data starts after header at offset specified in header
        let audioStart = data.subdata(in: 20..<28).withUnsafeBytes { 
            Int($0.load(as: UInt64.self).littleEndian)
        }
        return data.subdata(in: audioStart..<data.count)
    }
}

// MARK: - SACD MASTER.TOC Generator

struct SACDMasterTOC {
    let signature: String = "SACDMTOC"
    let versionMajor: UInt8 = 1
    let versionMinor: UInt8 = 20
    let albumSetSize: UInt16
    let albumSequenceNumber: UInt16
    let albumCatalogNumber: String
    let albumGenre: [UInt8]
    let area1TOC1Start: UInt32
    let area1TOC2Start: UInt32
    let area1TOCSize: UInt16
    let area2TOC1Start: UInt32
    let area2TOC2Start: UInt32
    let area2TOCSize: UInt16
    let discDateYear: UInt16
    let discDateMonth: UInt8
    let discDateDay: UInt8
    
    init(tracks: [DSDFileInfo], albumTitle: String = "Generated Album", isMultichannel: Bool = false) {
        self.albumSetSize = 1
        self.albumSequenceNumber = 1
        self.albumCatalogNumber = albumTitle.padding(toLength: 16, withPad: " ", startingAt: 0)
        self.albumGenre = [0, 0, 0, 0] // No genre specified
        
        // Calculate area positions
        // Standard SACD layout: Master TOC at 510-539, then areas
        let masterTOCEnd: UInt32 = 540
        
        if isMultichannel {
            // Multichannel disc
            self.area1TOC1Start = 0 // No 2CH area
            self.area1TOC2Start = 0
            self.area1TOCSize = 0
            self.area2TOC1Start = masterTOCEnd
            self.area2TOC2Start = masterTOCEnd + 10
            self.area2TOCSize = 10
        } else {
            // 2-channel disc
            self.area1TOC1Start = masterTOCEnd
            self.area1TOC2Start = masterTOCEnd + 10
            self.area1TOCSize = 10
            self.area2TOC1Start = 0 // No MCH area
            self.area2TOC2Start = 0
            self.area2TOCSize = 0
        }
        
        // Current date
        let date = Date()
        let calendar = Calendar.current
        self.discDateYear = UInt16(calendar.component(.year, from: date))
        self.discDateMonth = UInt8(calendar.component(.month, from: date))
        self.discDateDay = UInt8(calendar.component(.day, from: date))
    }
    
    func generateBinaryData() -> Data {
        var data = Data()
        
        // Signature (8 bytes)
        data.append(signature.data(using: .ascii)!)
        
        // Version (2 bytes)
        data.append(contentsOf: [versionMajor, versionMinor])
        
        // Reserved (6 bytes)
        data.append(Data(count: 6))
        
        // Album set size (2 bytes, big-endian)
        data.append(contentsOf: withUnsafeBytes(of: albumSetSize.bigEndian) { Array($0) })
        
        // Album sequence number (2 bytes, big-endian)
        data.append(contentsOf: withUnsafeBytes(of: albumSequenceNumber.bigEndian) { Array($0) })
        
        // Reserved (4 bytes)
        data.append(Data(count: 4))
        
        // Album catalog number (16 bytes)
        let catalogData = albumCatalogNumber.data(using: .ascii) ?? Data()
        data.append(catalogData.prefix(16))
        if catalogData.count < 16 {
            data.append(Data(count: 16 - catalogData.count))
        }
        
        // Album genre (4 bytes)
        data.append(contentsOf: albumGenre)
        
        // Reserved (4 bytes)
        data.append(Data(count: 4))
        
        // Area 1 (2CH) information
        data.append(contentsOf: withUnsafeBytes(of: area1TOC1Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area1TOC2Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area1TOCSize.bigEndian) { Array($0) })
        
        // Reserved (2 bytes)
        data.append(Data(count: 2))
        
        // Area 2 (MCH) information
        data.append(contentsOf: withUnsafeBytes(of: area2TOC1Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area2TOC2Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area2TOCSize.bigEndian) { Array($0) })
        
        // Reserved (2 bytes)
        data.append(Data(count: 2))
        
        // Disc date
        data.append(contentsOf: withUnsafeBytes(of: discDateYear.bigEndian) { Array($0) })
        data.append(contentsOf: [discDateMonth, discDateDay])
        
        // Reserved (4 bytes)
        data.append(Data(count: 4))
        
        // Pad to sector size (2048 bytes)
        let remainingBytes = 2048 - data.count
        if remainingBytes > 0 {
            data.append(Data(count: remainingBytes))
        }
        
        return data
    }
}

class SACDAreaTOC {
    let tracks: [DSDFileInfo]
    let isMultichannel: Bool
    let startSector: UInt32
    
    init(tracks: [DSDFileInfo], isMultichannel: Bool, startSector: UInt32) {
        self.tracks = tracks
        self.isMultichannel = isMultichannel
        self.startSector = startSector
    }
    
    func generateBinaryData() -> Data {
        var data = Data()
        
        print("DEBUG: Area TOC generation starting...")
        print("DEBUG: Track count: \(tracks.count)")
        print("DEBUG: Start sector: \(startSector)")
        print("DEBUG: Is multichannel: \(isMultichannel)")
        
        // Area TOC header
        data.append("SACDSTOC".data(using: .ascii)!) // 8 bytes signature
        
        // Version
        data.append(contentsOf: [1, 20]) // Major, Minor
        
        // Reserved
        data.append(Data(count: 6))
        
        // Track count
        let trackCount = UInt16(tracks.count)
        data.append(contentsOf: withUnsafeBytes(of: trackCount.bigEndian) { Array($0) })
        
        // Reserved
        data.append(Data(count: 2))
        
        // Track entries (each track gets an entry)
        var currentSector = startSector + 20 // Start after TOC area
        print("DEBUG: Audio will start at sector: \(currentSector)")
        
        for (index, track) in tracks.enumerated() {
            print("DEBUG: Processing track \(index + 1)")
            print("DEBUG:   Duration: \(track.duration)s")
            print("DEBUG:   File size: \(track.fileSize) bytes")
            print("DEBUG:   Track length sectors: \(track.trackLengthSectors)")
            print("DEBUG:   Current sector: \(currentSector)")
            
            // Track number
            data.append(UInt8(index + 1))
            
            // Audio format flags - CRITICAL FIX
            // Bit 0 (LSB): dst_encoded = 0 (raw DSD, not DST compressed)
            // Bit 1-7: reserved = 0
            data.append(0x00) // dst_encoded = 0 for raw DSD
            
            // Reserved
            data.append(Data(count: 2))
            
            // Track start sector
            data.append(contentsOf: withUnsafeBytes(of: currentSector.bigEndian) { Array($0) })
            
            // Track length in sectors
            let trackSectors = track.trackLengthSectors
            data.append(contentsOf: withUnsafeBytes(of: trackSectors.bigEndian) { Array($0) })
            
            // Track timing information (simplified)
            let minutes = UInt8(track.duration / 60)
            let seconds = UInt8(track.duration.truncatingRemainder(dividingBy: 60))
            data.append(contentsOf: [minutes, seconds])
            print("DEBUG:   Duration in TOC: \(minutes):\(String(format: "%02d", seconds))")
            
            // Reserved
            data.append(Data(count: 6))
            
            currentSector += trackSectors
        }
        
        print("DEBUG: Area TOC data size before padding: \(data.count) bytes")
        
        // Pad to sector size
        let remainingBytes = 2048 - (data.count % 2048)
        if remainingBytes < 2048 {
            data.append(Data(count: remainingBytes))
        }
        
        print("DEBUG: Area TOC generation completed. Final size: \(data.count) bytes")
        return data
    }
}

class SACDGenerator {
    static func generateSACDStructure(from tracks: [DSDFileInfo], albumTitle: String, isMultichannel: Bool) throws -> Data {
        var sacdData = Data()
        
        // Generate Master TOC
        let masterTOC = SACDMasterTOC(tracks: tracks, albumTitle: albumTitle, isMultichannel: isMultichannel)
        let masterTOCData = masterTOC.generateBinaryData()
        
        // Generate Area TOC
        let areaTOCStartSector: UInt32 = isMultichannel ? masterTOC.area2TOC1Start : masterTOC.area1TOC1Start
        let areaTOC = SACDAreaTOC(tracks: tracks, isMultichannel: isMultichannel, startSector: areaTOCStartSector)
        let areaTOCData = areaTOC.generateBinaryData()
        
        // Layout SACD structure
        // Sectors 0-509: UDF filesystem space
        sacdData.append(Data(count: 510 * 2048))
        
        // Sectors 510-512: Master TOC (3 copies)
        sacdData.append(masterTOCData)
        sacdData.append(masterTOCData)
        sacdData.append(masterTOCData)
        
        // Sectors 513-539: Reserved
        sacdData.append(Data(count: 27 * 2048))
        
        // Area TOC
        sacdData.append(areaTOCData)
        sacdData.append(areaTOCData) // Backup copy
        
        return sacdData
    }
}

class ISOReader {
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
    
    func parseUDFStructure() throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        var foundUDF = false
        
        // Start reading from sector 16 (typical UDF anchor volume descriptor location)
        for sector in 16..<256 {
            do {
                let data = try readSector(UInt32(sector))
                
                // Look for UDF Volume Descriptor Sequence
                // UDF identifier: "NSR02" or "NSR03"
                if let _ = data.range(of: "NSR02".data(using: .ascii)!) ?? data.range(of: "NSR03".data(using: .ascii)!) {
                    foundUDF = true
                    print("Found UDF structure at sector \(sector)")
                    // Found UDF structure, continue parsing
                    let udfEntries = try parseUDFDirectory(startSector: UInt32(sector + 1))
                    entries.append(contentsOf: udfEntries)
                    break
                }
                
                // Also look for ISO 9660 signature as fallback
                if data.count >= 2048 {
                    let iso9660Check = data.subdata(in: 1..<6)
                    if iso9660Check == "CD001".data(using: .ascii) {
                        print("Found ISO 9660 structure at sector \(sector)")
                        // Try to parse as ISO 9660 instead
                        let iso9660Entries = try parseISO9660Directory(startSector: UInt32(sector))
                        entries.append(contentsOf: iso9660Entries)
                        break
                    }
                }
            } catch {
                // Continue searching if this sector fails
                continue
            }
        }
        
        if !foundUDF && entries.isEmpty {
            print("No UDF or ISO 9660 structure found in sectors 16-255")
        }
        
        return entries
    }
    
    func parseUDFStructureWithLogging(_ logger: @escaping (String) async -> Void) async throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        var foundUDF = false
        
        await logger("Scanning ISO sectors 16-255 for UDF/ISO 9660 structure...")
        
        // Start reading from sector 16 (typical UDF anchor volume descriptor location)
        for sector in 16..<256 {
            do {
                let data = try readSector(UInt32(sector))
                
                // Look for UDF Volume Descriptor Sequence
                // UDF identifier: "NSR02" or "NSR03"
                if let _ = data.range(of: "NSR02".data(using: .ascii)!) ?? data.range(of: "NSR03".data(using: .ascii)!) {
                    foundUDF = true
                    await logger("Found UDF structure at sector \(sector)")
                    // Found UDF structure, continue parsing
                    let udfEntries = try await parseUDFDirectoryWithLogging(startSector: UInt32(sector + 1), logger: logger)
                    entries.append(contentsOf: udfEntries)
                    break
                }
                
                // Also look for ISO 9660 signature as fallback
                if data.count >= 2048 {
                    let iso9660Check = data.subdata(in: 1..<6)
                    if iso9660Check == "CD001".data(using: .ascii) {
                        await logger("Found ISO 9660 structure at sector \(sector)")
                        // Try to parse as ISO 9660 instead
                        let iso9660Entries = try await parseISO9660DirectoryWithLogging(startSector: UInt32(sector), logger: logger)
                        entries.append(contentsOf: iso9660Entries)
                        break
                    }
                }
            } catch {
                // Continue searching if this sector fails
                continue
            }
        }
        
        if !foundUDF && entries.isEmpty {
            await logger("❌ No UDF or ISO 9660 structure found in sectors 16-255")
            await logger("Attempting raw SACD signature scan...")
            
            // Try raw sector scanning for SACD content
            let rawEntries = try await rawSACDScan(logger: logger)
            entries.append(contentsOf: rawEntries)
        }
        
        return entries
    }
    
    private func parseUDFDirectory(startSector: UInt32) throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        
        // This is a simplified UDF parser - real implementation would be much more complex
        // We're looking for typical SACD structure files
        let sacdFiles = ["MASTER.TOC", "2CH", "MCH", "TEXT"]
        
        print("Searching for SACD files starting at sector \(startSector)")
        
        for offset in 0..<128 { // Expanded search range
            do {
                let data = try readSector(startSector + UInt32(offset))
                
                for fileName in sacdFiles {
                    if let _ = data.range(of: fileName.data(using: .ascii)!) {
                        print("Found \(fileName) at sector \(startSector + UInt32(offset))")
                        let entry = UDFFileEntry(
                            name: fileName,
                            isDirectory: fileName != "MASTER.TOC",
                            startSector: startSector + UInt32(offset),
                            length: fileName == "MASTER.TOC" ? 2048 : 0,
                            data: fileName == "MASTER.TOC" ? data : nil
                        )
                        entries.append(entry)
                    }
                }
            } catch {
                continue
            }
        }
        
        print("Found \(entries.count) SACD files via UDF parsing")
        return entries
    }
    
    private func parseISO9660Directory(startSector: UInt32) throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        let sacdFiles = ["MASTER.TOC", "2CH", "MCH", "TEXT"]
        
        print("Searching for SACD files via ISO 9660 starting at sector \(startSector)")
        
        // ISO 9660 directory parsing is complex, so we'll do a broader search
        for offset in 0..<512 { // Much broader search for ISO 9660
            do {
                let data = try readSector(startSector + UInt32(offset))
                
                for fileName in sacdFiles {
                    if let _ = data.range(of: fileName.data(using: .ascii)!) {
                        print("Found \(fileName) at sector \(startSector + UInt32(offset)) via ISO 9660")
                        let entry = UDFFileEntry(
                            name: fileName,
                            isDirectory: fileName != "MASTER.TOC",
                            startSector: startSector + UInt32(offset),
                            length: fileName == "MASTER.TOC" ? 2048 : 0,
                            data: fileName == "MASTER.TOC" ? data : nil
                        )
                        entries.append(entry)
                    }
                }
            } catch {
                continue
            }
        }
        
        print("Found \(entries.count) SACD files via ISO 9660 parsing")
        return entries
    }
    
    private func parseUDFDirectoryWithLogging(startSector: UInt32, logger: @escaping (String) async -> Void) async throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        let sacdFiles = ["MASTER.TOC", "2CH", "MCH", "TEXT"]
        
        await logger("Searching for SACD files starting at sector \(startSector)")
        
        for offset in 0..<128 {
            do {
                let data = try readSector(startSector + UInt32(offset))
                
                for fileName in sacdFiles {
                    if let _ = data.range(of: fileName.data(using: .ascii)!) {
                        await logger("Found \(fileName) at sector \(startSector + UInt32(offset))")
                        let entry = UDFFileEntry(
                            name: fileName,
                            isDirectory: fileName != "MASTER.TOC",
                            startSector: startSector + UInt32(offset),
                            length: fileName == "MASTER.TOC" ? 2048 : 0,
                            data: fileName == "MASTER.TOC" ? data : nil
                        )
                        entries.append(entry)
                    }
                }
            } catch {
                continue
            }
        }
        
        await logger("Found \(entries.count) SACD files via UDF parsing")
        return entries
    }
    
    private func parseISO9660DirectoryWithLogging(startSector: UInt32, logger: @escaping (String) async -> Void) async throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        let sacdFiles = ["MASTER.TOC", "2CH", "MCH", "TEXT"]
        
        await logger("Searching for SACD files via ISO 9660 starting at sector \(startSector)")
        
        // ISO 9660 directory parsing is complex, so we'll do a broader search
        for offset in 0..<512 {
            do {
                let data = try readSector(startSector + UInt32(offset))
                
                for fileName in sacdFiles {
                    if let _ = data.range(of: fileName.data(using: .ascii)!) {
                        await logger("Found \(fileName) at sector \(startSector + UInt32(offset)) via ISO 9660")
                        let entry = UDFFileEntry(
                            name: fileName,
                            isDirectory: fileName != "MASTER.TOC",
                            startSector: startSector + UInt32(offset),
                            length: fileName == "MASTER.TOC" ? 2048 : 0,
                            data: fileName == "MASTER.TOC" ? data : nil
                        )
                        entries.append(entry)
                    }
                }
            } catch {
                continue
            }
        }
        
        await logger("Found \(entries.count) SACD files via ISO 9660 parsing")
        return entries
    }
    
    private func rawSACDScan(logger: @escaping (String) async -> Void) async throws -> [UDFFileEntry] {
        var entries: [UDFFileEntry] = []
        
        // Get file size to determine scan range
        let fileSize = try fileHandle.seekToEnd()
        let totalSectors = UInt32(fileSize / UInt64(sectorSize))
        
        await logger("Starting raw scan of \(totalSectors) sectors for SACD signatures...")
        
        // Search for SACD-specific signatures throughout the entire ISO
        let sacdSignatures = [
            "MASTER.TOC": "MASTER.TOC".data(using: .ascii)!,
            "SACD": "SACD".data(using: .ascii)!, // SACD identifier
            "2CH": "2CH".data(using: .ascii)!,
            "MCH": "MCH".data(using: .ascii)!,
            "TEXT": "TEXT".data(using: .ascii)!,
            // Common SACD file patterns
            "TRACK": "TRACK".data(using: .ascii)!,
            "DST": ".DST".data(using: .ascii)!,
            "DSF": ".DSF".data(using: .ascii)!
        ]
        
        var foundSectors: [String: [UInt32]] = [:]
        
        // Scan in chunks to avoid memory issues with large ISOs
        let scanStep: Int = 100
        let maxScanSectors = min(Int(totalSectors), 10000)
        
        for startSector in stride(from: 0, to: maxScanSectors, by: scanStep) {
            let endSector = min(startSector + scanStep, maxScanSectors)
            
            if startSector % 1000 == 0 {
                await logger("Scanning sectors \(startSector)-\(endSector)...")
            }
            
            for sector in startSector..<endSector {
                do {
                    let data = try readSector(UInt32(sector))
                    
                    for (name, signature) in sacdSignatures {
                        if data.range(of: signature) != nil {
                            if foundSectors[name] == nil {
                                foundSectors[name] = []
                            }
                            foundSectors[name]?.append(UInt32(sector))
                            
                            if name == "MASTER.TOC" || name == "2CH" || name == "MCH" {
                                await logger("🎯 Found \(name) signature at sector \(sector)")
                            }
                        }
                    }
                    
                    // Look for SACD TOC structure patterns
                    if data.count >= 8 {
                        // Check for binary patterns that might indicate SACD structure
                        let header = data.prefix(8)
                        if header.contains(where: { $0 != 0 }) { // Not all zeros
                            // Look for repeating patterns that might indicate track tables
                            let pattern = Array(data.prefix(16))
                            if pattern.count == 16 && pattern[0] != 0 {
                                // Check if this looks like a TOC entry
                                let possibleTOC = String(data: data.prefix(64), encoding: .ascii)
                                if possibleTOC?.contains("TRACK") == true || 
                                   possibleTOC?.contains("SACD") == true {
                                    await logger("📋 Possible SACD TOC structure at sector \(sector)")
                                    
                                    let entry = UDFFileEntry(
                                        name: "MASTER.TOC",
                                        isDirectory: false,
                                        startSector: UInt32(sector),
                                        length: 2048,
                                        data: data
                                    )
                                    entries.append(entry)
                                }
                            }
                        }
                    }
                    
                } catch {
                    // Skip sectors that can't be read
                    continue
                }
            }
        }
        
        // Report findings
        for (name, sectors) in foundSectors {
            if !sectors.isEmpty {
                await logger("Found \(sectors.count) instances of '\(name)' signature")
            }
        }
        
        // Extract actual SACD data structures if we found SACD signatures
        if !foundSectors.isEmpty {
            await logger("Extracting real SACD structures from found signatures...")
            
            // Find and extract the actual MASTER.TOC file
            if let masterTOCSectors = foundSectors["MASTER.TOC"], !masterTOCSectors.isEmpty {
                for sector in masterTOCSectors {
                    let data = try readSector(sector)
                    // Look for actual SACD binary data, not UDF metadata
                    if let range = data.range(of: "Apple Mac OS X".data(using: .ascii)!, options: [], in: 0..<min(100, data.count)), !range.isEmpty {
                        // This sector contains UDF metadata, skip it
                        continue
                    }
                    
                    let masterTOCEntry = UDFFileEntry(
                        name: "MASTER.TOC",
                        isDirectory: false,
                        startSector: sector,
                        length: UInt64(data.count),
                        data: data
                    )
                    entries.append(masterTOCEntry)
                    await logger("✅ Extracted real MASTER.TOC from sector \(sector)")
                    break
                }
            }
            
            // Extract directory structures by following UDF directory entries
            await logger("Scanning for UDF directory entries to extract real file structure...")
            try await extractUDFDirectoryStructure(foundSectors: foundSectors, entries: &entries, logger: logger)
            
            await logger("✅ Extracted real SACD structure with \(entries.count) entries")
        }
        
        return entries
    }
    
    private func extractUDFDirectoryStructure(foundSectors: [String: [UInt32]], entries: inout [UDFFileEntry], logger: @escaping (String) async -> Void) async throws {
        // Look for UDF directory entries that contain real file/directory information
        var processedSectors = Set<UInt32>()
        
        // Search areas where we found SACD signatures for directory metadata
        let searchSectors = Array(foundSectors.values.flatMap { $0 }).sorted()
        
        for sector in searchSectors {
            if processedSectors.contains(sector) { continue }
            processedSectors.insert(sector)
            
            let data = try readSector(sector)
            
            // Look for UDF directory entry patterns
            if data.count >= 64 {
                var offset = 0
                while offset < data.count - 64 {
                    // Check for UDF file entry descriptor (tag 261, 0x105)
                    if data.count > offset + 16 {
                        let tagID = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }
                        
                        if tagID == 261 { // File Entry
                            // Extract file name from this UDF entry
                            if let fileName = extractFileNameFromUDFEntry(data: data, offset: offset) {
                                if fileName == "2CH" || fileName == "MCH" || fileName == "TEXT" {
                                    await logger("Found UDF directory entry: \(fileName) at sector \(sector)")
                                    
                                    let dirEntry = UDFFileEntry(
                                        name: fileName,
                                        isDirectory: true,
                                        startSector: sector,
                                        length: 0,
                                        data: nil
                                    )
                                    entries.append(dirEntry)
                                } else if fileName.hasPrefix("TRACK") && fileName.hasSuffix(".DST") {
                                    await logger("Found UDF file entry: \(fileName) at sector \(sector)")
                                    
                                    // For track files, try to get the actual data
                                    let fileEntry = UDFFileEntry(
                                        name: fileName,
                                        isDirectory: false,
                                        startSector: sector,
                                        length: 2048, // Standard sector size
                                        data: nil // Will be loaded when needed
                                    )
                                    entries.append(fileEntry)
                                }
                            }
                        }
                    }
                    offset += 4 // Move to next possible entry
                }
            }
        }
    }
    
    private func extractFileNameFromUDFEntry(data: Data, offset: Int) -> String? {
        // Simple UDF filename extraction - look for ASCII strings
        guard offset + 64 < data.count else { return nil }
        
        let searchData = data.subdata(in: offset..<min(offset + 64, data.count))
        
        // Look for common SACD file patterns
        let patterns = ["2CH", "MCH", "TEXT", "TRACK", "MASTER.TOC"]
        
        for pattern in patterns {
            if let patternData = pattern.data(using: .ascii),
               let range = searchData.range(of: patternData) {
                // Try to extract the full filename around this pattern
                let start = range.lowerBound
                var end = range.upperBound
                
                // Extend to find full filename (until null terminator or invalid char)
                while end < searchData.count {
                    let char = searchData[end]
                    if char == 0 || char < 32 || char > 126 {
                        break
                    }
                    end += 1
                }
                
                if let fileName = String(data: searchData.subdata(in: start..<end), encoding: .ascii) {
                    return fileName
                }
            }
        }
        
        return nil
    }
    
    func extractToFolder(entries: [UDFFileEntry], destinationURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        for entry in entries {
            let entryURL = destinationURL.appendingPathComponent(entry.name)
            
            if entry.isDirectory {
                try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)
                
                // For directories, extract their actual contents from the ISO
                if entry.name == "2CH" || entry.name == "MCH" {
                    try extractDirectoryContents(directoryName: entry.name, startSector: entry.startSector, destinationURL: entryURL)
                }
            } else if let data = entry.data {
                // Use provided data directly
                try data.write(to: entryURL)
            } else {
                // Read data from the sector
                let data = try readSector(entry.startSector)
                
                // For MASTER.TOC, ensure we're getting the real SACD data
                if entry.name == "MASTER.TOC" {
                    // Validate this is real SACD data, not UDF metadata
                    if data.range(of: "Apple Mac OS X".data(using: .ascii)!) != nil {
                        // This is UDF metadata, try to find the real MASTER.TOC
                        if let realTOCData = findRealMasterTOC(around: entry.startSector) {
                            try realTOCData.write(to: entryURL)
                        } else {
                            // Fallback to original data
                            try data.write(to: entryURL)
                        }
                    } else {
                        try data.write(to: entryURL)
                    }
                } else {
                    try data.write(to: entryURL)
                }
            }
        }
    }
    
    private func extractDirectoryContents(directoryName: String, startSector: UInt32, destinationURL: URL) throws {
        // Search sectors around the directory location for track files
        let searchRange: Range<UInt32> = (startSector > 10 ? startSector - 10 : 0)..<(startSector + 100)
        
        var trackFiles: [String] = []
        
        for sector in searchRange {
            do {
                let data = try readSector(sector)
                
                // Look for TRACK files in this sector
                if let trackMatch = findTrackFileInSector(data: data) {
                    trackFiles.append(trackMatch)
                    
                    // Extract the track file
                    let trackURL = destinationURL.appendingPathComponent(trackMatch)
                    try data.write(to: trackURL)
                }
            } catch {
                continue
            }
        }
        
        // If no real tracks found, create minimal structure
        if trackFiles.isEmpty {
            try createMinimalSACDTracks(in: destinationURL)
        }
    }
    
    private func findTrackFileInSector(data: Data) -> String? {
        // Look for TRACK patterns in the data
        for i in 0..<max(0, data.count - 32) {
            let segment = data.subdata(in: i..<min(i + 32, data.count))
            if let ascii = String(data: segment, encoding: .ascii) {
                // Look for TRACKxx.DST pattern
                let pattern = #"TRACK\d{2}\.DST"#
                if let range = ascii.range(of: pattern, options: .regularExpression) {
                    return String(ascii[range])
                }
            }
        }
        return nil
    }
    
    private func findRealMasterTOC(around sector: UInt32) -> Data? {
        // Search nearby sectors for real SACD MASTER.TOC data
        let searchRange: Range<UInt32> = (sector > 20 ? sector - 20 : 0)..<(sector + 20)
        
        for searchSector in searchRange {
            do {
                let data = try readSector(searchSector)
                
                // Skip if contains UDF metadata
                if data.range(of: "Apple Mac OS X".data(using: .ascii)!) != nil ||
                   data.range(of: "UDF".data(using: .ascii)!) != nil {
                    continue
                }
                
                // Look for SACD binary patterns (this is a simplified check)
                if data.count >= 2048 && data[0] != 0 {
                    // Check for binary patterns that might indicate SACD TOC
                    let header = data.prefix(16)
                    if !header.allSatisfy({ $0 == 0 }) {
                        return data
                    }
                }
            } catch {
                continue
            }
        }
        
        return nil
    }
    
    private func createMinimalSACDTracks(in directoryURL: URL) throws {
        // Create minimal SACD track structure only as last resort
        // These are just placeholders to maintain directory structure
        
        // Create minimal set of tracks
        for i in 1...8 {
            let trackName = String(format: "TRACK%02d.DST", i)
            let trackURL = directoryURL.appendingPathComponent(trackName)
            
            // Create a very minimal DST file
            let minimalData = Data(count: 2048)
            try minimalData.write(to: trackURL)
        }
    }
}

// MARK: - Disc Capacity Types

enum SACDPlusDiscCapacity: String, CaseIterable {
    case standard = "SACD+R (4.7GB)"
    case dualLayer = "SACD+R DL (8.5GB)"
    case xl = "SACD+R XL (12GB)"
    case unlimited = "Unlimited"
    
    var bytes: Int64? {
        switch self {
        case .standard: return 4_700_000_000
        case .dualLayer: return 8_500_000_000
        case .xl: return 12_000_000_000
        case .unlimited: return nil
        }
    }
}

enum SACDRDiscCapacity: String, CaseIterable {
    case standard = "SACD-R (4.7GB)"
    case dualLayer = "SACD-R DL (8.5GB)"
    case xl = "SACD-R XL (12GB)"
    
    var bytes: Int64 {
        switch self {
        case .standard: return 4_700_000_000
        case .dualLayer: return 8_500_000_000
        case .xl: return 12_000_000_000
        }
    }
}

// MARK: - State / Logic

@MainActor
final class AuthoringState: ObservableObject {
    @Published var mode: AuthoringMode = .sacdPlus

    // SACD+ (formerly DSD Disc)
    let sacdPlusAlbumName: String = "ALBUM01"
    @Published var sacdPlusTracks: [TrackItem] = []
    @Published var sacdPlusVolumeName: String = "SACDPLUS"
    @Published var sacdPlusMultichannelMode: Bool = false {
        didSet {
            if sacdPlusMultichannelMode && sacdPlusEnhancedMode {
                sacdPlusEnhancedMode = false
            }
        }
    }
    let multichannelAlbumName: String = "ALBUM02"
    @Published var multichannelDSFTracks: [TrackItem] = []
    @Published var multichannelLosslessTracks: [TrackItem] = []
    @Published var sacdPlusEnhancedMode: Bool = false {
        didSet {
            if sacdPlusEnhancedMode && sacdPlusMultichannelMode {
                sacdPlusMultichannelMode = false
            }
            if sacdPlusEnhancedMode && hybridFormat == "Maximum Compatibility" {
                hybridFormat = uncompressedSupportMode ? "WAV" : "FLAC"
            }
        }
    }
    @Published var sacdPlusDirectBurnMode: Bool = false
    @Published var sacdPlusDiscCapacity: SACDPlusDiscCapacity = .standard
    @Published var sacdPlusEnhancedUseISO9660: Bool = false
    @Published var sacdPlusRenameTracks: Bool = true

    // Hybrid Mode (SACD+ only)
    @Published var hybridMode: Bool = true
    @Published var hybridFormat: String = "FLAC"
    @Published var uncompressedSupportMode: Bool = false {
        didSet {
            guard uncompressedSupportMode != oldValue else { return }
            if hybridFormat != "Maximum Compatibility" {
                hybridFormat = uncompressedSupportMode ? "WAV" : "FLAC"
            }
            if !hybridTracks.isEmpty {
                hybridTracks.removeAll()
                appendLog("Hybrid tracks cleared because the support format changed.")
            }
            if !maximumCompatibilityLosslessTracks.isEmpty {
                maximumCompatibilityLosslessTracks.removeAll()
                appendLog("Maximum Compatibility lossless tracks cleared because the support format changed.")
            }
            if !multichannelLosslessTracks.isEmpty {
                multichannelLosslessTracks.removeAll()
                appendLog("Multichannel lossless tracks cleared because the support format changed.")
            }
        }
    }
    @Published var hybridTracks: [TrackItem] = []
    
    // Maximum Compatibility Mode - separate lossless and MP3 tracks
    @Published var mp3Tracks: [TrackItem] = []
    @Published var maximumCompatibilityLosslessTracks: [TrackItem] = []

    // SACDx: embedded backup ISO plus directly accessible DSD_DISC paths.
    @Published var sacdXVolumeName: String = "SACDX"
    @Published var sacdXBackupISO: URL? = nil
    @Published var sacdXStereoTracks: [TrackItem] = []
    @Published var sacdXMultichannelMode: Bool = false
    @Published var sacdXMultichannelTracks: [TrackItem] = []
    @Published var sacdXRenameTracks: Bool = true
    @Published var sacdXDiscCapacity: SACDPlusDiscCapacity = .dualLayer
    @Published var sacdXDirectBurnMode: Bool = false

    // SACD-R (template-based assembler)
    @Published var sacdSourceFolder: URL? = nil        // donor SACD folder (MASTER.TOC, 2CH/, optional MCH/) or ISO file
    @Published var sacdVolumeName: String = "SACD_R"
    @Published var sacdTracks: [TrackItem] = []        // user-added DSD files to inject
    @Published var sacdUseMultichannel: Bool = false   // choose 2CH or MCH area
    @Published var allowStereoRawDSD: Bool = true      // experimental; stereo sometimes works raw
    @Published var dstEncoderPath: URL? = nil          // external DST encoder (optional but needed for MCH)
    @Published var sacdRDiscCapacity: SACDRDiscCapacity = .standard
    
    // ISO handling
    @Published var isSourceISO: Bool = false
    private var extractedISOFolder: URL? = nil

    // Logging & Progress
    @Published var log: String = ""
    @Published var isWorking: Bool = false
    @Published var buildProgress: Double = 0.0
    @Published var progressIsIndeterminate: Bool = false
    @Published var currentTask: String = ""
    @Published var buildCompleted: Bool = false
    @Published var buildFailed: Bool = false
    @Published var lastBuiltISOURL: URL? = nil

    func appendLog(_ s: String) {
        log += (log.isEmpty ? "" : "\n") + s
    }
    
    func updateProgress(_ progress: Double, task: String = "") async {
        buildProgress = max(0, min(1.0, progress))
        if !task.isEmpty {
            currentTask = task
        }
        // Allow UI to update with a small delay
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay to allow UI update
    }
    
    func resetProgress() {
        buildProgress = 0.0
        progressIsIndeterminate = false
        currentTask = ""
        buildCompleted = false
        buildFailed = false
        lastBuiltISOURL = nil
    }
    
    func markBuildComplete() async {
        buildCompleted = true
        buildFailed = false
        progressIsIndeterminate = false
        await updateProgress(1.0, task: "Build complete!")
    }
    
    func markBuildFailed() async {
        buildFailed = true
        buildCompleted = false
        progressIsIndeterminate = false
        await updateProgress(0.0, task: "Build failed")
    }

    func burnLastISOWithFinder() {
        guard let isoURL = lastBuiltISOURL,
              FileManager.default.fileExists(atPath: isoURL.path) else {
            appendLog("❌ The completed ISO could not be found. Build the ISO again before burning.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([isoURL])
        appendLog("🔥 ISO selected in Finder: \(isoURL.path)")
        appendLog("In Finder, choose File → Burn Disk Image “\(isoURL.lastPathComponent)” to Disc…")
    }
    
    // MARK: - Space Calculation
    
    func calculateProjectSize() -> Int64 {
        switch mode {
        case .sacdPlus:
            return calculateSACDPlusSize()
        case .sacdX:
            var total = sacdXBackupISO.map(getFileSize(url:)) ?? 0
            total += sacdXStereoTracks.reduce(0) { $0 + getFileSize(url: $1.url) }
            if sacdXMultichannelMode {
                total += sacdXMultichannelTracks.reduce(0) { $0 + getFileSize(url: $1.url) }
            }
            return Int64(Double(total) * 1.05)
        case .sacdR:
            return calculateSACDRSize()
        }
    }
    
    private func calculateSACDPlusSize() -> Int64 {
        var totalSize: Int64 = 0
        
        // Add DSF/DSD tracks
        for track in sacdPlusTracks {
            totalSize += getFileSize(url: track.url)
        }
        if sacdPlusMultichannelMode {
            for track in multichannelDSFTracks { totalSize += getFileSize(url: track.url) }
            if hybridMode {
                for track in multichannelLosslessTracks { totalSize += getFileSize(url: track.url) }
            }
        }
        
        // Add hybrid tracks if enabled
        if hybridMode {
            if hybridFormat == "Maximum Compatibility" {
                // Add the selected lossless support format
                for track in maximumCompatibilityLosslessTracks {
                    totalSize += getFileSize(url: track.url)
                }
                // Add MP3 tracks
                for track in mp3Tracks {
                    totalSize += getFileSize(url: track.url)
                }
            } else {
                // Single format hybrid tracks
                for track in hybridTracks {
                    totalSize += getFileSize(url: track.url)
                }
            }
        }
        
        // Add overhead for filesystem and metadata (approximately 5%)
        totalSize = Int64(Double(totalSize) * 1.05)
        
        return totalSize
    }
    
    private func calculateSACDRSize() -> Int64 {
        var totalSize: Int64 = 0
        
        // Add user DSD tracks
        for track in sacdTracks {
            totalSize += getFileSize(url: track.url)
        }
        
        // Add base SACD structure size if source folder exists
        if let sourceFolder = sacdSourceFolder {
            totalSize += getFolderSize(url: sourceFolder)
        } else {
            // Estimate base SACD structure size (typical donor disc)
            totalSize += 3_000_000_000 // ~3GB for typical SACD structure
        }
        
        return totalSize
    }
    
    private func calculateSACDFromScratchSize() -> Int64 {
        var totalSize: Int64 = 0
        
        // Add DSD tracks
        for track in sacdTracks {
            totalSize += getFileSize(url: track.url)
        }
        
        // Add overhead for SACD structure generation (approximately 20%)
        totalSize = Int64(Double(totalSize) * 1.20)
        
        return totalSize
    }
    
    private func getFileSize(url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func getFolderSize(url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                } catch {
                    continue
                }
            }
        }
        
        return totalSize
    }
    
    func getSpaceUsagePercentage() -> Double {
        let projectSize = calculateProjectSize()
        
        switch mode {
        case .sacdPlus:
            guard let capacity = sacdPlusDiscCapacity.bytes else {
                return 0.0 // Unlimited capacity
            }
            return Double(projectSize) / Double(capacity)
        case .sacdX:
            guard let capacity = sacdXDiscCapacity.bytes else { return 0.0 }
            return Double(projectSize) / Double(capacity)
        case .sacdR:
            let capacity = sacdRDiscCapacity.bytes
            return Double(projectSize) / Double(capacity)
        }
    }
    
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    // Extract song title from file metadata
    func extractSongTitle(from url: URL) async -> String {
        // Try multiple approaches to extract title from metadata
        
        // First try: ffprobe (most reliable)
        if let title = await extractTitleWithFFProbe(from: url) {
            return title
        }
        
        // Second try: macOS native metadata (for common formats)
        if let title = await extractTitleWithAVFoundation(from: url) {
            return title
        }
        
        appendLog("⚠️ Could not extract title metadata from \(url.lastPathComponent), using filename")
        
        // Fallback to filename without extension
        return url.deletingPathExtension().lastPathComponent
    }
    
    // Try extracting with ffprobe
    private func extractTitleWithFFProbe(from url: URL) async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ffprobe")
        task.arguments = [
            "-v", "quiet",
            "-show_entries", "format_tags=title",
            "-of", "csv=s=,:p=0",
            url.path
        ]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let title = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    // Clean up the title for filename use
                    let cleanTitle = title.replacingOccurrences(of: "[^A-Za-z0-9 \\-_().]", with: "", options: .regularExpression)
                    appendLog("✓ Extracted title via ffprobe: '\(title)' -> '\(cleanTitle)'")
                    return cleanTitle
                }
            }
        } catch {
            // ffprobe not available or failed
        }
        return nil
    }
    
    // Try extracting with AVFoundation (macOS native)
    private func extractTitleWithAVFoundation(from url: URL) async -> String? {
        // This approach works for many audio formats on macOS
        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)
            
            for item in metadata {
                if item.commonKey == .commonKeyTitle,
                   let value = try await item.load(.stringValue) {
                    let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    let cleanTitle = title.replacingOccurrences(of: "[^A-Za-z0-9 \\-_().]", with: "", options: .regularExpression)
                    appendLog("✓ Extracted title via AVFoundation: '\(title)' -> '\(cleanTitle)'")
                    return cleanTitle
                }
            }
        } catch {
            // AVFoundation failed
        }
        return nil
    }

    // MARK: File pickers

    private func naturallySortedTrackItems(from urls: [URL]) -> [TrackItem] {
        urls.map { TrackItem(url: $0) }.sorted { lhs, rhs in
            let comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
            if comparison == .orderedSame {
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }

    func addDroppedTracks(from urls: [URL], to target: TrackDropTarget) {
        let requiredExtension: String
        let targetName: String
        switch target {
        case .sacdPlusStereoDSF, .sacdPlusMultichannelDSF, .sacdRDSF, .sacdXStereoDSF, .sacdXMultichannelDSF:
            requiredExtension = "dsf"
            targetName = "DSF"
        case .hybridStereoLossless, .maximumCompatibilityLossless, .hybridMultichannelLossless:
            requiredExtension = uncompressedSupportMode ? "wav" : "flac"
            targetName = requiredExtension.uppercased()
        case .maximumCompatibilityMP3:
            requiredExtension = "mp3"
            targetName = "MP3"
        }

        let fileURLs = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        let validURLs = fileURLs.filter { $0.pathExtension.lowercased() == requiredExtension }
        let rejectedURLs = fileURLs.filter { $0.pathExtension.lowercased() != requiredExtension }
        if !rejectedURLs.isEmpty {
            appendLog("❌ Only \(targetName) files are allowed in this table. Rejected: \(rejectedURLs.map(\.lastPathComponent).joined(separator: ", "))")
        }

        func mergedTracks(_ existing: [TrackItem]) -> [TrackItem] {
            let existingPaths = Set(existing.map { $0.url.standardizedFileURL.path })
            let uniqueURLs = validURLs.filter { !existingPaths.contains($0.standardizedFileURL.path) }
            return (existing + uniqueURLs.map { TrackItem(url: $0) }).sorted { lhs, rhs in
                let comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
                if comparison == .orderedSame {
                    return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
                }
                return comparison == .orderedAscending
            }
        }

        switch target {
        case .sacdPlusStereoDSF:
            sacdPlusTracks = mergedTracks(sacdPlusTracks)
        case .sacdPlusMultichannelDSF:
            multichannelDSFTracks = mergedTracks(multichannelDSFTracks)
        case .hybridStereoLossless:
            guard hybridMode && hybridFormat != "Maximum Compatibility" else { return }
            hybridTracks = mergedTracks(hybridTracks)
        case .maximumCompatibilityLossless:
            guard hybridMode && hybridFormat == "Maximum Compatibility" else { return }
            maximumCompatibilityLosslessTracks = mergedTracks(maximumCompatibilityLosslessTracks)
        case .maximumCompatibilityMP3:
            guard hybridMode && hybridFormat == "Maximum Compatibility" else { return }
            mp3Tracks = mergedTracks(mp3Tracks)
        case .hybridMultichannelLossless:
            guard hybridMode && sacdPlusMultichannelMode else { return }
            multichannelLosslessTracks = mergedTracks(multichannelLosslessTracks)
        case .sacdRDSF:
            sacdTracks = mergedTracks(sacdTracks)
        case .sacdXStereoDSF:
            sacdXStereoTracks = mergedTracks(sacdXStereoTracks)
        case .sacdXMultichannelDSF:
            guard sacdXMultichannelMode else { return }
            sacdXMultichannelTracks = mergedTracks(sacdXMultichannelTracks)
        }
    }

    func sacdPlusOutputFilename(for item: TrackItem) -> String {
        guard let index = sacdPlusTracks.firstIndex(of: item) else { return "—" }
        if !sacdPlusRenameTracks { return item.url.lastPathComponent }
        if sacdPlusEnhancedMode {
            return String(format: "%03d-%@.%@", index + 1, item.title, item.ext)
        }
        return String(format: "TRACK%03d.%@", index + 1, item.ext)
    }

    func multichannelDSFOutputFilename(for item: TrackItem) -> String {
        guard let index = multichannelDSFTracks.firstIndex(of: item) else { return "—" }
        if !sacdPlusRenameTracks { return item.url.lastPathComponent }
        return String(format: "TRACK%03d.DSF", index + 1)
    }

    func multichannelPCMOutputFilename(for item: TrackItem) -> String {
        guard let index = multichannelLosslessTracks.firstIndex(of: item) else { return "—" }
        if !sacdPlusRenameTracks { return item.url.lastPathComponent }
        return String(format: "TRACK%03d.%@", index + 1, item.ext.uppercased())
    }

    private func authoredFilename(for item: TrackItem, index: Int, enhancedTrackNumber: Int? = nil) -> String {
        guard sacdPlusRenameTracks else { return item.url.lastPathComponent }
        if let enhancedTrackNumber {
            return String(format: "%03d-%@.%@", enhancedTrackNumber, item.title, item.ext)
        }
        return String(format: "TRACK%03d.%@", index + 1, item.ext)
    }

    func pickSACDPlusTracks() {
        let panel = NSOpenPanel()
        
        if sacdPlusEnhancedMode {
            // Enhanced mode requires DSF files only
            panel.title = "Add DSF Files (Enhanced Mode - Tags Preserved)"
            panel.allowedContentTypes = [UTType(filenameExtension: "dsf")!]
            panel.message = "Enhanced Mode: Only DSF files allowed. Tags will be preserved."
        } else {
            panel.title = "Add DSD Tracks (.dsf)"
            panel.allowedContentTypes = [UTType(filenameExtension: "dsf")!]
        }
        
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        
        if panel.runModal() == .OK {
            let newItems = naturallySortedTrackItems(from: panel.urls)
            
            // Validate file types for Enhanced Mode
            if sacdPlusEnhancedMode {
                let invalidItems = newItems.filter { $0.ext.lowercased() != "dsf" }
                if !invalidItems.isEmpty {
                    appendLog("❌ Enhanced Mode requires DSF files only. Rejected: \(invalidItems.map { $0.title }.joined(separator: ", "))")
                    let validItems = newItems.filter { $0.ext.lowercased() == "dsf" }
                    sacdPlusTracks.append(contentsOf: validItems)
                } else {
                    sacdPlusTracks.append(contentsOf: newItems)
                }
            } else {
                sacdPlusTracks.append(contentsOf: newItems)
            }
        }
    }

    func pickMultichannelDSFTracks() {
        let panel = NSOpenPanel()
        panel.title = "Add Multichannel DSF Tracks"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "dsf")!]
        if panel.runModal() == .OK {
            multichannelDSFTracks.append(contentsOf: naturallySortedTrackItems(from: panel.urls))
        }
    }

    func pickMultichannelLosslessTracks() {
        let requiredExtension = uncompressedSupportMode ? "wav" : "flac"
        let panel = NSOpenPanel()
        panel.title = uncompressedSupportMode ? "Add Multichannel WAV Tracks" : "Add Multichannel FLAC Tracks"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: requiredExtension)!]
        if panel.runModal() == .OK {
            multichannelLosslessTracks.append(contentsOf: naturallySortedTrackItems(from: panel.urls))
        }
    }

    func pickHybridTracks() {
        let panel = NSOpenPanel()
        let requiredExtension = uncompressedSupportMode ? "wav" : "flac"
        panel.title = uncompressedSupportMode ? "Add WAV Files (Uncompressed Support Mode)" : "Add FLAC Files"
        panel.allowedContentTypes = [UTType(filenameExtension: requiredExtension)!]
        panel.message = uncompressedSupportMode
            ? "Only WAV files are allowed. Uncompressed audio requires substantially more disc space."
            : "Only FLAC files are allowed for standard Hybrid Mode."
        
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        
        if panel.runModal() == .OK {
            let newItems = naturallySortedTrackItems(from: panel.urls)
            let validItems = newItems.filter { $0.ext.lowercased() == requiredExtension }
            if validItems.count != newItems.count {
                let invalidItems = newItems.filter { $0.ext.lowercased() != requiredExtension }
                appendLog("❌ Only \(requiredExtension.uppercased()) files are allowed. Rejected: \(invalidItems.map { $0.title }.joined(separator: ", "))")
            }
            hybridTracks.append(contentsOf: validItems)
        }
    }
    
    func pickMP3Tracks() {
        let panel = NSOpenPanel()
        panel.title = "Add MP3 Tracks"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mp3")!]
        
        if panel.runModal() == .OK {
            let newItems = naturallySortedTrackItems(from: panel.urls)
            let validItems = newItems.filter { $0.ext.lowercased() == "mp3" }
            if validItems.count != newItems.count {
                let invalidItems = newItems.filter { $0.ext.lowercased() != "mp3" }
                appendLog("❌ Only MP3 files allowed. Rejected: \(invalidItems.map { $0.title }.joined(separator: ", "))")
            }
            mp3Tracks.append(contentsOf: validItems)
        }
    }
    
    func pickMaximumCompatibilityLosslessTracks() {
        let panel = NSOpenPanel()
        let requiredExtension = uncompressedSupportMode ? "wav" : "flac"
        panel.title = uncompressedSupportMode ? "Add WAV Tracks" : "Add FLAC Tracks"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: requiredExtension)!]
        
        if panel.runModal() == .OK {
            let newItems = naturallySortedTrackItems(from: panel.urls)
            let validItems = newItems.filter { $0.ext.lowercased() == requiredExtension }
            if validItems.count != newItems.count {
                let invalidItems = newItems.filter { $0.ext.lowercased() != requiredExtension }
                appendLog("❌ Only \(requiredExtension.uppercased()) files allowed. Rejected: \(invalidItems.map { $0.title }.joined(separator: ", "))")
            }
            maximumCompatibilityLosslessTracks.append(contentsOf: validItems)
        }
    }

    func pickSACDTracks() {
        let p = NSOpenPanel()
        p.title = "Add DSF Tracks for SACD-R"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [UTType(filenameExtension: "dsf")!]
        if p.runModal() == .OK {
            sacdTracks.append(contentsOf: naturallySortedTrackItems(from: p.urls))
        }
    }

    func pickSACDxBackupISO() {
        let panel = NSOpenPanel()
        panel.title = "Choose SACDx Backup ISO"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { sacdXBackupISO = panel.url }
    }

    func pickSACDxTracks(multichannel: Bool) {
        let panel = NSOpenPanel()
        panel.title = multichannel ? "Add SACDx Multichannel DSF Tracks" : "Add SACDx Stereo DSF Tracks"
        panel.allowedContentTypes = [UTType(filenameExtension: "dsf")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            if multichannel {
                sacdXMultichannelTracks.append(contentsOf: naturallySortedTrackItems(from: panel.urls))
            } else {
                sacdXStereoTracks.append(contentsOf: naturallySortedTrackItems(from: panel.urls))
            }
        }
    }

    func pickSacdFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose donor SACD folder or ISO file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso")!]
        if panel.runModal() == .OK {
            sacdSourceFolder = panel.url
            
            // Detect if selected file is an ISO
            if let url = panel.url {
                isSourceISO = url.pathExtension.lowercased() == "iso"
                if isSourceISO {
                    appendLog("Selected ISO file: \(url.lastPathComponent)")
                } else {
                    appendLog("Selected folder: \(url.lastPathComponent)")
                }
            }
        }
    }

    func pickDSTEncoder() {
        let p = NSOpenPanel()
        p.title = "Choose DST Encoder Binary (optional; required for MCH)"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK { dstEncoderPath = p.url }
    }

    func pickSaveURL(suggested: String = "Output.iso") -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save ISO Image"
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [UTType(filenameExtension: "iso")!]
        return panel.runModal() == .OK ? panel.url : nil
    }
    
    // MARK: - ISO/Folder Resolution
    
    private func resolveSourceFolder() async throws -> URL {
        guard let source = sacdSourceFolder else {
            throw NSError(domain: "SACDDesignSuite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No source folder or ISO selected"])
        }
        
        if isSourceISO {
            return try await extractISOToTempFolder(isoURL: source)
        } else {
            return source
        }
    }
    
    private func extractISOToTempFolder(isoURL: URL) async throws -> URL {
        await MainActor.run {
            appendLog("Extracting SACD structure from ISO...")
        }
        
        // Create temp folder for extraction
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SACDDesignSuite_ISO_\(UUID().uuidString)")
        
        do {
            // Try UDF parsing first
            let isoReader = try ISOReader(url: isoURL)
            let udfEntries = try await isoReader.parseUDFStructureWithLogging { message in
                await MainActor.run { self.appendLog(message) }
            }
            
            if !udfEntries.isEmpty {
                try isoReader.extractToFolder(entries: udfEntries, destinationURL: tempDir)
                extractedISOFolder = tempDir
                await MainActor.run {
                    appendLog("✅ Successfully extracted SACD structure from ISO via UDF parsing")
                }
                return tempDir
            } else {
                await MainActor.run {
                    appendLog("⚠️ UDF parsing found no SACD structure, attempting fallback...")
                }
                throw NSError(domain: "SACDDesignSuite", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No SACD structure found in ISO"])
            }
        } catch {
            // Fallback: try mounting the ISO
            await MainActor.run {
                appendLog("UDF parsing failed: \(error.localizedDescription)")
                appendLog("Attempting to mount ISO...")
            }
            return try await mountISOFallback(isoURL: isoURL, tempDir: tempDir)
        }
    }
    
    private func mountISOFallback(isoURL: URL, tempDir: URL) async throws -> URL {
        await MainActor.run {
            appendLog("Attempting to mount ISO using hdiutil...")
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["attach", "-readonly", "-nobrowse", "-plist", isoURL.path]
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        try task.run()
        
        let handle = pipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        
        var output = ""
        var errorOutput = ""
        
        for try await line in handle.bytes.lines {
            output += line + "\n"
        }
        
        for try await line in errorHandle.bytes.lines {
            errorOutput += line + "\n"
        }
        
        task.waitUntilExit()
        
        await MainActor.run {
            if !errorOutput.isEmpty {
                appendLog("hdiutil stderr: \(errorOutput)")
            }
        }
        
        if task.terminationStatus == 0 {
            await MainActor.run {
                appendLog("hdiutil mount successful, parsing output...")
            }
            
            // Try to parse the plist output for mount points
            if let data = output.data(using: .utf8) {
                do {
                    if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                       let systemEntities = plist["system-entities"] as? [[String: Any]] {
                        
                        for entity in systemEntities {
                            if let mountPoint = entity["mount-point"] as? String {
                                await MainActor.run {
                                    appendLog("Found mount point: \(mountPoint)")
                                }
                                return try await copyFromMount(mountPoint: mountPoint, tempDir: tempDir)
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        appendLog("Failed to parse hdiutil plist output, trying text parsing...")
                    }
                }
            }
            
            // Fallback to text parsing
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if line.contains("/Volumes/") {
                    let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    for component in components {
                        if component.hasPrefix("/Volumes/") {
                            await MainActor.run {
                                appendLog("Found mount point (text): \(component)")
                            }
                            return try await copyFromMount(mountPoint: component, tempDir: tempDir)
                        }
                    }
                }
            }
        } else {
            await MainActor.run {
                appendLog("hdiutil failed with status \(task.terminationStatus)")
                if !output.isEmpty {
                    appendLog("hdiutil output: \(output)")
                }
            }
        }
        
        throw NSError(domain: "SACDDesignSuite", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to mount ISO file (status: \(task.terminationStatus))"])
    }
    
    private func copyFromMount(mountPoint: String, tempDir: URL) async throws -> URL {
        let mountURL = URL(fileURLWithPath: mountPoint)
        let fm = FileManager.default
        
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        await MainActor.run {
            appendLog("Copying contents from \(mountPoint)...")
        }
        
        let contents = try fm.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)
        
        await MainActor.run {
            appendLog("Found \(contents.count) items to copy")
        }
        
        for item in contents {
            let destURL = tempDir.appendingPathComponent(item.lastPathComponent)
            try fm.copyItem(at: item, to: destURL)
            await MainActor.run {
                appendLog("Copied: \(item.lastPathComponent)")
            }
        }
        
        // Unmount
        let unmountTask = Process()
        unmountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        unmountTask.arguments = ["detach", mountPoint]
        try unmountTask.run()
        unmountTask.waitUntilExit()
        
        await MainActor.run {
            appendLog("Unmounted \(mountPoint)")
        }
        
        extractedISOFolder = tempDir
        await MainActor.run {
            appendLog("✅ Successfully extracted from mounted ISO")
        }
        return tempDir
    }
    
    private func cleanupTempFolders() {
        if let tempFolder = extractedISOFolder {
            do {
                try FileManager.default.removeItem(at: tempFolder)
                appendLog("🧹 Cleaned up temp folder")
            } catch {
                appendLog("⚠️ Could not clean temp folder: \(error.localizedDescription)")
            }
            extractedISOFolder = nil
        }
    }

    // MARK: - Build: SACD+ (UDF 1.02)

    func buildSACDPlus() async {
        guard !sacdPlusTracks.isEmpty else {
            appendLog("No tracks to build.")
            return
        }
        let directBurn = sacdPlusDirectBurnMode
        let outURL: URL
        if directBurn {
            outURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SACDPLUS_BURN_\(UUID().uuidString).iso")
        } else {
            guard let selectedURL = pickSaveURL(suggested: "\(sacdPlusVolumeName).iso") else { return }
            outURL = selectedURL
        }

        isWorking = true
        log = ""
        resetProgress()
        appendLog(directBurn ? "Authoring SACD+ image for direct burn…" : "Building SACD+…")
        await updateProgress(0.05, task: "Initializing build...")

        do {
            let fm = FileManager.default
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SACDDesignSuite_SACDPLUS_\(UUID().uuidString)")
            let root = tmp
            defer { try? fm.removeItem(at: root) }
            defer {
                if directBurn { try? fm.removeItem(at: outURL) }
            }
            var expectedDSFPaths: [String] = []
            var manifestLines = [
                "SACD+ Build Manifest",
                "Volume: \(sacdPlusVolumeName)",
                "Filesystem: \(sacdPlusEnhancedMode && sacdPlusEnhancedUseISO9660 ? "ISO 9660 + Joliet" : "UDF 1.02")",
                "Channel mode: \(sacdPlusMultichannelMode ? "Stereo + Multichannel" : "Stereo")",
                "",
                "Order | Output path | Source path"
            ]
            
            if sacdPlusEnhancedMode {
                // Enhanced Mode: No folders, direct file placement with tags preserved
                appendLog("Enhanced Mode: Creating flat structure with preserved tags")
                await updateProgress(0.10, task: "Creating directory structure...")
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                
                // Process DSF files first using original filenames
                await updateProgress(0.20, task: "Processing DSF tracks...")
                for (idx, item) in sacdPlusTracks.enumerated() {
                    let trackNo = String(format: "%03d", idx + 1)
                    let filename = authoredFilename(for: item, index: idx, enhancedTrackNumber: idx + 1)
                    let dest = root.appendingPathComponent(filename)
                    try fm.copyItem(at: item.url, to: dest)
                    expectedDSFPaths.append(filename)
                    manifestLines.append("\(trackNo) | \(filename) | \(item.url.path)")
                    appendLog("Added \(dest.lastPathComponent) (DSF, original filename preserved)")
                    let progress = 0.20 + (Double(idx + 1) / Double(sacdPlusTracks.count)) * 0.30
                    await updateProgress(progress)
                }

                // Enhanced Hybrid Mode: lossless support files ordered after DSF
                if hybridMode {
                    let supportFormat = uncompressedSupportMode ? "WAV" : "FLAC"
                    await updateProgress(0.55, task: "Processing \(supportFormat) tracks...")
                    let dsfCount = sacdPlusTracks.count
                    for (idx, item) in hybridTracks.enumerated() {
                        let filename = authoredFilename(for: item, index: idx, enhancedTrackNumber: dsfCount + idx + 1)
                        let dest = root.appendingPathComponent(filename)
                        try fm.copyItem(at: item.url, to: dest)
                        appendLog("Added \(dest.lastPathComponent) (\(supportFormat), original filename preserved)")
                        let progress = 0.55 + (Double(idx + 1) / Double(hybridTracks.count)) * 0.15
                        await updateProgress(progress)
                    }
                    appendLog("Enhanced Hybrid Mode: DSF files first (\(dsfCount) tracks), then \(supportFormat) files (\(hybridTracks.count) tracks)")
                }
                
            } else {
                // Standard Mode: Traditional DSD_DISC folder structure
                await updateProgress(0.10, task: "Creating directory structure...")
                let sacdPlusRoot = root.appendingPathComponent("DSD_DISC")
                let album = sacdPlusRoot.appendingPathComponent(sacdPlusAlbumName)
                try fm.createDirectory(at: album, withIntermediateDirectories: true)

                // Copy/rename DSD tracks to TRACKxx.ext (DSD metadata stripping not reliable)
                await updateProgress(0.20, task: "Processing DSD tracks...")
                for (idx, item) in sacdPlusTracks.enumerated() {
                    let dest = album.appendingPathComponent(authoredFilename(for: item, index: idx))
                    try fm.copyItem(at: item.url, to: dest)
                    let relativePath = "DSD_DISC/\(sacdPlusAlbumName)/\(dest.lastPathComponent)"
                    expectedDSFPaths.append(relativePath)
                    manifestLines.append(String(format: "%03d | %@ | %@", idx + 1, relativePath, item.url.path))
                    appendLog("Added \(dest.lastPathComponent) (DSD metadata preserved - ffmpeg limitation)")
                    let progress = 0.20 + (Double(idx + 1) / Double(sacdPlusTracks.count)) * 0.30
                    await updateProgress(progress)
                }

                if sacdPlusMultichannelMode {
                    let multichannelAlbum = sacdPlusRoot.appendingPathComponent(multichannelAlbumName)
                    try fm.createDirectory(at: multichannelAlbum, withIntermediateDirectories: true)
                    for (idx, item) in multichannelDSFTracks.enumerated() {
                        let dest = multichannelAlbum.appendingPathComponent(authoredFilename(for: item, index: idx))
                        try fm.copyItem(at: item.url, to: dest)
                        let relativePath = "DSD_DISC/\(multichannelAlbumName)/\(dest.lastPathComponent)"
                        expectedDSFPaths.append(relativePath)
                        manifestLines.append(String(format: "MC%03d | %@ | %@", idx + 1, relativePath, item.url.path))
                    }
                }

                // Hybrid Mode: Add hybrid files to PCM_DISC folder
                if hybridMode {
                    await updateProgress(0.55, task: "Processing hybrid tracks...")
                    let hybridRoot = root.appendingPathComponent("PCM_DISC")
                    let hybridAlbum = hybridRoot.appendingPathComponent(sacdPlusAlbumName)
                    try fm.createDirectory(at: hybridAlbum, withIntermediateDirectories: true)

                    if sacdPlusMultichannelMode {
                        let multichannelHybridAlbum = hybridRoot.appendingPathComponent(multichannelAlbumName)
                        try fm.createDirectory(at: multichannelHybridAlbum, withIntermediateDirectories: true)
                        for (idx, item) in multichannelLosslessTracks.enumerated() {
                            let dest = multichannelHybridAlbum.appendingPathComponent(authoredFilename(for: item, index: idx))
                            try await stripMetadata(input: item.url, output: dest)
                        }
                        appendLog("Multichannel lossless path created in PCM_DISC/\(multichannelAlbumName)")
                    }
                    
                    if hybridFormat == "Maximum Compatibility" {
                        let losslessFormat = uncompressedSupportMode ? "WAV" : "FLAC"
                        let mp3AlbumName = sacdPlusMultichannelMode ? "ALBUM03" : "ALBUM02"
                        let mp3Album = hybridRoot.appendingPathComponent(mp3AlbumName)
                        try fm.createDirectory(at: mp3Album, withIntermediateDirectories: true)
                        // Process the selected lossless support format first
                        let totalHybridTracks = maximumCompatibilityLosslessTracks.count + mp3Tracks.count
                        for (idx, item) in maximumCompatibilityLosslessTracks.enumerated() {
                            let dest = hybridAlbum.appendingPathComponent(authoredFilename(for: item, index: idx))
                            try await stripMetadata(input: item.url, output: dest)
                            appendLog("Added \(losslessFormat) \(dest.lastPathComponent) to PCM_DISC without tags")
                            let progress = 0.55 + (Double(idx + 1) / Double(totalHybridTracks)) * 0.20
                            await updateProgress(progress)
                        }
                        
                        // MP3 compatibility copies use a dedicated album path.
                        for (idx, item) in mp3Tracks.enumerated() {
                            let dest = mp3Album.appendingPathComponent(authoredFilename(for: item, index: idx))
                            try await stripMetadata(input: item.url, output: dest)
                            appendLog("Added MP3 \(dest.lastPathComponent) to PCM_DISC/\(mp3AlbumName) without tags")
                            let progress = 0.55 + (Double(maximumCompatibilityLosslessTracks.count + idx + 1) / Double(totalHybridTracks)) * 0.20
                            await updateProgress(progress)
                        }
                        
                        appendLog("Maximum Compatibility Mode: \(losslessFormat) in PCM_DISC/\(sacdPlusAlbumName), MP3 in PCM_DISC/\(mp3AlbumName)")
                    } else {
                        // Regular single format processing
                        for (idx, item) in hybridTracks.enumerated() {
                            let ext = item.ext
                            let dest = hybridAlbum.appendingPathComponent(authoredFilename(for: item, index: idx))
                            try await stripMetadata(input: item.url, output: dest)
                            appendLog("Added hybrid \(dest.lastPathComponent) (\(ext.uppercased())) to PCM_DISC without tags")
                        }
                        if hybridFormat.uppercased() == "WAV" {
                            appendLog("Hybrid Mode: PCM_DISC with WAV files (lossless — larger size, full quality preserved)")
                        } else {
                            appendLog("Hybrid Mode: PCM_DISC with FLAC files (lossless and space-efficient)")
                        }
                    }
                }
            }

            await updateProgress(0.80, task: "Creating ISO file...")
            if sacdPlusEnhancedMode && sacdPlusEnhancedUseISO9660 {
                try await runHDIUtilMakeHybrid(
                    inputFolder: root,
                    volumeName: sacdPlusVolumeName,
                    outputISO: outURL,
                    useISO9660: true
                )
            } else {
                try await runMKISOFS(inputFolder: root, volumeName: sacdPlusVolumeName, outputISO: outURL)
            }
            if !directBurn {
                let manifestURL = try writeSACDPlusManifest(lines: manifestLines, nextTo: outURL)
                appendLog("🧾 Build manifest created: \(manifestURL.path)")
            }
            await updateProgress(0.90, task: "Verifying ISO contents...")
            try verifySACDPlusISO(at: outURL, expectedDSFPaths: expectedDSFPaths)
            if !sacdPlusEnhancedMode && sacdPlusRenameTracks {
                try verifyTrackDirectoryRecordOrder(in: outURL)
                appendLog("✅ Verified deterministic UDF directory-record order")
            } else if !sacdPlusRenameTracks {
                appendLog("⚠️ Track renaming disabled: playback order depends on the player sorting the original filenames")
            }
            appendLog("✅ Verified \(expectedDSFPaths.count) DSF files in completed ISO")
            if directBurn {
                appendLog("✅ Temporary SACD+ image verified; starting optical burn")
                try await burnISOImageDirectly(at: outURL)
                appendLog("✅ SACD+ disc burned and verified")
                await markBuildComplete()
            } else {
                lastBuiltISOURL = outURL
                await markBuildComplete()
                if sacdPlusEnhancedMode {
                    appendLog("✅ SACD+ Enhanced ISO created: \(outURL.path)")
                } else {
                    appendLog("✅ SACD+ ISO created: \(outURL.path)")
                }
            }
        } catch {
            appendLog("❌ Error: \(error.localizedDescription)")
            await markBuildFailed()
        }

        isWorking = false
    }

    private func writeSACDPlusManifest(lines: [String], nextTo isoURL: URL) throws -> URL {
        let baseName = isoURL.deletingPathExtension().lastPathComponent
        let manifestURL = isoURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-manifest.txt")
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: manifestURL, atomically: true, encoding: .utf8)
        return manifestURL
    }

    private func verifySACDPlusISO(at isoURL: URL, expectedDSFPaths: [String]) throws {
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-readonly", "-nobrowse", "-plist", isoURL.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        attach.standardOutput = outputPipe
        attach.standardError = errorPipe
        try attach.run()
        attach.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard attach.terminationStatus == 0 else {
            throw NSError(domain: "SACDDesignSuite", code: Int(attach.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not mount completed ISO for verification. \(errorText)"])
        }

        guard let plist = try PropertyListSerialization.propertyList(from: output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw NSError(domain: "SACDDesignSuite", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "Completed ISO mounted, but no mount point was returned"])
        }

        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint]
            if (try? detach.run()) != nil {
                detach.waitUntilExit()
            }
        }

        let mountedRoot = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let missing = expectedDSFPaths.filter {
            !FileManager.default.fileExists(atPath: mountedRoot.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw NSError(domain: "SACDDesignSuite", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "ISO verification failed. Missing: \(missing.joined(separator: ", "))"])
        }
    }

    func buildSACDx() async {
        guard let backupISO = sacdXBackupISO else {
            appendLog("Choose a backup ISO for the BACKUP folder.")
            return
        }
        guard !sacdXStereoTracks.isEmpty else {
            appendLog("Add at least one stereo DSF track for DSD_DISC/ALBUM01.")
            return
        }
        guard let outURL = pickSaveURL(suggested: "\(sacdXVolumeName).iso") else { return }

        resetProgress()
        isWorking = true
        log = ""
        appendLog("Building SACDx…")
        do {
            let fm = FileManager.default
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SACDDesignSuite_SACDX_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let backupFolder = root.appendingPathComponent("BACKUP")
            let stereoFolder = root.appendingPathComponent("DSD_DISC/ALBUM01")
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: stereoFolder, withIntermediateDirectories: true)
            try fm.copyItem(at: backupISO, to: backupFolder.appendingPathComponent(backupISO.lastPathComponent))
            await updateProgress(0.20, task: "Adding stereo DSD tracks…")

            var expectedPaths: [String] = []
            var manifest = [
                "SACDx Build Manifest",
                "Volume: \(sacdXVolumeName)",
                "Backup: BACKUP/\(backupISO.lastPathComponent)",
                "Filesystem: UDF",
                "",
                "Order | Output path | Source path"
            ]
            func filename(for item: TrackItem, index: Int) -> String {
                sacdXRenameTracks ? String(format: "TRACK%03d.dsf", index + 1) : item.url.lastPathComponent
            }
            for (index, item) in sacdXStereoTracks.enumerated() {
                let name = filename(for: item, index: index)
                let relative = "DSD_DISC/ALBUM01/\(name)"
                try fm.copyItem(at: item.url, to: stereoFolder.appendingPathComponent(name))
                expectedPaths.append(relative)
                manifest.append(String(format: "%03d | %@ | %@", index + 1, relative, item.url.path))
            }
            if sacdXMultichannelMode {
                let multichannelFolder = root.appendingPathComponent("DSD_DISC/ALBUM02")
                try fm.createDirectory(at: multichannelFolder, withIntermediateDirectories: true)
                for (index, item) in sacdXMultichannelTracks.enumerated() {
                    let name = filename(for: item, index: index)
                    let relative = "DSD_DISC/ALBUM02/\(name)"
                    try fm.copyItem(at: item.url, to: multichannelFolder.appendingPathComponent(name))
                    expectedPaths.append(relative)
                    manifest.append(String(format: "MC%03d | %@ | %@", index + 1, relative, item.url.path))
                }
            }

            await updateProgress(0.70, task: "Creating deterministic SACDx UDF ISO…")
            try await runMKISOFS(inputFolder: root, volumeName: sacdXVolumeName, outputISO: outURL)
            _ = try writeSACDPlusManifest(lines: manifest, nextTo: outURL)
            await updateProgress(0.90, task: "Verifying SACDx ISO…")
            try verifySACDPlusISO(at: outURL, expectedDSFPaths: expectedPaths)
            if sacdXRenameTracks { try verifyTrackDirectoryRecordOrder(in: outURL) }
            lastBuiltISOURL = outURL
            appendLog("✅ SACDx ISO created: \(outURL.path)")
            await markBuildComplete()
        } catch {
            appendLog("❌ Error: \(error.localizedDescription)")
            await markBuildFailed()
        }
        isWorking = false
    }

    func burnSACDxBackupISODirectly() async {
        guard let isoURL = sacdXBackupISO,
              FileManager.default.fileExists(atPath: isoURL.path) else {
            appendLog("Choose an ISO to burn directly.")
            return
        }
        resetProgress()
        isWorking = true
        log = ""
        appendLog("Direct ISO burn selected. No SACDx folders or DSF tracks will be added.")
        appendLog("Burning \(isoURL.lastPathComponent) sector-for-sector with verification…")
        do {
            try await burnISOImageDirectly(at: isoURL)
            appendLog("✅ Direct ISO burn and verification completed")
            await markBuildComplete()
        } catch {
            appendLog("❌ Burn error: \(error.localizedDescription)")
            await markBuildFailed()
        }
        isWorking = false
    }

    private func burnISOImageDirectly(at isoURL: URL) async throws {
        progressIsIndeterminate = false
        await updateProgress(0.05, task: "Waiting for writable optical media…")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        var burnArguments = ["burn", "-verifyburn", "-puppetstrings"]
        if let selectedDrivePath = UserDefaults.standard.string(forKey: selectedOpticalDrivePathKey),
           !selectedDrivePath.isEmpty {
            burnArguments += ["-device", selectedDrivePath]
            let selectedDriveName = UserDefaults.standard.string(forKey: "selectedOpticalDriveName") ?? selectedDrivePath
            appendLog("Using selected optical drive: \(selectedDriveName)")
        } else {
            appendLog("Using the macOS default optical drive")
        }
        burnArguments.append(isoURL.path)
        task.arguments = burnArguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        enum BurnPhase { case waiting, preparing, burning, finalizing, verifying }
        var burnPhase: BurnPhase = .waiting
        var lastDisplayedProgress = 0.05
        var lastRawFraction = 0.0
        for try await line in pipe.fileHandleForReading.bytes.lines {
                let message = String(line)
                if message.hasPrefix("MESSAGE:") {
                    let status = String(message.dropFirst("MESSAGE:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !status.isEmpty { appendLog(status) }
                    let normalizedStatus = status.lowercased()
                    if normalizedStatus.contains("verify") {
                        burnPhase = .verifying
                        progressIsIndeterminate = false
                        lastRawFraction = 0
                        lastDisplayedProgress = max(lastDisplayedProgress, 0.82)
                        await updateProgress(lastDisplayedProgress, task: "Verifying burned disc…")
                    } else if normalizedStatus.contains("prepar") ||
                                normalizedStatus.contains("open") ||
                                normalizedStatus.contains("scan") {
                        burnPhase = .preparing
                        lastRawFraction = 0
                        await updateProgress(max(lastDisplayedProgress, 0.06), task: "Preparing image and optical media…")
                    } else if normalizedStatus.contains("close") ||
                                normalizedStatus.contains("finish") ||
                                normalizedStatus.contains("finaliz") {
                        burnPhase = .finalizing
                        progressIsIndeterminate = true
                        lastRawFraction = 0
                        await updateProgress(max(lastDisplayedProgress, 0.78), task: "Finishing burn and closing disc…")
                    } else if normalizedStatus.contains("burn") || normalizedStatus.contains("writ") {
                        if burnPhase != .burning {
                            burnPhase = .burning
                            lastRawFraction = 0
                        }
                        await updateProgress(max(lastDisplayedProgress, 0.10), task: "Burning selected ISO…")
                    }
                } else if message.hasPrefix("PERCENT:"),
                          let rawPercent = Double(message.dropFirst("PERCENT:".count)),
                          rawPercent >= 0 {
                    let fraction = min(max(rawPercent > 1 ? rawPercent / 100 : rawPercent, 0), 1)
                    if fraction + 0.05 < lastRawFraction {
                        lastRawFraction = 0
                    }
                    lastRawFraction = fraction
                    // Many optical drives stop reporting hdiutil percentages around 97%
                    // while their hardware buffer is flushed and the disc/session is closed.
                    // Treat that boundary as a distinct, indeterminate phase instead of
                    // leaving a misleading determinate percentage frozen near 76%.
                    if burnPhase == .burning && fraction >= 0.97 {
                        burnPhase = .finalizing
                        progressIsIndeterminate = true
                        lastDisplayedProgress = max(lastDisplayedProgress, 0.78)
                        await updateProgress(lastDisplayedProgress, task: "Finishing burn and closing disc…")
                        continue
                    }
                    let mappedProgress: Double
                    let phaseText: String
                    switch burnPhase {
                    case .waiting, .preparing:
                        mappedProgress = 0.05 + (fraction * 0.05)
                        phaseText = "Preparing image and optical media…"
                    case .burning:
                        mappedProgress = 0.10 + (fraction * 0.68)
                        phaseText = "Burning selected ISO…"
                    case .finalizing:
                        mappedProgress = 0.78 + (fraction * 0.04)
                        phaseText = "Finishing burn and closing disc…"
                    case .verifying:
                        mappedProgress = 0.82 + (fraction * 0.17)
                        phaseText = "Verifying burned disc…"
                    }
                    if mappedProgress >= lastDisplayedProgress + 0.007 || mappedProgress >= 0.99 {
                        lastDisplayedProgress = mappedProgress
                        await updateProgress(mappedProgress, task: phaseText)
                    }
                } else if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLog(message)
                }
            }
            task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "SACDDesignSuite", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Direct ISO burn failed with exit code \(task.terminationStatus)"])
        }
    }

    // MARK: - Strip metadata from audio files using ffmpeg
    func stripMetadata(input: URL, output: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        task.arguments = [
            "-i", input.path,
            "-map_metadata", "-1",
            "-c", "copy",
            output.path,
            "-y"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let handle = pipe.fileHandleForReading
        for try await _ in handle.bytes.lines {
            // Optionally log output lines if needed
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(domain: "SACDDesignSuite", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed to strip metadata (\(task.terminationStatus))"])
        }
    }

    // MARK: - Build: package an existing SACD folder as ISO

    func buildSACDRFromFolder() async {
        guard sacdSourceFolder != nil else {
            appendLog("Choose a source folder or ISO file that contains MASTER.TOC, 2CH/, etc.")
            return
        }
        guard let outURL = pickSaveURL(suggested: "\(sacdVolumeName).iso") else { return }

        resetProgress()
        isWorking = true
        log = ""
        let sourceType = isSourceISO ? "ISO" : "folder"
        appendLog("Building SACD-R ISO from \(sourceType)…")

        do {
            let src = try await resolveSourceFolder()
            let masterTOC = src.appendingPathComponent("MASTER.TOC")
            let twoCH = src.appendingPathComponent("2CH")
            let fm = FileManager.default
            
            // Check for basic SACD structure (more lenient for extracted ISOs)
            let hasMASTER_TOC = fm.fileExists(atPath: masterTOC.path)
            let has2CH = fm.fileExists(atPath: twoCH.path)
            
            if !hasMASTER_TOC && !has2CH {
                // Check what was actually extracted
                appendLog("Standard SACD structure not found, checking extracted contents...")
                let contents = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
                appendLog("Source contents: \(contents.map { $0.lastPathComponent })")
                
                // Look for any SACD-related files
                let sacdFiles = contents.filter { url in
                    let name = url.lastPathComponent.uppercased()
                    return name.contains("MASTER") || name.contains("TOC") || 
                           name.contains("2CH") || name.contains("MCH") ||
                           name.contains("TRACK") || name.contains("SACD")
                }
                
                if sacdFiles.isEmpty {
                    throw NSError(domain: "SACDDesignSuite", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No SACD files found in source. Contents: \(contents.map { $0.lastPathComponent })"])
                } else {
                    appendLog("Found SACD-related files: \(sacdFiles.map { $0.lastPathComponent })")
                    appendLog("Proceeding with extracted structure...")
                }
            } else {
                appendLog("✅ SACD structure validated")
            }
            try await runHDIUtilMakeHybrid(inputFolder: src, volumeName: sacdVolumeName, outputISO: outURL)
            appendLog("✅ SACD-R ISO created: \(outURL.path)")
            lastBuiltISOURL = outURL
            await markBuildComplete()
        } catch {
            appendLog("❌ Error: \(error.localizedDescription)")
            await markBuildFailed()
        }

        isWorking = false
        cleanupTempFolders()
    }

    // MARK: - Assemble SACD-R from imported DSD tracks using donor template

    func assembleSACDRFromTracks() async {
        guard sacdSourceFolder != nil else {
            appendLog("Choose a donor SACD folder or ISO (MASTER.TOC, 2CH/, optional MCH/)")
            return
        }
        guard !sacdTracks.isEmpty else {
            appendLog("Add at least one DSD track.")
            return
        }
        guard let outURL = pickSaveURL(suggested: "\(sacdVolumeName).iso") else { return }

        resetProgress()
        isWorking = true
        log = ""
        let sourceType = isSourceISO ? "ISO" : "folder"
        appendLog("Assembling SACD-R from \(sourceType) with \(sacdTracks.count) track(s)…")

        do {
            // Resolve template source (folder or extracted ISO)
            let template = try await resolveSourceFolder()
            
            // Validate donor structure
            let twoCH = template.appendingPathComponent("2CH")
            let masterTOC = template.appendingPathComponent("MASTER.TOC")
            let fm = FileManager.default
            
            // Check for basic SACD structure
            let hasMASTER_TOC = fm.fileExists(atPath: masterTOC.path)
            let has2CH = fm.fileExists(atPath: twoCH.path)
            
            if !hasMASTER_TOC && !has2CH {
                // If neither exists, check what was actually extracted
                appendLog("Standard SACD structure not found, checking extracted contents...")
                do {
                    let contents = try fm.contentsOfDirectory(at: template, includingPropertiesForKeys: nil)
                    appendLog("Extracted contents: \(contents.map { $0.lastPathComponent })")
                    
                    // Look for any SACD-related files
                    let sacdFiles = contents.filter { url in
                        let name = url.lastPathComponent.uppercased()
                        return name.contains("MASTER") || name.contains("TOC") || 
                               name.contains("2CH") || name.contains("MCH") ||
                               name.contains("TRACK") || name.contains("SACD")
                    }
                    
                    if sacdFiles.isEmpty {
                        throw NSError(domain: "SACDDesignSuite", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "No SACD files found in extracted structure. Contents: \(contents.map { $0.lastPathComponent })"])
                    } else {
                        appendLog("Found SACD-related files: \(sacdFiles.map { $0.lastPathComponent })")
                        // Continue with the extracted structure as-is
                    }
                } catch {
                    throw NSError(domain: "SACDDesignSuite", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not validate extracted structure: \(error.localizedDescription)"])
                }
            } else if !hasMASTER_TOC {
                appendLog("⚠️ MASTER.TOC not found, but 2CH/ exists - attempting to continue...")
            } else if !has2CH {
                appendLog("⚠️ 2CH/ not found, but MASTER.TOC exists - attempting to continue...")
            } else {
                appendLog("✅ Standard SACD structure validated (MASTER.TOC + 2CH/)")
            }

            // Copy donor to temp
            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SACDDesignSuite_SACDR_\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let dstRoot = work.appendingPathComponent("TEMPLATE")
            try fm.copyItem(at: template, to: dstRoot)

            // Choose program area
            let programArea = sacdUseMultichannel
                ? dstRoot.appendingPathComponent("MCH")
                : dstRoot.appendingPathComponent("2CH")
            if !fm.fileExists(atPath: programArea.path) {
                try fm.createDirectory(at: programArea, withIntermediateDirectories: true)
            }

            // Replace TRACKxx files
            for (i, item) in sacdTracks.enumerated() {
                let trackNo = String(format: "TRACK%02d", i + 1)
                let outDST = programArea.appendingPathComponent("\(trackNo).DST")
                
                // Remove existing file if it exists (from synthetic structure)
                if fm.fileExists(atPath: outDST.path) {
                    try fm.removeItem(at: outDST)
                    appendLog("Removed existing \(outDST.lastPathComponent)")
                }
                
                let needsDST = sacdUseMultichannel || !allowStereoRawDSD
                if needsDST {
                    guard let enc = dstEncoderPath else {
                        throw NSError(domain: "SACDDesignSuite", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "DST encoder not set. Choose an external encoder (required for MCH)."])
                    }
                    try await runExternalEncoder(encoder: enc, input: item.url, output: outDST)
                    appendLog("Encoded → \(outDST.lastPathComponent)")
                } else {
                    // Experimental: copy raw DSD into .DST name (relies on donor control files).
                    try fm.copyItem(at: item.url, to: outDST)
                    appendLog("Copied raw DSD as \(outDST.lastPathComponent) (experimental)")
                }
            }

            // NOTE: We DO NOT regenerate MASTER.TOC / INDEX.PTI here.

            try await runHDIUtilMakeHybrid(inputFolder: dstRoot, volumeName: sacdVolumeName, outputISO: outURL)
            appendLog("✅ SACD-R ISO created: \(outURL.path)")
            lastBuiltISOURL = outURL
            await markBuildComplete()
        } catch {
            appendLog("❌ Error: \(error.localizedDescription)")
            await markBuildFailed()
        }

        isWorking = false
        cleanupTempFolders()
    }

    // MARK: - Build: Generate SACD from DSD files (no donor needed)
    
    func buildSACDFromScratch() async {
        guard !sacdTracks.isEmpty else {
            appendLog("Add at least one DSD track.")
            return
        }
        guard let outURL = pickSaveURL(suggested: "\(sacdVolumeName)_Generated.iso") else { return }

        resetProgress()
        isWorking = true
        log = ""
        appendLog("Generating SACD from \(sacdTracks.count) DSD track(s)…")

        do {
            // Parse DSD files to get track information
            appendLog("Analyzing DSD files...")
            var dsdTracks: [DSDFileInfo] = []
            
            for (index, trackItem) in sacdTracks.enumerated() {
                do {
                    let dsdInfo = try DSDFileParser.parseFile(at: trackItem.url)
                    dsdTracks.append(dsdInfo)
                    appendLog("Track \(index + 1): \(dsdInfo.format.fileExtension.uppercased()) \(dsdInfo.sampleRate)Hz \(dsdInfo.channels)ch \(String(format: "%.1f", dsdInfo.duration))s")
                } catch {
                    appendLog("⚠️ Could not parse \(trackItem.url.lastPathComponent): \(error.localizedDescription)")
                    // Create a fallback DSD info
                    let fallbackInfo = DSDFileInfo(
                        url: trackItem.url,
                        format: .dsf,
                        sampleRate: 2822400, // DSD64
                        channels: 2,
                        bitsPerSample: 1,
                        sampleCount: 0,
                        duration: 0,
                        fileSize: UInt64(trackItem.url.fileSize ?? 0)
                    )
                    dsdTracks.append(fallbackInfo)
                }
            }
            
            // Determine if multichannel
            let isMultichannel = sacdUseMultichannel || dsdTracks.contains { $0.channels > 2 }
            appendLog(isMultichannel ? "Creating multichannel SACD" : "Creating stereo SACD")
            
            // Generate SACD structure
            appendLog("Generating SACD binary structure...")
            var sacdBinaryData = Data()
            
            // Generate Master TOC
            let masterTOC = SACDMasterTOC(tracks: dsdTracks, albumTitle: sacdVolumeName, isMultichannel: isMultichannel)
            let masterTOCData = masterTOC.generateBinaryData()
            
            // Generate Area TOC
            let areaTOCStartSector: UInt32 = isMultichannel ? masterTOC.area2TOC1Start : masterTOC.area1TOC1Start
            appendLog("DEBUG: Creating Area TOC with \(dsdTracks.count) tracks, startSector: \(areaTOCStartSector)")
            let areaTOC = SACDAreaTOC(tracks: dsdTracks, isMultichannel: isMultichannel, startSector: areaTOCStartSector)
            appendLog("DEBUG: Calling Area TOC generateBinaryData()...")
            let areaTOCData = areaTOC.generateBinaryData()
            appendLog("DEBUG: Area TOC generated \(areaTOCData.count) bytes")
            
            // Check what's actually in the Area TOC data
            let firstTrackEntry = areaTOCData.subdata(in: 20..<36)
            let trackNum = firstTrackEntry[0]
            let startSectorBytes = firstTrackEntry.subdata(in: 4..<8)
            let startSector = startSectorBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let minutes = firstTrackEntry[12]
            let seconds = firstTrackEntry[13]
            appendLog("DEBUG: First track in generated TOC: #\(trackNum), sector \(startSector), duration \(minutes):\(String(format: "%02d", seconds))")
            
            // Layout SACD structure
            // Sectors 0-509: UDF filesystem space (filled with zeros for now)
            sacdBinaryData.append(Data(count: 510 * 2048))
            
            // Sectors 510-512: Master TOC (3 copies)
            sacdBinaryData.append(masterTOCData)
            sacdBinaryData.append(masterTOCData)
            sacdBinaryData.append(masterTOCData)
            appendLog("✅ Generated MASTER.TOC at sectors 510-512")
            
            // Sectors 513-539: Reserved
            sacdBinaryData.append(Data(count: 27 * 2048))
            
            // Area TOC (2 copies)
            sacdBinaryData.append(areaTOCData)
            sacdBinaryData.append(areaTOCData)
            let areaTOCSector = 540
            appendLog("✅ Generated Area TOC at sectors \(areaTOCSector)-\(areaTOCSector + 1)")
            
            // Add DSD audio data extracted from DSF files
            for (index, track) in dsdTracks.enumerated() {
                appendLog("Adding track \(index + 1) raw DSD audio data...")
                
                // Extract raw DSD audio data instead of copying complete file
                let rawDSDData = try DSDFileParser.extractRawDSDFromDSF(url: track.url)
                appendLog("✓ Extracted raw DSD from DSF file")
                
                // Pad to sector boundary
                let paddedSize = ((rawDSDData.count + 2047) / 2048) * 2048
                sacdBinaryData.append(rawDSDData)
                if rawDSDData.count < paddedSize {
                    sacdBinaryData.append(Data(count: paddedSize - rawDSDData.count))
                }
                appendLog("✓ Added \(rawDSDData.count) bytes of raw DSD audio data")
            }
            
            // Write raw binary ISO
            appendLog("Writing raw SACD ISO...")
            try sacdBinaryData.write(to: outURL)
            appendLog("✅ Generated raw SACD ISO: \(outURL.path)")
            appendLog("✅ Total size: \(sacdBinaryData.count) bytes (\(sacdBinaryData.count / 2048) sectors)")
            lastBuiltISOURL = outURL
            await markBuildComplete()
            
        } catch {
            appendLog("❌ Error: \(error.localizedDescription)")
            await markBuildFailed()
        }

        isWorking = false
    }

    // MARK: - External tools + hdiutil

    func runExternalEncoder(encoder: URL, input: URL, output: URL) async throws {
        let task = Process()
        task.executableURL = encoder
        // Adjust args to your encoder (example: dstenc -i in.dsf -o out.DST)
        task.arguments = ["-i", input.path, "-o", output.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let h = pipe.fileHandleForReading
        for try await line in h.bytes.lines {
            await MainActor.run { self.appendLog(String(line)) }
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(domain: "SACDDesignSuite", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "DST encoder failed (\(task.terminationStatus))"])
        }
    }

    private func mkisofsURL() -> URL? {
        let fm = FileManager.default
        let bundledCandidates = [
            Bundle.main.url(forResource: "mkisofs", withExtension: nil, subdirectory: "Tools"),
            Bundle.main.url(forResource: "mkisofs", withExtension: nil, subdirectory: "Resources/Tools"),
            Bundle.main.url(forResource: "mkisofs", withExtension: nil)
        ].compactMap { $0 }
        if let bundled = bundledCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            appendLog("Using bundled deterministic UDF authoring tool")
            return bundled
        }
        for path in ["/opt/homebrew/bin/mkisofs", "/usr/local/bin/mkisofs", "/usr/bin/mkisofs"] {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func runMKISOFS(inputFolder: URL, volumeName: String, outputISO: URL) async throws {
        guard let executable = mkisofsURL() else {
            throw NSError(
                domain: "SACDDesignSuite",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "The bundled deterministic UDF authoring tool is missing or cannot run. Reinstall the app, or install the Homebrew dvdrtools package. The app will not fall back to unordered UDF authoring."]
            )
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = [
            "-udf",
            "-V", String(volumeName.prefix(32)),
            "-o", outputISO.path,
            inputFolder.path
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        appendLog("Creating deterministic UDF image with mkisofs...")
        try task.run()
        for try await line in pipe.fileHandleForReading.bytes.lines {
            await MainActor.run { self.appendLog(String(line)) }
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "SACDDesignSuite",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "mkisofs failed with exit code \(task.terminationStatus)"]
            )
        }
    }

    private func verifyTrackDirectoryRecordOrder(in isoURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: isoURL)
        defer { try? handle.close() }
        let metadata = try handle.read(upToCount: 16 * 1024 * 1024) ?? Data()
        guard let text = String(data: metadata, encoding: .isoLatin1) else {
            throw NSError(domain: "SACDDesignSuite", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "Could not inspect ISO directory metadata"])
        }
        let expression = try NSRegularExpression(pattern: #"TRACK([0-9]{3})\.(DSF|FLAC|WAV|MP3)"#, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let numbers = expression.matches(in: text, range: range).compactMap { match -> Int? in
            guard let numberRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[numberRange])
        }
        guard !numbers.isEmpty else {
            throw NSError(domain: "SACDDesignSuite", code: 32,
                          userInfo: [NSLocalizedDescriptionKey: "No track directory records were found in the completed ISO"])
        }

        var previous: Int?
        for number in numbers {
            if let prior = previous {
                let continuesSequence = number == prior + 1
                let startsNewSequence = number == 1
                if !continuesSequence && !startsNewSequence {
                    throw NSError(
                        domain: "SACDDesignSuite",
                        code: 33,
                        userInfo: [NSLocalizedDescriptionKey: "ISO directory records are out of order: TRACK\(String(format: "%03d", prior)) is followed by TRACK\(String(format: "%03d", number)). Build rejected."]
                    )
                }
            }
            previous = number
        }
    }

    func runHDIUtilMakeHybrid(inputFolder: URL, volumeName: String, outputISO: URL, useISO9660: Bool = false) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        
        var arguments = ["makehybrid"]
        
        if useISO9660 {
            // ISO 9660 mode with Joliet extensions for long filenames
            arguments.append(contentsOf: ["-iso", "-joliet"])
            appendLog("Using ISO 9660 + Joliet filesystem")
        } else {
            // UDF 1.02 mode (original SACD+ behavior)
            arguments.append(contentsOf: ["-udf", "-udf-version", "1.02"])
            appendLog("Using UDF 1.02 filesystem")
        }
        
        arguments.append(contentsOf: [
            "-default-volume-name", volumeName,
            "-o", outputISO.path,
            inputFolder.path
        ])
        
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        appendLog("Creating hybrid image...")
        try task.run()
        let handle = pipe.fileHandleForReading
        for try await line in handle.bytes.lines {
            await MainActor.run { self.appendLog(String(line)) }
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            // Provide detailed error information based on exit code
            let errorMsg = if task.terminationStatus == 1 {
                "hdiutil failed - This may be due to:\n• macOS security restrictions (try enabling 'ISO 9660' mode)\n• Insufficient disk permissions\n• Files too large for selected filesystem\n• System policy restrictions"
            } else {
                "hdiutil failed with exit code \(task.terminationStatus)"
            }
            throw NSError(domain: "SACDDesignSuite", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
    }
}

// MARK: - Views

// MARK: - Space Usage Bar Component

struct SpaceUsageBar: View {
    let projectSize: Int64
    let capacity: Int64?
    let capacityName: String
    let formatBytes: (Int64) -> String
    
    private var usagePercentage: Double {
        guard let capacity = capacity else { return 0.0 }
        return Double(projectSize) / Double(capacity)
    }
    
    private var progressColor: Color {
        if capacity == nil { return .blue }
        if usagePercentage > 1.0 { return .red }
        if usagePercentage > 0.9 { return .orange }
        if usagePercentage > 0.75 { return .yellow }
        return .green
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disc Space Usage")
                    .font(.headline)
                Spacer()
                if let capacity = capacity {
                    Text("\(formatBytes(projectSize)) / \(formatBytes(capacity))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(formatBytes(projectSize))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if capacity != nil {
                // Progress bar for limited capacity
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 8)
                        
                        Rectangle()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * min(usagePercentage, 1.0), height: 8)
                    }
                    .cornerRadius(4)
                }
                .frame(height: 8)
                
                HStack {
                    Text(capacityName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(usagePercentage * 100))%")
                        .font(.caption)
                        .foregroundColor(usagePercentage > 1.0 ? .red : .secondary)
                }
            } else {
                // Unlimited capacity display
                HStack {
                    Rectangle()
                        .fill(progressColor)
                        .frame(height: 8)
                        .cornerRadius(4)
                    Text("∞")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text(capacityName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            if capacity != nil && usagePercentage > 1.0 {
                Text("⚠️ Project exceeds disc capacity!")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ContentView: View {
    private enum PendingDirectBurn {
        case sacdPlus
        case sacdX
    }

    @Environment(\.openSettings) private var openSettings
    @AppStorage(minimalistModeKey) private var minimalistMode = true
    @AppStorage(sacdPlusFocusModeKey) private var sacdPlusFocusMode = true
    @AppStorage(startupInterfaceModeKey) private var startupInterfaceMode = "super"
    @StateObject private var state = AuthoringState()
    @State private var sacdPlusSelection = Set<TrackItem.ID>()
    @State private var multichannelDSFSelection = Set<TrackItem.ID>()
    @State private var multichannelPCMSelection = Set<TrackItem.ID>()
    @State private var sacdSelection = Set<TrackItem.ID>()
    @State private var sacdXStereoSelection = Set<TrackItem.ID>()
    @State private var sacdXMultichannelSelection = Set<TrackItem.ID>()
    @State private var showLog: Bool = false
    @State private var showHelpPane: Bool = false
    @State private var experimentalMode: Bool = false
    @State private var showExperimentalModeWarning: Bool = false
    @State private var experimentalTriggerClickCount: Int = 0
    @State private var experimentalTriggerLastClick: Date? = nil
    @State private var showDriveWarning: Bool = false
    @State private var pendingDirectBurn: PendingDirectBurn? = nil

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            if !sacdPlusFocusMode {
                ToolbarItem(placement: .navigation) {
                    Picker("Mode", selection: $state.mode) {
                        ForEach(availableAuthoringModes) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }
            }
            if !minimalistMode {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showHelpPane.toggle()
                    } label: {
                        Label(showHelpPane ? "Hide Help Pane" : "Show Help Pane",
                              systemImage: showHelpPane ? "sidebar.left" : "sidebar.right")
                    }
                }
            }
        }
        .alert("Enter Experimental Mode?", isPresented: $showExperimentalModeWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    experimentalMode = true
                }
            }
        } message: {
            Text("Experimental features are incomplete, unsupported, and provided for testing at your own risk. They may produce unusable images, failed burns, incompatible discs, or unintended data loss. The creators and contributors of this program accept no responsibility for damage, loss, infringement, or other consequences resulting from their use.\n\nSACD and related technologies and trademarks are the property of their respective rights holders, including Sony and Philips. This project is independent and is not affiliated with, endorsed by, or sponsored by those companies. Use these tools only with original material and donor templates you are legally authorized to use.")
        }
        .alert(driveWarningTitle, isPresented: $showDriveWarning) {
            Button("Cancel", role: .cancel) { pendingDirectBurn = nil }
            Button("Open Settings…") {
                pendingDirectBurn = nil
                openSettings()
            }
            if writableOpticalDrives.count > 1 {
                Button("Burn Anyway") { performPendingDirectBurn() }
            }
        } message: {
            Text(driveWarningMessage)
        }
        .onChange(of: minimalistMode) { _, enabled in
            if enabled {
                showHelpPane = false
                experimentalMode = false
                state.sacdXDirectBurnMode = false
                if state.mode == .sacdR { state.mode = .sacdPlus }
            }
        }
        .onChange(of: sacdPlusFocusMode) { _, enabled in
            if enabled && state.mode == .sacdX { state.mode = .sacdPlus }
        }
        .onAppear { applyStartupInterfaceMode() }
    }

    private var writableOpticalDrives: [DRDevice] {
        (DRDevice.devices() as? [DRDevice] ?? []).filter { $0.writesDVD() }
    }

    private func applyStartupInterfaceMode() {
        switch startupInterfaceMode {
        case "minimalist":
            minimalistMode = true
            sacdPlusFocusMode = false
        case "focus":
            minimalistMode = false
            sacdPlusFocusMode = true
        case "super":
            minimalistMode = true
            sacdPlusFocusMode = true
        default:
            break
        }
    }

    private var driveWarningTitle: String {
        writableOpticalDrives.isEmpty ? "No Optical Drive Detected" : "Multiple Optical Drives Detected"
    }

    private var driveWarningMessage: String {
        if writableOpticalDrives.isEmpty {
            return "No writable optical drive is currently connected. Connect a compatible disc writer, then open Settings and refresh the drive list before trying again."
        }
        let selectedName = UserDefaults.standard.string(forKey: "selectedOpticalDriveName") ?? "Automatic"
        return "More than one writable optical drive is connected. The current burner setting is “\(selectedName)”. Open Settings to confirm the intended drive before continuing."
    }

    private func requestDirectBurn(_ burn: PendingDirectBurn) {
        pendingDirectBurn = burn
        if writableOpticalDrives.count != 1 {
            showDriveWarning = true
        } else {
            performPendingDirectBurn()
        }
    }

    private func performPendingDirectBurn() {
        guard let burn = pendingDirectBurn else { return }
        pendingDirectBurn = nil
        switch burn {
        case .sacdPlus:
            Task { await state.buildSACDPlus() }
        case .sacdX:
            Task { await state.burnSACDxBackupISODirectly() }
        }
    }

    private var availableAuthoringModes: [AuthoringMode] {
        if experimentalMode && !minimalistMode {
            return sacdPlusFocusMode ? [.sacdPlus, .sacdR] : AuthoringMode.allCases
        }
        return sacdPlusFocusMode ? [.sacdPlus] : [.sacdPlus, .sacdX]
    }

    @ViewBuilder private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            if showHelpPane && !minimalistMode {
                descriptionPanel
                    .frame(width: 340, alignment: .top)
                    .padding(12)
                Divider()
            }
            ScrollView {
                VStack {
                    switch state.mode {
                    case .sacdR:
                        sacdRView
                    case .sacdX:
                        sacdXView
                    case .sacdPlus:
                        sacdPlusView
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: SACD+ View

    private var sacdPlusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !minimalistMode { experimentalModeTrigger }
                if !minimalistMode {
                    Spacer()
                    Image("SACDPlusLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                }
            }

            HStack {
                Text("Volume Name:")
                TextField("SACDPLUS", text: $state.sacdPlusVolumeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
                
                if !state.sacdPlusEnhancedMode {
                    Text("Stereo DSD Folder: ALBUM01")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Output:")
                Picker("", selection: $state.sacdPlusDirectBurnMode) {
                    Text("Create ISO").tag(false)
                    Text("Burn Directly").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Text(state.sacdPlusDirectBurnMode
                     ? "Authors and verifies a temporary deterministic ISO, then burns and verifies the disc."
                     : "Creates and verifies an ISO file that you can save or burn later.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            HStack {
                Text("Filesystem:")
                if state.sacdPlusEnhancedMode {
                    Picker("", selection: $state.sacdPlusEnhancedUseISO9660) {
                        Text("UDF 1.02").tag(false)
                        Text("ISO 9660 + Joliet").tag(true)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    Text("Enhanced mode allows either filesystem")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("UDF 1.02 (required for DSD Disc compatibility)")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            HStack {
                Text("Mode:")
                Picker("", selection: $state.sacdPlusEnhancedMode) {
                    Text("SACD+").tag(false)
                    Text("SACD+ Enhanced").tag(true)
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                Toggle("Multichannel", isOn: $state.sacdPlusMultichannelMode)
                Spacer()
                if state.sacdPlusEnhancedMode {
                    Text("DSF only, tags preserved")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            HStack {
                Text("Disc Capacity:")
                Picker("", selection: $state.sacdPlusDiscCapacity) {
                    ForEach(SACDPlusDiscCapacity.allCases, id: \.self) { capacity in
                        Text(capacity.rawValue).tag(capacity)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                Spacer()
            }
            
            // Space Usage Bar for SACD+
            SpaceUsageBar(
                projectSize: state.calculateProjectSize(),
                capacity: state.sacdPlusDiscCapacity.bytes,
                capacityName: state.sacdPlusDiscCapacity.rawValue,
                formatBytes: state.formatBytes
            )

            HStack {
                Button("Add DSF Tracks") {
                    state.pickSACDPlusTracks() 
                }
                Button("Remove Selected") { removeSelectedSACDPlusTracks() }
                    .disabled(sacdPlusSelection.isEmpty)
                Button("Move Up") { moveSelectedSACDPlusTracksUp() }
                    .disabled(sacdPlusSelection.isEmpty)
                Button("Move Down") { moveSelectedSACDPlusTracksDown() }
                    .disabled(sacdPlusSelection.isEmpty)
                Spacer()
                Toggle("Disable Track Renaming", isOn: Binding(
                    get: { !state.sacdPlusRenameTracks },
                    set: { state.sacdPlusRenameTracks = !$0 }
                ))
            }
            if !state.sacdPlusRenameTracks {
                Label("Original filenames will be preserved. Playback order depends on the player sorting those filenames correctly.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                // Row striping background
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { i in
                        Rectangle()
                            .fill(i % 2 == 0 ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                            .frame(height: 28)
                    }
                }
                .allowsHitTesting(false)
                // Table
                Table(state.sacdPlusTracks, selection: $sacdPlusSelection) {
                    TableColumn("#") { item in
                        Text(sacdPlusIndex(of: item)).font(.system(.body, design: .monospaced))
                    }.width(48)
                    TableColumn("File") { item in Text(item.title) }
                    TableColumn("Disc Filename") { item in
                        Text(state.sacdPlusOutputFilename(for: item))
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Path") { item in Text(item.url.path) }
                }
                // Overlay placeholder if empty
                if state.sacdPlusTracks.isEmpty {
                    Text("Drop or Add Files")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                }
            }
            .frame(minHeight: 150, maxHeight: 190)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleTrackDrop(providers, target: .sacdPlusStereoDSF)
            }

            VStack(alignment: .leading, spacing: 8) {
                if state.sacdPlusMultichannelMode {
                    HStack {
                        Text("Multichannel DSD Album")
                            .font(.headline)
                        Text("Folder: ALBUM02")
                            .foregroundColor(.secondary)
                        Button("Add Multichannel DSF…") { state.pickMultichannelDSFTracks() }
                        Button("Remove Selected") {
                            state.multichannelDSFTracks.removeAll { multichannelDSFSelection.contains($0.id) }
                            multichannelDSFSelection.removeAll()
                        }
                        .disabled(multichannelDSFSelection.isEmpty)
                        Spacer()
                    }
                    ZStack {
                        VStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { index in
                                Rectangle()
                                    .fill(index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                                    .frame(height: 28)
                            }
                        }
                        .allowsHitTesting(false)
                        Table(state.multichannelDSFTracks, selection: $multichannelDSFSelection) {
                            TableColumn("#") { item in
                                Text(multichannelDSFIndex(of: item))
                                    .font(.system(.body, design: .monospaced))
                            }.width(48)
                            TableColumn("File") { item in Text(item.title) }
                            TableColumn("Disc Filename") { item in
                                Text(state.multichannelDSFOutputFilename(for: item))
                                    .font(.system(.body, design: .monospaced))
                            }
                            TableColumn("Path") { item in Text(item.url.path) }
                        }
                        if state.multichannelDSFTracks.isEmpty {
                            Text("Drop or Add Files")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(minHeight: 150, maxHeight: 190)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleTrackDrop(providers, target: .sacdPlusMultichannelDSF)
                    }
                    Text("Written to DSD_DISC/\(state.multichannelAlbumName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Hybrid Mode UI (revised)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Hybrid Mode", systemImage: "externaldrive.badge.plus")
                        .font(.headline)
                    Spacer()
                }
                HStack(spacing: 24) {
                    Toggle("Disable Hybrid Mode", isOn: Binding(
                        get: { !state.hybridMode },
                        set: { state.hybridMode = !$0 }
                    ))
                    Toggle("Maximum Compatibility Mode", isOn: Binding(
                        get: { state.hybridFormat == "Maximum Compatibility" },
                        set: { enabled in
                            state.hybridFormat = enabled
                                ? "Maximum Compatibility"
                                : (state.uncompressedSupportMode ? "WAV" : "FLAC")
                        }
                    ))
                    .disabled(!state.hybridMode || state.sacdPlusEnhancedMode)
                    Toggle("Uncompressed Support Mode", isOn: $state.uncompressedSupportMode)
                        .disabled(!state.hybridMode)
                    Spacer()
                }
                if !state.hybridMode {
                    Label("SACD+ was designed to provide both DSD and PCM file paths. Disabling Hybrid Mode creates a DSD-only disc and removes the PCM compatibility path.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.hybridMode {
                    Text(state.uncompressedSupportMode
                         ? "Adds an uncompressed WAV copy of your album for compatible data-disc players. MP3 is available only in Maximum Compatibility Mode."
                         : "Adds a lossless FLAC copy of your album for compatible data-disc players. MP3 is available only in Maximum Compatibility Mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !state.sacdPlusEnhancedMode {
                        Label(state.uncompressedSupportMode
                              ? "Adds uncompressed WAV files plus MP3 compatibility copies. MP3 uses ALBUM02, or ALBUM03 when multichannel reserves ALBUM02. This has the largest disc-space requirement."
                              : "Adds lossless FLAC files plus MP3 compatibility copies. MP3 uses ALBUM02, or ALBUM03 when multichannel reserves ALBUM02.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .center, spacing: 12) {
                        if state.hybridFormat == "Maximum Compatibility" {
                            HStack(spacing: 8) {
                                Button(state.uncompressedSupportMode ? "Add WAV Tracks…" : "Add FLAC Tracks…") {
                                    state.pickMaximumCompatibilityLosslessTracks()
                                }
                                Button("Add MP3 Tracks…") { 
                                    state.pickMP3Tracks() 
                                }
                            }
                        } else {
                            Button(state.uncompressedSupportMode ? "Add WAV Tracks…" : "Add FLAC Tracks…") {
                                state.pickHybridTracks() 
                            }
                        }
                        Spacer()
                    }
                    if state.uncompressedSupportMode {
                        Label("WAV files are much larger than FLAC files and may cause the project to exceed the selected disc capacity.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if state.hybridFormat == "Maximum Compatibility" {
                        VStack(alignment: .leading, spacing: 12) {
                            maximumCompatibilityTable(
                                title: state.uncompressedSupportMode ? "Stereo WAV Album" : "Stereo FLAC Album",
                                tracks: state.maximumCompatibilityLosslessTracks,
                                emptyMessage: "Drop or Add Files",
                                albumName: state.sacdPlusAlbumName,
                                dropTarget: .maximumCompatibilityLossless
                            )
                            maximumCompatibilityTable(
                                title: "Stereo MP3 Album",
                                tracks: state.mp3Tracks,
                                emptyMessage: "Drop or Add Files",
                                albumName: state.sacdPlusMultichannelMode ? "ALBUM03" : "ALBUM02",
                                dropTarget: .maximumCompatibilityMP3
                            )
                        }
                    } else {
                        ZStack {
                            VStack(spacing: 0) {
                                ForEach(0..<6, id: \.self) { index in
                                    Rectangle()
                                        .fill(index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                                        .frame(height: 28)
                                }
                            }
                            .allowsHitTesting(false)
                            Table(state.hybridTracks) {
                                TableColumn("#") { item in
                                    Text(hybridIndex(of: item)).font(.system(.body, design: .monospaced))
                                }.width(40)
                                TableColumn("File") { item in Text(item.title) }
                                TableColumn("Ext") { item in Text(item.ext.uppercased()) }.width(60)
                                TableColumn("Path") { item in Text(item.url.path) }
                            }
                            .frame(minHeight: 160, maxHeight: 200)
                            if state.hybridTracks.isEmpty {
                                Text("Drop or Add Files")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.clear)
                            }
                        }
                        .frame(minHeight: 150, maxHeight: 190)
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleTrackDrop(providers, target: .hybridStereoLossless)
                        }
                    }
                    if state.sacdPlusMultichannelMode {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Multichannel PCM Album")
                                    .font(.headline)
                                Button(state.uncompressedSupportMode ? "Add Multichannel WAV…" : "Add Multichannel FLAC…") {
                                    state.pickMultichannelLosslessTracks()
                                }
                                Button("Remove Selected") {
                                    state.multichannelLosslessTracks.removeAll { multichannelPCMSelection.contains($0.id) }
                                    multichannelPCMSelection.removeAll()
                                }
                                .disabled(multichannelPCMSelection.isEmpty)
                                Spacer()
                            }
                            ZStack {
                                VStack(spacing: 0) {
                                    ForEach(0..<6, id: \.self) { index in
                                        Rectangle()
                                            .fill(index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                                            .frame(height: 28)
                                    }
                                }
                                .allowsHitTesting(false)
                                Table(state.multichannelLosslessTracks, selection: $multichannelPCMSelection) {
                                    TableColumn("#") { item in
                                        Text(multichannelPCMIndex(of: item))
                                            .font(.system(.body, design: .monospaced))
                                    }.width(48)
                                    TableColumn("File") { item in Text(item.title) }
                                    TableColumn("Disc Filename") { item in
                                        Text(state.multichannelPCMOutputFilename(for: item))
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    TableColumn("Path") { item in Text(item.url.path) }
                                }
                                if state.multichannelLosslessTracks.isEmpty {
                                    Text("Drop or Add Files")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(minHeight: 150, maxHeight: 190)
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                handleTrackDrop(providers, target: .hybridMultichannelLossless)
                            }
                            Text("Written to PCM_DISC/\(state.multichannelAlbumName). MP3 remains in the separate stereo compatibility album.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if state.sacdPlusMultichannelMode && state.hybridFormat == "Maximum Compatibility" {
                        Label("Multichannel Mode plus Maximum Compatibility Mode requires stereo DSF, multichannel DSF, lossless FLAC/WAV support paths, and MP3 copies. This is a massive storage requirement for most albums and may not fit on the selected disc capacity.", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: {
                    if state.sacdPlusDirectBurnMode {
                        requestDirectBurn(.sacdPlus)
                    } else {
                        Task { await state.buildSACDPlus() }
                    }
                }) {
                    Label(state.sacdPlusDirectBurnMode ? "Author and Burn SACD+" : "Build SACD+ ISO",
                          systemImage: "opticaldisc")
                }
                .disabled(state.isWorking || state.sacdPlusTracks.isEmpty)
            }
        }
        .padding(12)
    }

    private func maximumCompatibilityTable(
        title: String,
        tracks: [TrackItem],
        emptyMessage: String,
        albumName: String,
        dropTarget: TrackDropTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        Rectangle()
                            .fill(index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                            .frame(height: 28)
                    }
                }
                .allowsHitTesting(false)
                Table(tracks) {
                    TableColumn("#") { item in
                        Text(maximumCompatibilityIndex(of: item, in: tracks))
                            .font(.system(.body, design: .monospaced))
                    }.width(48)
                    TableColumn("File") { item in Text(item.title) }
                    TableColumn("Disc Filename") { item in
                        Text(maximumCompatibilityOutputFilename(for: item, in: tracks))
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Path") { item in Text(item.url.path) }
                }
                if tracks.isEmpty {
                    Text(emptyMessage)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minHeight: 150, maxHeight: 190)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleTrackDrop(providers, target: dropTarget)
            }
            Text("Written to PCM_DISC/\(albumName)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func handleTrackDrop(_ providers: [NSItemProvider], target: TrackDropTarget) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !urlProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var droppedURLs: [URL] = []
        for provider in urlProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                if let url = object {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            state.addDroppedTracks(from: droppedURLs, to: target)
        }
        return true
    }

    private func maximumCompatibilityIndex(of item: TrackItem, in tracks: [TrackItem]) -> String {
        guard let index = tracks.firstIndex(of: item) else { return "---" }
        return String(format: "%03d", index + 1)
    }

    private func maximumCompatibilityOutputFilename(for item: TrackItem, in tracks: [TrackItem]) -> String {
        guard let index = tracks.firstIndex(of: item) else { return "—" }
        if !state.sacdPlusRenameTracks { return item.url.lastPathComponent }
        return String(format: "TRACK%03d.%@", index + 1, item.ext.uppercased())
    }

    private func multichannelDSFIndex(of item: TrackItem) -> String {
        guard let index = state.multichannelDSFTracks.firstIndex(of: item) else { return "---" }
        return String(format: "%03d", index + 1)
    }

    private func multichannelPCMIndex(of item: TrackItem) -> String {
        guard let index = state.multichannelLosslessTracks.firstIndex(of: item) else { return "---" }
        return String(format: "%03d", index + 1)
    }

    private func hybridIndex(of item: TrackItem) -> String {
        if let i = state.hybridTracks.firstIndex(of: item) { return String(format: "%02d", i + 1) }
        return "--"
    }
    
    private func mp3Index(of item: TrackItem) -> String {
        if let i = state.mp3Tracks.firstIndex(of: item) { return String(format: "%02d", i + 1) }
        return "--"
    }
    
    private func maximumCompatibilityLosslessIndex(of item: TrackItem) -> String {
        if let i = state.maximumCompatibilityLosslessTracks.firstIndex(of: item) { return String(format: "%02d", i + 1) }
        return "--"
    }

    private func sacdPlusIndex(of item: TrackItem) -> String {
        if let i = state.sacdPlusTracks.firstIndex(of: item) { return String(format: "%03d", i + 1) }
        return "--"
    }

    private func removeSelectedSACDPlusTracks() {
        state.sacdPlusTracks.removeAll { sacdPlusSelection.contains($0.id) }
        sacdPlusSelection.removeAll()
    }

    private func moveSelectedSACDPlusTracksUp() {
        guard state.sacdPlusTracks.count > 1 else { return }
        for index in state.sacdPlusTracks.indices where index > 0 {
            let currentID = state.sacdPlusTracks[index].id
            let previousID = state.sacdPlusTracks[index - 1].id
            if sacdPlusSelection.contains(currentID) && !sacdPlusSelection.contains(previousID) {
                state.sacdPlusTracks.swapAt(index, index - 1)
            }
        }
    }

    private func moveSelectedSACDPlusTracksDown() {
        guard state.sacdPlusTracks.count > 1 else { return }
        for index in state.sacdPlusTracks.indices.reversed() where index < state.sacdPlusTracks.count - 1 {
            let currentID = state.sacdPlusTracks[index].id
            let nextID = state.sacdPlusTracks[index + 1].id
            if sacdPlusSelection.contains(currentID) && !sacdPlusSelection.contains(nextID) {
                state.sacdPlusTracks.swapAt(index, index + 1)
            }
        }
    }

    // MARK: SACDx View

    private var sacdXView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !minimalistMode { experimentalModeTrigger }
                if !minimalistMode {
                    Spacer()
                    Image("SACDextendedlogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                }
            }
            Text("Creates a data disc containing an original ISO backup plus directly accessible DSF album paths. SACDx does not include Hybrid Mode or PCM_DISC.")
                .foregroundColor(.secondary)

            if experimentalMode {
                Toggle("Disable Backup Mode", isOn: $state.sacdXDirectBurnMode)
                if state.sacdXDirectBurnMode {
                    Label("Experimental direct burn: the selected ISO will be written sector-for-sector and verified. No BACKUP or DSD_DISC content will be authored or added.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !state.sacdXDirectBurnMode {
                HStack {
                    Text("Volume Name:")
                    TextField("SACDX", text: $state.sacdXVolumeName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Toggle("Multichannel", isOn: $state.sacdXMultichannelMode)
                    Toggle("Disable Track Renaming", isOn: Binding(
                        get: { !state.sacdXRenameTracks },
                        set: { state.sacdXRenameTracks = !$0 }
                    ))
                    Spacer()
                }
                HStack {
                    Text("Disc Capacity:")
                    Picker("", selection: $state.sacdXDiscCapacity) {
                        ForEach(SACDPlusDiscCapacity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    Spacer()
                }
                SpaceUsageBar(
                    projectSize: state.calculateProjectSize(),
                    capacity: state.sacdXDiscCapacity.bytes,
                    capacityName: state.sacdXDiscCapacity.rawValue,
                    formatBytes: state.formatBytes
                )
            }

            GroupBox(state.sacdXDirectBurnMode ? "ISO to Burn Directly" : "BACKUP Folder") {
                HStack {
                    Button("Choose Backup ISO…") { state.pickSACDxBackupISO() }
                    Text(state.sacdXBackupISO?.path ?? "No ISO selected")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            if !state.sacdXDirectBurnMode {
                sacdXTrackSection(
                    title: "Stereo DSD Album — DSD_DISC/ALBUM01",
                    tracks: state.sacdXStereoTracks,
                    selection: $sacdXStereoSelection,
                    multichannel: false,
                    dropTarget: .sacdXStereoDSF
                )
                if state.sacdXMultichannelMode {
                    sacdXTrackSection(
                        title: "Multichannel DSD Album — DSD_DISC/ALBUM02",
                        tracks: state.sacdXMultichannelTracks,
                        selection: $sacdXMultichannelSelection,
                        multichannel: true,
                        dropTarget: .sacdXMultichannelDSF
                    )
                }
            }

            HStack {
                Spacer()
                Button {
                    if state.sacdXDirectBurnMode {
                        requestDirectBurn(.sacdX)
                    } else {
                        Task { await state.buildSACDx() }
                    }
                } label: {
                    Label(state.sacdXDirectBurnMode ? "Burn Selected ISO Directly" : "Build SACDx ISO", systemImage: "opticaldisc")
                }
                .disabled(state.isWorking || state.sacdXBackupISO == nil || (!state.sacdXDirectBurnMode && state.sacdXStereoTracks.isEmpty))
            }
        }
        .padding(12)
    }

    private func sacdXTrackSection(
        title: String,
        tracks: [TrackItem],
        selection: Binding<Set<TrackItem.ID>>,
        multichannel: Bool,
        dropTarget: TrackDropTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Button("Add DSF Tracks") { state.pickSACDxTracks(multichannel: multichannel) }
                Button("Remove Selected") {
                    if multichannel {
                        state.sacdXMultichannelTracks.removeAll { selection.wrappedValue.contains($0.id) }
                    } else {
                        state.sacdXStereoTracks.removeAll { selection.wrappedValue.contains($0.id) }
                    }
                    selection.wrappedValue.removeAll()
                }
                .disabled(selection.wrappedValue.isEmpty)
                Spacer()
            }
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        Rectangle()
                            .fill(index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                            .frame(height: 28)
                    }
                }
                .allowsHitTesting(false)
                Table(tracks, selection: selection) {
                    TableColumn("#") { item in
                        Text(sacdXIndex(of: item, in: tracks)).font(.system(.body, design: .monospaced))
                    }.width(48)
                    TableColumn("File") { item in Text(item.title) }
                    TableColumn("Disc Filename") { item in
                        Text(sacdXOutputFilename(for: item, in: tracks)).font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Path") { item in Text(item.url.path) }
                }
                if tracks.isEmpty { Text("Drop or Add Files").foregroundColor(.secondary) }
            }
            .frame(minHeight: 150, maxHeight: 190)
            .onDrop(of: [.fileURL], isTargeted: nil) { handleTrackDrop($0, target: dropTarget) }
        }
    }

    private func sacdXIndex(of item: TrackItem, in tracks: [TrackItem]) -> String {
        guard let index = tracks.firstIndex(of: item) else { return "---" }
        return String(format: "%03d", index + 1)
    }

    private func sacdXOutputFilename(for item: TrackItem, in tracks: [TrackItem]) -> String {
        guard let index = tracks.firstIndex(of: item) else { return "—" }
        return state.sacdXRenameTracks ? String(format: "TRACK%03d.dsf", index + 1) : item.url.lastPathComponent
    }

    // MARK: SACD-R View

    private var sacdRView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                if !minimalistMode { experimentalModeTrigger }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Rights & Responsible Use", systemImage: "shield.lefthalf.filled")
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text("SACD and its related technologies and trademarks belong to their respective rights holders, including Sony and Philips. This independent application is not affiliated with, endorsed by, or sponsored by those companies.")
                        Text("This experimental tool is intended only for authoring your own original material with a lawfully obtained donor SACD template that you are authorized to use. It must not be used to copy, circumvent protections on, reproduce, or distribute unauthorized SACD content. You are responsible for complying with all applicable rights and laws.")
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: 680, alignment: .leading)
                if !minimalistMode {
                    Spacer()
                    Image("SACDRLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                }
            }

            HStack {
                Text("Volume Name:")
                TextField("SACD_R", text: $state.sacdVolumeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
            }
            
            HStack {
                Text("Disc Capacity:")
                Picker("", selection: $state.sacdRDiscCapacity) {
                    ForEach(SACDRDiscCapacity.allCases, id: \.self) { capacity in
                        Text(capacity.rawValue).tag(capacity)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                Spacer()
            }
            
            // Space Usage Bar for SACD-R
            SpaceUsageBar(
                projectSize: state.calculateProjectSize(),
                capacity: state.sacdRDiscCapacity.bytes,
                capacityName: state.sacdRDiscCapacity.rawValue,
                formatBytes: state.formatBytes
            )

            GroupBox(label: Label("Donor SACD Template", systemImage: "folder")) {
                HStack(spacing: 8) {
                    Button("Choose SACD Folder/ISO…") { state.pickSacdFolder() }
                    if let src = state.sacdSourceFolder {
                        Text(src.path).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("(folder with MASTER.TOC, 2CH/, MCH/ or SACD ISO file)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    Button(action: { Task { await state.buildSACDRFromFolder() } }) {
                        Label("Package Template → ISO", systemImage: "opticaldiscdrive")
                    }
                    .disabled(state.isWorking || state.sacdSourceFolder == nil)
                    Spacer()
                }
            }

            GroupBox(label: Label("Tracks → SACD-R Assembler (Template-based)", systemImage: "waveform")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Toggle("Multichannel (MCH)", isOn: $state.sacdUseMultichannel)
                        Toggle("Allow raw stereo DSD (experimental)", isOn: $state.allowStereoRawDSD)
                            .disabled(state.sacdUseMultichannel)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("Add DSD Tracks…") { state.pickSACDTracks() }
                        Button("Remove Selected") { removeSelectedSACDTracks() }
                            .disabled(sacdSelection.isEmpty)
                        Divider()
                        Button("Choose DST Encoder…") { state.pickDSTEncoder() }
                        Text(state.dstEncoderPath?.path ?? "(optional; required for MCH or when DST forced)")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ZStack {
                        // Row striping background
                        VStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { i in
                                Rectangle()
                                    .fill(i % 2 == 0 ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                                    .frame(height: 28)
                            }
                        }
                        .allowsHitTesting(false)
                        // Table
                        Table(state.sacdTracks, selection: $sacdSelection) {
                            TableColumn("#") { item in
                                Text(sacdIndex(of: item)).font(.system(.body, design: .monospaced))
                            }.width(40)
                            TableColumn("File") { item in Text(item.title) }
                            TableColumn("Ext") { item in Text(item.ext.uppercased()) }.width(60)
                            TableColumn("Path") { item in Text(item.url.path) }
                        }
                        // Overlay placeholder if empty
                        if state.sacdTracks.isEmpty {
                            Text("Drop or Add Files")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.clear)
                        }
                    }
                    .frame(minHeight: 150, maxHeight: 190)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleTrackDrop(providers, target: .sacdRDSF)
                    }

                    HStack {
                        Button(action: { Task { await state.buildSACDFromScratch() } }) {
                            Label("Generate SACD from DSD", systemImage: "sparkles")
                        }
                        .disabled(state.isWorking || state.sacdTracks.isEmpty)
                        
                        Spacer()
                        
                        Button(action: { Task { await state.assembleSACDRFromTracks() } }) {
                            Label("Build SACD-R ISO from Tracks", systemImage: "opticaldisc")
                        }
                        .disabled(state.isWorking || state.sacdSourceFolder == nil || state.sacdTracks.isEmpty)
                    }
                }
            }
        }
        .padding(12)
    }

    private func sacdIndex(of item: TrackItem) -> String {
        if let i = state.sacdTracks.firstIndex(of: item) { return String(format: "%02d", i + 1) }
        return "--"
    }

    private func removeSelectedSACDTracks() {
        state.sacdTracks.removeAll { sacdSelection.contains($0.id) }
        sacdSelection.removeAll()
    }

    // MARK: Footer / Log Panel Only

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Build Log").font(.headline)
                Spacer()
                Toggle("Show Build Log", isOn: $showLog)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                Text("Show Build Log")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 3)
            }
            if showLog {
                ScrollView {
                    Text(state.log.isEmpty ? "(No output yet)" : state.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .frame(maxHeight: 120)
            }
            
            // Progress bar - always visible during work, when completed, or when failed
            if state.isWorking || state.buildProgress > 0 || state.buildCompleted || state.buildFailed {
                VStack(alignment: .leading, spacing: 4) {
                    if state.buildCompleted {
                        // Show green "Done" indicator
                        HStack {
                            Text("Done")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                            Spacer()
                            Button {
                                state.burnLastISOWithFinder()
                            } label: {
                                Label("Burn ISO with Finder…", systemImage: "opticaldiscdrive")
                            }
                            .disabled(state.lastBuiltISOURL == nil)
                            Text("✓")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                        Rectangle()
                            .fill(Color.green)
                            .frame(height: 4)
                    } else if state.buildFailed {
                        // Show red "Failed" indicator
                        HStack {
                            Text("Failed")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                            Spacer()
                            Text("✗")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.red)
                        }
                        Rectangle()
                            .fill(Color.red)
                            .frame(height: 4)
                    } else {
                        // Show normal progress bar
                        HStack {
                            Text(state.currentTask.isEmpty ? "Processing..." : state.currentTask)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if state.progressIsIndeterminate {
                                Text("Working…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(String(format: "%.0f%%", state.buildProgress * 100))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if state.progressIsIndeterminate {
                            ProgressView()
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                .frame(height: 4)
                        } else {
                            ProgressView(value: state.buildProgress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                .frame(height: 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .padding(12)
    }

    private var experimentalModeTrigger: some View {
        Button(action: registerExperimentalTriggerClick) {
            VStack(spacing: 4) {
                Image("DSDlogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 82, height: 82)
                if experimentalMode {
                    Text("Experimental")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                }
            }
            .frame(width: 100, height: 100)
            .contentShape(Rectangle())
        }
        .buttonStyle(ExperimentalTriggerButtonStyle(active: experimentalMode))
        .accessibilityLabel(experimentalMode ? "Experimental Mode enabled" : "DSD")
        .help(experimentalMode ? "Experimental Mode enabled" : "DSD")
    }

    private func registerExperimentalTriggerClick() {
        let now = Date()
        if let lastClick = experimentalTriggerLastClick,
           now.timeIntervalSince(lastClick) <= 0.8 {
            experimentalTriggerClickCount += 1
        } else {
            experimentalTriggerClickCount = 1
        }
        experimentalTriggerLastClick = now

        guard experimentalTriggerClickCount >= 3 else { return }
        experimentalTriggerClickCount = 0
        experimentalTriggerLastClick = nil
        if experimentalMode {
            withAnimation(.easeInOut(duration: 0.18)) {
                experimentalMode = false
            }
            if state.mode == .sacdR { state.mode = .sacdPlus }
            state.sacdXDirectBurnMode = false
        } else {
            showExperimentalModeWarning = true
        }
    }

    private var descriptionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                switch state.mode {
            case .sacdX:
                VStack(alignment: .leading, spacing: 10) {
                    Text("SACDx").font(.headline).bold()
                    Text("Preserves a complete ISO in BACKUP while exposing DSF tracks through a deterministic DSD_DISC structure.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Disc layout:").font(.subheadline.bold())
                    Text("BACKUP/<selected ISO>\nDSD_DISC/ALBUM01/<stereo DSF>\nDSD_DISC/ALBUM02/<multichannel DSF, optional>")
                        .font(.caption.monospaced())
                    Label("No Hybrid Mode, PCM_DISC, FLAC, WAV, or MP3 paths", systemImage: "info.circle")
                        .font(.caption)
                }
            case .sacdR:
                VStack(alignment: .leading, spacing: 10) {
                    Text("SACD-R Discs")
                        .font(.headline).bold()
                    Text("Create disc images compatible with many SACD players using a donor SACD folder as a template. Replace or add DSD tracks and package as an ISO for burning or playback.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Requirements:")
                        .font(.subheadline).bold()
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Donor SACD folder (must contain MASTER.TOC, 2CH/, optional MCH/)", systemImage: "folder")
                            .font(.caption)
                        Label("DSF tracks to inject", systemImage: "music.note")
                            .font(.caption)
                        Label("DST encoder binary (required for MCH or when DST forced)", systemImage: "gear")
                            .font(.caption)
                    }
                    Spacer().frame(height: 6)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Limitations").font(.subheadline).bold()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Does not regenerate MASTER.TOC or INDEX.PTI.")
                        Text("• Track count/length must match donor template.")
                        Text("• Raw stereo DSD is experimental.")
                    }
                    .font(.caption)
                }
            case .sacdPlus:
                VStack(alignment: .leading, spacing: 10) {
                    if state.sacdPlusEnhancedMode {
                        // Enhanced Mode Description
                        Text("SACD+ Enhanced")
                            .font(.headline).bold()
                            .foregroundColor(.blue)
                        
                        Text("Modern flat structure format with preserved metadata. Perfect for software playback and modern SACD players that support flat file organization.")
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Text("Key Features:")
                            .font(.subheadline).bold()
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Flat file structure (no folders)", systemImage: "folder")
                            Label("DSF files only (required)", systemImage: "music.note")
                            Label("Optional multichannel DSF and lossless support paths", systemImage: "speaker.wave.3")
                            Label("All metadata preserved", systemImage: "tag")
                            Label("FLAC hybrid support with tags", systemImage: "waveform")
                            Label("Optional uncompressed WAV support", systemImage: "externaldrive")
                        }
                        .font(.caption)
                        
                        Spacer().frame(height: 6)
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Requirements & Limitations").font(.subheadline).bold()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• DSF files only.")
                            Text("• Hybrid mode uses FLAC unless Uncompressed Support Mode is enabled.")
                            Text("• WAV support uses substantially more disc space.")
                            Text("• No traditional folder organization.")
                            Text("• May not work with older SACD players.")
                        }
                        .font(.caption)
                        
                    } else {
                        // Standard Mode Description
                        Text("SACD+ Discs")
                            .font(.headline).bold()
                        
                        Text("Build UDF 1.02 disc images with DSD tracks for playback on compatible hardware and software. Simple folder structure, easy to author.")
                            .fixedSize(horizontal: false, vertical: true)
                            
                        Text("SACD+ is an evolution of the classic DSD DISC concept. Hybrid Mode adds lossless FLAC support, with optional uncompressed WAV support. Maximum Compatibility Mode pairs MP3 with the selected lossless path: FLAC by default or WAV in Uncompressed Support Mode.")
                            .fixedSize(horizontal: false, vertical: true)
                            
                        Text("How it works:")
                            .font(.subheadline).bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• Add your DSF tracks to an album folder.")
                            Text("• Each track is renamed to TRACKxxx.ext.")
                            Text("• Output is a standard UDF ISO image.")
                            Text("• Multichannel Mode supports DSF with FLAC or WAV, but never MP3.")
                        }
                        .font(.caption)
                        
                        Spacer().frame(height: 6)
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("Limitations").font(.subheadline).bold()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• Not compatible with all SACD players.")
                            Text("• No copy protection or advanced features.")
                        }
                        .font(.caption)
                    }
                }
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
