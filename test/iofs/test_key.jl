using TTree.Bytes
using TTree.IOFS

@testset "iofs: keys" begin
    @testset "header round-trip" begin
        k = Key(;
            name="thing",
            title="a thing",
            class="TObjString",
            cycle=3,
            objlen=100,
            nbytes=140,
            keylen=40,
            seekkey=1234,
            seekpdir=100,
        )
        w = WBuffer()
        write_key!(w, k)
        got = read_key(RBuffer(bytes(w)))

        @test got.name == k.name
        @test got.title == k.title
        @test got.class == k.class
        @test got.cycle == k.cycle
        @test got.objlen == k.objlen
        @test got.nbytes == k.nbytes
        @test got.keylen == k.keylen
        @test got.seekkey == k.seekkey
        @test got.seekpdir == k.seekpdir
        # ROOT's timestamp keeps two-second resolution, so equality holds only
        # after the same rounding the format applies.
        @test Bytes.datetime_to_datime(got.datetime) == Bytes.datetime_to_datime(k.datetime)
    end

    @testset "keylen matches what is written" begin
        for (n, t, c) in (
            ("x", "", "TObjString"),
            ("", "", ""),
            ("a"^300, "t", "TTree"),
            ("b", "long "^80, "TH1F"),
        )
            k = Key(; name=n, title=t, class=c, keylen=keylen_for(n, t, c))
            w = WBuffer()
            write_key!(w, k)
            @test length(bytes(w)) == keylen_for(n, t, c)
        end

        # 22 fixed bytes, four of timestamp, and the three names inline.
        @test keylen_for("b", "", "TObject") == 22 + 4 + 8 + 2 + 1
        @test keylen_for("b", "", "TObject"; bigfile=true) == 22 + 8 + 4 + 8 + 2 + 1

        # A basket's key carries the basket's own bookkeeping — ROOT puts it in
        # the key rather than the payload — so it is 19 bytes longer than the
        # names alone would say.
        @test keylen_for("b", "", "TBasket") == 22 + 4 + 8 + 2 + 1 + 19
    end

    @testset "big-file keys" begin
        k = Key(;
            name="far",
            class="TObjString",
            seekkey=START_BIG_FILE + 1,
            seekpdir=100,
            rvers=IOFS.KEY_VERSION + 1000,
            keylen=keylen_for("far", "", "TObjString"; bigfile=true),
        )
        @test is_bigfile(k)
        w = WBuffer()
        write_key!(w, k)
        @test length(bytes(w)) == k.keylen
        got = read_key(RBuffer(bytes(w)))
        @test is_bigfile(got)
        @test got.seekkey == START_BIG_FILE + 1
    end

    @testset "compressed and gap" begin
        # "Stored uncompressed" is not a flag: it is the payload's two lengths
        # agreeing.
        @test !is_compressed(Key(; objlen=60, nbytes=100, keylen=40))
        @test is_compressed(Key(; objlen=200, nbytes=100, keylen=40))
        @test !is_gap(Key(; nbytes=100))
        @test is_gap(Key(; nbytes=-100))
    end

    @testset "name;cycle" begin
        @test decode_namecycle("h") == ("h", Int16(9999))
        @test decode_namecycle("h;2") == ("h", Int16(2))
        @test decode_namecycle("h;*") == ("h", Int16(9999))
        @test decode_namecycle("h;nonsense") == ("h;nonsense", Int16(9999))
        @test decode_namecycle("a;b;3") == ("a;b", Int16(3))
        @test keyname(Key(; name="h", cycle=2)) == "h;2"
    end

    @testset "tstring_sizeof" begin
        @test tstring_sizeof("") == 1
        @test tstring_sizeof("abc") == 4
        @test tstring_sizeof("a"^254) == 255
        @test tstring_sizeof("a"^255) == 260
    end
end

@testset "iofs: free list" begin
    @testset "segment round-trip" begin
        for s in (FreeSegment(0, 99), FreeSegment(START_BIG_FILE + 1, START_BIG_FILE + 9))
            w = WBuffer()
            write_free_segment!(w, s)
            @test length(bytes(w)) == segment_sizeof(s)
            @test read_free_segment(RBuffer(bytes(w))) == s
        end
    end

    @testset "coalescing" begin
        spans = FreeSegment[]
        free_add!(spans, 100, 199)
        free_add!(spans, 300, 399)
        @test length(spans) == 2

        # Adjacent, not merely overlapping: a gap of zero bytes between two
        # spans is not a gap.
        free_add!(spans, 200, 299)
        @test spans == [FreeSegment(100, 399)]

        free_add!(spans, 50, 60)
        @test spans == [FreeSegment(50, 60), FreeSegment(100, 399)]
        @test free_bytes(spans) == 11 + 300
    end

    @testset "the trailing segment" begin
        spans = FreeSegment[]
        free_add!(spans, 1000, START_BIG_FILE)
        @test free_tail(spans) == FreeSegment(1000, START_BIG_FILE)
        @test free_bytes(spans) == 0

        # A record freed right before the end of file has to join the tail, or
        # the file would have two different ideas of where it ends.
        free_add!(spans, 900, 999)
        @test free_tail(spans) == FreeSegment(900, START_BIG_FILE)
        @test length(spans) == 1
    end
end
