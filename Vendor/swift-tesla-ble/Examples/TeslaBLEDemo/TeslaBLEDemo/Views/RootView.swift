//
//  RootView.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import SwiftUI

struct RootView: View {
    @Environment(VehicleController.self)
    private var controller

    var body: some View {
        @Bindable var bindable = controller

        NavigationStack {
            Group {
                if controller.pairedVIN != nil {
                    DashboardView(controller: controller)
                } else {
                    PairingView()
                }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { controller.lastError != nil },
                set: { if !$0 { bindable.lastError = nil } },
            ),
            actions: { Button("OK") {} },
            message: { Text(controller.lastError ?? "") },
        )
    }
}

#if DEBUG

#Preview {
    RootView()
        .environment(VehicleController())
}

#endif
