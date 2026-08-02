using TTree
using TTree.Objects
using TTree.Trees

using Dates: DateTime

@testset "trees: objects" begin
    rows = reference("corpus_objects.txt")
    @test !isempty(rows)

    # Grouped by file so each is opened once; the reference is generated in
    # file order, so this preserves it.
    byfile = Dict{String,Vector{Vector{String}}}()
    for r in rows
        push!(get!(byfile, r[2], Vector{String}[]), r)
    end

    for fn in unique(r[2] for r in rows)
        TTree.open(joinpath(corpus_dir(), fn)) do f
            trees = Dict{String,Any}()
            for r in byfile[fn]
                kind, tn, bname, cls = r[1], r[3], r[4], r[5]

                @testset "$fn/$tn/$bname" begin
                    t = get!(() -> f[tn], trees, tn)
                    b = t[bname]
                    @test isobjectbranch(b)

                    a = array(b)
                    chunks = collect(eachchunk(b))

                    if kind == "NOREF"
                        # ROOT would not read this one without a compiled
                        # dictionary, so there is nothing to compare against.
                        # That it comes back at all is what is left to check.
                        @test length(a) == entries(t)
                    else
                        nent, nbytes, want = parse(Int, r[6]),
                        parse(Int, r[7]),
                        parse(UInt64, r[8]; base=16)

                        @test length(a) == nent
                        s = objectcanon(a; unordered=occursin("unordered_", cls))
                        @test ncodeunits(s) == nbytes
                        @test objectdigest(s) == want
                    end

                    # Reading the branch a basket at a time has to give the
                    # same answer as reading it whole.
                    @test (isempty(chunks) ? a : reduce(vcat, chunks)) == a
                end
            end
        end
    end
end

"Every entry of the one object branch of `tn` in the corpus file `fn`."
function objectsof(fn, tn="tree", bname="evt")
    return TTree.open(joinpath(corpus_dir(), fn)) do f
        return array(f[tn][bname])
    end
end

@testset "trees: object shapes" begin
    # The digests above say the values are right but not what they look like.
    # These are the shapes each kind of member comes back in, spelled out.
    TTree.open(joinpath(corpus_dir(), "small-evnt-tree-nosplit.root")) do f
        t = f["tree"]
        b = t["evt"]
        @test leaves(b)[1] isa Union{TLeafElement,TLeafObject}

        # A class is a NamedTuple, its members in the order they are streamed.
        a = array(b)
        @test a isa Vector{<:NamedTuple}
        @test length(a) == 100
        e = a[4]
        @test e.Beg == "beg-003"           # a TString
        @test e.StdStr == "std-003"        # an std::string
        @test e.I32 === Int32(3)
        @test e.F64 === 3.0

        # A member that is itself a class nests, rather than being flattened
        # into the entry the way a split branch flattens it on disk.
        @test e.P3 isa NamedTuple{(:Px, :Py, :Pz)}
        @test e.P3.Px === Int32(2)

        # A fixed-size member is one array per entry — a member of an object,
        # not a column of the tree, so not a column of a matrix either.
        @test e.ArrayI32 isa Vector{Int32}
        @test length(e.ArrayI32) == 10
        @test all(==(Int32(3)), e.ArrayI32)

        # A counted member is as long as its counter says.
        @test e.N === Int32(3)
        @test length(e.SliceF64) == 3

        # An STL sequence comes back as a Vector, of Strings where it holds
        # std::string.
        @test e.StlVecI32 == Int32[3, 3, 3]
        @test e.StlVecStr == ["vec-003", "vec-003", "vec-003"]
    end

    # The same events written at different split levels are the same events:
    # how ROOT chose to lay them out is not supposed to be visible from here.
    @test objectsof("small-evnt-tree-fullsplit.root") ==
        objectsof("small-evnt-tree-nosplit.root")
    @test objectsof("tlv-split99.root", "tree", "p4") ==
        objectsof("tlv-split00.root", "tree", "p4")
    @test objectsof("stdvec-bool-fullsplit-6.10.08.root") ==
        objectsof("stdvec-bool-nosplit-6.10.08.root")

    # A base class is a member named for the base, at the front where it is
    # streamed. TObject is one of those, and is read like any other.
    d1 = objectsof("tbase.root", "tree", "d1")
    @test d1[1] == (Base=(I32=Int32(1),), D32=Int32(2))

    p4 = objectsof("tlv-split00.root", "tree", "p4")
    @test keys(p4[1]) == (:TObject, :fP, :fE)
    @test p4[1].fP.fX === 0.0
    @test p4[1].TObject.fUniqueID === UInt32(0)

    # A TDatime is a date, not the packed number it is stored as.
    @test objectsof("tdatime.root", "tree", "b0") ==
        [DateTime(2006, 1, 2, 15, 4, 5), DateTime(2006, 1, 3, 15, 4, 5)]
    @test objectsof("tdatime.root", "tree", "b1")[1].d == DateTime(2006, 1, 2, 15, 4, 5)

    TTree.open(joinpath(corpus_dir(), "std-containers-split00.root")) do f
        t = f["tree"]

        # A string branch is a column of strings, whichever string it holds.
        @test array(t["str"]) == ["one", "two"]
        @test array(t["tstr"]) == ["one", "two"]

        # Every sequence container is a Vector, holding what it was written
        # holding — sorted, for the std::set that was written sorted.
        @test array(t["vec_i32"])[2] == Int32[-1, -2]
        @test array(t["lst_i32"])[2] == Int32[-1, -2]
        @test array(t["deq_i32"])[2] == Int32[-1, -2]
        @test array(t["set_i32"])[2] == Int32[-2, -1]
        @test array(t["vec_str"])[2] == ["one", "two"]

        # Nesting is nesting, however deep.
        @test array(t["vec_vec_i32"])[2] == [Int32[-1], Int32[-1, -2]]

        # A map is a sequence of pairs, spelled the way C++ spells them, so a
        # value that is itself a container stays one.
        m = array(t["map_i32_vec_i16"])[2]
        @test m isa Vector{<:NamedTuple{(:first, :second)}}
        @test m ==
            [(first=Int32(-2), second=Int16[-1, -2]), (first=Int32(-1), second=Int16[-1])]

        @test array(t["map_str_str"])[2] ==
            [(first="one", second="ONE"), (first="two", second="TWO")]

        # An unordered container is read in the order it was written, which is
        # the order its writer's hash put it in and no order at all to anyone
        # else — hence the sorted comparison against ROOT above.
        @test sort(array(t["uset_str"])[2]) == ["one", "two"]
    end

    # An std::bitset is a run of bits, one Bool each.
    bs = objectsof("std-bitset.root")
    @test bs[1].Bs8 == Bool[1, 0, 0, 0, 1, 0, 0, 0]
    @test bs[1].VecBs8 == [Bool[0, 1, 1, 1, 0, 1, 1, 1]]

    # A branch of no objects at all is still asked the same way.
    TTree.open(joinpath(corpus_dir(), "leaves.root")) do f
        b = f["tree"]["I32"]
        @test !isobjectbranch(b)
    end
end
