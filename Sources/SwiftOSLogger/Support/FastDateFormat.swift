import Foundation

/// Formats numeric date patterns (`yyyy MM dd HH mm ss SSS Z XXXXX` plus literals) without
/// `DateFormatter`, producing exactly what an `en_US_POSIX` Gregorian `DateFormatter` produces.
///
/// `DateFormatter` costs several microseconds per call and leaves autoreleased objects behind;
/// this is plain integer arithmetic. Anything outside the supported subset returns `nil` so the
/// caller can fall back to `DateFormatter`.
enum FastDateFormat {
    enum Token: Equatable {
        case year4, month2, day2, hour2, minute2, second2, millis3
        /// `Z`: `+0530`
        case offsetBasic
        /// `XXXXX`: `Z` for UTC, otherwise `+05:30`
        case offsetISO
        case literal(UInt8)
    }

    /// Instants handled by the fast path: 1970-01-01 up to 2100-01-01, in milliseconds.
    private static let supportedMilliseconds: ClosedRange<Double> = 0...4_102_444_800_000

    static func string(from date: Date, format: String, timeZone: TimeZone) -> String? {
        compile(format).flatMap { string(from: date, tokens: $0, timeZone: timeZone) }
    }

    /// Parses `format` into tokens, or returns `nil` if it uses anything unsupported.
    static func compile(_ format: String) -> [Token]? {
        var tokens: [Token] = []
        let bytes = Array(format.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte < 0x80 else { return nil }
            if byte == UInt8(ascii: "'") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "'") {   // '' is a literal quote
                    tokens.append(.literal(byte))
                    index += 1
                    continue
                }
                while index < bytes.count, bytes[index] != UInt8(ascii: "'") {
                    guard bytes[index] < 0x80 else { return nil }
                    tokens.append(.literal(bytes[index]))
                    index += 1
                }
                guard index < bytes.count else { return nil }   // unterminated quote
                index += 1
                continue
            }
            let isLetter = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            guard isLetter else {
                tokens.append(.literal(byte))
                index += 1
                continue
            }
            var run = 1
            while index + run < bytes.count, bytes[index + run] == byte { run += 1 }
            switch (Character(Unicode.Scalar(byte)), run) {
            case ("y", 4): tokens.append(.year4)
            case ("M", 2): tokens.append(.month2)
            case ("d", 2): tokens.append(.day2)
            case ("H", 2): tokens.append(.hour2)
            case ("m", 2): tokens.append(.minute2)
            case ("s", 2): tokens.append(.second2)
            case ("S", 3): tokens.append(.millis3)
            case ("Z", 1): tokens.append(.offsetBasic)
            case ("X", 5): tokens.append(.offsetISO)
            default: return nil
            }
            index += run
        }
        return tokens
    }

    static func string(from date: Date, tokens: [Token], timeZone: TimeZone) -> String? {
        // Same arithmetic as CFDateFormatter: absolute time -> Unix milliseconds, rounded to nearest.
        let unixMilliseconds = (date.timeIntervalSinceReferenceDate + 978_307_200.0) * 1000.0
        guard supportedMilliseconds.contains(unixMilliseconds) else { return nil }
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        guard offsetSeconds % 60 == 0 else { return nil }

        let local = Int64(unixMilliseconds.rounded()) + Int64(offsetSeconds) * 1000
        let (days, millisOfDay) = local.floorDivided(by: 86_400_000)
        let fields = Fields(days: days, millisOfDay: millisOfDay, offsetMinutes: offsetSeconds / 60)

        var length = 0
        for token in tokens {
            switch token {
            case .year4: length += 4
            case .month2, .day2, .hour2, .minute2, .second2: length += 2
            case .millis3: length += 3
            case .offsetBasic: length += 5
            case .offsetISO: length += fields.offsetMinutes == 0 ? 1 : 6
            case .literal: length += 1
            }
        }
        return String(unsafeUninitializedCapacity: length) { buffer in
            var i = 0
            func put(_ byte: UInt8) { buffer[i] = byte; i += 1 }
            func digits(_ value: Int, _ count: Int) {
                var divisor = 1
                for _ in 1..<count { divisor *= 10 }
                var remaining = value
                for _ in 0..<count {
                    put(UInt8(ascii: "0") + UInt8(remaining / divisor % 10))
                    remaining %= divisor
                    divisor /= 10
                }
            }
            for token in tokens {
                switch token {
                case .year4: digits(fields.year, 4)
                case .month2: digits(fields.month, 2)
                case .day2: digits(fields.day, 2)
                case .hour2: digits(fields.hour, 2)
                case .minute2: digits(fields.minute, 2)
                case .second2: digits(fields.second, 2)
                case .millis3: digits(fields.millisecond, 3)
                case .offsetBasic:
                    put(fields.offsetMinutes < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
                    digits(abs(fields.offsetMinutes) / 60, 2)
                    digits(abs(fields.offsetMinutes) % 60, 2)
                case .offsetISO:
                    if fields.offsetMinutes == 0 {
                        put(UInt8(ascii: "Z"))
                    } else {
                        put(fields.offsetMinutes < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
                        digits(abs(fields.offsetMinutes) / 60, 2)
                        put(UInt8(ascii: ":"))
                        digits(abs(fields.offsetMinutes) % 60, 2)
                    }
                case .literal(let byte): put(byte)
                }
            }
            return i
        }
    }

    /// Calendar fields for a local day number (days since 1970-01-01) and time of day.
    private struct Fields {
        let year, month, day, hour, minute, second, millisecond, offsetMinutes: Int

        init(days: Int64, millisOfDay: Int64, offsetMinutes: Int) {
            // Howard Hinnant's civil_from_days (proleptic Gregorian).
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let monthPrime = (5 * dayOfYear + 2) / 153
            let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
            year = Int(yearOfEra + era * 400 + (month <= 2 ? 1 : 0))
            self.month = Int(month)
            day = Int(dayOfYear - (153 * monthPrime + 2) / 5 + 1)
            hour = Int(millisOfDay / 3_600_000)
            minute = Int(millisOfDay / 60_000 % 60)
            second = Int(millisOfDay / 1_000 % 60)
            millisecond = Int(millisOfDay % 1_000)
            self.offsetMinutes = offsetMinutes
        }
    }
}

private extension Int64 {
    /// Floor division and the matching non-negative remainder.
    func floorDivided(by divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        let quotient = (self >= 0 ? self : self - divisor + 1) / divisor
        return (quotient, self - quotient * divisor)
    }
}
