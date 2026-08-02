# Graphs, read out of the same fixture as the histograms.
#
# The points are y = 2x on x = 1..4, and every error is distinct — the low side
# differs from the high side and x from y — so a pair read in the wrong order,
# or an asymmetric pair read as a symmetric one, shows up as a wrong number
# rather than as a coincidence.

using TTree
using TTree.Bytes
using TTree.Objects

@testset "objects: graphs" begin
    @testset "reading ROOT's own file" begin
        TTree.open(HISTS) do f
            g = f["tg"]
            @test g isa TGraph
            @test Objects.name(g) == "tg"
            @test Objects.title(g) == "plain"
            @test length(g) == 4
            x, y = points(g)
            @test x == [1.0, 2.0, 3.0, 4.0]
            @test y == [2.0, 4.0, 6.0, 8.0]
            # A plain graph carries no errors, and says so as zeros rather than
            # as an empty vector, so that plotting code need not ask which class
            # it has.
            @test xerrors(g) == (zeros(4), zeros(4))
            @test yerrors(g) == (zeros(4), zeros(4))

            e = f["tge"]
            @test e isa TGraphErrors
            @test points(e) == (x, y)
            @test xerrors(e) == ([0.1, 0.2, 0.3, 0.4], [0.1, 0.2, 0.3, 0.4])
            @test yerrors(e) == ([0.5, 0.6, 0.7, 0.8], [0.5, 0.6, 0.7, 0.8])

            a = f["tgae"]
            @test a isa TGraphAsymmErrors
            @test points(a) == (x, y)
            @test xerrors(a) == ([0.01, 0.02, 0.03, 0.04], [0.11, 0.12, 0.13, 0.14])
            @test yerrors(a) == ([0.21, 0.22, 0.23, 0.24], [0.31, 0.32, 0.33, 0.34])

            @test graphcore(a) === a.g
            @test graphcore(g) === g
        end
    end

    @testset "round-trip through this package's writer" begin
        TTree.open(HISTS) do f
            for nm in ("tg", "tge", "tgae")
                a = f[nm]
                b = reencode(a)
                @test typeof(b) === typeof(a)
                @test Objects.name(b) == Objects.name(a)
                @test Objects.title(b) == Objects.title(a)
                @test points(b) == points(a)
                @test xerrors(b) == xerrors(a)
                @test yerrors(b) == yerrors(a)
            end
        end
    end

    @testset "building" begin
        g = TGraph("g", "t", [1, 2, 3], [4, 5, 6])
        @test points(g) == ([1.0, 2.0, 3.0], [4.0, 5.0, 6.0])
        @test length(g) == 3
        @test !isempty(g)
        @test isempty(TGraph())
        @test_throws ArgumentError TGraph("g", "t", [1, 2], [1, 2, 3])

        e = TGraphErrors("e", "t", [1, 2], [3, 4], [0.1, 0.2], [0.3, 0.4])
        @test yerrors(e) == ([0.3, 0.4], [0.3, 0.4])
        @test_throws ArgumentError TGraphErrors("e", "t", [1, 2], [3, 4], [0.1], [0.3, 0.4])

        a = TGraphAsymmErrors("a", "t", [1, 2], [3, 4], [1, 2], [3, 4], [5, 6], [7, 8])
        @test xerrors(a) == ([1.0, 2.0], [3.0, 4.0])
        @test yerrors(a) == ([5.0, 6.0], [7.0, 8.0])

        # The graphs built here have never been through a buffer, so this is
        # where the write side is checked against nothing but itself.
        for x in (g, e, a)
            b = reencode(x)
            @test points(b) == points(x)
            @test xerrors(b) == xerrors(x)
            @test yerrors(b) == yerrors(x)
        end
    end
end
