"""
    TTree.Objects

Layer 3: ROOT's class hierarchy — the objects a file's keys actually contain.

Each class is a Julia type with `Bytes.unmarshal!` / `Bytes.marshal!` methods
that mirror ROOT's `Streamer`, and an entry in the class registry so that a
class name read out of a buffer can be turned into an instance.

C++ inheritance is modelled by composition rather than by Julia's abstract
types: a class holds its base class as a field and streams it in place. ROOT
writes base classes inline, so the byte layout is the same, and the Julia types
stay concrete.
"""
module Objects

using Dates: DateTime

using ..Bytes
using ..Bytes: Bytes, KBYTE_COUNT_VMASK
using ..IOFS
using ..IOFS: IOFS, ROOTFile, StreamerDB

export ROOTObject,
    rversion,
    name,
    title,
    entries,
    # base
    TObject,
    TNamed,
    TObjString,
    TAttLine,
    TAttFill,
    TAttMarker,
    TAttAxis,
    # collections
    TList,
    THashList,
    TObjArray,
    TArray,
    TArrayC,
    TArrayS,
    TArrayI,
    TArrayL,
    TArrayL64,
    TArrayF,
    TArrayD,
    options,
    # histograms and graphs
    TAxis,
    TH1,
    TH1C,
    TH1S,
    TH1I,
    TH1L,
    TH1F,
    TH1D,
    TH2,
    TH2C,
    TH2S,
    TH2I,
    TH2L,
    TH2F,
    TH2D,
    TH3,
    TH3C,
    TH3S,
    TH3I,
    TH3L,
    TH3F,
    TH3D,
    TProfile,
    TProfile2D,
    TAtt3D,
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
    # streamer info
    StreamerElement,
    TStreamerInfo,
    TStreamerBase,
    TStreamerBasicType,
    TStreamerBasicPointer,
    TStreamerLoop,
    TStreamerObject,
    TStreamerObjectPointer,
    TStreamerObjectAny,
    TStreamerObjectAnyPointer,
    TStreamerString,
    TStreamerSTL,
    TStreamerSTLstring,
    TStreamerArtificial,
    AbstractStreamerElement,
    element,
    elements,
    etype,
    typename,
    arraylen,
    arraydims,
    describe,
    # registry
    register_class!,
    class_registry,
    streamer_info,
    streamer_closure,
    describable_classes,
    CLASS_FACTORY

include("rmeta.jl")
include("base.jl")
include("collections.jl")
include("streamerinfo.jl")
include("dictionary.jl")
include("streamers_gen.jl")
include("layout.jl")
include("hist.jl")
include("graph.jl")

# The key that holds an object records its title, which for ROOT is whatever
# `GetTitle` returns — the object's own for a `TNamed`, the class's otherwise.
Bytes.object_title(o::ROOTObject) = title(o)

"""
    CLASS_REGISTRY

Maps a ROOT class name to a zero-argument constructor.

This is the equivalent of ROOT's `TClass` dictionary, and the only way the byte
layer can act on a class name it reads out of a buffer. A class absent from the
registry is not an error: [`read_object_any`](@ref) skips it using its byte
count and decoding continues, which is what lets this package read a file
containing experiment-specific classes it has never heard of.
"""
const CLASS_REGISTRY = Dict{String,Any}()

"""
    register_class!(name, ctor) -> ctor

Make `name` constructible by the class factory. Call this for any class added
outside this module; the constructor must take no arguments.
"""
function register_class!(cls::AbstractString, ctor)
    CLASS_REGISTRY[String(cls)] = ctor
    return ctor
end

"The class-name → constructor table, for inspection."
class_registry() = CLASS_REGISTRY

"""
    ClassFactory

The object layer's entry point for the layers below it.

Called with a class name it returns a fresh instance, or `nothing` for a class
it does not know. The symbol form builds the containers the file layer needs
without giving it a dependency on the container types themselves.
"""
struct ClassFactory end

function (::ClassFactory)(cls::AbstractString)
    ctor = get(CLASS_REGISTRY, cls, nothing)
    ctor === nothing && return nothing
    return ctor()
end

function (::ClassFactory)(what::Symbol, args...)
    what === :list && return TList(args[2], args[1])
    what === :streamers && return streamer_closure(args[1])
    return throw(ArgumentError("TTree: the class factory does not build $(repr(what))"))
end

"The singleton factory registered with the file layer."
const CLASS_FACTORY = ClassFactory()

for (cls, ctor) in (
    "TObject" => TObject,
    "TNamed" => TNamed,
    "TObjString" => TObjString,
    "TAttLine" => TAttLine,
    "TAttFill" => TAttFill,
    "TAttMarker" => TAttMarker,
    "TAttAxis" => TAttAxis,
    "TList" => TList,
    "THashList" => THashList,
    "TObjArray" => TObjArray,
    "TArrayC" => TArrayC,
    "TArrayS" => TArrayS,
    "TArrayI" => TArrayI,
    "TArrayL" => TArrayL,
    "TArrayL64" => TArrayL64,
    "TArrayF" => TArrayF,
    "TArrayD" => TArrayD,
    "TAxis" => TAxis,
    "TAtt3D" => TAtt3D,
    "TH1" => TH1,
    "TH1C" => TH1C,
    "TH1S" => TH1S,
    "TH1I" => TH1I,
    "TH1L" => TH1L,
    "TH1F" => TH1F,
    "TH1D" => TH1D,
    "TH2" => TH2,
    "TH2C" => TH2C,
    "TH2S" => TH2S,
    "TH2I" => TH2I,
    "TH2L" => TH2L,
    "TH2F" => TH2F,
    "TH2D" => TH2D,
    "TH3" => TH3,
    "TH3C" => TH3C,
    "TH3S" => TH3S,
    "TH3I" => TH3I,
    "TH3L" => TH3L,
    "TH3F" => TH3F,
    "TH3D" => TH3D,
    "TProfile" => TProfile,
    "TProfile2D" => TProfile2D,
    "TGraph" => TGraph,
    "TGraphErrors" => TGraphErrors,
    "TGraphAsymmErrors" => TGraphAsymmErrors,
    "TStreamerInfo" => TStreamerInfo,
    "TStreamerElement" => StreamerElement,
    "TStreamerBase" => TStreamerBase,
    "TStreamerBasicType" => TStreamerBasicType,
    "TStreamerBasicPointer" => TStreamerBasicPointer,
    "TStreamerLoop" => TStreamerLoop,
    "TStreamerObject" => TStreamerObject,
    "TStreamerObjectPointer" => TStreamerObjectPointer,
    "TStreamerObjectAny" => TStreamerObjectAny,
    "TStreamerObjectAnyPointer" => TStreamerObjectAnyPointer,
    "TStreamerString" => TStreamerString,
    "TStreamerSTL" => TStreamerSTL,
    "TStreamerSTLstring" => TStreamerSTLstring,
    "TStreamerArtificial" => TStreamerArtificial,
)
    register_class!(cls, ctor)
end

end # module Objects
