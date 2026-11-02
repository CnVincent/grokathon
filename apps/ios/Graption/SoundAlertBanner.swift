//
//  SoundAlertBanner.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import GraptionAudio
import SwiftUI

// Minimal banner so A3 can be checked on a phone.
// The styled version belongs in GraptionUI.
struct SoundAlertBanner: View {
    let alert: SoundAlert

    var body: some View {
        Label(
            Self.title(for: alert.label),
            systemImage: Self.symbol(for: alert.label)
        )
        .font(.title.bold())
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.yellow, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    static func title(for label: String) -> String {
        switch label {
        case "doorbell": "Doorbell"
        case "knock": "Knocking"
        case "alarm": "Alarm"
        case "siren": "Siren"
        case "dog_bark": "Dog barking"
        case "baby_cry": "Baby crying"
        case "laughter": "Laughter"
        case "phone_ring": "Phone ringing"
        default: label
        }
    }

    static func symbol(for label: String) -> String {
        switch label {
        case "doorbell": "bell.fill"
        case "knock": "hand.raised.fill"
        case "alarm": "alarm.fill"
        case "siren": "light.beacon.max.fill"
        case "dog_bark": "dog.fill"
        case "baby_cry": "figure.child"
        case "laughter": "face.smiling"
        case "phone_ring": "phone.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
