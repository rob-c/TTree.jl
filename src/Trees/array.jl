# Turning a branch back into values.
#
# A basket's payload is one entry after another, and an entry is its branch's
# leaves in order — nothing separates them, nothing labels them. So decoding is
# entirely a matter of what the leaves say: how many values each holds and how
# wide they are.
#
# Two shapes need more than that. A leaf whose length varies per entry says so
# by naming another leaf that holds the length, and that leaf usually lives in
# a branch of its own — so reading one column can mean reading two. And a string
# leaf carries its own length, so it needs nothing but to be read in sequence.

"""
    array(branch) -> Array
    array(branch, leaf::AbstractString) -> Array
    array(tree, name::AbstractString) -> Array

Read a branch's values, every basket of it, as a Julia array.

The shape follows the leaf:

  - a scalar leaf gives a `Vector{T}`, one element per entry;
  - a fixed-length leaf of `n` values gives an `n × entries` `Matrix{T}`;
  - a variable-length leaf gives a `Vector{Vector{T}}`;
  - a `TLeafC` gives a `Vector{String}`.

A branch with more than one leaf holds them interleaved, so `leaf` says which
one to pull out; with a single leaf — the usual case — it can be left off.

A branch holding streamed objects rather than numbers is read by
[`object_array`](@ref), and gives whatever shape the C++ type has — a
`NamedTuple` for a class, a `Vector` for an STL container.

The whole branch is materialised. To fold over a branch larger than memory,
iterate [`eachchunk`](@ref) instead.
"""
function array(b::AnyBranch, leafname::Union{Nothing,AbstractString}=nothing)
    if isobjectbranch(b)
        _checkleafname(b, leafname)
        return object_array(b)
    end
    l, walk, counts, n = _plan(b, leafname)
    l isa TLeafC && return _read_strings(b, l, walk, counts, n)
    isjagged(l) && return _read_jagged(b, l, walk, counts, n)
    v = _read_fixed(b, l, walk, counts, n)
    per = length(l)
    return per == 1 ? v : reshape(v, per, n)
end

array(t::AnyTree, name::AbstractString) = array(t[name])

"""
    _plan(b, leafname) -> (leaf, walk, counts, n)

Everything reading a branch needs settled before a byte of it is decoded: the
leaf asked for, the leaves that have to be stepped over to reach it, how many
values each of those holds in each entry, and how many entries there are.

`walk` is the leaves up to and including the one wanted, or all of them when
none varies in length — a leaf is always counted by one that comes before it,
which is what keeps a count leaf in the same branch from asking to be read by
itself.
"""
function _plan(b::AnyBranch, leafname)
    ls = leaves(b)
    i = _pickleaf(b, ls, leafname)
    l = ls[i]
    n = _nentries(b)
    head = @view ls[1:i]
    walk = any(isjagged, ls) ? head : ls
    return l, walk, _entrycounts(b, walk, n), n
end

"""
    _pickleaf(b, ls, leafname) -> Int

Where in `ls` the leaf `array` was asked for sits: the named one, or the only
one there is.

The position rather than the leaf, because the leaves before it have to be
stepped over to reach it — and because an index that was found is an index,
where searching for the leaf again would leave open the possibility that it is
not there.
"""
function _pickleaf(b::AnyBranch, ls::AbstractVector, leafname)
    if leafname === nothing
        length(ls) == 1 && return 1
        isempty(ls) && throw(
            ArgumentError("TTree: branch $(repr(Objects.name(b))) has no leaves to read"),
        )
        got = join((repr(Objects.name(l)) for l in ls), ", ")
        throw(
            ArgumentError(
                "TTree: branch $(repr(Objects.name(b))) has several leaves — name one of $got",
            ),
        )
    end
    for (i, l) in enumerate(ls)
        Objects.name(l) == leafname && return i
    end
    return throw(KeyError(leafname))
end

"""
    _checkleafname(b, leafname) -> nothing

Refuse a leaf name that names nothing in an object branch.

An object branch is read whole — its value is the object, not one leaf of it —
so a name is accepted only when it is the branch's own leaf, and is then no
more than a longer way of asking for the branch.
"""
function _checkleafname(b::AnyBranch, leafname)
    leafname === nothing && return nothing
    any(l -> Objects.name(l) == leafname, leaves(b)) && return nothing
    return throw(KeyError(leafname))
end

