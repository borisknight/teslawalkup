//
//  ConnectionStatusRow.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import SwiftUI
import TeslaBLE

/// Single row summarizing `ConnectionState`. Driven entirely by the enum
/// — errors are shown via the global alert, not this row.
struct ConnectionStatusRow: View {
    let state: ConnectionState

    var body: some View {
        LabeledContent {
            if isBusy {
                ProgressView()
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    private var title: String {
        switch state {
        case .disconnected: "Disconnected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .handshaking: "Handshaking…"
        case .connected: "Connected"
        }
    }

    private var systemImage: String {
        switch state {
        case .disconnected: "wifi.slash"
        case .scanning, .connecting, .handshaking: "antenna.radiowaves.left.and.right"
        case .connected: "wifi"
        }
    }

    private var isBusy: Bool {
        switch state {
        case .scanning, .connecting, .handshaking: true
        default: false
        }
    }
}
