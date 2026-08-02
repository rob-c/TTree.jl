using TTree
using TTree.Bytes
using TTree.IOFS
using TTree.Objects
using TTree.Trees

# Every column kind, written and read back. The comparisons are exact — a
# rounding difference would mean the bytes went out as something other than
# what came in, which is the one thing a serializer may not do.
@testset "trees: writing" begin
    N = 300
    i32 = Int32.(1:N)
    u32 = UInt32.((1:N) .* 7)
    i64 = Int64.(1:N) .^ 2
    f32 = Float32.(1:N) ./ 3
    f64 = sqrt.(Float64.(1:N))
    flag = isodd.(1:N)
    lab = ["row-$i" for i in 1:N]
    jag = [fill(Float32(i), i % 5) for i in 1:N]
    mat = reshape(Float64.(1:(3N)), 3, N)

    @testset "one-shot write" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            write!(
                f,
                "tree",
                (
                    i32=i32,
                    u32=u32,
                    i64=i64,
                    f32=f32,
                    f64=f64,
                    flag=flag,
                    lab=lab,
                    jag=jag,
                    mat=mat,
                );
                title="written from Julia",
            )
        end

        TTree.open(path) do f
            @test keys(f) == ["tree"]
            t = f["tree"]
            @test t isa Tree
            @test Objects.title(t) == "written from Julia"
            @test entries(t) == N
            # The count branch a variable-length column needs is written
            # alongside it, immediately before the column it counts.
            @test keys(t) ==
                ["i32", "u32", "i64", "f32", "f64", "flag", "lab", "njag", "jag", "mat"]

            @test array(t["i32"]) == i32
            @test array(t["u32"]) == u32
            @test array(t["i64"]) == i64
            @test array(t["f32"]) == f32
            @test array(t["f64"]) == f64
            @test array(t["flag"]) == flag
            @test array(t["lab"]) == lab
            @test array(t["jag"]) == jag
            @test array(t["njag"]) == Int32.(length.(jag))
            @test array(t["mat"]) == mat

            @test eltype(array(t["u32"])) === UInt32
            @test eltype(array(t["flag"])) === Bool
            @test eltype(array(t["lab"])) === String
        end
        rm(path; force=true)
    end

    @testset "entry at a time" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            TreeWriter(f, "t", "pushed"; basketsize=512) do w
                branch!(w, "i32", Int32)
                branch!(w, "lab", String)
                branch!(w, "jag", Vector{Float32})
                branch!(w, "mat", Float64, 3)
                @test keys(w) == ["i32", "lab", "njag", "jag", "mat"]
                for i in 1:N
                    push!(
                        w,
                        (i32=i32[i], lab=lab[i], jag=jag[i], mat=@view(mat[:, i])),
                    )
                end
                @test entries(w) == N
            end
        end

        TTree.open(path) do f
            t = f["t"]
            @test Objects.title(t) == "pushed"
            @test entries(t) == N
            @test array(t["i32"]) == i32
            @test array(t["lab"]) == lab
            @test array(t["jag"]) == jag
            @test array(t["mat"]) == mat
            # A basket size that small forces several baskets per column, which
            # is the case worth testing: the entry each one starts at is what
            # turns an entry number into a seek.
            for k in keys(t)
                b = t[k]
                @test nbaskets(b) > 1
                @test entries(b) == N
                core = Trees.branchcore(b)
                @test core.basketentry[1] == 0
                @test core.basketentry[Int(core.writebasket) + 1] == N
                @test issorted(core.basketentry[1:(Int(core.writebasket) + 1)])
                # The three basket tables are written to `fMaxBaskets` slots, so
                # a reader that trusts the count must find that many.
                @test length(core.basketseek) == core.maxbaskets
                @test length(core.basketbytes) == core.maxbaskets
                @test length(core.basketentry) == core.maxbaskets
                @test core.maxbaskets > core.writebasket
            end
        end
        rm(path; force=true)
    end

    @testset "basket layout" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            write!(f, "t", (x=i32, v=jag); compression=0)
        end

        TTree.open(path) do f
            t = f["t"]
            x = Trees.branchcore(t["x"])
            v = Trees.branchcore(t["v"])

            # A fixed-size column has no offset table, and says so where ROOT
            # looks: `fEntryOffsetLen` is zero, and its readers step through the
            # basket by `fNevBufSize` bytes an entry.
            @test x.entryoffsetlen == 0
            bk = basket(t["x"], 1)
            @test isempty(bk.offsets)
            @test bk.nevbufsize == sizeof(Int32)
            @test length(bk.data) == bk.nevbuf * sizeof(Int32)
            @test bk.last == Int32(bk.key.keylen) + Int32(length(bk.data))
            @test bk.key.class == "TBasket"
            @test bk.key.name == "x"
            @test bk.key.title == "t"

            # A variable-length one is the other way round: non-zero, which is
            # what makes ROOT go looking for the table at `fLast`.
            @test v.entryoffsetlen != 0
            bv = basket(t["v"], 1)
            @test length(bv.offsets) == bv.nevbuf + 1
            @test bv.offsets[1] == 1
            @test bv.offsets[end] == length(bv.data) + 1
            @test issorted(bv.offsets)
            @test bv.last == Int32(bv.key.keylen) + Int32(length(bv.data))

            # What the tree claims about its size is the sum of what its
            # baskets took, which is how ROOT reports a file's contents.
            core = Trees.treecore(t)
            @test core.totbytes == sum(Trees.branchcore(t[k]).totbytes for k in keys(t))
            @test core.zipbytes == sum(Trees.branchcore(t[k]).zipbytes for k in keys(t))
            @test core.zipbytes > 0
        end
        rm(path; force=true)
    end

    @testset "leaf description" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            write!(f, "t", (x=u32, lab=lab, jag=jag, mat=mat))
        end

        TTree.open(path) do f
            t = f["t"]
            # ROOT describes a branch by its leaf list, and this is the spelling
            # `TTree::Branch` would have been given.
            @test Objects.title(t["x"]) == "x/i"
            @test Objects.title(t["lab"]) == "lab/C"
            @test Objects.title(t["jag"]) == "jag[njag]/F"
            @test Objects.title(t["mat"]) == "mat[3]/D"

            lx = only(leaves(t["x"]))
            @test lx isa TLeafI
            @test Trees.elementtype(lx) === UInt32
            @test leafcore(lx).isunsigned

            # A string leaf declares the longest string it holds, plus the byte
            # C would need for the terminator.
            ll = only(leaves(t["lab"]))
            @test ll isa TLeafC
            @test length(ll) == maximum(ncodeunits, lab) + 1

            # A counted leaf is found through the count leaf itself, not by
            # name, so the tree's leaf list must hold the very same object.
            lj = only(leaves(t["jag"]))
            lc = countleaf(lj)
            @test lc !== nothing
            @test Objects.name(lc) == "njag"
            @test lc === only(leaves(t["njag"]))
            @test leafcore(lc).isrange
            # ROOT sizes its read buffer from the counter's declared maximum.
            @test lc.max == maximum(length, jag)
            @test length(lj) == 1

            @test length(only(leaves(t["mat"]))) == 3
        end
        rm(path; force=true)
    end

    @testset "shared counter" begin
        path = tempname() * ".root"
        px = [fill(Float32(i), i % 4) for i in 1:N]
        py = [fill(Float32(-i), i % 4) for i in 1:N]
        TTree.create(path) do f
            TreeWriter(f, "t") do w
                branch!(w, "n", Int32)
                branch!(w, "px", Vector{Float32}; count="n")
                branch!(w, "py", Vector{Float32}; count="n")
                for i in 1:N
                    push!(w, (n=Int32(i % 4), px=px[i], py=py[i]))
                end
            end
        end

        TTree.open(path) do f
            t = f["t"]
            @test keys(t) == ["n", "px", "py"]
            @test array(t["px"]) == px
            @test array(t["py"]) == py
            @test countleaf(only(leaves(t["px"]))) === countleaf(only(leaves(t["py"])))
        end
        rm(path; force=true)
    end

    @testset "alongside other objects" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            f["before"] = TObjString("an object")
            write!(f, "one", (x=i32,))
            write!(f, "two", (y=f64,))
            f["after"] = TNamed("a name", "a title")
        end

        TTree.open(path) do f
            @test keys(f) == ["before", "one", "two", "after"]
            @test f["before"].str == "an object"
            @test array(f["one"]["x"]) == i32
            @test array(f["two"]["y"]) == f64
            @test Objects.title(f["after"]) == "a title"
        end
        rm(path; force=true)
    end

    @testset "empty and edge cases" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            # A tree of no entries is still a tree: every branch is there, with
            # nothing in it.
            TreeWriter(f, "empty") do w
                branch!(w, "x", Int32)
                branch!(w, "v", Vector{Float64})
            end
            # Entries that are all empty leave a basket that is nothing but its
            # offset table.
            write!(f, "hollow", (v=[Float32[] for _ in 1:10],))
        end

        TTree.open(path) do f
            t = f["empty"]
            @test entries(t) == 0
            @test keys(t) == ["x", "nv", "v"]
            @test isempty(array(t["x"]))
            @test isempty(array(t["v"]))

            h = f["hollow"]
            @test entries(h) == 10
            @test array(h["v"]) == [Float32[] for _ in 1:10]
            @test array(h["nv"]) == zeros(Int32, 10)
        end
        rm(path; force=true)
    end

    @testset "flushing and closing" begin
        path = tempname() * ".root"
        f = TTree.create(path)
        w = TreeWriter(f, "t")
        branch!(w, "x", Int32)
        for i in 1:10
            push!(w, (x=Int32(i),))
        end
        # Forcing a boundary makes each side of it a basket of its own.
        flush!(w)
        for i in 11:20
            push!(w, (x=Int32(i),))
        end
        k = close(w)
        @test close(w) === k
        @test !isopen(w)
        close(f)

        TTree.open(path) do g
            t = g["t"]
            @test array(t["x"]) == Int32.(1:20)
            @test nbaskets(t["x"]) == 2
            @test Trees.branchcore(t["x"]).basketentry[2] == 10
        end
        rm(path; force=true)
    end

    @testset "a writer never closed writes no tree" begin
        path = tempname() * ".root"
        f = TTree.create(path)
        w = TreeWriter(f, "t")
        branch!(w, "x", Int32)
        push!(w, (x=Int32(1),))
        close(f)

        # The baskets are on the file, but nothing points at them — which is
        # what makes an abandoned writer harmless rather than corrupting.
        TTree.open(path) do g
            @test isempty(keys(g))
        end
        rm(path; force=true)
    end

    @testset "rejected" begin
        path = tempname() * ".root"
        f = TTree.create(path)
        try
            w = TreeWriter(f, "t")
            branch!(w, "x", Int32)
            branch!(w, "v", Vector{Float32})
            branch!(w, "m", Float64, 3)

            @test_throws ArgumentError branch!(w, "x", Int32)
            @test_throws ArgumentError branch!(w, "bad", Complex{Float64})
            @test_throws ArgumentError branch!(w, "bad", Vector{String})
            @test_throws ArgumentError branch!(w, "bad", Vector{Float32}; count="absent")
            @test_throws ArgumentError branch!(w, "bad", Vector{Float32}; count="m")
            @test_throws ArgumentError branch!(w, "bad", Float64, 0)

            # An entry that leaves a column out, or one whose fixed-size column
            # is the wrong length.
            @test_throws ArgumentError push!(w, (x=Int32(1),))
            @test_throws ArgumentError push!(
                w, (x=Int32(1), v=Float32[1], m=[1.0, 2.0])
            )

            push!(w, (x=Int32(1), v=Float32[1, 2], m=[1.0, 2.0, 3.0]))
            @test_throws ArgumentError branch!(w, "late", Int32)
            close(w)
            @test_throws ArgumentError push!(w, (x=Int32(2), v=Float32[], m=zeros(3)))
        finally
            close(f)
            rm(path; force=true)
        end

        # A shared counter is checked against the columns it counts.
        path2 = tempname() * ".root"
        f2 = TTree.create(path2)
        try
            w = TreeWriter(f2, "t")
            branch!(w, "n", Int32)
            branch!(w, "v", Vector{Float32}; count="n")
            @test_throws ArgumentError push!(w, (n=Int32(2), v=Float32[1]))
        finally
            close(f2)
            rm(path2; force=true)
        end

        # A file open for reading has nothing to write into.
        ro = TTree.open(joinpath(@__DIR__, "..", "data", "trees", "trees.root"))
        try
            @test_throws ArgumentError TreeWriter(ro, "t")
        finally
            close(ro)
        end

        g = TTree.create(tempname() * ".root")
        try
            @test_throws ArgumentError write!(g, "t", (;))
            @test_throws ArgumentError write!(g, "t", (x=1:3, y=1:4))
            @test_throws ArgumentError write!(g, "t", (x=3,))
        finally
            close(g)
            rm(g.id; force=true)
        end
    end
end