"""
    _nentries(b) -> Int

How many entries of `b` to read.

The tree has the last word on how many rows there are: a branch can carry
entries the tree was never told about, and ROOT ignores those too.
"""
function _nentries(b::AnyBranch)
    n = Int(entries(b))
    t = owner(b)
    return t === nothing ? n : min(n, Int(entries(t)))
end

# ---------------------------------------------------------------------------
# Entry lengths.

"""
    _entrycounts(b, ls, n) -> IdDict

For each leaf in `ls` whose length varies, the length of every entry, read from
the leaf that counts it.

The count could in principle be recovered from the basket's offset table by
dividing the span of an entry by the width of a value, but not always
correctly: a `Float16_t` occupies fewer bytes than its type says, so the
division would give the wrong answer for exactly the leaves that are hardest to
read. ROOT reads the count leaf; so does this.
"""
function _entrycounts(b::AnyBranch, ls::AbstractVector, n::Int)
    counts = IdDict{Any,Vector{Int}}()
    for l in ls
        c = countleaf(l)
        (c === nothing || haskey(counts, c)) && continue
        counts[c] = _readcounts(b, l, c, n)
    end
    return counts
end

function _readcounts(b::AnyBranch, l, c, n::Int)
    v = array(_countbranch(b, l, c), Objects.name(c))
    v isa AbstractVector{<:Integer} || throw(
        ArgumentError(
            "TTree: leaf $(repr(Objects.name(l))) is counted by $(repr(Objects.name(c))), which does not hold whole numbers",
        ),
    )
    length(v) >= n || throw(
        ArgumentError(
            "TTree: leaf $(repr(Objects.name(l))) needs $n counts but $(repr(Objects.name(c))) has $(length(v))",
        ),
    )
    return Int[Int(x) for x in v]
end

"""
    _countbranch(b, l, c) -> branch

The branch holding the leaf that counts `l`.

The count leaf is usually a column of its own, so the tree has to be searched
for it — by identity, since two branches may well hold leaves of the same name.
"""
function _countbranch(b::AnyBranch, l, c)
    any(x -> x === c, leaves(b)) && return b
    t = owner(b)
    if t !== nothing
        for other in allbranches(t)
            any(x -> x === c, leaves(other)) && return other
        end
    end
    return throw(
        ArgumentError(
            "TTree: leaf $(repr(Objects.name(l))) is counted by $(repr(Objects.name(c))), which is not in this tree",
        ),
    )
end

"""
    _entrycount(l, counts, e) -> Int

Number of values leaf `l` holds in entry `e`.

A leaf may vary in its first dimension and be fixed in the rest — `x[n][3]` —
in which case `len` is the fixed part and the count leaf gives the varying one,
so the two multiply. For the ordinary `x[n]` the fixed part is one and this is
just the count.
"""
function _entrycount(l, counts::IdDict{Any,Vector{Int}}, e::Int)
    c = countleaf(l)
    c === nothing && return length(l)
    return counts[c][e] * length(l)
end

# ---------------------------------------------------------------------------
# Reading.

"""
    read_values(r::RBuffer, leaf, n) -> Vector

`n` values of `leaf` from the cursor.

Most leaves are packed numbers and take the bulk path; a `Float16_t` or
`Double32_t` leaf is stored scaled into its declared range, so each value is
unpacked on its own.

A leaf whose values are not numbers at all — a string, a streamed object — is
refused here rather than reinterpreted: those are read by their own path, or
not yet read.
"""
read_values(r::RBuffer, l::PlainLeaf, n::Integer) = read_array(r, elementtype(l), n)

function read_values(r::RBuffer, l::TLeafF16, n::Integer)
    xmin, xmax, factor = _leaf_range(l)
    return Float32[read_float16(r, xmin, xmax, factor) for _ in 1:n]
end

function read_values(r::RBuffer, l::TLeafD32, n::Integer)
    xmin, xmax, factor = _leaf_range(l)
    return Float64[read_double32(r, xmin, xmax, factor) for _ in 1:n]
end

function read_values(::RBuffer, l, ::Integer)
    return throw(
        ArgumentError(
            "TTree: a $(typeof(l)) does not hold numbers, so its values are not read here"
        ),
    )
end

