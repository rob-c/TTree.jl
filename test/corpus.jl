# Locating the corpus of ROOT files the tree tests read, and the reference
# answers they are checked against.
#
# The files themselves are not part of this package: they are the go-hep/groot
# corpus, which is where the format's awkward cases are already collected —
# packed floats, multidimensional slices, a basket left unflushed inside its
# branch. Copying several megabytes of another project's fixtures in here would
# be worse than pointing at them, so the tests that need them run when they are
# present and are skipped, loudly, when they are not. Point `TTREE_TESTDATA` at
# the directory to say where they live.
#
# What ROOT says about those files *is* checked in, under `data/`, because that
# is what makes the comparison possible on a machine with no ROOT installed.
# Regenerate it with `dev/gen_corpus_reference.jl`.

using Dates: DateTime

using TTree
using TTree.IOFS
using TTree.Objects
using TTree.Trees

"Directory holding the corpus, whether or not it exists."
function corpus_dir()
    return get(
        ENV,
        "TTREE_TESTDATA",
        normpath(joinpath(@__DIR__, "..", "..", "go-hep", "groot", "testdata")),
    )
end

"Whether the corpus is where [`corpus_dir`](@ref) says it is."
have_corpus() = isdir(corpus_dir())

"Every `.root` file in the corpus, sorted, as bare file names."
corpus_files() = sort(filter(f -> endswith(f, ".root"), readdir(corpus_dir())))

"""
    treepaths(f) -> Vector{Tuple{String,String}}

Every tree in an open file as `(path, class)`, descending into subdirectories.
The path is what `f[path]` takes.
"""
function treepaths(f, d=f.dir, prefix="")
    out = Tuple{String,String}[]
    for k in d.keys
        nm = prefix * k.name
        if k.class == "TDirectoryFile"
            append!(out, treepaths(f, IOFS.read_object(f, k), nm * "/"))
        elseif k.class in ("TTree", "TNtuple", "TNtupleD")
            push!(out, (nm, k.class))
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Leaf digests.
#
# A leaf's values are reduced to one number so that ROOT's answer for all 375 of
# them fits in a checked-in file a few lines long. The reduction is FNV-1a over
# a canonical encoding — big-endian values, each entry prefixed by its length —
# which makes it independent of the host's byte order and sensitive to exactly
# what the tests care about: the values, their type, and where one entry ends
# and the next begins.
#
# It compares bit patterns, so it is stricter than `==` on a NaN. No leaf in the
# corpus holds one; if that ever changes, this is where it would show up.

const _FNV_OFFSET = 0xcbf29ce484222325
const _FNV_PRIME = 0x00000100000001b3

@inline _fnv(h::UInt64, b::UInt8) = (h ⊻ UInt64(b)) * _FNV_PRIME

@inline function _fnv_be(h::UInt64, x::Unsigned, nbytes::Integer)
    for k in (Int(nbytes) - 1):-1:0
        h = _fnv(h, UInt8((UInt64(x) >> (8 * k)) & 0xff))
    end
    return h
end

_digest(h::UInt64, x::Bool) = _fnv_be(h, UInt8(x), 1)
_digest(h::UInt64, x::Unsigned) = _fnv_be(h, x, sizeof(x))
_digest(h::UInt64, x::Signed) = _fnv_be(h, reinterpret(unsigned(typeof(x)), x), sizeof(x))
_digest(h::UInt64, x::Float32) = _fnv_be(h, reinterpret(UInt32, x), 4)
_digest(h::UInt64, x::Float64) = _fnv_be(h, reinterpret(UInt64, x), 8)

function _digest(h::UInt64, s::AbstractString)
    h = _fnv_be(h, UInt32(ncodeunits(s)), 4)
    for b in codeunits(s)
        h = _fnv(h, b)
    end
    return h
end

"""
    leafdigest(entries) -> UInt64

Reduce a leaf — an iterable of entries, each an iterable of values — to a single
number. See the note above for what it is and is not sensitive to.
"""
function leafdigest(entries)
    h = _FNV_OFFSET
    for v in entries
        h = _fnv_be(h, UInt32(length(v)), 4)
        for x in v
            h = _digest(h, x)
        end
    end
    return h
end

# The shapes `Trees.array` returns, viewed uniformly as entries of values.
entrycount(v::AbstractVector) = length(v)
entrycount(m::AbstractMatrix) = size(m, 2)

entryvalues(v::AbstractVector, i::Integer) = (v[i],)
entryvalues(v::AbstractVector{<:AbstractVector}, i::Integer) = v[i]
entryvalues(m::AbstractMatrix, i::Integer) = @view m[:, i]

