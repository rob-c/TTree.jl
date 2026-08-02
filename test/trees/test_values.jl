using TTree
using TTree.Objects
using TTree.Trees

"The branch of `t` named `bname` that holds a leaf named `lname`."
function findleaf(t, bname, lname)
    for b in allbranches(t)
        Objects.name(b) == bname || continue
        for l in leaves(b)
            Objects.name(l) == lname && return b, l
        end
    end
    return nothing, nothing
end

"""
    unchunk(a, chunks)

The chunks of a leaf put back together, in the shape `array` returns — `hcat`
for the matrix a fixed-length leaf gives, `vcat` otherwise. `a` is what the
whole branch came back as, which is where the empty case gets its type.
"""
function unchunk(a, chunks)
    if isempty(chunks)
        return a isa AbstractMatrix ? similar(a, size(a, 1), 0) : similar(a, 0)
    end
    return a isa AbstractMatrix ? reduce(hcat, chunks) : reduce(vcat, chunks)
end

@testset "trees: values" begin
    rows = reference("corpus_leaves.txt")
    @test !isempty(rows)

    # Grouped by file so each is opened once; the reference is generated in
    # file order, so this preserves it.
    byfile = Dict{String,Vector{Vector{String}}}()
    for r in rows
        push!(get!(byfile, r[1], Vector{String}[]), r)
    end

    for fn in unique(r[1] for r in rows)
        TTree.open(joinpath(corpus_dir(), fn)) do f
            trees = Dict{String,Any}()
            for r in byfile[fn]
                tn, bname, lname, cls = r[2], r[3], r[4], r[5]
                nent, nvals, want = parse(Int, r[6]),
                parse(Int, r[7]),
                parse(UInt64, r[8]; base=16)

                @testset "$fn/$tn/$bname.$lname" begin
                    t = get!(() -> f[tn], trees, tn)
                    b, l = findleaf(t, bname, lname)
                    @test b !== nothing
                    b === nothing && return nothing

                    a = array(b, lname)
                    @test entrycount(a) == nent
                    @test sum(length(v) for v in asentries(a); init=0) == nvals

                    # A TLeafC value may contain a newline, which the reference
                    # cannot; it stands in the same character on both sides.
                    got = if cls == "TLeafC"
                        ((replace(s, '\n' => '\001'),) for s in a)
                    else
                        asentries(a)
                    end
                    @test leafdigest(got) == want

                    # Reading the branch a basket at a time has to give the
                    # same answer as reading it whole, for every leaf in the
                    # corpus and not only for the ones the fixture covers.
                    @test unchunk(a, collect(eachchunk(b, lname))) == a
                end
            end
        end
    end
end

@testset "trees: shapes" begin
    # The digests above say the values are right but not what they look like.
    # These are the shapes each kind of leaf comes back in, spelled out.
    TTree.open(joinpath(corpus_dir(), "leaves.root")) do f
        t = f["tree"]

        # A scalar leaf: one value per entry.
        v = array(t, "I32")
        @test v isa Vector{Int32}
        @test length(v) == 10

        @test array(t, "U32") isa Vector{UInt32}
        @test array(t, "F64") isa Vector{Float64}
        @test array(t, "B") isa Vector{Bool}

        # A fixed-length leaf: a column per entry.
        m = array(t, "ArrI32")
        @test m isa Matrix{Int32}
        @test size(m, 2) == 10
        @test size(m, 1) == length(leaves(t["ArrI32"])[1])

        # A variable-length leaf: one vector per entry, as long as the count
        # leaf says.
        j = array(t, "SliI32")
        @test j isa Vector{Vector{Int32}}
        @test length(j) == 10
        @test [length(x) for x in j] == Int.(array(t, "N"))

        # A string leaf carries its own length.
        s = array(t, "Str")
        @test s isa Vector{String}
        @test length(s) == 10

        # Float16_t and Double32_t occupy fewer bytes than their type says, so
        # the count leaf — not arithmetic on the entry's span — is what gives
        # their lengths.
        @test array(t, "D32") isa Vector{Float64}
        @test [length(x) for x in array(t, "SliD32")] == Int.(array(t, "N"))
    end

    # A leaf may vary in its first dimension and be fixed in the rest, in which
    # case ROOT's length is the product of the two.
    TTree.open(joinpath(corpus_dir(), "ndim-slice.root")) do f
        t = f["tree"]
        n = Int.(array(t, "N"))
        l = leaves(t["SliF32"])[1]
        @test length(l) == 24            # [N][2][3][4], with N left out
        @test [length(x) for x in array(t, "SliF32")] == n .* 24
    end

    # A branch of several leaves holds them interleaved, so one has to be named.
    TTree.open(joinpath(corpus_dir(), "pod-advanced.root")) do f
        b = f["orange"]["orange"]
        @test length(leaves(b)) > 1
        @test_throws ArgumentError array(b)
        @test_throws KeyError array(b, "no-such-leaf")
        @test array(b, Objects.name(leaves(b)[1])) !== nothing
    end

    # The tree has the last word on how many rows there are, even when a branch
    # carries entries it was never told about.
    TTree.open(joinpath(corpus_dir(), "string-example.root")) do f
        t = f["Refs"]
        b = t["Params"]
        @test entries(t) == 0
        @test entries(b) > 0
        @test entrycount(array(b, Objects.name(leaves(b)[1]))) == 0
    end

    # An object branch is not decoded, and says so rather than returning bytes.
    TTree.open(joinpath(corpus_dir(), "small-evnt-tree-nosplit.root")) do f
        t = f["tree"]
        b = first(allbranches(t))
        @test leaves(b)[1] isa Union{TLeafElement,TLeafObject}
        @test_throws ArgumentError array(b)
    end
end
