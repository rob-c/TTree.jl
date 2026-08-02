# Building a tree out of Julia data.
#
# Reading a tree is a matter of following what the file says; writing one is a
# matter of saying it. The tree record itself is only bookkeeping — names,
# types, and the offsets of the baskets — so almost everything here is about
# getting that bookkeeping to agree with the bytes actually written, because
# nothing in the format checks it and a reader that trusts it will simply
# return the wrong numbers.
#
# Three of those agreements are worth naming, since each is a place ROOT's
# reader would go wrong if it were broken:
#
#   - a basket's entry offsets are absolute positions from the start of its
#     key, not from the start of its payload, so the key's length has to be
#     known before the table can be written;
#   - a branch whose entries vary in length says so through `fEntryOffsetLen`,
#     and a reader consults *that* rather than the basket to decide whether an
#     offset table is there at all;
#   - a basket of fixed-size entries carries no table, and its reader finds
#     entry `i` at `fKeylen + i * fNevBufSize` — so `fNevBufSize` is the size of
#     one entry in bytes, and nothing else will do.
#
# Values go out a column at a time. A branch's baskets are its own, so nothing
# forces the columns to be interleaved, and writing one to the end before
# starting the next keeps each column's baskets contiguous on the file.

"""
    SCALAR_LEAVES

The leaf class, value width, sign and leaf-list code for each Julia type a
branch can be declared with.

ROOT spells the sign in the leaf-list code and in `fIsUnsigned` rather than in
the leaf class, which is why `Int32` and `UInt32` share a `TLeafI` here.
"""
const SCALAR_LEAVES = Dict{Type,Tuple{DataType,Int,Bool,Char}}(
    Bool => (TLeafO, 1, false, 'O'),
    Int8 => (TLeafB, 1, false, 'B'),
    UInt8 => (TLeafB, 1, true, 'b'),
    Int16 => (TLeafS, 2, false, 'S'),
    UInt16 => (TLeafS, 2, true, 's'),
    Int32 => (TLeafI, 4, false, 'I'),
    UInt32 => (TLeafI, 4, true, 'i'),
    Int64 => (TLeafL, 8, false, 'L'),
    UInt64 => (TLeafL, 8, true, 'l'),
    Float32 => (TLeafF, 4, false, 'F'),
    Float64 => (TLeafD, 8, false, 'D'),
    String => (TLeafC, 1, false, 'C'),
)

"The types a branch can hold, named for an error message."
function _leaftypes()
    return join(sort!([string(T) for T in keys(SCALAR_LEAVES)]), ", ")
end

"""
    ColumnWriter

One column of a tree being written: the branch and leaf that describe it, and
the buffer its entries are accumulating in until they are large enough to be a
basket.

`kind` is `:scalar`, `:fixed`, `:jagged` or `:string`, which is the whole of
what the encoding depends on. `counter` is the column holding this one's
per-entry length; `iscounter` says some other column is counted by this one, and
`counts` names that column when this one was created for it alone.
"""
mutable struct ColumnWriter
    name::String
    valuetype::Type
    kind::Symbol
    per::Int
    branch::TBranch
    leaf::Any
    counter::Union{Nothing,ColumnWriter}
    iscounter::Bool
    counts::Union{Nothing,String}
    data::WBuffer
    offsets::Vector{Int32}
    nev::Int
    written::Int
    maxcount::Int
    maxlen::Int
end

"Whether this column's entries differ in length, and so need an offset table."
_isjagged(c::ColumnWriter) = c.kind === :jagged || c.kind === :string

"Bytes one entry of a fixed-size column occupies."
_entrysize(c::ColumnWriter) = c.per * SCALAR_LEAVES[c.valuetype][2]

