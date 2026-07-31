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
                .invoiceeEnvironment(environment)
        }
    }
}

extension View {
    /// Publishes the shared stores the feature views read via `@EnvironmentObject`.
    ///
    /// One list, in one place: the app entry point and the previews used to each maintain
    /// their own copy, so a new store had to be remembered twice or previews crashed at
    /// runtime with a missing-environment-object trap.
    func invoiceeEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environmentObject(environment)
            .environmentObject(environment.invoiceArchive)
            .environmentObject(environment.reportingPeriodStore)
            .environmentObject(environment.driveConnector)
            .environmentObject(environment.categoryStore)
    }
}
