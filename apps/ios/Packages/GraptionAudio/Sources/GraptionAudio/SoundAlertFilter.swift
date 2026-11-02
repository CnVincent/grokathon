//
//  SoundAlertFilter.swift
//  Graption
//
//  Created by Arjun on 10/6/26.
//

import Foundation

public struct SoundAlertFilter: Sendable {
    // Apple `.version1` identifiers mapped to Graption labels.
    // Every key is checked against `knownClassifications` in tests.
    public static let labels: [String: String] = [
        "door_bell": "doorbell",
        "knock": "knock",
        "smoke_detector": "alarm",
        "alarm_clock": "alarm",
        "siren": "siren",
        "civil_defense_siren": "siren",
        "police_siren": "siren",
        "ambulance_siren": "siren",
        "fire_engine_siren": "siren",
        "dog_bark": "dog_bark",
        "dog_bow_wow": "dog_bark",
        "baby_crying": "baby_cry",
        "laughter": "laughter",
        "belly_laugh": "laughter",
        "telephone_bell_ringing": "phone_ring",
        "ringtone": "phone_ring"
    ]

    public let minConfidence: Double
    public let cooldown: TimeInterval

    private var lastAlertTime: [String: TimeInterval] = [:]

    public init(
        minConfidence: Double = 0.7,
        cooldown: TimeInterval = 3
    ) {
        self.minConfidence = minConfidence
        self.cooldown = cooldown
    }

    // Returns at most one alert per label for this window,
    // skipping labels still inside their cooldown.
    public mutating func alerts(
        for classifications: [(identifier: String, confidence: Double)],
        at t: TimeInterval
    ) -> [SoundAlert] {
        // Several identifiers can share a label (e.g. sirens).
        var best: [String: Double] = [:]

        for (identifier, confidence) in classifications {
            guard let label = Self.labels[identifier],
                  confidence >= minConfidence else {
                continue
            }

            best[label] = max(best[label] ?? 0, confidence)
        }

        let ranked = best.sorted {
            ($0.value, $1.key) > ($1.value, $0.key)
        }

        var alerts: [SoundAlert] = []

        for (label, confidence) in ranked {
            if let last = lastAlertTime[label],
               t - last < cooldown {
                continue
            }

            lastAlertTime[label] = t
            alerts.append(
                SoundAlert(label: label, t: t, confidence: confidence)
            )
        }

        return alerts
    }

    public mutating func reset() {
        lastAlertTime.removeAll()
    }
}
