# Regenerate `src/Objects/streamers_gen.jl` — the class descriptions this
# package writes into a file's StreamerInfo record.
#
# The descriptions are not invented: they are ROOT's own, read back out of a
# file ROOT was asked to write them into. Transcribing them by hand would be
# both tedious and unverifiable, whereas this reads them with the same decoder
# the package uses everywhere else, and the round-trip test in `test/` proves
# the result re-encodes to the bytes ROOT produced.
#
# Usage, from the package root:
#
#     julia --project=. dev/gen_streamers.jl
#
# Requires a `root` on PATH. Re-run it when a class is added to `Objects`,
# after adding the class name to `CLASSES` below.

using TTree
using TTree.Bytes
using TTree.IOFS
using TTree.Objects

# Every class this package can write, in no particular order: ROOT emits each
# one's bases along with it, and the generated file is sorted afterwards.
const CLASSES = [
    "TObject",
    "TNamed",
    "TString",
    "TObjString",
    "TCollection",
    "TSeqCollection",
    "TList",
    "THashList",
    "TObjArray",
    "TArrayC",
    "TArrayS",
    "TArrayI",
    "TArrayL",
    "TArrayL64",
    "TArrayF",
    "TArrayD",
    "TStreamerInfo",
    "TStreamerElement",
    "TStreamerBase",
    "TStreamerBasicType",
    "TStreamerBasicPointer",
    "TStreamerLoop",
    "TStreamerObject",
    "TStreamerObjectPointer",
    "TStreamerObjectAny",
    "TStreamerObjectAnyPointer",
    "TStreamerString",
    "TStreamerSTL",
    "TStreamerSTLstring",
    "TStreamerArtificial",
    "TAttLine",
    "TAttFill",
    "TAttMarker",
    "TAttAxis",
    "TAtt3D",
    "TAxis",
    "TH1",
    "TH1C",
    "TH1S",
    "TH1I",
    "TH1L",
    "TH1F",
    "TH1D",
    "TH2",
    "TH2C",
    "TH2S",
    "TH2I",
    "TH2L",
    "TH2F",
    "TH2D",
    "TH3",
    "TH3C",
    "TH3S",
    "TH3I",
    "TH3L",
    "TH3F",
    "TH3D",
    "TProfile",
    "TProfile2D",
    "TGraph",
    "TGraphErrors",
    "TGraphAsymmErrors",
    "ROOT::TIOFeatures",
    "TTree",
    "TNtuple",
    "TNtupleD",
    "TBranch",
    "TBranchElement",
    "TBranchObject",
    "TBranchRef",
    "TLeaf",
    "TLeafO",
    "TLeafB",
    "TLeafS",
    "TLeafI",
    "TLeafL",
    "TLeafG",
    "TLeafF",
    "TLeafD",
    "TLeafC",
    "TLeafF16",
    "TLeafD32",
    "TLeafElement",
    "TLeafObject",
]

const OUT = joinpath(@__DIR__, "..", "src", "Objects", "streamers_gen.jl")

function root_dump(dir::AbstractString)
    macro_path = joinpath(dir, "dump.C")
    out_path = joinpath(dir, "infos.root")
    open(macro_path, "w") do io
        println(io, "void dump() {")
        println(io, "  TFile *f = TFile::Open(\"$out_path\", \"RECREATE\");")
        for c in CLASSES
            println(io, "  {")
            println(io, "    TClass *k = TClass::GetClass(\"$c\");")
            println(io, "    if (!k) { printf(\"MISSING $c\\n\"); }")
            println(io, "    else k->GetStreamerInfo()->ForceWriteInfo(f, kTRUE);")
            println(io, "  }")
        end
        println(io, "  printf(\"ROOTVERSION %s\\n\", gROOT->GetVersion());")
        println(io, "  f->Close();")
        return println(io, "}")
    end
    out = read(`root -l -b -q $macro_path`, String)
    occursin("MISSING", out) && error("ROOT does not know: $(out)")
    m = match(r"ROOTVERSION (\S+)", out)
    m === nothing && error("could not determine the ROOT version:\n$out")
    return joinpath(dir, "infos.root"), m.captures[1]
end

_q(s) = repr(String(s))

function emit_element(io, e)
    el = Objects.element(e)
    args = [
        _q(el.named.name),
        _q(el.ename),
        string(el.etype),
        string(el.esize),
        _q(el.named.title),
    ]
    el.arrlen == 0 || push!(args, "arrlen=$(el.arrlen)")
    el.arrdim == 0 || push!(args, "arrdim=$(el.arrdim)")
    if any(!iszero, el.maxidx)
        push!(args, "maxidx=(" * join(el.maxidx, ", ") * ")")
    end
    inner = "_el(" * join(args, ", ") * ")"

    if e isa TStreamerBase
        print(io, "        TStreamerBase(", inner, ", ", e.vbase, "),\n")
    elseif e isa TStreamerBasicPointer || e isa TStreamerLoop
        print(
            io,
            "        ",
            nameof(typeof(e)),
            "(",
            inner,
            ", ",
            e.cvers,
            ", ",
            _q(e.cname),
            ", ",
            _q(e.ccls),
            "),\n",
        )
    elseif e isa TStreamerSTL
        print(io, "        TStreamerSTL(", inner, ", ", e.vtype, ", ", e.ctype, "),\n")
    elseif e isa TStreamerSTLstring
        stl = e.stl
        print(
            io,
            "        TStreamerSTLstring(TStreamerSTL(",
            inner,
            ", ",
            stl.vtype,
            ", ",
            stl.ctype,
            ")),\n",
        )
    else
        print(io, "        ", nameof(typeof(e)), "(", inner, "),\n")
    end
    return nothing
end

function main()
    mktempdir() do dir
        path, rootver = root_dump(dir)
        println("ROOT ", rootver, " wrote ", path)

        infos = Any[]
        TTree.open(path) do f
            return append!(infos, streamers(f).order)
        end
        sort!(infos; by=si -> Bytes.described_class(si))
        println("read ", length(infos), " streamer infos")

        open(OUT, "w") do io
            println(io, "# Generated by dev/gen_streamers.jl from ROOT ", rootver, ".")
            println(io, "# Do not edit: regenerate instead.")
            println(io, "#")
            println(
                io,
                "# ROOT's description of its own classes, which a file this package writes",
            )
            println(
                io, "# carries so that a reader with no dictionary can still decode it. See"
            )
            println(io, "# `streamer_info` for how these are selected when writing.")
            println(io)
            println(io, "function _builtin_streamers()")
            println(io, "    v = Any[]")
            for si in infos
                cls = Bytes.described_class(si)
                println(io)
                print(
                    io,
                    "    push!(v, TStreamerInfo(",
                    _q(cls),
                    ", ",
                    Bytes.class_version(si),
                    "; checksum=",
                    repr(Bytes.class_checksum(si)),
                    ", elems=[\n",
                )
                for e in elements(si)
                    emit_element(io, e)
                end
                println(io, "    ]))")
            end
            println(io)
            println(io, "    return v")
            return println(io, "end")
        end
        return println("wrote ", OUT, " (", filesize(OUT), " bytes)")
    end
    return nothing
end

main()
