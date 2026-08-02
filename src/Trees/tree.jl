# TTree: the table.
#
# A tree is a header and nothing more. Everything it appears to contain lives in
# baskets scattered through the file, and the tree only says where they are —
# which is what makes a tree of a hundred columns cheap to open and cheap to
# read one column of.
#
# The Julia type is called `Tree` rather than `TTree` because the package itself
# is `TTree`, and a module cannot hold a type of its own name. Every other class
# here keeps the name ROOT gave it.

"""
    Tree

ROOT's `TTree`: a named table of [`TBranch`](@ref)es.

`entries` is the number of rows; each branch holds that many, and holds them in
its own baskets. The remaining fields are the tree's write-time policy —
`autoflush`, `basketsize` on the branches, the cluster ranges — which a reader
needs only to write the tree back out unchanged.
"""
mutable struct Tree <: ROOTObject
    named::TNamed
    attline::TAttLine
    attfill::TAttFill
    attmarker::TAttMarker
    entries::Int64
    totbytes::Int64
    zipbytes::Int64
    savedbytes::Int64
    flushedbytes::Int64
    weight::Float64
    timerinterval::Int32
    scanfield::Int32
    update::Int32
    defaultentryoffsetlen::Int32
    nclusterrange::Int32
    maxentries::Int64
    maxentryloop::Int64
    maxvirtualsize::Int64
    autosave::Int64
    autoflush::Int64
    estimate::Int64
    clusterrangeend::Vector{Int64}
    clustersize::Vector{Int64}
    iofeatures::TIOFeatures
    branches::Vector{Any}
    leaves::Vector{Any}
    aliases::Any
    indexvalues::Vector{Float64}
    index::Vector{Int32}
    treeindex::Any
    friends::Any
    userinfo::Any
    branchref::Any
    # Not streamed: the file the tree was read from.
    file::Any
end

function Tree(name::AbstractString="", title::AbstractString="")
    return Tree(
        TNamed(name, title),
        TAttLine(),
        TAttFill(Int16(0), Int16(1001)),
        TAttMarker(),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        1.0,
        Int32(0),
        Int32(25),
        Int32(0),
        Int32(1000),
        Int32(0),
        Int64(1_000_000_000_000),
        Int64(1_000_000_000_000),
        Int64(0),
        Int64(300_000_000),
        Int64(-30_000_000),
        Int64(1_000_000),
        Int64[],
        Int64[],
        TIOFeatures(),
        Any[],
        Any[],
        nothing,
        Float64[],
        Int32[],
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
    )
end

Bytes.classname(::Tree) = "TTree"
rversion(::Tree) = Int16(20)

function Bytes.unmarshal!(t::Tree, r::RBuffer)
    hdr = read_header(r, "TTree")
    for e in layout(r, "TTree", hdr.vers)
        m = name(e)
        if m == "TNamed"
            Bytes.unmarshal!(t.named, r)
        elseif m == "TAttLine"
            Bytes.unmarshal!(t.attline, r)
        elseif m == "TAttFill"
            Bytes.unmarshal!(t.attfill, r)
        elseif m == "TAttMarker"
            Bytes.unmarshal!(t.attmarker, r)
        elseif m == "fEntries"
            t.entries = read_count(r, e)
        elseif m == "fTotBytes"
            t.totbytes = read_count(r, e)
        elseif m == "fZipBytes"
            t.zipbytes = read_count(r, e)
        elseif m == "fSavedBytes"
            t.savedbytes = read_count(r, e)
        elseif m == "fFlushedBytes"
            t.flushedbytes = read_count(r, e)
        elseif m == "fWeight"
            t.weight = read_scalar(r, e)
        elseif m == "fTimerInterval"
            t.timerinterval = read_scalar(r, e)
        elseif m == "fScanField"
            t.scanfield = read_scalar(r, e)
        elseif m == "fUpdate"
            t.update = read_scalar(r, e)
        elseif m == "fDefaultEntryOffsetLen"
            t.defaultentryoffsetlen = read_scalar(r, e)
        elseif m == "fNClusterRange"
            t.nclusterrange = read_scalar(r, e)
        elseif m == "fMaxEntries"
            t.maxentries = read_count(r, e)
        elseif m == "fMaxEntryLoop"
            t.maxentryloop = read_count(r, e)
        elseif m == "fMaxVirtualSize"
            t.maxvirtualsize = read_count(r, e)
        elseif m == "fAutoSave"
            t.autosave = read_count(r, e)
        elseif m == "fAutoFlush"
            t.autoflush = read_count(r, e)
        elseif m == "fEstimate"
            t.estimate = read_count(r, e)
        elseif m == "fClusterRangeEnd"
            t.clusterrangeend = read_pointer_array(r, e, t.nclusterrange, Int64)
        elseif m == "fClusterSize"
            t.clustersize = read_pointer_array(r, e, t.nclusterrange, Int64)
        elseif m == "fIOFeatures"
            Bytes.unmarshal!(t.iofeatures, r)
        elseif m == "fBranches"
            read_objarray!(t.branches, r)
        elseif m == "fLeaves"
            read_objarray!(t.leaves, r)
        elseif m == "fAliases"
            t.aliases = read_object_any(r)
        elseif m == "fIndexValues"
            t.indexvalues = _read_array_member(r, TArrayD)
        elseif m == "fIndex"
            t.index = _read_array_member(r, TArrayI)
        elseif m == "fTreeIndex"
            t.treeindex = read_object_any(r)
        elseif m == "fFriends"
            t.friends = read_object_any(r)
        elseif m == "fUserInfo"
            t.userinfo = read_object_any(r)
        elseif m == "fBranchRef"
            t.branchref = read_object_any(r)
        else
            unknown_member("TTree", hdr.vers, m)
        end
    end
    check_header(r, hdr)
    return t