"""
    TreeWriter

A tree being built in a file.

Columns are declared with [`branch!`](@ref), entries appended with
[`push!`](@ref Base.push!), and the tree becomes an object of the file when it
is [`close`](@ref Base.close)d — until then its baskets are on the file but
nothing points at them, so a writer that is never closed leaves the file exactly
as valid as it was before, only larger.
"""
mutable struct TreeWriter
    file::ROOTFile
    dir::Directory
    tree::Tree
    columns::Vector{ColumnWriter}
    basketsize::Int
    compression::Any
    nentries::Int
    closed::Bool
    key::Any
end

"""
    TreeWriter(f, name, title=""; basketsize=32000, compression=nothing) -> TreeWriter
    TreeWriter(f, dir, name, title=""; ...) -> TreeWriter
    TreeWriter(fn, f, name, title=""; ...)

Start a tree called `name` in `f`, or in one of its directories.

`basketsize` is the number of bytes of a column to gather before flushing a
basket, which is ROOT's `fBasketSize`, and `compression` overrides the file's
setting for this tree's baskets alone.

The three-argument form with a function first closes the writer when the
function returns, including on error, which is the only way to be sure the tree
is written:

```julia
TTree.create("out.root") do f
    TreeWriter(f, "tree") do t
        branch!(t, "x", Int32)
        branch!(t, "y", Float64)
        for i in 1:1000
            push!(t, (x=Int32(i), y=sqrt(i)))
        end
    end
end
```

The schema can also be given up front, as a `NamedTuple` of types — see
[`branch!`](@ref) for what a type may be:

```julia
t = TreeWriter(f, "tree", (x=Int32, y=Float64, v=Vector{Float32}, s=String))
```
"""
function TreeWriter(
    f::ROOTFile,
    dir::Directory,
    name::AbstractString,
    title::AbstractString="";
    basketsize::Integer=32000,
    compression=nothing,
)
    f.sink === nothing && throw(ArgumentError("TTree: $(f.id) is open for reading only"))
    basketsize > 0 ||
        throw(ArgumentError("TTree: a basket size must be positive, not $basketsize"))
    t = Tree(name, isempty(title) ? name : title)
    return TreeWriter(
        f, dir, t, ColumnWriter[], Int(basketsize), compression, 0, false, nothing
    )
end

function TreeWriter(f::ROOTFile, name::AbstractString, title::AbstractString=""; kwargs...)
    return TreeWriter(f, f.dir, name, title; kwargs...)
end

function TreeWriter(
    f::ROOTFile,
    name::AbstractString,
    schema::NamedTuple,
    title::AbstractString="";
    kwargs...,
)
    w = TreeWriter(f, f.dir, name, title; kwargs...)
    for (nm, T) in pairs(schema)
        branch!(w, String(nm), T)
    end
    return w
end

function TreeWriter(fn::Function, f::ROOTFile, args...; kwargs...)
    w = TreeWriter(f, args...; kwargs...)
    try
        return fn(w)
    finally
        close(w)
    end
end

Objects.name(w::TreeWriter) = Objects.name(w.tree)
Objects.title(w::TreeWriter) = Objects.title(w.tree)

"Number of entries appended so far."
entries(w::TreeWriter) = w.nentries

"""
    keys(w::TreeWriter) -> Vector{String}

The names of the columns declared so far, the ones created to count a
variable-length column included.
"""
Base.keys(w::TreeWriter) = String[c.name for c in w.columns]

function _column(w::TreeWriter, name::AbstractString)
    for c in w.columns
        c.name == name && return c
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Declaring columns.

"""
    branch!(w::TreeWriter, name, T) -> ColumnWriter
    branch!(w::TreeWriter, name, T, n::Integer) -> ColumnWriter

Add a column called `name` to a tree that has no entries yet.

`T` may be

  - one of $(_leaftypes()), for a column of single values;
  - `NTuple{n,T}`, or `T` with a length `n`, for `n` values per entry;
  - `Vector{T}` — any `AbstractVector` type — for a column whose entries differ
    in length.

A varying column is counted by a column of its own, since that is how ROOT
records the length: one is created alongside it, named `n` followed by this
column's name, unless `count` names an `Int32` column already declared. Sharing
one counter between several columns is what `count` is for, and then every entry
of those columns must be as long as the counter says.

Columns cannot be added once entries have been pushed: a tree's entries all have
the same columns, and there would be nothing to put in the new one for the
entries already written.
"""
function branch!(
    w::TreeWriter,
    name::AbstractString,
    ::Type{T},
    n::Union{Nothing,Integer}=nothing;
    count=nothing,
) where {T}
    return _branch!(w, String(name), T, n, count)
