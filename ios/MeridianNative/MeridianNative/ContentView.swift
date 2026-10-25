//
//  ContentView.swift
//  MeridianNative
//

import SwiftUI

struct ContentView: View {
    @State private var host = GameHost()
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            MetalView(host: host).ignoresSafeArea()
            GameUI(ui: host.game.ui)
        }
        .background(Color(red: 0xf3 / 255, green: 0xea / 255, blue: 0xd9 / 255))
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onChange(of: scenePhase) { _, phase in host.setActive(phase == .active) }
    }
}

private struct MetalView: UIViewRepresentable {
    let host: GameHost

    func makeUIView(context: Context) -> GameMTKView { host.view }
    func updateUIView(_ view: GameMTKView, context: Context) {}
}