"""
    skip_leaf!(r::RBuffer, leaf, n) -> nothing

Step the cursor over `n` values of `leaf`.

A plain number has a width, so stepping over it is arithmetic. The two packed
leaves and a string do not — a `Float16_t` occupies fewer bytes than its type
suggests and a string as many as it happens to need — so those are decoded and
thrown away, which is the only width that is always right. Only a branch of
several leaves pays for any of this.
"""
function skip_leaf!(r::RBuffer, l, n::Integer)
    if l isa TLeafC
        read_tstring(r)
    elseif l isa Union{TLeafF16,TLeafD32}
        read_values(r, l, n)
    else
        skip!(r, Int(n) * sizeof(elementtype(l)))
    end
    return nothing
end

"""
    _foreachbasket(f, b, n) -> nothing

Call `f(bk, e0, m)` for each basket of `b` that carries entries the tree admits
to, where `m` of them start at entry `e0 + 1`.

A branch can hold entries past the end of its tree, and ROOT ignores those; so
does this, which is why the last basket may be taken only in part.
"""
function _foreachbasket(f, b::AnyBranch, n::Int)
    e = 0
    for bk in eachbasket(b)
        m = min(length(bk), n - e)
        m > 0 || continue
        f(bk, e, m)
        e += m
        e == n && break
    end
    return nothing
end

"""
    _eachentry(bk, b, l, ls, counts, e0, m, take) -> nothing

Walk `m` entries of one basket, calling `take(r, k)` with the cursor on leaf
`l`'s `k` values.

The leaves before `l` are stepped over, because an entry is its leaves run
together with nothing between them. When any leaf of the branch varies in
length the entries are found through the basket's offset table instead of by
reading forward, so the leaves *after* `l` never have to be looked at at all.
"""
function _eachentry(
    bk::Basket, b::AnyBranch, l, ls::AbstractVector, counts, e0::Int, m::Int, take
)
    seekable = any(isjagged, leaves(b))
    seekable &&
        !isjagged(bk) &&
        throw(
            ArgumentError(
                "TTree: a basket of branch $(repr(Objects.name(b))) has no entry offsets, so its entries cannot be found",
            ),
        )
    r = RBuffer(bk.data)
    for i in 1:m
        isjagged(bk) && seek!(r, bk.offsets[i] - 1)
        for other in ls
            k = _entrycount(other, counts, e0 + i)
            other === l ? take(r, k) : skip_leaf!(r, other, k)
        end
    end
    return nothing
end

"""
    _wholebasket(bk, l, k) -> Vector{T} or nothing

A basket read in one go as `k` values of `l`'s type, or `nothing` for a leaf
whose values are not stored that way and have to be walked one at a time.
"""
_wholebasket(::Basket, ::Any, ::Int) = nothing
function _wholebasket(bk::Basket, l::PlainLeaf, k::Int)
    return read_array(RBuffer(bk.data), elementtype(l), k)
end

"""
    _fixed(bk, b, l, ls, counts, e0, m) -> Vector{T}

One basket's worth of a fixed-length leaf, entries end to end.
"""
function _fixed(bk::Basket, b::AnyBranch, l, ls::AbstractVector, counts, e0::Int, m::Int)
    per = length(l)
    if length(leaves(b)) == 1
        # The common case: the branch's only leaf, plain numbers, so an entry
        # is its values and nothing else — the whole basket in one read.
        v = _wholebasket(bk, l, per * m)
        v === nothing || return v
    end
    T = elementtype(l)
    out = Vector{T}(undef, 0)
    sizehint!(out, per * m)
    _eachentry(bk, b, l, ls, counts, e0, m, (r, k) -> append!(out, read_values(r, l, k)))
    return out
end

"""
    _jagged(bk, b, l, ls, counts, e0, m) -> Vector{Vector{T}}

One basket's worth of a variable-length leaf.
"""
function _jagged(bk::Basket, b::AnyBranch, l, ls::AbstractVector, counts, e0::Int, m::Int)
    out = Vector{Vector{elementtype(l)}}(undef, 0)
    sizehint!(out, m)
    _eachentry(bk, b, l, ls, counts, e0, m, (r, k) -> push!(out, read_values(r, l, k)))
    return out
end

"""
    _strings(bk, b, l, ls, counts, e0, m) -> Vector{String}

One basket's worth of a `TLeafC`, which ROOT stores as a length and that many
characters — the same encoding as a `TString`, and self-delimiting.
"""
function _strings(bk::Basket, b::AnyBranch, l, ls::AbstractVector, counts, e0::Int, m::Int)
    out = Vector{String}(undef, 0)
    sizehint!(out, m)
    _eachentry(bk, b, l, ls, counts, e0, m, (r, _) -> push!(out, read_tstring(r)))
    return out
end