end

function _branch!(w::TreeWriter, name::String, ::Type{T}, n, count) where {T}
    w.closed && throw(ArgumentError("TTree: tree $(repr(name)) is already written"))
    w.nentries == 0 || throw(
        ArgumentError(
            "TTree: branch $(repr(name)) cannot be added after $(w.nentries) entries have been pushed",
        ),
    )
    _column(w, name) === nothing ||
        throw(ArgumentError("TTree: this tree already has a branch called $(repr(name))"))

    if T <: AbstractVector
        n === nothing || throw(
            ArgumentError(
                "TTree: branch $(repr(name)) is a $(T), whose entries carry their own length — drop the $n",
            ),
        )
        return _jagged_branch!(w, name, _elementtype(name, T), count)
    end
    count === nothing || throw(
        ArgumentError(
            "TTree: branch $(repr(name)) is not a variable-length column, so nothing counts it",
        ),
    )
    if T <: Tuple
        n === nothing || throw(
            ArgumentError(
                "TTree: branch $(repr(name)) is an $(T), which says its own length — drop the $n",
            ),
        )
        return _fixed_branch!(w, name, _elementtype(name, T), fieldcount(T))
    end
    n === nothing && return _plain_branch!(w, name, T)
    return _fixed_branch!(w, name, T, Int(n))
end

"The one element type of a container a branch was declared with."
function _elementtype(name::String, ::Type{T}) where {T}
    E = eltype(T)
    E <: AbstractString && (E = String)
    haskey(SCALAR_LEAVES, E) || throw(
        ArgumentError(
            "TTree: branch $(repr(name)) holds $(E), which is not one of $(_leaftypes())",
        ),
    )
    return E
end

"A column of one value per entry, or of one string per entry."
function _plain_branch!(w::TreeWriter, name::String, ::Type{T}) where {T}
    S = T <: AbstractString ? String : T
    haskey(SCALAR_LEAVES, S) || throw(
        ArgumentError(
            "TTree: branch $(repr(name)) holds $(T), which is not one of $(_leaftypes())",
        ),
    )
    kind = S === String ? :string : :scalar
    return _addcolumn!(w, name, S, kind, 1, name, nothing, nothing)
end

"A column of `per` values per entry, all entries the same length."
function _fixed_branch!(w::TreeWriter, name::String, ::Type{T}, per::Int) where {T}
    per > 0 ||
        throw(ArgumentError("TTree: branch $(repr(name)) must hold at least one value"))
    T === String && throw(
        ArgumentError(
            "TTree: branch $(repr(name)) cannot hold a fixed number of strings — ROOT has no such leaf",
        ),
    )
    return _addcolumn!(w, name, T, :fixed, per, "$name[$per]", nothing, nothing)
end

"A column whose entries differ in length, and the column that counts it."
function _jagged_branch!(w::TreeWriter, name::String, ::Type{T}, count) where {T}
    T === String && throw(
        ArgumentError(
            "TTree: branch $(repr(name)) cannot hold a varying number of strings — ROOT has no such leaf",
        ),
    )
    cnt = if count === nothing
        _addcolumn!(w, "n$name", Int32, :scalar, 1, "n$name", nothing, name)
    else
        c = _column(w, String(count))
        c === nothing && throw(
            ArgumentError(
                "TTree: branch $(repr(name)) is counted by $(repr(String(count))), which this tree does not have",
            ),
        )
        (c.kind === :scalar && c.valuetype === Int32) || throw(
            ArgumentError(
                "TTree: branch $(repr(name)) is counted by $(repr(c.name)), which is not a column of Int32",
            ),
        )
        c
    end
    cnt.iscounter = true
    # ROOT reads a counted leaf into a buffer sized from its counter's declared
    # maximum, so the counter is a leaf with a range whether or not the caller
    # thought of it as one.
    leafcore(cnt.leaf).isrange = true
    return _addcolumn!(w, name, T, :jagged, 1, "$name[$(cnt.name)]", cnt, nothing)
