//
//  SACD_Design_SuiteApp.swift
//  SACD Design Suite
//
//  Created by Cory on 9/8/25.
//

import SwiftUI
import DiscRecording

let selectedOpticalDrivePathKey = "selectedOpticalDrivePath"
private let selectedOpticalDriveNameKey = "selectedOpticalDriveName"
let minimalistModeKey = "minimalistMode"
let sacdPlusFocusModeKey = "sacdPlusFocusMode"
let startupInterfaceModeKey = "startupInterfaceMode"

private struct OpticalDriveChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct DriveSettingsView: View {
    @AppStorage(selectedOpticalDrivePathKey) private var selectedDrivePath = ""
    @AppStorage(selectedOpticalDriveNameKey) private var selectedDriveName = "Automatic"
    @State private var drives: [OpticalDriveChoice] = []

    var body: some View {
        Form {
            Section("Optical Disc Burning") {
                Picker("Burner:", selection: $selectedDrivePath) {
                    Text("Automatic (macOS default)").tag("")
                    ForEach(drives) { drive in
                        Text(drive.name).tag(drive.id)
                    }
                    if !selectedDrivePath.isEmpty && !drives.contains(where: { $0.id == selectedDrivePath }) {
                        Text("\(selectedDriveName) (Not Connected)").tag(selectedDrivePath)
                    }
                }
                .frame(maxWidth: 430)

                Text("The selected drive is used by both SACD+ and SACDx direct burns. Automatic lets macOS choose the burner.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Refresh Drives") { refreshDrives() }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDrives() }
        .onChange(of: selectedDrivePath) { _, newPath in
            selectedDriveName = drives.first(where: { $0.id == newPath })?.name ?? "Automatic"
        }
    }

    private func refreshDrives() {
        drives = (DRDevice.devices() as? [DRDevice] ?? [])
            .filter { $0.writesDVD() }
            .map {
                OpticalDriveChoice(
                    id: $0.ioRegistryEntryPath(),
                    name: $0.displayName()
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct ModeSettingsView: View {
    @AppStorage(minimalistModeKey) private var minimalistMode = true
    @AppStorage(sacdPlusFocusModeKey) private var sacdPlusFocusMode = true
    @AppStorage(startupInterfaceModeKey) private var startupInterfaceMode = "super"

    var body: some View {
        Form {
            Section("Interface") {
                HStack {
                    Toggle("Super Minimal Mode", isOn: Binding(
                        get: { minimalistMode && sacdPlusFocusMode },
                        set: { enabled in
                            minimalistMode = enabled
                            sacdPlusFocusMode = enabled
                        }
                    ))
                    Spacer()
                    startupButton(for: "super")
                }
                Text("Enables both Minimalist Mode and SACD+ Focus Mode for the simplest SACD+‑only interface.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Toggle("Minimalist Mode", isOn: $minimalistMode)
                    Spacer()
                    startupButton(for: "minimalist")
                }
                Text("Hides artwork and logos, keeps the Help pane closed, and removes the Show/Hide Help control.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Toggle("SACD+ Focus Mode", isOn: $sacdPlusFocusMode)
                    Spacer()
                    startupButton(for: "focus")
                }
                Text("Hides SACDx from the main mode selector. SACD+ remains available, along with SACD when Experimental Mode is unlocked.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func startupButton(for profile: String) -> some View {
        Button(startupInterfaceMode == profile ? "Startup Default ✓" : "Set as Startup Default") {
            startupInterfaceMode = profile
            switch profile {
            case "minimalist":
                minimalistMode = true
                sacdPlusFocusMode = false
            case "focus":
                minimalistMode = false
                sacdPlusFocusMode = true
            default:
                minimalistMode = true
                sacdPlusFocusMode = true
            }
        }
        .controlSize(.small)
        .disabled(startupInterfaceMode == profile)
    }
}

private struct AppSettingsView: View {
    @AppStorage(selectedOpticalDrivePathKey) private var selectedDrivePath = ""
    @AppStorage(selectedOpticalDriveNameKey) private var selectedDriveName = "Automatic"
    @AppStorage(minimalistModeKey) private var minimalistMode = true
    @AppStorage(sacdPlusFocusModeKey) private var sacdPlusFocusMode = true
    @AppStorage(startupInterfaceModeKey) private var startupInterfaceMode = "super"

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                DriveSettingsView()
                    .tabItem { Label("Drive", systemImage: "opticaldiscdrive") }
                ModeSettingsView()
                    .tabItem { Label("Mode", systemImage: "switch.2") }
            }
            Divider()
            HStack {
                Spacer()
                Button("Reset Defaults") { resetDefaults() }
            }
            .padding(12)
        }
        .frame(width: 620, height: 340)
    }

    private func resetDefaults() {
        selectedDrivePath = ""
        selectedDriveName = "Automatic"
        minimalistMode = false
        sacdPlusFocusMode = false
        startupInterfaceMode = "standard"
    }
}

@main
struct SACD_Design_SuiteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.expanded)
        Settings {
            AppSettingsView()
        }
    }
}
