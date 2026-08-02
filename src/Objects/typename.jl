# Reading a C++ type name.
#
# An STL container's streamer info does not say what the container holds. ROOT
# describes `std::vector<double>` with a single element named "This" whose type
# code is 500 — the very same element, but for its type *name*, that describes
# `std::map<std::string,std::vector<int> >`. The name is the description, so
# decoding a container means parsing C++.
#
# Only as much C++ as a type name can contain: an identifier, possibly
# qualified, possibly followed by template arguments. Nothing here is a parser
# in any larger sense, and nothing needs one — a name is all a container's
# layout depends on.

"""
    CppType

A C++ type name split into its head and its template arguments.

`bitset<8>`'s argument is the literal `8` rather than a type, so an argument is
kept as a `CppType` of its own with no arguments and read as a number where one
is wanted.
"""
struct CppType
    name::String
    args::Vector{CppType}
end

CppType(name::AbstractString) = CppType(String(name), CppType[])

Base.:(==)(a::CppType, b::CppType) = a.name == b.name && a.args == b.args
Base.hash(t::CppType, h::UInt) = hash(t.args, hash(t.name, h))
Base.show(io::IO, t::CppType) = print(io, "CppType(", repr(cppname(t)), ")")

"""
    parse_typename(s) -> CppType

Break a C++ type name into its head and its template arguments.

Spellings of the same type are folded together: `std::` and its inline
namespaces are dropped, whitespace is normalised, `basic_string<…>` becomes
`string`, and a trailing `*` or `&` is discarded — whether a member is a
pointer is in its streamer code, not in the name a container carries.

```jldoctest
julia> TTree.Objects.parse_typename("std::map<std::string, std::vector<int> >")
CppType("map<string,vector<int> >")
```
"""
function parse_typename(s::AbstractString)
    t, _ = _read_type(String(s), 1)
    return t
end

"""
    _read_type(s, i) -> (CppType, Int)

Read one type starting at index `i`, returning it and the index just past it.

A type ends at a comma or a closing angle bracket, both of which are consumed
by whoever opened the list; `>>` at the end of a nested template therefore
needs no special handling, each `>` closing the list that asked for it.
"""
function _read_type(s::String, i::Int)
    n = ncodeunits(s)
    j = i
    while j <= n
        c = s[j]
        (c == '<' || c == ',' || c == '>') && break
        j = nextind(s, j)
    end
    head = _normalise(SubString(s, i, prevind(s, j)))
    args = CppType[]
    if j <= n && s[j] == '<'
        j = nextind(s, j)
        while true
            a, j = _read_type(s, j)
            push!(args, a)
            j > n && break
            c = s[j]
            j = nextind(s, j)
            c == ',' || break
        end
    end
    # `basic_string<char, …>` is `string`, and its arguments say only that it
    # is the ordinary one — a container's element type, not the string's.
    head == "string" && return CppType("string"), j
    return CppType(head, args), j
end

"The namespaces a name may be qualified with that say nothing about its layout."
const _NAMESPACES = ("std::__1::", "std::__cxx11::", "std::", "__gnu_cxx::")

"Words that may precede a type name and are not part of it."
const _QUALIFIERS = ("class ", "struct ", "enum ", "const ", "volatile ")

"""
    _normalise(s) -> String

One type name in the spelling this package matches on.

The point is that `std::vector`, `vector` and `class std::vector` are the same
container, and that `unsigned int` is one name with a space in it rather than
two names — so whitespace is collapsed but not removed.
"""
function _normalise(s::AbstractString)
    t = strip(s)
    changed = true
    while changed
        changed = false
        for q in _QUALIFIERS
            if startswith(t, q)
                t = strip(t[(ncodeunits(q) + 1):end])
                changed = true
            end
        end
    end
    while !isempty(t) && (last(t) == '*' || last(t) == '&' || isspace(last(t)))
        t = strip(t[1:prevind(t, lastindex(t))])
    end
    for ns in _NAMESPACES
        t = replace(t, ns => "")
    end
    t = join(split(t), " ")
    t == "basic_string" && return "string"
    return t
end

"""
    cppname(t::CppType) -> String

Spell a type back the way ROOT spells it, which is how the class it names has
to be looked up: no space around a comma, and one before a closing bracket that
would otherwise follow another — `pair<int,vector<short> >`.
"""
function cppname(t::CppType)
    isempty(t.args) && return t.name
    inner = join((cppname(a) for a in t.args), ',')
    return string(t.name, '<', inner, endswith(inner, '>') ? " >" : ">")
end

"""
    CPP_SCALARS

The C++ spellings of a number and the width ROOT streams each with.

`long` maps to 64 bits regardless of the platform's `long`, because that is
what ROOT writes; `Double32_t` and `Float16_t` are here as the types they are
*read back* as, their storage being narrower and handled where they are read.
"""
const CPP_SCALARS = Dict{String,DataType}(
    "bool" => Bool,
    "Bool_t" => Bool,
    "char" => Int8,
    "signed char" => Int8,
    "Char_t" => Int8,
    "int8_t" => Int8,
    "unsigned char" => UInt8,
    "UChar_t" => UInt8,
    "Byte_t" => UInt8,
    "uint8_t" => UInt8,
    "short" => Int16,
    "short int" => Int16,
    "Short_t" => Int16,
    "Version_t" => Int16,
    "int16_t" => Int16,
    "unsigned short" => UInt16,
    "unsigned short int" => UInt16,
    "UShort_t" => UInt16,
    "uint16_t" => UInt16,
    "int" => Int32,
    "Int_t" => Int32,
    "Seek_t" => Int32,
    "int32_t" => Int32,
    "unsigned" => UInt32,
    "unsigned int" => UInt32,
    "UInt_t" => UInt32,
    "uint32_t" => UInt32,
    "long" => Int64,
    "long int" => Int64,
    "Long_t" => Int64,
    "long long" => Int64,
    "long long int" => Int64,
    "Long64_t" => Int64,
    "int64_t" => Int64,
    "unsigned long" => UInt64,
    "unsigned long int" => UInt64,
    "ULong_t" => UInt64,
    "unsigned long long" => UInt64,
    "unsigned long long int" => UInt64,
    "ULong64_t" => UInt64,
    "uint64_t" => UInt64,
    "float" => Float32,
    "Float_t" => Float32,
    "double" => Float64,
    "Double_t" => Float64,
)

"""
    cpp_scalar(name) -> Union{DataType,Nothing}

The Julia type a C++ scalar name streams as, or `nothing` if the name is not a
number's.
"""
cpp_scalar(name::AbstractString) = get(CPP_SCALARS, name, nothing)

"The container names whose elements follow one after another."
const CPP_SEQUENCES = (
    "vector",
    "list",
    "deque",
    "forward_list",
    "set",
    "multiset",
    "unordered_set",
    "unordered_multiset",
    "ROOT::VecOps::RVec",
    "RVec",
)

"The container names whose elements are key–value pairs."
const CPP_MAPS = ("map", "multimap", "unordered_map", "unordered_multimap")

"Whether `t` names a container this package reads as a sequence of values."
is_sequence(t::CppType) = t.name in CPP_SEQUENCES && length(t.args) >= 1

"Whether `t` names a container this package reads as a sequence of pairs."
is_map(t::CppType) = t.name in CPP_MAPS && length(t.args) >= 2

"Whether `t` names an STL container at all."
function is_container(t::CppType)
    return is_sequence(t) || is_map(t) || t.name == "bitset" || t.name == "string"
end
