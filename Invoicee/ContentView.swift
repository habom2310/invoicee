//
//  ContentView.swift
//  Invoicee
//
//  Created by Ha Nguyen on 3/10/2025.
//

internal import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        TabView {
            InvoiceTabView()
                .tabItem {
                    Label("Invoice", systemImage: "doc.text.viewfinder")
                }

            ExpenseTabView(viewModel: ExpenseAnalyticsViewModel(archive: appEnvironment.invoiceArchive,
                                                                 periodStore: appEnvironment.reportingPeriodStore,
                                                                 revenueSummaryProvider: appEnvironment.revenueSummaryProvider))
                .tabItem {
                    Label("Expense", systemImage: "chart.pie")
                }

            RevenueTabView(viewModel: RevenueViewModel(store: appEnvironment.revenueStore,
                                                       driveConnector: appEnvironment.driveConnector))
                .tabItem {
                    Label("Revenue", systemImage: "dollarsign.arrow.circlepath")
                }

            ProfitTabView(viewModel: ProfitAnalyticsViewModel(invoiceArchive: appEnvironment.invoiceArchive,
                                                              revenueStore: appEnvironment.revenueStore,
                                                              driveConnector: appEnvironment.driveConnector))
                .tabItem {
                    Label("Profit", systemImage: "chart.line.uptrend.xyaxis")
                }

            ProfileTabView(viewModel: appEnvironment.makeDriveLinkViewModel())
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
    }
}

#Preview {
    let environment = AppEnvironment.makeDefault()
    return ContentView()
        .environmentObject(environment)
        .environmentObject(environment.invoiceArchive)
        .environmentObject(environment.reportingPeriodStore)
        .environmentObject(environment.driveConnector)
        .environmentObject(environment.categoryStore)
}
