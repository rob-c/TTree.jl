using TTree.Compress

@testset "compress: xxhash64" begin
    # Known answers from the xxHash reference implementation. This is the one
    # piece of the compression layer with no round-trip to fall back on: an LZ4
    # block carries the hash ROOT computed over it, so getting this wrong makes
    # every LZ4 file unreadable and no amount of self-consistency would say so.
    # The fixtures in `test/data/compressed` are the other half of the check —
    # those hashes were written by ROOT.
    @test Compress.xxhash64(UInt8[]) == 0xef46db3751d8e999
    @test Compress.xxhash64(b"a") == 0xd24ec4f1a98c6e5b

    @test Compress.xxhash64(UInt8[]) != Compress.xxhash64(UInt8[], UInt64(1))

    # Long enough to exercise the four-lane bulk loop and its tail, at every
    # length either side of the 32-byte stripe.
    long = UInt8[(i * 37 + 11) % 256 for i in 1:200]
    hs = [Compress.xxhash64(@view long[1:n]) for n in 0:200]
    @test length(unique(hs)) == length(hs)
    @test Compress.xxhash64(long) == Compress.xxhash64(collect(long))
end