end

function Bytes.marshal!(w::WBuffer, t::Tree)
    hdr = write_header!(w, "TTree", rversion(t))
    Bytes.marshal!(w, t.named)
    Bytes.marshal!(w, t.attline)
    Bytes.marshal!(w, t.attfill)
    Bytes.marshal!(w, t.attmarker)
    writebe!(w, t.entries)
    writebe!(w, t.totbytes)
    writebe!(w, t.zipbytes)
    writebe!(w, t.savedbytes)
    writebe!(w, t.flushedbytes)
    writebe!(w, t.weight)
    writebe!(w, t.timerinterval)
    writebe!(w, t.scanfield)
    writebe!(w, t.update)
    writebe!(w, t.defaultentryoffsetlen)
    writebe!(w, Int32(length(t.clusterrangeend)))
    writebe!(w, t.maxentries)
    writebe!(w, t.maxentryloop)
    writebe!(w, t.maxvirtualsize)
    writebe!(w, t.autosave)
    writebe!(w, t.autoflush)
    writebe!(w, t.estimate)
    write_pointer_array!(w, t.clusterrangeend)
    write_pointer_array!(w, t.clustersize)
    Bytes.marshal!(w, t.iofeatures)
    write_objarray!(w, t.branches)
    write_objarray!(w, t.leaves)
    write_object_any!(w, t.aliases)
    Bytes.marshal!(w, TArrayD(t.indexvalues))
    Bytes.marshal!(w, TArrayI(t.index))
    write_object_any!(w, t.treeindex)
    write_object_any!(w, t.friends)
    write_object_any!(w, t.userinfo)
    write_object_any!(w, t.branchref)
    set_header!(w, hdr)
    return w
end

"A `TArray*` member, kept as the plain `Vector` it wraps."
function _read_array_member(r::RBuffer, ::Type{A}) where {A}
    a = A()
    Bytes.unmarshal!(a, r)
    return a.data
end

# ---------------------------------------------------------------------------
# The n-tuples: a tree of nothing but single-precision — or double-precision —
# columns, which is all most people ever want a tree to be.

for (cls, T, V) in ((:TNtuple, Float32, 2), (:TNtupleD, Float64, 1))
    cls_str = String(cls)
    @eval begin
        """
            $($cls_str)

        ROOT's `$($cls_str)`: a [`Tree`](@ref) whose every branch holds one
        `$($T)`. `nvar` is how many columns there are, which is also the number
        of branches.
        """
        mutable struct $cls <: ROOTObject
            tree::Tree
            nvar::Int32
        end

        $cls(name::AbstractString="", title::AbstractString="") =
            $cls(Tree(name, title), Int32(0))

        Bytes.classname(::$cls) = $cls_str
        rversion(::$cls) = Int16($V)
        Base.eltype(::Type{$cls}) = $T

        function Bytes.unmarshal!(n::$cls, r::RBuffer)
            hdr = read_header(r, $cls_str)
            for e in layout(r, $cls_str, hdr.vers)
                m = name(e)
                if m == "TTree"
                    Bytes.unmarshal!(n.tree, r)
                elseif m == "fNvar"
                    n.nvar = read_scalar(r, e)
                else
                    unknown_member($cls_str, hdr.vers, m)
                end
            end
            check_header(r, hdr)
            return n
        end

        function Bytes.marshal!(w::WBuffer, n::$cls)
            hdr = write_header!(w, $cls_str, rversion(n))
            Bytes.marshal!(w, n.tree)
            writebe!(w, n.nvar)
            set_header!(w, hdr)
            return w
        end
    end
