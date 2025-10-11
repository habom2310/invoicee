//
//  InvoiceeApp.swift
//  Invoicee
//
//  Created by Ha Nguyen on 3/10/2025.
//

import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct InvoiceeApp: App {
    init() {
#if canImport(FirebaseCore)
        FirebaseApp.configure()
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
