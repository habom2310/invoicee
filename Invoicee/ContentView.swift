//
//  ContentView.swift
//  Invoicee
//
//  Created by Ha Nguyen on 3/10/2025.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            InvoiceTabView()
                .tabItem {
                    Label("Invoice", systemImage: "doc.text.viewfinder")
                }

            ExpenseTabView()
                .tabItem {
                    Label("Expense", systemImage: "chart.pie")
                }

            ProfileTabView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
    }
}

#Preview {
    ContentView()
}
