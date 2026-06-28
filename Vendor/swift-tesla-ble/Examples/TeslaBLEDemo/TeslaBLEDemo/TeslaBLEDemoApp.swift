//
//  TeslaBLEDemoApp.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import SwiftUI

@main
struct TeslaBLEDemoApp: App {
    @State
    private var controller = VehicleController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
        }
    }
}