end

"""
    AnyTree

A [`Tree`](@ref) or one of the n-tuple classes built on it, which
[`treecore`](@ref) reaches uniformly.
"""
const AnyTree = Union{Tree,TNtuple,TNtupleD}

"The common `TTree` part of any tree."
treecore(t::Tree) = t
treecore(t::Union{TNtuple,TNtupleD}) = t.tree

Objects.name(t::Tree) = Objects.name(t.named)
Objects.title(t::Tree) = Objects.title(t.named)
Objects.name(t::Union{TNtuple,TNtupleD}) = Objects.name(treecore(t))
Objects.title(t::Union{TNtuple,TNtupleD}) = Objects.title(treecore(t))

"""
    branches(t) -> Vector

The tree's top-level branches. A split branch's own branches are reached
through [`branches`](@ref) on it, or all at once through [`allbranches`](@ref).
"""
branches(t::AnyTree) = treecore(t).branches

"Every leaf of the tree, in the order ROOT lists them."
leaves(t::AnyTree) = treecore(t).leaves

"Number of entries — rows — in the tree."
entries(t::AnyTree) = treecore(t).entries

Base.length(t::AnyTree) = Int(entries(t))

"""
    allbranches(t) -> Vector

Every branch of `t`, nested ones included, parents before children.
"""
function allbranches(t::Union{AnyTree,AnyBranch})
    out = Any[]
    for b in branches(t)
        b === nothing && continue
        push!(out, b)
        append!(out, allbranches(b))
    end
    return out
end

"""
    keys(t) -> Vector{String}

Names of the tree's top-level branches, which is what `t[name]` resolves
against first.
"""
Base.keys(t::AnyTree) = String[Objects.name(b) for b in branches(t) if b !== nothing]

Base.haskey(t::AnyTree, name::AbstractString) = _findbranch(t, name) !== nothing

"""
    t[name] -> branch

The branch called `name`.

A top-level branch wins; failing that the nested branches are searched, so a
split object's member can be asked for by its own name — `"pt"` as well as
`"muons.pt"`.
"""
function Base.getindex(t::AnyTree, name::AbstractString)
    b = _findbranch(t, name)
    b === nothing && throw(KeyError(name))
    return b
end

function Base.get(t::AnyTree, name::AbstractString, default)
    return something(_findbranch(t, name), Some(default))
end

function _findbranch(t::AnyTree, want::AbstractString)
    for b in branches(t)
        b === nothing && continue
        Objects.name(b) == want && return b
    end
    for b in allbranches(t)
        Objects.name(b) == want && return b
    end
    return nothing
end

function Bytes.bind!(t::AnyTree, file)
    core = treecore(t)
    core.file = file
    for b in core.branches
        b === nothing && continue
        Bytes.bind!(b, file)
        adopt!(b, t)
    end
    if core.branchref !== nothing
        Bytes.bind!(core.branchref, file)
        adopt!(core.branchref, t)
    end
    return t
end

function Base.show(io::IO, t::AnyTree)
    print(
        io, Bytes.classname(t), "(", repr(Objects.name(t)), ", ", entries(t), " entries, "
    )
    return print(io, length(branches(t)), " branches)")
end

function Base.show(io::IO, ::MIME"text/plain", t::AnyTree)
    println(
        io, Bytes.classname(t), " ", repr(Objects.name(t)), " — ", repr(Objects.title(t))
    )
    println(io, "  ", entries(t), " entries, ", treecore(t).zipbytes, " bytes on disk")
    for b in allbranches(t)
        core = branchcore(b)
        pad = "  "
        print(io, pad, rpad(Objects.name(b), 28), " ")
        ls = leaves(b)
        types = join((_leaf_label(l) for l in ls), ", ")
        print(io, rpad(types, 20))
        println(io, lpad(string(core.entries), 10), " entries")
    end
    return nothing
end

function _leaf_label(l)
    c = countleaf(l)
    n = length(l)
    body = string(elementtype(l))
    c !== nothing && return body * "[" * Objects.name(c) * "]"
    n == 1 && return body
    return body * "[" * string(n) * "]"
end
