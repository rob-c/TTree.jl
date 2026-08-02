"""
    TTree

A pure-Julia reader and writer for ROOT files.

```julia
using TTree

TTree.open("events.root") do f
    keys(f)
end
```

Local paths, `root://` URLs and `http(s)://` URLs are all opened the same way;
remote access goes through [XRootD.jl](https://github.com/JuliaHEP/XRootD.jl).

# Layers

The package is built as a stack, each layer usable on its own:

  - [`TTree.Bytes`](@ref) — ROOT's serialization format as byte codecs.
  - [`TTree.Compress`](@ref) — ROOT's compression envelope.
  - [`TTree.IOFS`](@ref) — the file container: keys, directories, headers.
  - [`TTree.Objects`](@ref) — ROOT's classes: collections, streamer info.
  - [`TTree.Trees`](@ref) — trees, branches, leaves and baskets.

Read and write are implemented as mirror images at every layer, so a file this
package writes decodes with the same code that reads one ROOT wrote.
"""
module TTree

include("Bytes/Bytes.jl")
include("Compress/Compress.jl")
include("IOFS/IOFS.jl")
include("Objects/Objects.jl")
include("Trees/Trees.jl")

using .Bytes
using .Compress
using .IOFS
using .Objects
using .Trees

# The file layer decodes objects through a factory it does not own, so that it
# can be used — and tested — without the class hierarchy above it. Installing
# the real one is the last step of loading the package.
function __init__()
    IOFS.register_factory!(Objects.CLASS_FACTORY)
    return nothing
end

export ROOTFile,
    Directory,
    write!,
    streamers,
    name,
    title,
    describe,
    TObject,
    TNamed,
    TObjString,
    TList,
    THashList,
    TObjArray,
    TArrayC,
    TArrayS,
    TArrayI,
    TArrayL,
    TArrayL64,
    TArrayF,
    TArrayD,
    TAxis,
    TH1C,
    TH1S,
    TH1I,
    TH1L,
    TH1F,
    TH1D,
    TH2C,
    TH2S,
    TH2I,
    TH2L,
    TH2F,
    TH2D,
    TH3C,
    TH3S,
    TH3I,
    TH3L,
    TH3F,
    TH3D,
    TProfile,
    TProfile2D,
    TGraph,
    TGraphErrors,
    TGraphAsymmErrors,
    AnyHist,
    AnyProfile,
    AnyGraph,
    histcore,
    graphcore,
    axis,
    nbins,
    bincontents,
    binerrors,
    binentries,
    bineffentries,
    binedges,
    bincenters,
    binlowedge,
    binwidth,
    binlabels,
    findbin,
    sumw2!,
    points,
    xerrors,
    yerrors,
    TStreamerInfo,
    elements,
    Tree,
    TBranch,
    TBranchElement,
    Basket,
    array,
    branches,
    allbranches,
    leaves,
    entries,
    basket,
    eachbasket,
    eachchunk

"""
    open(target; kwargs...) -> ROOTFile
    open(f, target; kwargs...)

Open a ROOT file for reading.

`target` may be a path, a `root://`, `http(s)://`, `dav(s)://` or `s3://` URL,
an `IO`, or a byte vector. Keyword arguments are passed to the underlying
source, which is where remote credentials go.

The two-argument form closes the file when `f` returns, including on error.
"""
open(target; kwargs...) = ROOTFile(target; kwargs...)
open(f::Function, target; kwargs...) = ROOTFile(f, target; kwargs...)

"""
    create(target; compression=Compress.DEFAULT_SETTINGS, kwargs...) -> ROOTFile
    create(f, target; kwargs...)

Create a ROOT file and return it open for writing.

`compression` is a [`Compress.Settings`](@ref) or a packed `fCompress` integer;
it becomes the file's default for every object written into it.
"""
create(target; kwargs...) = IOFS.create(target; kwargs...)
create(f::Function, target; kwargs...) = IOFS.create(f, target; kwargs...)

include("precompile.jl")

end # module TTree
