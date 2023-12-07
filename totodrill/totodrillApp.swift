//
//  totodrillApp.swift
//  totodrill
//
//  Created by Jesus Lopez on 12/4/23.
//

import SwiftUI

@main
struct totodrillApp: App {
    @State private var speechRecognizer = SpeechRecognizer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(speechRecognizer)
        }
    }
}