"A leaf's values as [`leafdigest`](@ref) wants them, whatever shape it came in."
asentries(a) = (entryvalues(a, i) for i in 1:entrycount(a))

# ---------------------------------------------------------------------------
# Object digests.
#
# An object branch holds a C++ object rather than a number, so there is nothing
# as simple as a leaf's value list to compare. What is compared instead is a
# canonical spelling of the whole object — one that names every member and
# every nesting level, so that a member read at the wrong width, in the wrong
# order, or into the wrong shape all show up as different text.
#
#     i<dec>            a signed integer
#     u<dec>            an unsigned integer
#     b0 / b1           a bool
#     f<8 hex digits>   a float, as its bit pattern
#     d<16 hex digits>  a double, as its bit pattern
#     s<len>:<bytes>    a string, TString or std::string alike
#     t<dec>            a TDatime, as the packed number ROOT stores
#     [<n>:<values>]    a sequence: a container, a fixed array, a counted member
#     {<n>:<name>=<v>…} an object, its base classes named as members
#
# Floats go out as bit patterns because a decimal spelling would compare two
# roundings rather than two values. `dev/gen_corpus_objects.jl` writes the same
# spelling from the C++ side; the two are only useful together.

"C's ordering of a member's values — the order ROOT streams a `[2][3]` in."
_corder(v::AbstractVector) = v
function _corder(a::AbstractArray{<:Any,N}) where {N}
    return vec(permutedims(a, ntuple(i -> N - i + 1, N)))
end

_canon(io::IO, x::Bool) = print(io, x ? "b1" : "b0")
_canon(io::IO, x::Signed) = print(io, 'i', x)
_canon(io::IO, x::Unsigned) = print(io, 'u', x)
_canon(io::IO, x::Float32) = print(io, 'f', string(reinterpret(UInt32, x); base=16, pad=8))
_canon(io::IO, x::Float64) = print(io, 'd', string(reinterpret(UInt64, x); base=16, pad=16))
_canon(io::IO, s::AbstractString) = print(io, 's', ncodeunits(s), ':', s)
_canon(io::IO, t::DateTime) = print(io, 't', TTree.Bytes.datetime_to_datime(t))

function _canon(io::IO, a::AbstractArray)
    print(io, '[', length(a), ':')
    for x in _corder(a)
        _canon(io, x)
    end
    return print(io, ']')
end

function _canon(io::IO, nt::NamedTuple)
    print(io, '{', length(nt), ':')
    for (k, x) in pairs(nt)
        print(io, k, '=')
        # The top byte of a TObject's fBits is memory state — kIsOnHeap and
        # kNotDeleted are set by ROOT's constructor and never written — so only
        # the stored bits are compared.
        _canon(io, k === :fBits ? x & 0x00ffffff : x)
    end
    return print(io, '}')
end

"""
    objectcanon(entries; unordered=false) -> String

One object branch, every entry after another, in the canonical spelling above.

`unordered` is for a branch holding an `unordered_set` or `unordered_map`,
where there is no order to compare: what ROOT iterates is the bucket order its
own hash produced while reading, not the order the elements were written in.
Its entries are spelled with their elements sorted, which is what
`dev/gen_corpus_objects.jl` does for the same containers. Nothing distinguishes
such a container from an ordered one once it has been read — both are a
`Vector` — so the caller says which it was, from the class name the reference
records.
"""
function objectcanon(entries; unordered::Bool=false)
    return sprint() do io
        for v in entries
            unordered ? _canon_unordered(io, v) : _canon(io, v)
        end
    end
end

function _canon_unordered(io::IO, a::AbstractVector)
    parts = sort!([sprint(_canon, x) for x in a])
    print(io, '[', length(a), ':')
    for p in parts
        print(io, p)
    end
    return print(io, ']')
end

"FNV-1a over a canonical spelling, which is how the reference file records it."
function objectdigest(s::AbstractString)
    h = _FNV_OFFSET
    for b in codeunits(s)
        h = _fnv(h, b)
    end
    return h
end

# ---------------------------------------------------------------------------
# The reference files.

"""
    reference(name) -> Vector{Vector{String}}

The tab-separated rows of a file under `test/data`, comments and blanks dropped.
"""
function reference(name::AbstractString)
    rows = Vector{String}[]
    for line in eachline(joinpath(@__DIR__, "data", name))
        (isempty(line) || startswith(line, '#')) && continue
        push!(rows, String.(split(line, '\t')))
    end
    return rows
end