end

"""
    _addcolumn!(w, name, T, kind, per, spec, counter, counts) -> ColumnWriter

Build the branch and leaf ROOT would have built, and hang a buffer off them.

`spec` is the leaf's title — the name with its dimensions, which is what ROOT
writes there and what a reader with no other description would go by. The
branch's title is the same thing with the type code appended, exactly as it was
given to `TTree::Branch`.
"""
function _addcolumn!(
    w::TreeWriter,
    name::String,
    ::Type{T},
    kind::Symbol,
    per::Int,
    spec::String,
    counter,
    counts,
) where {T}
    cls, width, unsigned, code = SCALAR_LEAVES[T]
    leaf = cls()
    lc = leafcore(leaf)
    lc.named = TNamed(name, spec)
    lc.len = Int32(per)
    lc.lentype = Int32(width)
    lc.isunsigned = unsigned
    counter === nothing || (lc.count = counter.leaf)

    b = TBranch(name, "$spec/$code")
    b.compress = _compression_code(w)
    b.basketsize = Int32(w.basketsize)
    b.entryoffsetlen = Int32(kind === :jagged || kind === :string ? 1000 : 0)
    b.leaves = Any[leaf]

    c = ColumnWriter(
        name, T, kind, per, b, leaf, counter, false, counts, WBuffer(), Int32[], 0, 0, 0, 0
    )
    push!(w.columns, c)
    return c
end

"The `fCompress` code this tree's baskets are written with."
function _compression_code(w::TreeWriter)
    s = w.compression
    s === nothing && return w.file.compression
    return s isa Compress.Settings ? Compress.compression_code(s) : Int32(s)
end

# ---------------------------------------------------------------------------
# Appending entries.

"""
    push!(w::TreeWriter, entry::NamedTuple) -> w

Append one entry.

`entry` names every column of the tree except the ones created to count a
varying column, whose values follow from the columns they count and are filled
in here.

The whole entry is checked before any of it is written, so a rejected one
leaves the tree as it was rather than half a row longer.
"""
function Base.push!(w::TreeWriter, entry::NamedTuple)
    w.closed && throw(ArgumentError("TTree: this tree is already written"))
    vals = Vector{Any}(undef, length(w.columns))
    for (i, c) in enumerate(w.columns)
        # A generated counter takes its value from the column it counts, which
        # is the one the caller was asked for.
        src = c.counts === nothing ? c.name : c.counts
        haskey(entry, Symbol(src)) || throw(
            ArgumentError(
                "TTree: this entry has no value for branch $(repr(src)) — it names $(join((string(k) for k in keys(entry)), ", "))",
            ),
        )
        v = entry[Symbol(src)]
        vals[i] = c.counts === nothing ? v : length(v)
    end
    for (i, c) in enumerate(w.columns)
        _check_value(c, vals[i], entry)
    end
    for (i, c) in enumerate(w.columns)
        _push_value!(w, c, vals[i])
    end
    w.nentries += 1
    return w
end

"""
    _check_value(c, v, entry) -> nothing

Everything about one column's value that can be wrong.

The two ways an entry can fail to describe itself: a fixed-size column given
the wrong number of values, and a variable-length one that disagrees with the
counter the caller declared for it. A counter of this package's own making
cannot disagree — it was filled from the very value being checked.
"""
function _check_value(c::ColumnWriter, v, entry::NamedTuple)
    if c.kind === :fixed
        length(v) == c.per || throw(
            ArgumentError(
                "TTree: branch $(repr(c.name)) holds $(c.per) values per entry, and this one has $(length(v))",
            ),
        )
    elseif c.kind === :jagged
        cnt = c.counter::ColumnWriter
        cnt.counts === nothing || return nothing
        n = entry[Symbol(cnt.name)]
        length(v) == n || throw(
            ArgumentError(
                "TTree: branch $(repr(c.name)) has $(length(v)) values in this entry, but $(repr(cnt.name)) counts $n",
            ),
        )
    end
    return nothing
