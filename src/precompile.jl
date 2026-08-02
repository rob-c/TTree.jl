# Compiling the paths a first call would otherwise pay for.
#
# The workload writes a file and reads it back, which is the whole of the byte
# layer in miniature: a key header, a compressed record, a streamer info block,
# and objects marshalled and unmarshalled through the class factory. It is the
# read side that this is really for: opening a file and decoding a histogram out
# of it took about nine seconds cold and about a third of a second with this,
# against several seconds added to the package's own precompilation — which is
# paid once, on installation.
#
# Trees are not in it. This package can round-trip a tree it has read but cannot
# yet build one from nothing, and a workload cannot ship a file to read; so the
# tree layer is compiled on first use, and adding it here is the natural thing
# to do once basket writing exists.

using PrecompileTools: @compile_workload, @setup_workload

@setup_workload begin
    dir = mktempdir()
    path = joinpath(dir, "precompile.root")
    @compile_workload begin
        # `__init__` has not run at precompile time, so the factory the file
        # layer decodes through has to be installed by hand here.
        IOFS.register_factory!(Objects.CLASS_FACTORY)

        h = Objects.TH1F("h", "precompile", 4, 0.0, 4.0)
        push!(h, 1.5)
        push!(h, 2.5, 2.0)
        g = Objects.TGraph("g", "precompile", [1.0, 2.0], [3.0, 4.0])

        create(path) do f
            write!(f, "h", h)
            write!(f, "g", g)
            write!(f, "s", TObjString("hello"))
        end

        open(path) do f
            streamers(f)
            for k in f.dir.keys
                o = f[k.name]
                o isa Objects.AnyHist && (Objects.bincontents(o); Objects.binerrors(o))
                o isa Objects.AnyGraph && Objects.points(o)
            end
        end
    end
    rm(dir; recursive=true, force=true)
end
