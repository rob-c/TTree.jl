using TTree
using TTree.Objects
using TTree.Trees

@testset "trees: structure" begin
    rows = reference("corpus_structure.txt")
    @test !isempty(rows)

    seen = Set{Tuple{String,String}}()
    for (fn, tn, nent, nbr, nlf) in
        ((r[1], r[2], parse(Int, r[3]), parse(Int, r[4]), parse(Int, r[5])) for r in rows)
        @testset "$fn/$tn" begin
            TTree.open(joinpath(corpus_dir(), fn)) do f
                t = f[tn]
                push!(seen, (fn, tn))
                @test entries(t) == nent
                @test length(allbranches(t)) == nbr
                @test sum(length(leaves(b)) for b in allbranches(t); init=0) == nlf
            end
        end
    end

    # The other direction: nothing in the corpus may be a tree this package
    # fails to notice.
    found = Set{Tuple{String,String}}()
    for fn in corpus_files()
        TTree.open(joinpath(corpus_dir(), fn)) do f
            for (tn, _) in treepaths(f)
                push!(found, (fn, tn))
            end
        end
    end
    @test found == seen
end

@testset "trees: navigation" begin
    # `leaves.root` is the corpus file that holds one branch per leaf type, so
    # it is where the accessors can be checked against something known.
    TTree.open(joinpath(corpus_dir(), "leaves.root")) do f
        t = f["tree"]
        @test entries(t) == 10

        names = [Objects.name(b) for b in allbranches(t)]
        @test "I32" in names
        @test "SliF64" in names

        b = t["I32"]
        @test Objects.name(b) == "I32"
        @test owner(b) === t
        @test length(leaves(b)) == 1
        @test elementtype(leaves(b)[1]) === Int32
        @test !isjagged(leaves(b)[1])
        @test nbaskets(b) >= 1
        @test entries(b) == 10

        # A variable-length leaf knows which leaf counts it, and that leaf is
        # in a branch of its own.
        s = leaves(t["SliF64"])[1]
        @test isjagged(s)
        c = countleaf(s)
        @test c !== nothing
        @test Objects.name(c) == "N"
        @test any(l -> l === c, leaves(t["N"]))

        @test_throws Exception t["NoSuchBranch"]
    end
end

@testset "trees: baskets" begin
    TTree.open(joinpath(corpus_dir(), "leaves.root")) do f
        b = f["tree"]["I32"]
        n = 0
        total = 0
        for bk in eachbasket(b)
            n += 1
            total += length(bk)
            @test bk isa Basket
            @test !isempty(bk.data)
        end
        @test n == nbaskets(b)
        @test total >= entries(b)
        @test length(basket(b, 1)) == length(first(eachbasket(b)))
    end

    # ROOT streams a branch's still-filling basket into the branch record rather
    # than onto the file, and a tree that was never flushed has all its data
    # there. Such a branch has no basket to seek to at all.
    TTree.open(joinpath(corpus_dir(), "g4-like.root")) do f
        t = f["mytree"]
        b = first(allbranches(t))
        @test nbaskets(b) == 1
        @test all(iszero, Trees.branchcore(b).basketseek[1:nbaskets(b)])
        @test length(first(eachbasket(b))) > 0
    end
end
