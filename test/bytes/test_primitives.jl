using Dates: DateTime
using TTree.Bytes

@testset "bytes: primitives" begin
    @testset "byte order" begin
        # The one thing that must not be taken on trust: ROOT is big-endian on
        # the wire whatever the host is.
        w = WBuffer()
        writebe!(w, Int32(1))
        @test bytes(w) == UInt8[0x00, 0x00, 0x00, 0x01]

        w = WBuffer()
        writebe!(w, Float32(1.0))
        @test bytes(w) == UInt8[0x3f, 0x80, 0x00, 0x00]

        @test readbe(RBuffer(UInt8[0xff, 0xff, 0xff, 0xfe]), Int32) == Int32(-2)
        @test readbe(RBuffer(UInt8[0x80, 0x00]), UInt16) == 0x8000
    end

    @testset "scalar round-trip" begin
        for v in (
            true,
            false,
            Int8(-3),
            UInt8(0xfe),
            Int16(-1234),
            UInt16(0xbeef),
            Int32(-70_000),
            UInt32(0xdeadbeef),
            Int64(-(1 << 40)),
            UInt64(0xfeedfacecafebeef),
            Float32(-1.5),
            Float64(1e300),
        )
            w = WBuffer()
            writebe!(w, v)
            b = bytes(w)
            @test length(b) == sizeof(v)
            r = RBuffer(b)
            @test readbe(r, typeof(v)) == v
            @test remaining(r) == 0
        end
    end

    @testset "arrays" begin
        for v in (Int32[-1, 0, 7], Float64[1.5, -2.5], UInt8[1, 2, 3], Bool[true, false])
            w = WBuffer()
            write_array!(w, v)
            r = RBuffer(bytes(w))
            @test read_array(r, eltype(v), length(v)) == v
            @test remaining(r) == 0
        end

        # Bulk decoding must agree with reading one value at a time, since the
        # two paths are separate implementations of the same thing.
        v = Int32[i * 7 - 3 for i in 1:64]
        w = WBuffer()
        write_array!(w, v)
        r = RBuffer(bytes(w))
        @test [readbe(r, Int32) for _ in 1:64] == v

        dst = Vector{Float32}(undef, 3)
        w = WBuffer()
        write_array!(w, Float32[1, 2, 3])
        @test read_array!(RBuffer(bytes(w)), dst) == Float32[1, 2, 3]
    end

    @testset "strings" begin
        # A TString spends one byte on its length until it cannot, and then
        # five; both sides of that boundary have to agree on where it is.
        for s in ("", "x", "root", "a"^254, "b"^255, "c"^1000)
            w = WBuffer()
            write_tstring!(w, s)
            @test length(bytes(w)) == (length(s) < 255 ? 1 : 5) + length(s)
            r = RBuffer(bytes(w))
            @test read_tstring(r) == s
            @test remaining(r) == 0
        end

        w = WBuffer()
        write_cstring!(w, "TObjString")
        @test last(bytes(w)) == 0x00
        @test read_cstring(RBuffer(bytes(w))) == "TObjString"

        w = WBuffer()
        write_stdstring!(w, "hello")
        @test read_stdstring(RBuffer(bytes(w))) == "hello"
    end

    @testset "packed floats" begin
        # Float16_t/Double32_t are lossy by construction, so the test is that a
        # value survives to the precision the range and bit count allow.
        for x in (0.0, 1.0, -1.0, 3.25, 99.5)
            w = WBuffer()
            write_double32!(w, x, -100.0, 100.0, 0.0)
            @test read_double32(RBuffer(bytes(w)), -100.0, 100.0, 0.0) ≈ x atol = 1e-4

            w = WBuffer()
            write_float16!(w, x, -100.0, 100.0, 0.0)
            @test read_float16(RBuffer(bytes(w)), -100.0, 100.0, 0.0) ≈ x atol = 1e-1
        end

        # Without a range a Float16_t is three bytes: exponent and the top bits
        # of the mantissa.
        w = WBuffer()
        write_float16!(w, 1.5f0)
        @test length(bytes(w)) == 3
        @test read_float16(RBuffer(bytes(w))) ≈ 1.5f0 atol = 1e-3
    end

    @testset "cursor" begin
        w = WBuffer()
        write_array!(w, Int32[1, 2, 3, 4])
        r = RBuffer(bytes(w))
        @test pos(r) == 0
        skip!(r, 8)
        @test pos(r) == 8
        @test readbe(r, Int32) == 3
        seek!(r, 0)
        @test readbe(r, Int32) == 1
        @test remaining(r) == 12

        # The offset is what lets a buffer holding a key's payload report
        # positions in the file's coordinates rather than its own.
        o = RBuffer(bytes(w); offset=100)
        @test pos(o) == 100
        skip!(o, 4)
        @test pos(o) == 104
    end

    @testset "short buffer" begin
        r = RBuffer(UInt8[0x01, 0x02])
        @test_throws Exception readbe(r, Int32)
        @test_throws Exception read_bytes(RBuffer(UInt8[0x01]), 4)
        @test_throws Exception read_tstring(RBuffer(UInt8[0x05, 0x61]))
    end

    @testset "datime" begin
        # ROOT packs a whole timestamp into 32 bits, six fields, epoch 1995.
        # Anything with a whole number of seconds inside its range is exact.
        for dt in (
            DateTime(1995, 1, 1, 0, 0, 0),
            DateTime(2026, 8, 2, 14, 33, 7),
            DateTime(2058, 12, 31, 23, 59, 59),
        )
            @test Bytes.datime_to_datetime(Bytes.datetime_to_datime(dt)) == dt
        end

        # A record ROOT wrote with no timestamp has zero where the month and
        # day should be; opening the file matters more than the missing day.
        @test Bytes.datime_to_datetime(UInt32(0)) == DateTime(1995, 1, 1, 0, 0, 0)
    end
end