"The chunk of values `bk` holds, shaped as [`array`](@ref) shapes a branch."
function _chunk(bk::Basket, b::AnyBranch, l, ls::AbstractVector, counts, e0::Int, m::Int)
    l isa TLeafC && return _strings(bk, b, l, ls, counts, e0, m)
    isjagged(l) && return _jagged(bk, b, l, ls, counts, e0, m)
    v = _fixed(bk, b, l, ls, counts, e0, m)
    per = length(l)
    return per == 1 ? v : reshape(v, per, m)
end

function _read_fixed(b::AnyBranch, l, ls::AbstractVector, counts, n::Int)
    out = Vector{elementtype(l)}(undef, 0)
    sizehint!(out, length(l) * n)
    _foreachbasket(b, n) do bk, e0, m
        return append!(out, _fixed(bk, b, l, ls, counts, e0, m))
    end
    return out
end

function _read_jagged(b::AnyBranch, l, ls::AbstractVector, counts, n::Int)
    out = Vector{Vector{elementtype(l)}}(undef, 0)
    sizehint!(out, n)
    _foreachbasket(b, n) do bk, e0, m
        return append!(out, _jagged(bk, b, l, ls, counts, e0, m))
    end
    return out
end

function _read_strings(b::AnyBranch, l, ls::AbstractVector, counts, n::Int)
    out = Vector{String}(undef, 0)
    sizehint!(out, n)
    _foreachbasket(b, n) do bk, e0, m
        return append!(out, _strings(bk, b, l, ls, counts, e0, m))
    end
    return out
end

# ---------------------------------------------------------------------------
# Streaming.

"""
    BranchChunks

A branch's values a basket at a time. Built by [`eachchunk`](@ref).

The plan — which leaves to walk, how long their entries are — is made once,
when the iterator is built, because it is the same for every basket. What is
deferred is the reading: a basket is fetched, decoded and handed over, and
nothing holds on to it afterwards.
"""
struct BranchChunks{B<:AnyBranch,L}
    branch::B
    leaf::L
    walk::Vector{Any}
    counts::IdDict{Any,Vector{Int}}
    n::Int
end

"""
    eachchunk(branch) -> iterator
    eachchunk(branch, leaf::AbstractString) -> iterator
    eachchunk(tree, name::AbstractString) -> iterator

A branch's values one basket at a time, each chunk shaped the way
[`array`](@ref) shapes a whole branch.

This is the streaming path: only the basket in hand is materialised, so a
column far larger than memory can be folded over. Concatenating the chunks —
`vcat` for a vector, `hcat` for the matrix a fixed-length leaf gives — gives
back exactly what `array` returns.

```julia
total = 0.0
for v in eachchunk(tree, "energy")
    total += sum(v)
end
```

A variable-length leaf is counted by another leaf, usually in a branch of its
own; that column of counts is read in full when the iterator is built, since
finding where entry `n` begins is what it is for. It is one integer per entry
against however many values per entry the branch itself holds.

A branch of objects gives [`ObjectChunks`](@ref), whose values are the ones
[`object_array`](@ref) reads. A split branch is the one case where a chunk is
not a basket: its members' baskets belong to its children, so there is nothing
to hand over one at a time and its single chunk is the whole column.
"""
function eachchunk(b::AnyBranch, leafname::Union{Nothing,AbstractString}=nothing)
    if isobjectbranch(b)
        _checkleafname(b, leafname)
        return object_chunks(b)
    end
    l, walk, counts, n = _plan(b, leafname)
    return BranchChunks(b, l, Any[x for x in walk], counts, n)
end

eachchunk(t::AnyTree, name::AbstractString) = eachchunk(t[name])

Base.IteratorSize(::Type{<:BranchChunks}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:BranchChunks}) = Base.EltypeUnknown()

function Base.iterate(c::BranchChunks, state=(1, 0))
    i, e = state
    nb = nbaskets(c.branch)
    while i <= nb && e < c.n
        bk = basket(c.branch, i)
        m = min(length(bk), c.n - e)
        if m == 0
            i += 1
            continue
        end
        chunk = _chunk(bk, c.branch, c.leaf, c.walk, c.counts, e, m)
        return chunk, (i + 1, e + m)
    end
    return nothing
end

function Base.show(io::IO, c::BranchChunks)
    return print(
        io,
        "BranchChunks(",
        repr(Objects.name(c.branch)),
        ", ",
        c.n,
        " entries in ",
        nbaskets(c.branch),
        " baskets)",
    )
end
