//
//  InvoiceeApp.swift
//  Invoicee
//
//  Created by Ha Nguyen on 3/10/2025.
//

internal import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct InvoiceeApp: App {
    @StateObject private var environment = AppEnvironment.makeDefault()

    init() {
#if canImport(FirebaseCore)
        FirebaseApp.configure()
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(environment)
                .environmentObject(environment.invoiceArchive)
                .environmentObject(environment.reportingPeriodStore)
                .environmentObject(environment.driveConnector)
                .environmentObject(environment.categoryStore)
        }
    }
}
