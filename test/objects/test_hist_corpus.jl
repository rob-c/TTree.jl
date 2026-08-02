# Every histogram and graph in the corpus, against what ROOT says about it.
#
# The fixture in `test/data/hists` is one ROOT's current version wrote; the
# corpus is where the old layouts are. `g4-hist.root` carries TAxis 6 and TH1 3,
# `graphs.root` a TGraph 4, `dirs-6.14.00.root` a histogram inside two nested
# directories — none of which any ROOT built this decade would write, and all of
# which a reader that follows the file's own class description reads anyway.
#
# The numbers are ROOT's, recorded by `dev/gen_corpus_reference.jl`, so this
# compares against ROOT rather than against a previous run of this package.

using TTree
using TTree.Objects

# Sums over a hundred thousand cells are not accumulated in the same order here
# as in ROOT, and a bin content stored as a `Float32` widens exactly — so the
# comparison is loose enough for the former and tight enough to catch the
# latter being read as anything else.
_close(a, b) = isapprox(Float64(a), Float64(b); atol=1e-9, rtol=1e-9)

@testset "objects: corpus histograms" begin
    rows = reference("corpus_hists.txt")
    @test !isempty(rows)

    # Grouped by file so that each is opened once, in the order ROOT walked it:
    # a CELL or POINT row belongs to the HIST or GRAPH row above it.
    byfile = Dict{String,Vector{Vector{String}}}()
    order = String[]
    for r in rows
        fn = r[2]
        haskey(byfile, fn) || push!(order, fn)
        push!(get!(byfile, fn, Vector{String}[]), r)
    end

    nhist = 0
    ngraph = 0
    for fn in order
        TTree.open(joinpath(corpus_dir(), fn)) do f
            obj = nothing
            for r in byfile[fn]
                path = r[3]
                if r[1] == "HIST"
                    obj = f[path]
                    nhist += 1
                    cls, ent, ncells, nx, ny, nz = r[4], r[5], r[6], r[7], r[8], r[9]
                    sumc, sume, xlow, xhigh, midedge, labels = r[10],
                    r[11], r[12], r[13], r[14],
                    r[15]

                    @test Bytes.classname(obj) == cls
                    @test obj isa AnyHist
                    @test _close(entries(obj), parse(Float64, ent))

                    c = bincontents(obj)
                    @test length(c) == parse(Int, ncells)
                    @test length(c) == histcore(obj).ncells
                    @test nbins(obj, :x) == parse(Int, nx)
                    @test nbins(obj, :y) == parse(Int, ny)
                    @test nbins(obj, :z) == parse(Int, nz)
                    @test _close(sum(Float64.(c)), parse(Float64, sumc))
                    @test _close(sum(binerrors(obj)), parse(Float64, sume))

                    edges = binedges(obj)
                    @test length(edges) == parse(Int, nx) + 1
                    @test _close(edges[1], parse(Float64, xlow))
                    @test _close(edges[end], parse(Float64, xhigh))
                    @test _close(edges[parse(Int, nx) ÷ 2 + 1], parse(Float64, midedge))
                    @test binlabels(obj) ==
                        (labels == "-" ? String[] : String.(split(labels, ",")))
                elseif r[1] == "CELL"
                    # ROOT numbers cells from zero, this package from one.
                    i = parse(Int, r[4]) + 1
                    @test _close(vec(bincontents(obj))[i], parse(Float64, r[5]))
                    @test _close(vec(binerrors(obj))[i], parse(Float64, r[6]))
                elseif r[1] == "GRAPH"
                    obj = f[path]
                    ngraph += 1
                    @test Bytes.classname(obj) == r[4]
                    @test obj isa AnyGraph
                    @test length(obj) == parse(Int, r[5])
                    x, y = points(obj)
                    @test _close(sum(x), parse(Float64, r[6]))
                    @test _close(sum(y), parse(Float64, r[7]))
                elseif r[1] == "POINT"
                    i = parse(Int, r[4]) + 1
                    x, y = points(obj)
                    exl, exh = xerrors(obj)
                    eyl, eyh = yerrors(obj)
                    @test _close(x[i], parse(Float64, r[5]))
                    @test _close(y[i], parse(Float64, r[6]))
                    for (got, want) in
                        zip((exl[i], exh[i], eyl[i], eyh[i]), parse.(Float64, r[7:10]))
                        # ROOT answers -1 for a class that carries no error at
                        # all, as a sentinel; this package answers zero, which
                        # is the width of the error bar to draw. The one place
                        # the two deliberately differ.
                        @test _close(got, want < 0 ? 0.0 : want)
                    end
                else
                    error("corpus_hists.txt: unknown row $(r[1])")
                end
            end
        end
    end

    # The corpus is not shipped, but the reference is, so a corpus that has
    # lost a file would otherwise show up as a quietly shorter test.
    @test nhist + ngraph == count(r -> r[1] in ("HIST", "GRAPH"), rows)

    @testset "old class versions really are in there" begin
        # What makes the files above worth reading: were they all written by a
        # recent ROOT, the description-driven decoding would never be exercised.
        seen = Dict{String,Set{Int}}()
        for fn in order
            TTree.open(joinpath(corpus_dir(), fn)) do f
                for (cls, vers) in keys(IOFS.streamers(f).byversion)
                    push!(get!(seen, cls, Set{Int}()), Int(vers))
                end
            end
        end
        @test 3 in get(seen, "TH1", Set{Int}())
        @test 6 in get(seen, "TAxis", Set{Int}())
        @test 4 in get(seen, "TGraph", Set{Int}())
    end
end
