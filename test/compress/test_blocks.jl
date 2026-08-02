using Random: Random
using TTree
using TTree.Compress
using TTree.IOFS
using TTree.Trees

@testset "compress: blocks" begin
    @testset "settings" begin
        for alg in
            (Compress.ALG_ZLIB, Compress.ALG_LZMA, Compress.ALG_LZ4, Compress.ALG_ZSTD),
            lvl in (1, 5, 9)

            s = Settings(alg, lvl)
            @test settings_from(compression_code(s)) == s
        end
        @test compression_code(Settings(Compress.ALG_ZSTD, 5)) == 505
        @test settings_from(0) == Settings(0, 0)
    end

    @testset "round-trip" begin
        # Compressible, and well past MIN_COMPRESS_SIZE, so every algorithm
        # actually engages rather than handing the payload back.
        src = repeat(
            collect(codeunits("the quick brown fox jumps over the lazy dog ")), 200
        )
        for alg in
            (Compress.ALG_ZLIB, Compress.ALG_LZMA, Compress.ALG_LZ4, Compress.ALG_ZSTD)
            enc = compress(src, Settings(alg, 5))
            @test length(enc) < length(src)
            @test decompress(enc, length(src)) == src
        end
    end

    @testset "incompressible or too small stays as it is" begin
        # ROOT signals "stored uncompressed" by the key's lengths agreeing, so
        # a payload that would grow must come back identical — not merely
        # equivalent — for the key layer to be able to say so.
        tiny = collect(codeunits("short"))
        @test compress(tiny, Settings(Compress.ALG_ZLIB, 5)) === tiny

        noise = rand(Random.MersenneTwister(20260802), UInt8, 4096)
        @test compress(noise, Settings(Compress.ALG_ZLIB, 9)) === noise

        @test compress(noise, Settings(Compress.ALG_ZLIB, 0)) === noise
        @test compress(noise, Settings(0, 5)) === noise
    end

    @testset "damaged payloads are refused" begin
        src = repeat(collect(codeunits("abcdefgh")), 200)
        enc = compress(src, Settings(Compress.ALG_ZLIB, 5))

        @test_throws ArgumentError decompress(enc[1:(end - 5)], length(src))
        @test_throws ArgumentError decompress(UInt8[], length(src))

        bad = copy(enc)
        bad[1] = UInt8('?')
        @test_throws ArgumentError decompress(bad, length(src))

        # An LZ4 block's checksum is the only integrity check ROOT's format
        # carries, so it has to be enforced rather than skipped.
        enc4 = compress(src, Settings(Compress.ALG_LZ4, 5))
        bad4 = copy(enc4)
        bad4[Compress.HEADER_SIZE + 1] ⊻= 0xff
        @test_throws ArgumentError decompress(bad4, length(src))
    end

    @testset "files ROOT compressed" begin
        # The corpus is zlib throughout; these four are the same tree written
        # by ROOT with each algorithm it supports, which is what exercises the
        # other three block readers and the xxHash64 in front of an LZ4 block.
        dir = joinpath(@__DIR__, "..", "data", "compressed")
        for (name, alg) in (
            "zlib" => Compress.ALG_ZLIB,
            "lzma" => Compress.ALG_LZMA,
            "lz4" => Compress.ALG_LZ4,
            "zstd" => Compress.ALG_ZSTD,
        )
            TTree.open(joinpath(dir, name * ".root")) do f
                @test settings_from(f.compression).alg == alg
                t = f["t"]
                @test entries(t) == 2000
                @test [Objects.name(b) for b in allbranches(t)] == ["i", "x", "d"]

                # Whatever the algorithm, the values are the same values.
                @test array(t, "i") == Int32.(0:1999)
                @test array(t, "x") == Float32.((0:1999) .* 0.5)
                @test array(t, "d") == (0:1999) .* 0.25

                # And they really did arrive compressed, or this proves nothing.
                @test any(is_compressed, f.dir.keys)
            end
        end
    end
end
