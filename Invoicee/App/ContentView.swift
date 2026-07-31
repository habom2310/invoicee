internal import SwiftUI

/// The app's tab bar. Each tab owns its view model for the lifetime of the tab; the
/// `@autoclosure` initialisers mean `AppEnvironment.make…ViewModel()` is called once,
/// not on every `body` pass.
struct ContentView: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        TabView {
            InvoiceTabView()
                .tabItem { Label("Invoice", systemImage: "doc.text.viewfinder") }

            ExpenseTabView(viewModel: appEnvironment.makeExpenseViewModel())
                .tabItem { Label("Expense", systemImage: "chart.pie") }

            RevenueTabView(viewModel: appEnvironment.makeRevenueViewModel())
                .tabItem { Label("Revenue", systemImage: "dollarsign.arrow.circlepath") }

            ProfitTabView(viewModel: appEnvironment.makeProfitViewModel())
                .tabItem { Label("Profit", systemImage: "chart.line.uptrend.xyaxis") }

            ProfileTabView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}
