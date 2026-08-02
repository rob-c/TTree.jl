using TTree
using TTree.Bytes
using TTree.Objects
using TTree.Trees

# The one tree fixture shipped with the package: 100 entries of every leaf
# shape, written by ROOT into several baskets per branch. See
# `dev/gen_tree_fixtures.jl` for what is in it and why.
#
# The fills are a rule, so what follows states the rule rather than a table of
# numbers: entry `e` holds `e`, `e/2`, `e % 4` values, and so on.

const TREES = joinpath(@__DIR__, "..", "data", "trees", "trees.root")

@testset "trees: fixture" begin
    TTree.open(TREES) do f
        @test keys(f) == ["t"]
        t = f["t"]
        @test Objects.name(t) == "t"
        @test title(t) == "every leaf shape"
        @test entries(t) == 100
        @test length(branches(t)) == 11
        @test sum(length(leaves(b)) for b in branches(t)) == 12

        e = 0:99

        @test array(t, "i32") == Int32.(e)
        @test array(t, "u32") == UInt32.(4000000000 .+ e)
        @test array(t, "i64") == Int64.(5000000000 .* (e .+ 1))
        @test array(t, "f32") == Float32.(e .+ 0.5)
        @test array(t, "f64") == Float64.(e ./ 2)
        @test array(t, "bo") == [x % 3 == 0 for x in e]
        @test array(t, "n") == Int32.(e .% 4)
        @test array(t, "str") == ["e$x" for x in e]

        # x fastest: a fixed-length leaf is a value per column, an entry per
        # row, so `arr[k, i]` is value `k` of entry `i`.
        arr = array(t, "arr")
        @test size(arr) == (3, 100)
        @test arr == [x + (k - 1) / 10 for k in 1:3, x in e]

        # A variable-length leaf, counted by a leaf in another branch.
        sli = array(t, "sli")
        @test length(sli) == 100
        @test [length(v) for v in sli] == collect(e .% 4)
        @test sli == [Float64[100 * x + k for k in 0:(x % 4 - 1)] for x in e]

        # Two leaves in one branch, so each is reached by stepping over the
        # other in every entry.
        pair = t["pair"]
        @test [Objects.name(l) for l in leaves(pair)] == ["b", "a"]
        @test array(pair, "b") == Float64.(e .* 1.5)
        @test array(pair, "a") == Int32.(.-e)
        @test_throws ArgumentError array(pair)

        # Element types come from the leaf, including the unsigned flag that
        # distinguishes `u32` from `i32` — both are `TLeafI`.
        @test eltype(array(t, "i32")) === Int32
        @test eltype(array(t, "u32")) === UInt32
        @test countleaf(leaves(t["sli"])[1]) === leaves(t["n"])[1]
        @test countleaf(leaves(t["arr"])[1]) === nothing
    end
end

@testset "trees: fixture baskets" begin
    TTree.open(TREES) do f
        t = f["t"]

        # The point of the fixture: entries really do span baskets, so a reader
        # that stopped after the first would fail here rather than silently
        # agree.
        @test nbaskets(t["i32"]) > 1
        @test nbaskets(t["arr"]) > 1
        @test nbaskets(t["pair"]) > 1

        for b in branches(t)
            @test sum(length(bk) for bk in eachbasket(b)) == entries(t)
        end
    end
end

@testset "trees: chunks" begin
    TTree.open(TREES) do f
        t = f["t"]

        for b in branches(t), l in leaves(b)
            nm = Objects.name(l)
            @testset "$(Objects.name(b)).$nm" begin
                whole = array(b, nm)
                chunks = collect(eachchunk(b, nm))
                @test length(chunks) == nbaskets(b)

                # A chunk is shaped the way the whole branch is, so the pieces
                # go back together with the concatenation that shape calls for.
                if whole isa AbstractMatrix
                    @test all(c -> size(c, 1) == size(whole, 1), chunks)
                    @test reduce(hcat, chunks) == whole
                else
                    @test all(c -> eltype(c) === eltype(whole), chunks)
                    @test reduce(vcat, chunks) == whole
                end

                # Nothing is read twice and nothing is dropped.
                n = sum(c -> c isa AbstractMatrix ? size(c, 2) : length(c), chunks)
                @test n == entries(t)
            end
        end

        # The fold the streaming path exists for.
        @test sum(sum, eachchunk(t, "f64")) == sum(array(t, "f64"))
        @test eachchunk(t["i32"]) isa Trees.BranchChunks
        @test occursin("i32", sprint(show, eachchunk(t, "i32")))
    end
end

@testset "trees: fixture round-trip" begin
    # The tree written back out with this package's own streamer and read
    # again. The baskets stay on the file it came from, so the copy is bound to
    # that file and asked for its values.
    TTree.open(TREES) do f
        t = f["t"]
        w = WBuffer()
        Bytes.marshal!(w, t)
        back = Objects.CLASS_FACTORY("TTree")
        Bytes.unmarshal!(back, RBuffer(bytes(w); factory=Objects.CLASS_FACTORY))
        Bytes.bind!(back, f)

        @test Objects.name(back) == Objects.name(t)
        @test entries(back) == entries(t)
        @test [Objects.name(b) for b in branches(back)] == [Objects.name(b) for b in branches(t)]

        for b in branches(back), l in leaves(b)
            nm = Objects.name(l)
            @test array(b, nm) == array(t[Objects.name(b)], nm)
        end
    end
end