end

"""
    _push_value!(w, c, v) -> nothing

Encode one entry of one column, and flush the column if that filled a basket.

Where the entry began is noted before it is written, since that is exactly what
the offset table holds — and for a column whose entries all have the same size,
not writing that table is the whole difference.
"""
function _push_value!(w::TreeWriter, c::ColumnWriter, v)
    _isjagged(c) && push!(c.offsets, Int32(pos(c.data)))
    _encode!(c, v)
    c.nev += 1
    length(c.data) >= w.basketsize && _flush_column!(w, c)
    return nothing
end

function _encode!(c::ColumnWriter, v)
    if c.kind === :scalar
        # ROOT reads a counted column into a buffer sized from its counter's
        # largest value, so the largest is worth keeping as they go by.
        c.iscounter && (c.maxcount = max(c.maxcount, Int(v)))
        _write_one!(c.data, c.valuetype, v)
    elseif c.kind === :string
        s = v isa AbstractString ? v : string(v)
        c.maxlen = max(c.maxlen, ncodeunits(s))
        write_tstring!(c.data, s)
    else
        _write_many!(c.data, c.valuetype, v)
    end
    return nothing
end

_write_one!(w::WBuffer, ::Type{String}, v) = write_tstring!(w, v)
_write_one!(w::WBuffer, ::Type{T}, v) where {T} = writebe!(w, convert(T, v))

function _write_many!(w::WBuffer, ::Type{T}, v) where {T}
    if v isa AbstractVector{T}
        write_array!(w, v)
    else
        for x in v
            writebe!(w, convert(T, x))
        end
    end
    return w
end

"""
    _append_column!(w, c, values) -> nothing

Every entry of one column, in order.

The whole column at once rather than an entry at a time, so that the element
type is known to the compiler for the length of it — which is what makes
writing a column of a million numbers a loop over numbers rather than a loop
over `Any`.
"""
function _append_column!(w::TreeWriter, c::ColumnWriter, values)
    for v in values
        _push_value!(w, c, v)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Flushing baskets.

"""
    flush!(w::TreeWriter) -> w

Write out every column's pending entries as a basket each.

Baskets are flushed on their own as columns fill, so this is only needed to
force a boundary — before an interruption the file should survive, say. It costs
one record per column, so flushing after every entry would produce a file of
one-entry baskets.
"""
function flush!(w::TreeWriter)
    for c in w.columns
        _flush_column!(w, c)
    end
    return w
end

