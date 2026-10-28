import Foundation
import SwiftUI

@Observable final class SkyScroll {
    static let fadeDistance: CGFloat = 320
    var offset: CGFloat = 0
}

struct TwilightSky: View {
    var scroll: SkyScroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var start = Date.now

    var body: some View {
        let offset = scroll.offset
        GeometryReader { proxy in
            if offset < SkyScroll.fadeDistance {
                sky(in: proxy.size)
                    .offset(y: -offset)
                    .opacity(1 - offset / SkyScroll.fadeDistance)
            }
        }
        .background(colorScheme == .light ? .white : .black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sky(in size: CGSize) -> some View {
        Group {
            let height = size.height * 0.78
            TimelineView(.animation(minimumInterval: reduceMotion ? 60 : 1 / 24)) { context in
                let elapsed = reduceMotion ? 0 : context.date.timeIntervalSince(start)
                let sky = SkyState(at: SolarClock.date(for: context.date, since: start))
                Rectangle()
                    .colorEffect(ShaderLibrary.twilightSky(
                        .float2(size.width, height),
                        .float(elapsed * min(SolarClock.speed, 40)),
                        .float4(sky.sunHourAngle, sky.sunElevation, sky.cloudCover, elapsed),
                        .float4(sky.moonHourAngle, sky.moonElevation, sky.moonPhase, colorScheme == .light ? 1 : 0)
                    ))
                    .frame(height: height)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// Without location access, the time zone's standard meridian stands in for longitude and a mid-latitude for
// latitude. That places sunrise and sunset within roughly half an hour for most of the populated world.
nonisolated struct SkyState {
    var sunHourAngle: Double
    var sunElevation: Double
    var moonHourAngle: Double
    var moonElevation: Double
    var moonPhase: Double
    var cloudCover: Double

    private static let newMoon = Date(timeIntervalSince1970: 947_182_440)
    private static let synodicMonth = 29.530588853

    init(at date: Date, timeZone: TimeZone = .current, latitude: Double = 40) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let utcHours = date.timeIntervalSince(calendar.startOfDay(for: date)) / 3600
        let standardOffset = Double(timeZone.secondsFromGMT(for: date)) - timeZone.daylightSavingTimeOffset(for: date)
        let longitude = standardOffset / 3600 * 15

        let declination = -23.44 * cos(2 * .pi / 365 * (day + 10))
        let b = 2 * Double.pi * (day - 81) / 364
        let equationOfTime = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)
        sunHourAngle = Self.wrap(15 * (utcHours + longitude / 15 + equationOfTime / 60 - 12))
        sunElevation = Self.elevation(hourAngle: sunHourAngle, declination: declination, latitude: latitude)

        let lunations = date.timeIntervalSince(Self.newMoon) / 86_400 / Self.synodicMonth
        moonPhase = lunations - lunations.rounded(.down)
        // The moon trails the sun by its phase angle and sits on the opposite side of the ecliptic when full.
        moonHourAngle = Self.wrap(sunHourAngle - moonPhase * 360)
        moonElevation = Self.elevation(hourAngle: moonHourAngle, declination: declination * cos(2 * .pi * moonPhase), latitude: latitude)

        let seed = sin(day * 12.9898 + Double(calendar.component(.year, from: date)) * 78.233) * 43_758.5453
        cloudCover = 0.2 + 0.45 * (seed - seed.rounded(.down))
    }

    private static func wrap(_ degrees: Double) -> Double {
        let turned = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (turned < 0 ? turned + 360 : turned) - 180
    }

    private static func elevation(hourAngle: Double, declination: Double, latitude: Double) -> Double {
        let radians = Double.pi / 180
        let sine = sin(latitude * radians) * sin(declination * radians)
            + cos(latitude * radians) * cos(declination * radians) * cos(hourAngle * radians)
        return asin(max(-1, min(1, sine))) / radians
    }
}

nonisolated enum SolarClock {
    #if DEBUG
    private static func argument(_ name: String) -> Double? {
        guard let index = CommandLine.arguments.firstIndex(of: name) else { return nil }
        return CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init)
    }
    private static let hour = argument("-skyHour")
    static let speed = argument("-skySpeed") ?? 1
    #else
    static let speed = 1.0
    #endif

    static func date(for now: Date, since start: Date) -> Date {
        #if DEBUG
        let base = hour.map { Calendar.current.startOfDay(for: start).addingTimeInterval($0 * 3600) } ?? start
        return base.addingTimeInterval(now.timeIntervalSince(start) * speed)
        #else
        return now
        #endif
    }
}
