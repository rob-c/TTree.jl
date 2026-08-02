# ROOT's TDatime: a whole timestamp packed into 32 bits, with the epoch at
# January 1995. Field widths are, from the top: 6 bits of year-since-1995,
# 4 of month, 5 of day, 5 of hour, 6 of minute, 6 of second.

"ROOT's TDatime epoch year; a packed value of zero in the year field means 1995."
const DATIME_EPOCH_YEAR = 1995

"""
    datime_to_datetime(d::UInt32) -> DateTime

Unpack a `TDatime`.

A field of zero is not a valid month or day, but it does occur — in records
ROOT wrote with an unset timestamp — so month and day are clamped to 1 rather
than allowed to throw. Losing a day on a record that never had a date is
better than failing to open the file.
"""
function datime_to_datetime(d::UInt32)
    year = Int(d >> 26) + DATIME_EPOCH_YEAR
    month = Int((d << 6) >> 28)
    day = Int((d << 10) >> 27)
    hour = Int((d << 15) >> 27)
    minute = Int((d << 20) >> 26)
    sec = Int((d << 26) >> 26)
    return DateTime(year, max(month, 1), max(day, 1), hour, minute, sec)
end

"""
    datetime_to_datime(t::DateTime) -> UInt32

Pack a `DateTime` into a `TDatime`. Sub-second precision and any year outside
1995–2058 cannot be represented and are lost.
"""
function datetime_to_datime(t::DateTime)
    y = UInt32(Dates.year(t) - DATIME_EPOCH_YEAR)
    return (y << 26) | (UInt32(Dates.month(t)) << 22) | (UInt32(Dates.day(t)) << 17) |
           (UInt32(Dates.hour(t)) << 12) | (UInt32(Dates.minute(t)) << 6) |
           UInt32(Dates.second(t))
end
