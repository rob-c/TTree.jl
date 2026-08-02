using Test
using TTree

include("corpus.jl")

@testset verbose = true "TTree.jl" begin
    @testset "package smoke" begin
        @test isdefined(TTree, :Bytes)
        @test isdefined(TTree, :Compress)
        @test isdefined(TTree, :IOFS)
        @test isdefined(TTree, :Objects)
        @test isdefined(TTree, :Trees)
        # The class factory is installed at load time; without it a file's
        # objects would all come back as `nothing`.
        @test IOFS.factory() === Objects.CLASS_FACTORY
    end

    include("bytes/test_primitives.jl")
    include("bytes/test_framing.jl")
    include("compress/test_xxhash.jl")
    include("compress/test_blocks.jl")
    include("iofs/test_key.jl")
    include("iofs/test_file.jl")
    include("objects/test_classes.jl")
    include("objects/test_hist.jl")
    include("objects/test_graph.jl")
    include("objects/test_streamers.jl")
    include("trees/test_fixture.jl")

    # The tree tests read ROOT's own files rather than any this package wrote,
    # which is the only way to find out whether it agrees with ROOT — and which
    # means they need a corpus that is not shipped with the package. See
    # `corpus.jl` for where it is looked for.
    if have_corpus()
        @testset verbose = true "corpus" begin
            include("objects/test_hist_corpus.jl")
            include("trees/test_structure.jl")
            include("trees/test_values.jl")
            include("trees/test_objects.jl")
            include("trees/test_roundtrip.jl")
        end
    else
        @warn "no ROOT corpus at $(corpus_dir()) — tree tests skipped; set TTREE_TESTDATA"
    end

    include("test_quality.jl")
end
