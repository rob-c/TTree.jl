using TTree.Bytes
using TTree.Objects

@testset "bytes: framing" begin
    @testset "byte count and version" begin
        w = WBuffer()
        hdr = write_header!(w, "Thing", 7)
        write_array!(w, Int32[1, 2, 3])
        n = set_header!(w, hdr)
        b = bytes(w)

        # A header is a count of everything after it, with ROOT's flag bit set,
        # then the version.
        @test length(b) == n == 4 + 2 + 12
        @test readbe(RBuffer(b), UInt32) == UInt32(14) | Bytes.KBYTE_COUNT_MASK

        r = RBuffer(b)
        got = read_header(r, "Thing")
        @test got.vers == 7
        @test got.len == 14
        @test read_array(r, Int32, 3) == Int32[1, 2, 3]
        @test check_header(r, got)
        @test remaining(r) == 0
    end

    @testset "check_header resynchronises after a short read" begin
        # Leaving a member unread is the characteristic streamer bug. The byte
        # count is what catches it — and, more usefully, what recovers from it:
        # the cursor lands where the next object begins either way, which is
        # what lets a partly-understood class be read at all.
        w = WBuffer()
        hdr = write_header!(w, "Thing", 1)
        write_array!(w, Int32[1, 2, 3])
        set_header!(w, hdr)

        r = RBuffer(bytes(w))
        got = read_header(r, "Thing")
        read_array(r, Int32, 2)
        @test !check_header(r, got)
        @test remaining(r) == 0

        # Overrunning is caught the same way, and rewound.
        r = RBuffer(vcat(bytes(w), zeros(UInt8, 8)))
        got = read_header(r, "Thing")
        read_array(r, Int32, 4)
        @test !check_header(r, got)
        @test remaining(r) == 8
    end

    @testset "object references" begin
        # The second write of the same object is a back-reference, and the
        # second write of a class name is a back-reference too. Both have to
        # come back as the object they point at.
        s = TObjString("shared")
        w = WBuffer()
        write_object_any!(w, s)
        write_object_any!(w, s)
        write_object_any!(w, TObjString("other"))

        r = RBuffer(bytes(w); factory=Objects.CLASS_FACTORY)
        a = read_object_any(r)
        b = read_object_any(r)
        c = read_object_any(r)
        @test a isa TObjString && a.str == "shared"
        @test b === a
        @test c isa TObjString && c.str == "other"
        @test remaining(r) == 0
    end

    @testset "a null reference" begin
        w = WBuffer()
        write_object_any!(w, nothing)
        r = RBuffer(bytes(w); factory=Objects.CLASS_FACTORY)
        @test read_object_any(r) === nothing
        @test remaining(r) == 0
    end

    @testset "an unknown class is stepped over" begin
        # Reading a file full of experiment-specific classes has to work, so an
        # unregistered class must consume exactly its byte count and no more —
        # the object after it is what proves the cursor landed in the right
        # place.
        function encoded(s)
            w = WBuffer()
            write_object_any!(w, TObjString(s))
            return bytes(w)
        end

        # Nothing is registered under this name, and it is exactly as long as
        # "TObjString", so substituting it changes the class and not the framing.
        unknown = encoded("hidden")
        i = findfirst(
            j -> unknown[j:(j + 9)] == codeunits("TObjString"), 1:(length(unknown) - 10)
        )
        @test i !== nothing
        unknown[i:(i + 9)] .= codeunits("TNotAClass")

        raw = vcat(encoded("before"), unknown, encoded("after"))
        r = RBuffer(raw; factory=Objects.CLASS_FACTORY)
        @test read_object_any(r).str == "before"
        @test read_object_any(r) === nothing
        @test read_object_any(r).str == "after"
        @test remaining(r) == 0
    end
end