"""
    _flush_column!(w, c) -> nothing

Write one column's pending entries as a `TBasket` record and note where it went.

The payload is the entries as they were encoded, followed — for a column whose
entries differ in length — by the table of where each began. ROOT numbers those
positions from the start of the key, so the key's length is settled first and
added to every one of them; `fLast`, which marks the end of the entries and the
start of the table, is measured the same way.
"""
function _flush_column!(w::TreeWriter, c::ColumnWriter)
    c.nev == 0 && return nothing
    f = w.file
    jag = _isjagged(c)
    keylen = keylen_for(
        c.name, Objects.name(w.tree), "TBasket"; bigfile=f.fend > START_BIG_FILE
    )

    ndata = length(c.data)
    payload = WBuffer(bytes(c.data))
    if jag
        # ROOT writes one position more than there are entries: the last is
        # where the entries end, which is where this table itself begins.
        writebe!(payload, Int32(c.nev + 1))
        for o in c.offsets
            writebe!(payload, Int32(keylen) + o)
        end
        writebe!(payload, Int32(keylen) + Int32(ndata))
    end

    last = Int32(keylen) + Int32(ndata)
    head = WBuffer()
    writebe!(head, Int16(3))                          # TBasket class version
    writebe!(head, Int32(max(w.basketsize, last)))    # fBufferSize
    writebe!(head, Int32(jag ? 4 * c.nev : _entrysize(c)))
    writebe!(head, Int32(c.nev))
    writebe!(head, last)
    writebe!(head, UInt8(0))                          # fFlag: nothing deferred

    k = put_record!(
        f,
        c.name,
        Objects.name(w.tree),
        "TBasket",
        bytes(payload);
        cycle=0,
        header=bytes(head),
        keylen=keylen,
        compression=w.compression,
    )

    b = c.branch
    push!(b.basketseek, k.seekkey)
    push!(b.basketbytes, k.nbytes)
    push!(b.basketentry, Int64(c.written))
    b.writebasket += Int32(1)
    b.totbytes += Int64(keylen) + Int64(k.objlen)
    b.zipbytes += Int64(k.nbytes)
    b.entryoffsetlen = Int32(jag ? 4 * c.nev : 0)

    c.written += c.nev
    c.nev = 0
    c.data = WBuffer()
    empty!(c.offsets)
    return nothing
end

# ---------------------------------------------------------------------------
# Finishing.

"""
    close(w::TreeWriter) -> Key

Flush what is left and write the tree, returning the key that now holds it.

Closing twice is not an error and does not write a second tree: the key from
the first close is returned again.
"""
function Base.close(w::TreeWriter)
    w.closed && return w.key
    w.closed = true
    for c in w.columns
        _flush_column!(w, c)
        _finish_column!(w, c)
    end

    t = w.tree
    t.entries = Int64(w.nentries)
    t.totbytes = sum(c -> c.branch.totbytes, w.columns; init=Int64(0))
    t.zipbytes = sum(c -> c.branch.zipbytes, w.columns; init=Int64(0))
    t.branches = Any[c.branch for c in w.columns]
    t.leaves = Any[c.leaf for c in w.columns]

    w.key = IOFS.write!(w.file, w.dir, Objects.name(t), t)
    return w.key
end

Base.isopen(w::TreeWriter) = !w.closed

"""
    _finish_column!(w, c) -> nothing

Settle the parts of a column's description that are only known once every entry
has been written.

Some of it is bookkeeping ROOT keeps for its own use — the basket tables have
spare slots, as a tree still being filled would. The rest a reader needs: a
string leaf's `fLen` and a count leaf's `fMaximum` are how much room ROOT sets
aside for one entry, so both have to cover the largest entry actually written.
"""
function _finish_column!(w::TreeWriter, c::ColumnWriter)
    b = c.branch
    b.entries = Int64(c.written)
    b.entrynumber = Int64(c.written)

    # ROOT keeps room for baskets not yet written and expands in tens; the
    # count of slots is what says how long the three tables are on the file.
    slots = max(10, Int(b.writebasket) + 1)
    b.maxbaskets = Int32(slots)
    resize!(b.basketseek, slots)
    resize!(b.basketbytes, slots)
    resize!(b.basketentry, slots)
    for i in (Int(b.writebasket) + 1):slots
        b.basketseek[i] = 0
        b.basketbytes[i] = 0
        b.basketentry[i] = 0
    end
    b.basketentry[Int(b.writebasket) + 1] = Int64(c.written)

    lc = leafcore(c.leaf)
    if c.kind === :string
        # A `TLeafC` declares the longest string it holds, with room for the
        # terminator C would need.
        lc.len = Int32(c.maxlen + 1)
        c.leaf.max = Int32(c.maxlen + 1)
    elseif c.iscounter
        lc.isrange = true
        c.leaf.max = Int32(c.maxcount)
    end
    return nothing
end

function Base.show(io::IO, w::TreeWriter)
    print(io, "TreeWriter(", repr(Objects.name(w.tree)), ", ", w.nentries, " entries, ")
    print(io, length(w.columns), " branches")
    return print(io, w.closed ? ", written)" : ")")
end

# ---------------------------------------------------------------------------
# The one-shot form.

"""
    write!(f, name, columns; title="", basketsize=32000, compression=nothing) -> Key
    write!(dir, name, columns; ...) -> Key

Write a whole tree at once, from columns already in memory.

`columns` is a `NamedTuple` or a dictionary of column name to values, each of
which says by its own type what the branch holds:

| Julia                       | branch                                     |
|:----------------------------|:-------------------------------------------|
| `Vector{T}`                 | one `T` per entry                          |
| `Vector{String}`            | one string per entry                       |
| `Matrix{T}`                 | a column of the matrix per entry           |
| `Vector{NTuple{n,T}}`       | `n` values per entry                       |
| `Vector{Vector{T}}`         | as many values per entry as there are      |

Every column must have the same number of entries — for a matrix, that is its
number of columns, which is the shape [`array`](@ref) gives a fixed-length leaf
back in.

```julia
TTree.create("out.root") do f
    write!(f, "tree", (x=1:1000, y=randn(1000), v=[rand(rand(0:3)) for _ in 1:1000]))
end
```

A varying column is counted by a column ROOT can see, so one is written
alongside it — `nv` for `v` above. To build a tree too large to have in memory,
or to share one counter between columns, use [`TreeWriter`](@ref).
"""
function IOFS.write!(
    f::ROOTFile,
    dir::Directory,
    name::AbstractString,
    columns::Union{NamedTuple,AbstractDict};
    title::AbstractString="",
    basketsize::Integer=32000,
    compression=nothing,
)
    w = TreeWriter(f, dir, name, title; basketsize=basketsize, compression=compression)
    sources = Any[]
    n = -1
    for (nm, v) in pairs(columns)
        cn = String(nm)
        m = _columnlength(cn, v)
        n < 0 && (n = m)
        m == n || throw(
            ArgumentError(
                "TTree: column $(repr(cn)) has $m entries, but $(repr(String(first(keys(columns))))) has $n",
            ),
        )
        _declare!(w, cn, v, sources)
    end
    n < 0 && throw(ArgumentError("TTree: a tree needs at least one column"))

    for (c, src) in zip(w.columns, sources)
        _append_column!(w, c, src)
    end
    w.nentries = n
    return close(w)
end

function IOFS.write!(
    f::ROOTFile, name::AbstractString, columns::Union{NamedTuple,AbstractDict}; kwargs...
)
    return IOFS.write!(f, f.dir, name, columns; kwargs...)
end

function IOFS.write!(
    d::Directory, name::AbstractString, columns::Union{NamedTuple,AbstractDict}; kwargs...
)
    return IOFS.write!(IOFS._owner(d), d, name, columns; kwargs...)
end

"How many entries a column of the one-shot form holds."
_columnlength(::String, v::AbstractVector) = length(v)
_columnlength(::String, v::AbstractMatrix) = size(v, 2)
function _columnlength(name::String, v)
    return throw(
        ArgumentError(
            "TTree: column $(repr(name)) is a $(typeof(v)), which is not a vector or a matrix of values",
        ),
    )
end

"""
    _declare!(w, name, v, sources) -> nothing

Add the branch a column of values calls for, and record where its entries come
from.

A varying column brings a counter with it, and the counter's entries are the
lengths of the column's — so the two are declared, and appended, in that order.
"""
function _declare!(w::TreeWriter, name::String, v::AbstractMatrix{T}, sources) where {T}
    branch!(w, name, T, size(v, 1))
    push!(sources, eachcol(v))
    return nothing
end

function _declare!(w::TreeWriter, name::String, v::AbstractVector{T}, sources) where {T}
    if T <: AbstractVector
        branch!(w, name, T)
        push!(sources, (length(x) for x in v))
        push!(sources, v)
    elseif T <: Tuple
        branch!(w, name, T)
        push!(sources, v)
    else
        branch!(w, name, T)
        push!(sources, v)
    end
    return nothing
end
